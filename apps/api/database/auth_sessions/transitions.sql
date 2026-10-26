-- 2026-10-26: 사용자 잠금 아래 자격 재조회·세션 생성·명시 종료를 정의한다.
-- 호출: 004_auth_sessions.sql의 두 번째 단계. 기존 세션의 만료 정책이나 금융 버전은 바꾸지 않는다.

-- 2026-10-26: 로그인 후보의 사용자 행을 잠근 뒤 현재 자격 검증값을 다시 읽는다.
-- 사용: AuthRepository.lockCode → AuthService. 코드 비교는 Java가 수행하며 이 조회만으로 인증되지 않는다.
CREATE FUNCTION payse.auth_login_account(input_name text, input_phone text)
RETURNS TABLE(user_id uuid, name text, code_verifier text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  candidate_id uuid;
BEGIN
  PERFORM payse.auth_require_transaction();
  PERFORM set_config('payse.user_id', '', true);

  IF input_name IS NULL
    OR input_phone IS NULL
    OR input_name COLLATE "C" !~ '^[가-힣A-Za-z]{2,20}$'
    OR input_phone COLLATE "C" !~ '^010[0-9]{8}$' THEN
    RAISE EXCEPTION 'Invalid normalized credentials' USING ERRCODE = '22023';
  END IF;

  -- 최초 조회는 잠글 후보만 고른다. 기다리는 동안 자격이 바뀌면 아래 재조회에서 거절한다.
  SELECT u.id
  INTO candidate_id
  FROM payse.users u
  WHERE u.name = input_name
    AND u.phone = input_phone;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  PERFORM u.id
  FROM payse.users u
  WHERE u.id = candidate_id
  FOR UPDATE;

  -- 비활성·DISABLED도 비교 후보로 유지한다. 정확한 자격의 상태 거절은 조합 실패와 구별한다.
  RETURN QUERY
    SELECT u.id, u.name, u.code_verifier
    FROM payse.users u
    WHERE u.id = candidate_id
      AND u.name = input_name
      AND u.phone = input_phone;
END $$;

-- 2026-10-26: 코드 대조를 끝낸 사용자의 활성 상태·세션을 잠금 뒤 확인하고 한 세션만 생성한다.
-- 사용: AuthRepository.openSession → AuthService. 같은 트랜잭션의 잠긴 자격을 대조한 뒤 호출한다.
CREATE FUNCTION payse.auth_open_session(owner_id uuid, digest text)
RETURNS TABLE(user_id uuid, session_id uuid, name text, issued_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
BEGIN
  PERFORM payse.auth_require_transaction();
  PERFORM set_config('payse.user_id', '', true);

  IF owner_id IS NULL
    OR digest IS NULL
    OR digest COLLATE "C" !~ '^sha256:[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid session input' USING ERRCODE = '22023';
  END IF;

  -- 로그인·로그아웃·비활성화·금융 작업 모두 같은 사용자 행으로 실행 순서를 맞춘다.
  PERFORM u.id
  FROM payse.users u
  WHERE u.id = owner_id
  FOR UPDATE;

  SELECT u.id, u.name
  INTO user_id, name
  FROM payse.users u
  WHERE u.id = owner_id
    AND u.deactivated_at IS NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- 기존 세션을 끊지 않으며, 잠금 대기 뒤 새로 커밋된 세션까지 확인한다.
  IF EXISTS (
    SELECT 1
    FROM payse.demo_sessions s
    WHERE s.user_id = owner_id
      AND s.ended_at IS NULL
  ) THEN
    RETURN;
  END IF;

  session_id := gen_random_uuid();
  issued_at := clock_timestamp();

  INSERT INTO payse.demo_sessions (
    id,
    user_id,
    token_digest,
    issued_at
  ) VALUES (
    session_id,
    owner_id,
    digest,
    issued_at
  );

  -- 반환은 아직 커밋 전이다. AuthTransactions의 커밋 성공 이후에만 응답용 토큰을 전달한다.
  RETURN NEXT;
END $$;

-- 2026-10-26: 검증된 현재 세션 한 건만 명시 종료하고 사용자 문맥을 비운다.
-- 사용: AuthRepository.endSession → AuthService. 무효/종료 토큰은 false이며 재로그인이나 금융 변경은 하지 않는다.
CREATE FUNCTION payse.auth_end_session(digest text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  owner_id uuid;
  active_id uuid;
  changed_count bigint;
BEGIN
  -- 기존 함수가 이전 문맥을 비우고 사용자 잠금 뒤 계정·세션을 재검증한다.
  SELECT a.user_id, a.session_id
  INTO owner_id, active_id
  FROM payse.auth_authorize(digest) a;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE payse.demo_sessions s
  SET ended_at = clock_timestamp()
  WHERE s.id = active_id
    AND s.user_id = owner_id
    AND s.token_digest = digest
    AND s.ended_at IS NULL;

  GET DIAGNOSTICS changed_count = ROW_COUNT;
  IF changed_count <> 1 THEN
    RAISE EXCEPTION 'Session state changed during termination' USING ERRCODE = '55000';
  END IF;

  PERFORM set_config('payse.user_id', '', true);
  RETURN true;
END $$;
