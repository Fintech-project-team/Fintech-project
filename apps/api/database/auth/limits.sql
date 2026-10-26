-- 트랜잭션 조건·행 잠금과 IP/조합 요청 제한 함수를 정의한다.
-- 2026-10-26: 003_auth_access.sql에서 목적별로 분리. 해당 진입점의 단일 트랜잭션에서만 실행한다.
-- 순서: 3/5. 단독 실행하거나 트랜잭션 제어 BEGIN/COMMIT을 추가하지 않는다.

-- 2026-10-25: 잠금 뒤 최신 행을 읽을 수 있는 READ COMMITTED·읽기/쓰기 환경을 요구한다.
-- 사용: auth_lock_limit, auth_credentials, auth_authorize. 명시적 BEGIN 여부를 판별하는 함수는 아니다.
CREATE FUNCTION payse.auth_require_transaction()
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, payse, pg_temp
AS $$
BEGIN
  -- 다른 격리 수준이나 읽기 전용이면 잠금 후 최신 상태 확인을 보장할 수 없어 25000으로 거절한다.
  IF current_setting('transaction_isolation') <> 'read committed'
    OR current_setting('transaction_read_only') <> 'off' THEN
    RAISE EXCEPTION 'Auth requires a read committed read-write transaction' USING ERRCODE = '25000';
  END IF;
END $$;

-- 2026-10-25: 제한 키의 최초 행을 준비하고 같은 키 요청을 행 잠금으로 직렬화한다.
-- 사용: auth_ip_request, auth_combo_state. 반환한 행의 잠금은 호출자 트랜잭션 종료까지 유지된다.
CREATE FUNCTION payse.auth_lock_limit(limit_kind text, digest text)
RETURNS payse.auth_rate_limits
LANGUAGE plpgsql
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  state payse.auth_rate_limits;
BEGIN
  -- 현재 트랜잭션의 격리 수준과 쓰기 가능 여부를 먼저 확인한다.
  PERFORM payse.auth_require_transaction();
  -- 종류와 64자리 소문자 HMAC 키 형식을 확인하고 원문을 오류에 넣지 않는다.
  IF limit_kind IS NULL
    OR limit_kind NOT IN ('combo', 'ip')
    OR digest IS NULL
    OR digest COLLATE "C" !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid auth limit key' USING ERRCODE = '22023';
  END IF;
  -- 최초 요청의 빈 행만 만든다. 같은 키의 동시 삽입은 PK 충돌 처리로 기존 행을 유지한다.
  INSERT INTO payse.auth_rate_limits(kind, key_digest, event_times)
    VALUES(limit_kind, digest, ARRAY[]::timestamptz[])
    ON CONFLICT DO NOTHING;
  -- 대상이 정확히 한 행인지 확인하며 잠근다. 다음 요청은 이 트랜잭션이 끝날 때까지 기다린다.
  SELECT *
  INTO STRICT state
  FROM payse.auth_rate_limits
  WHERE kind = limit_kind
    AND key_digest = digest
  FOR UPDATE;
  -- 저장된 마지막 사건보다 DB 시계가 뒤로 갔으면 잘못된 제한 판정을 막기 위해 실패시킨다.
  IF cardinality(state.event_times)>0
    AND state.event_times[cardinality(state.event_times)]>clock_timestamp() THEN
    RAISE EXCEPTION 'Auth clock moved backwards' USING ERRCODE = '55000';
  END IF;
  -- 잠근 제한 행을 호출 함수에 전달한다. 여기서 커밋하거나 잠금을 해제하지 않는다.
  RETURN state;
END $$;

-- 2026-10-25: 성공·오류·거절을 포함한 IP별 인증 요청을 기록하고 허용 여부·재시도 시각을 반환한다.
-- 사용: AuthRepository.recordIp. 본문/Bearer 검사 전에 호출하고 별도 선행 트랜잭션을 커밋한다.
CREATE FUNCTION payse.auth_ip_request(digest text)
RETURNS TABLE(allowed boolean, retry_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  state payse.auth_rate_limits;
  observed_at timestamptz;
  events timestamptz[];
BEGIN
  -- 동일 IP 키의 행을 먼저 잠그고 대기 종료 뒤 현재 DB 시각을 읽는다.
  state := payse.auth_lock_limit('ip', digest);
  observed_at := clock_timestamp();
  -- 최근 60초의 열린 하한(now−60초)보다 뒤인 사건만 순서를 유지해 남긴다.
  SELECT coalesce(array_agg(at ORDER BY position), ARRAY[]::timestamptz[])
  INTO events
  FROM unnest(state.event_times) WITH ORDINALITY e(at, position)
  WHERE at > observed_at - interval '60 seconds';
  -- 새 사건을 넣기 전 60건 미만인 요청까지만 허용한다.
  allowed := cardinality(events)<60;
  -- 거절 요청도 기록한다. 61개가 되면 가장 오래된 사건을 빼 최근 60개를 유지한다.
  events := array_append(events, observed_at);
  IF cardinality(events)>60 THEN
    events := events[2:61];
  END IF;
  -- 허용은 null, 거절은 현재 가장 오래된 저장 사건의 60초 창이 끝나는 시각을 반환한다.
  retry_at := CASE WHEN allowed THEN NULL ELSE events[1]+interval '60 seconds' END;
  -- 이 IP 키의 사건 목록만 저장한다. 커밋 책임은 호출자에게 있다.
  UPDATE payse.auth_rate_limits
  SET event_times = events
  WHERE kind = 'ip'
    AND key_digest = digest;
  -- 허용 여부와 재시도 시각을 한 행으로 돌려준다.
  RETURN NEXT;
END $$;

-- 2026-10-25: 조합 키를 잠그고 만료된 실패 창·차단만 정리해 관측 시각과 상태를 반환한다.
-- 사용: auth_limit, auth_failure. 코드 비교·후속 세션 처리도 같은 트랜잭션에서 이어가야 한다.
CREATE FUNCTION payse.auth_combo_state(digest text)
RETURNS TABLE(observed_at timestamptz, events timestamptz[], retry_at timestamptz)
LANGUAGE plpgsql
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  state payse.auth_rate_limits;
BEGIN
  -- 조합 행을 잠근 뒤 현재 시각·실패 이력·차단 기한을 읽는다.
  state := payse.auth_lock_limit('combo', digest);
  observed_at := clock_timestamp();
  events := state.event_times;
  retry_at := state.blocked_until;
  -- 차단 기한에 도달했으면 이전 실패 창과 차단을 함께 비운다.
  IF retry_at IS NOT NULL AND retry_at <= observed_at THEN
    events := ARRAY[]::timestamptz[];
    retry_at := NULL;
  -- 차단되지 않은 경우에만 5분 창 하한 이하의 오래된 실패를 제거한다.
  ELSIF retry_at IS NULL THEN
    -- 남은 실패의 순서를 유지하고 사건이 없으면 null 대신 빈 배열로 만든다.
    SELECT coalesce(array_agg(at ORDER BY position), ARRAY[]::timestamptz[])
    INTO events
    FROM unnest(events) WITH ORDINALITY e(at, position)
    WHERE at > observed_at - interval '5 minutes';
  END IF;
  -- 만료 정리 결과만 저장한다. 진행 중인 차단의 사건·기한은 그대로다.
  UPDATE payse.auth_rate_limits
  SET event_times = events,
      blocked_until = retry_at
  WHERE kind = 'combo'
    AND key_digest = digest;
  -- 관측 시각·정리된 사건·차단 기한을 한 행으로 반환하며 잠금은 트랜잭션에 남긴다.
  RETURN NEXT;
END $$;

-- 2026-10-25: 조합 차단 종료 시각을 조회하며 null은 미차단을 뜻한다.
-- 사용: AuthRepository.retryAt. 인증 성공을 뜻하지 않으며 정상 대조만으로 실패 기록을 지우지 않는다.
CREATE FUNCTION payse.auth_limit(digest text)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  retry_at timestamptz;
BEGIN
  -- 같은 조합 행을 잠그고 만료 상태를 정리한 결과에서 차단 기한을 읽는다.
  SELECT state.retry_at
  INTO retry_at
  FROM payse.auth_combo_state(digest) state;
  -- 차단 시각 또는 null만 반환한다. 성공 대조를 이유로 실패 기록을 지우지 않는다.
  RETURN retry_at;
END $$;

-- 2026-10-25: 자격 대조 실패를 한 번 기록하고 차단 종료 시각 또는 null을 반환한다.
-- 사용: AuthRepository.recordFailure. 거절도 정상 반환하므로 호출자가 기록을 커밋한 뒤 HTTP 오류로 바꾼다.
CREATE FUNCTION payse.auth_failure(digest text)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  state record;
BEGIN
  -- 조합 행을 잠그고 만료 정리 후 상태를 정확히 한 행으로 받는다.
  SELECT *
  INTO STRICT state
  FROM payse.auth_combo_state(digest);
  -- 이미 차단 중이면 새 사건을 추가하지 않고 기존 기한을 그대로 반환한다.
  IF state.retry_at IS NOT NULL THEN
    RETURN state.retry_at;
  END IF;
  -- 이번 자격 대조 실패를 관측 시각으로 한 번 추가한다.
  state.events := array_append(state.events, state.observed_at);
  -- 다섯 번째 실패부터 그 시각+5분으로 차단한다.
  IF cardinality(state.events) = 5 THEN
    state.retry_at := state.observed_at+interval '5 minutes';
  END IF;
  -- 실패 이력과 차단 기한을 같은 행 갱신으로 저장한다.
  UPDATE payse.auth_rate_limits
  SET event_times = state.events,
      blocked_until = state.retry_at
  WHERE kind = 'combo'
    AND key_digest = digest;
  -- 실패 기록을 커밋할 수 있도록 예외가 아닌 결과를 반환한다.
  RETURN state.retry_at;
END $$;
