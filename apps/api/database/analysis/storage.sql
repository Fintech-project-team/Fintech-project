-- 2026-11-01: 분석 작업과 암호화 기억을 사용자별 일반 저장 구조에 추가한다.
-- 호출: 008_analysis_storage.sql에서 preflight 다음 실행. 금융 원천·설정·dataVersion을 변경하지 않는다.
-- 결과 본문은 items의 암호문에만 보관한다. JSONB 메타에는 요청·응답 본문을 넣지 않는다.

-- 결과 헤더는 단기 작업이 정리돼도 보존 기억을 참조할 수 있도록 먼저 독립 생성한다.
CREATE TABLE payse.analysis_results (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  semantic_kind text NOT NULL,
  input_hash text NOT NULL,
  provenance jsonb NOT NULL,
  accepted_manifest jsonb NOT NULL,
  committed_at timestamptz NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  CHECK (semantic_kind IN ('transactionMeaning', 'recurringMeaning')),
  CHECK (input_hash COLLATE "C" ~ '^sha256:[0-9a-f]{64}$'),
  CHECK (jsonb_typeof(provenance) = 'object'),
  CHECK (jsonb_typeof(accepted_manifest) = 'array'),
  CHECK (isfinite(committed_at))
);

CREATE INDEX analysis_results_reuse
  ON payse.analysis_results (user_id, semantic_kind, input_hash, committed_at DESC);

-- 접수 식별과 실행창은 분리한다. 사용자 재시도는 실행창만 바꾸고 최초 보관 기한은 유지한다.
CREATE TABLE payse.analysis_jobs (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  semantic_kind text NOT NULL,
  trigger_kind text NOT NULL,
  descriptor_hash text NOT NULL,
  input_hash text,
  accepted_at timestamptz NOT NULL,
  guard_expires_at timestamptz NOT NULL,
  execution_expires_at timestamptz NOT NULL,
  state text NOT NULL,
  attempt_count bigint NOT NULL DEFAULT 0,
  selected_result_id uuid,
  canonical_job_id uuid,
  execution_session_id uuid,
  finished_at timestamptz,
  permit_expires_at timestamptz,
  permit_hash text,
  detail jsonb,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, selected_result_id)
    REFERENCES payse.analysis_results(user_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, canonical_job_id)
    REFERENCES payse.analysis_jobs(user_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, execution_session_id)
    REFERENCES payse.demo_sessions(user_id, id) ON DELETE RESTRICT,
  CHECK (semantic_kind IN ('transactionMeaning', 'recurringMeaning')),
  CHECK (trigger_kind IN ('A', 'B', 'recovery')),
  CHECK (descriptor_hash COLLATE "C" ~ '^sha256:[0-9a-f]{64}$'),
  CHECK (input_hash IS NULL OR input_hash COLLATE "C" ~ '^sha256:[0-9a-f]{64}$'),
  CHECK (permit_hash IS NULL OR permit_hash COLLATE "C" ~ '^sha256:[0-9a-f]{64}$'),
  CHECK (state IN (
    'queued', 'awaitingInput', 'running', 'succeeded',
    'failed', 'outcomeUnknown', 'cancelled', 'expired'
  )),
  CHECK (attempt_count >= 0),
  CHECK (canonical_job_id IS DISTINCT FROM id),
  CHECK (isfinite(accepted_at)),
  CHECK (isfinite(guard_expires_at) AND guard_expires_at > accepted_at),
  CHECK (isfinite(execution_expires_at) AND execution_expires_at > accepted_at),
  CHECK (finished_at IS NULL OR (isfinite(finished_at) AND finished_at >= accepted_at)),
  CHECK (permit_expires_at IS NULL OR isfinite(permit_expires_at)),
  CHECK ((permit_hash IS NULL) = (permit_expires_at IS NULL)),
  CHECK (detail IS NULL OR jsonb_typeof(detail) = 'object')
);

-- 활성 대표 작업만 중복을 막는다. 종료 행의 정리는 기존 결과·삭제 차단을 지우지 않는다.
CREATE UNIQUE INDEX analysis_jobs_active_input
  ON payse.analysis_jobs (user_id, semantic_kind, input_hash)
  WHERE input_hash IS NOT NULL
    AND canonical_job_id IS NULL
    AND state IN ('queued', 'awaitingInput', 'running');

CREATE UNIQUE INDEX analysis_jobs_active_descriptor
  ON payse.analysis_jobs (user_id, semantic_kind, descriptor_hash)
  WHERE input_hash IS NULL
    AND canonical_job_id IS NULL
    AND state IN ('queued', 'awaitingInput', 'running');

CREATE INDEX analysis_jobs_capacity
  ON payse.analysis_jobs (state, execution_expires_at, guard_expires_at)
  WHERE canonical_job_id IS NULL
    AND state IN ('queued', 'awaitingInput', 'running');

CREATE INDEX analysis_jobs_expiry ON payse.analysis_jobs (guard_expires_at);

-- 전송 상태는 작업 완료와 구별한다. 횟수는 기록하며 임의 최대 재시도 횟수를 두지 않는다.
CREATE TABLE payse.analysis_attempts (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  job_id uuid NOT NULL,
  attempt_no bigint NOT NULL,
  dispatch_state text NOT NULL,
  created_at timestamptz NOT NULL,
  finished_at timestamptz,
  detail jsonb,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  UNIQUE (user_id, job_id, id),
  UNIQUE (user_id, job_id, attempt_no),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, job_id)
    REFERENCES payse.analysis_jobs(user_id, id) ON DELETE RESTRICT,
  CHECK (attempt_no >= 1),
  CHECK (dispatch_state IN ('notSent', 'sent', 'outcomeUnknown', 'settled')),
  CHECK (isfinite(created_at)),
  CHECK (finished_at IS NULL OR (isfinite(finished_at) AND finished_at >= created_at)),
  CHECK (detail IS NULL OR jsonb_typeof(detail) = 'object')
);

-- 기억마다 독립 암호화와 보존 상태를 둔다. 헤더 삭제의 CASCADE로 기억을 지우지 않는다.
CREATE TABLE payse.analysis_items (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  result_id uuid NOT NULL,
  item_key text NOT NULL,
  semantic_kind text NOT NULL,
  memory_key text NOT NULL,
  evidence_hash text NOT NULL,
  stored_at timestamptz NOT NULL,
  normal_expires_at timestamptz NOT NULL,
  ciphertext bytea,
  crypto_meta jsonb,
  active boolean NOT NULL,
  is_reference boolean NOT NULL,
  important boolean NOT NULL,
  reference_policy text NOT NULL,
  metadata_version bigint NOT NULL,
  policy_version text NOT NULL,
  policy_actor text NOT NULL,
  deleted_at timestamptz,
  purge_requested_at timestamptz,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  UNIQUE (user_id, result_id, item_key),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, result_id)
    REFERENCES payse.analysis_results(user_id, id) ON DELETE RESTRICT,
  CHECK (length(btrim(item_key)) > 0),
  CHECK (semantic_kind IN ('transactionMeaning', 'recurringMeaning')),
  CHECK (length(btrim(memory_key)) > 0),
  CHECK (evidence_hash COLLATE "C" ~ '^sha256:[0-9a-f]{64}$'),
  CHECK (isfinite(stored_at)),
  CHECK (isfinite(normal_expires_at) AND normal_expires_at > stored_at),
  CHECK (
    (
      ciphertext IS NOT NULL
      AND crypto_meta IS NOT NULL
      AND octet_length(ciphertext) >= 16
      AND jsonb_typeof(crypto_meta) = 'object'
    )
    OR (
      ciphertext IS NULL
      AND crypto_meta IS NULL
      AND (deleted_at IS NOT NULL OR purge_requested_at IS NOT NULL)
    )
  ),
  CHECK (NOT important OR is_reference),
  CHECK (reference_policy IN ('optional', 'required')),
  CHECK (metadata_version >= 1),
  CHECK (length(btrim(policy_version)) > 0),
  CHECK (policy_actor IN ('ai', 'server', 'user')),
  CHECK (deleted_at IS NULL OR (isfinite(deleted_at) AND deleted_at >= stored_at)),
  CHECK (purge_requested_at IS NULL OR (isfinite(purge_requested_at) AND purge_requested_at >= stored_at)),
  CHECK (deleted_at IS NULL OR (NOT active AND purge_requested_at IS NOT NULL))
);

CREATE INDEX analysis_items_identity
  ON payse.analysis_items (user_id, semantic_kind, memory_key, evidence_hash);

CREATE INDEX analysis_items_expiry
  ON payse.analysis_items (normal_expires_at)
  WHERE NOT important AND deleted_at IS NULL;

-- 명령 기록은 같은 사용자 키 하나로 입력·재시도·삭제의 중복을 판정한다. 응답 본문을 복사하지 않는다.
CREATE TABLE payse.analysis_commands (
  user_id uuid NOT NULL,
  request_key text NOT NULL,
  operation text NOT NULL,
  request_hash text NOT NULL,
  job_id uuid,
  attempt_id uuid,
  item_id uuid,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, request_key),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, job_id)
    REFERENCES payse.analysis_jobs(user_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, job_id, attempt_id)
    REFERENCES payse.analysis_attempts(user_id, job_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, item_id)
    REFERENCES payse.analysis_items(user_id, id) ON DELETE RESTRICT,
  CHECK (request_key COLLATE "C" ~ '^[A-Za-z0-9._-]{1,128}$'),
  CHECK (operation IN ('intake', 'input', 'retry', 'delete')),
  CHECK (request_hash COLLATE "C" ~ '^sha256:[0-9a-f]{64}$'),
  CHECK (
    (operation = 'delete' AND item_id IS NOT NULL AND job_id IS NULL AND attempt_id IS NULL)
    OR (operation IN ('intake', 'input', 'retry') AND job_id IS NOT NULL AND item_id IS NULL)
  ),
  CHECK (isfinite(created_at)),
  CHECK (isfinite(expires_at) AND expires_at > created_at)
);

CREATE INDEX analysis_commands_expiry ON payse.analysis_commands (expires_at);

-- 본문 없이 삭제 효력을 보존한다. 모델·프롬프트·묶음 교체로 동일 근거 차단을 우회하지 않는다.
CREATE TABLE payse.analysis_suppressions (
  user_id uuid NOT NULL,
  semantic_kind text NOT NULL,
  memory_key text NOT NULL,
  evidence_hash text NOT NULL,
  blocked_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, semantic_kind, memory_key, evidence_hash),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  CHECK (semantic_kind IN ('transactionMeaning', 'recurringMeaning')),
  CHECK (length(btrim(memory_key)) > 0),
  CHECK (evidence_hash COLLATE "C" ~ '^sha256:[0-9a-f]{64}$'),
  CHECK (isfinite(blocked_at))
);

-- 2026-11-01: 최초 입력/결과와 합류 관계를 불변으로 유지하고 순환 대표 작업을 거절한다.
-- 사용: analysis_jobs BEFORE INSERT/UPDATE 트리거. 업무 상태 전이는 application service가 검증한다.
CREATE FUNCTION payse.analysis_job_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, payse, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF (OLD.input_hash IS NOT NULL AND NEW.input_hash IS DISTINCT FROM OLD.input_hash)
      OR (OLD.selected_result_id IS NOT NULL AND NEW.selected_result_id IS DISTINCT FROM OLD.selected_result_id)
      OR (OLD.canonical_job_id IS NOT NULL AND NEW.canonical_job_id IS DISTINCT FROM OLD.canonical_job_id)
      OR NEW.attempt_count < OLD.attempt_count
    THEN
      RAISE EXCEPTION 'Analysis input, adopted result and canonical target cannot be replaced'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.canonical_job_id IS NOT NULL AND EXISTS (
    WITH RECURSIVE parents(id, canonical_job_id) AS (
      SELECT job.id, job.canonical_job_id
      FROM payse.analysis_jobs job
      WHERE job.user_id = NEW.user_id
        AND job.id = NEW.canonical_job_id
      UNION
      SELECT job.id, job.canonical_job_id
      FROM payse.analysis_jobs job
      JOIN parents parent ON job.id = parent.canonical_job_id
      WHERE job.user_id = NEW.user_id
    )
    SELECT 1
    FROM parents
    WHERE id = NEW.id OR canonical_job_id = NEW.id
  ) THEN
    RAISE EXCEPTION 'Analysis canonical job cycle is not allowed'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER analysis_job_guard
  BEFORE INSERT OR UPDATE ON payse.analysis_jobs
  FOR EACH ROW EXECUTE FUNCTION payse.analysis_job_guard();

-- 2026-11-01: 기억 메타 버전 증가와 삭제 시 암호문 제거를 허용하되 교체·복원을 차단한다.
-- 사용: analysis_items BEFORE UPDATE 트리거. 사용자 삭제와 차단 기록은 서비스가 같은 트랜잭션으로 저장한다.
CREATE FUNCTION payse.analysis_item_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, payse, pg_temp
AS $$
BEGIN
  IF NEW.metadata_version <> OLD.metadata_version + 1
    OR (OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS DISTINCT FROM OLD.deleted_at)
    OR (OLD.purge_requested_at IS NOT NULL AND NEW.purge_requested_at IS DISTINCT FROM OLD.purge_requested_at)
    OR (NEW.ciphertext IS NOT NULL AND NEW.ciphertext IS DISTINCT FROM OLD.ciphertext)
    OR (NEW.crypto_meta IS NOT NULL AND NEW.crypto_meta IS DISTINCT FROM OLD.crypto_meta)
  THEN
    RAISE EXCEPTION 'Analysis metadata must advance without replacing or restoring memory'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER analysis_item_guard
  BEFORE UPDATE ON payse.analysis_items
  FOR EACH ROW EXECUTE FUNCTION payse.analysis_item_guard();

-- 2026-11-01: 명시 세션 종료와 같은 트랜잭션에서 해당 세션의 미시작 분석만 취소한다.
-- 사용: demo_sessions AFTER UPDATE OF ended_at 트리거. SECURITY INVOKER로 호출 역할의 기존 사용자 문맥을 유지한다.
-- running 결과는 기존 worker의 토큰 재확인이 차단한다. 원천·결과·시도·비용 사실을 지우지 않는다.
CREATE FUNCTION payse.analysis_cancel_waiting()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, payse, pg_temp
AS $$
BEGIN
  UPDATE payse.analysis_jobs job
  SET state = 'cancelled',
    finished_at = NEW.ended_at,
    permit_hash = NULL,
    permit_expires_at = NULL
  WHERE job.user_id = NEW.user_id
    AND job.execution_session_id = NEW.id
    AND job.state IN ('queued', 'awaitingInput');
  RETURN NEW;
END $$;

CREATE TRIGGER analysis_session_ended
  AFTER UPDATE OF ended_at ON payse.demo_sessions
  FOR EACH ROW
  WHEN (OLD.ended_at IS NULL AND NEW.ended_at IS NOT NULL)
  EXECUTE FUNCTION payse.analysis_cancel_waiting();

-- 2026-11-01: 인증된 현재 사용자의 대기/실행 수와 전체 합계만 동일 트랜잭션 잠금 아래 읽는다.
-- 사용: AnalysisRepository의 접수/실행 슬롯 검증. 사용자 ID·본문·다른 사용자 행은 반환하지 않는다.
CREATE FUNCTION payse.analysis_capacity()
RETURNS TABLE (
  queued_user bigint,
  queued_global bigint,
  running_user bigint,
  running_global bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  owner_id uuid;
  observed_at timestamptz;
BEGIN
  IF current_setting('role', true) IS DISTINCT FROM 'payse_runtime'
    OR current_setting('transaction_isolation') <> 'read committed'
    OR current_setting('transaction_read_only') <> 'off'
    OR NULLIF(current_setting('payse.user_id', true), '') IS NULL
  THEN
    RAISE EXCEPTION 'Analysis capacity requires the authenticated runtime transaction'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    owner_id := current_setting('payse.user_id', true)::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Analysis owner context is invalid' USING ERRCODE = '42501';
  END;

  -- 고정 키는 전역 분석 슬롯의 이름 공간이다. 요청별 사용자 식별자가 아니다.
  -- 사용자 행 잠금(auth_authorize) → 이 전역 잠금 순서를 서비스에서 유지한다.
  PERFORM pg_advisory_xact_lock(1346459987, 32);
  observed_at := clock_timestamp();

  RETURN QUERY
    SELECT
      count(*) FILTER (WHERE job.state IN ('queued', 'awaitingInput') AND job.user_id = owner_id),
      count(*) FILTER (WHERE job.state IN ('queued', 'awaitingInput')),
      count(*) FILTER (WHERE job.state = 'running' AND job.user_id = owner_id),
      count(*) FILTER (WHERE job.state = 'running')
    FROM payse.analysis_jobs job
    WHERE job.canonical_job_id IS NULL
      AND job.state IN ('queued', 'awaitingInput', 'running')
      AND job.guard_expires_at > observed_at
      AND job.execution_expires_at > observed_at;
END $$;

COMMENT ON FUNCTION payse.analysis_capacity() IS '인증된 runtime에 사용자/전체 대기·실행 건수만 반환; 트랜잭션 잠금은 커밋까지 유지';

COMMENT ON TABLE payse.analysis_results IS '본문 없는 분석 채택 묶음; 단기 작업/시도 수명과 독립';
COMMENT ON TABLE payse.analysis_jobs IS '금융 dataVersion과 독립적인 사용자별 분석 접수와 고정 복구 식별';
COMMENT ON TABLE payse.analysis_attempts IS '사용자 명시 재시도와 전송 사실; 외부 결과 불명을 미전송으로 바꾸지 않음';
COMMENT ON TABLE payse.analysis_commands IS '분석 접수·입력·재시도·개별 삭제의 사용자별 멱등 식별';
COMMENT ON TABLE payse.analysis_items IS '기억별 암호문·고정 보관 기간·유효성 메타; 원천 금융 사실이 아님';
COMMENT ON TABLE payse.analysis_suppressions IS '본문 없는 동일 기억·동일 근거의 자동 재보존 차단';

COMMENT ON COLUMN payse.analysis_results.id IS '안정된 분석 묶음 식별; 금융 원천 ID가 아님';
COMMENT ON COLUMN payse.analysis_results.user_id IS '인증 세션에서 정한 소유자; 캐시 검색도 이 범위에 한정';
COMMENT ON COLUMN payse.analysis_results.semantic_kind IS 'transactionMeaning 또는 recurringMeaning';
COMMENT ON COLUMN payse.analysis_results.input_hash IS '검증 입력과 서버 승인 모델·규격·정책의 정규 지문';
COMMENT ON COLUMN payse.analysis_results.provenance IS '스키마 검증된 최초 출처 메타만 저장; 원천·응답 본문 금지';
COMMENT ON COLUMN payse.analysis_results.accepted_manifest IS '항목 ID와 처리 범위 배열; 현재 기억 내용과 사용 가능 여부를 복제하지 않음';
COMMENT ON COLUMN payse.analysis_results.committed_at IS '최초 채택 시각; 조회로 갱신하지 않음';

COMMENT ON COLUMN payse.analysis_jobs.id IS '분석 접수 식별; DB가 미확인 입력을 생성하는 근거가 아님';
COMMENT ON COLUMN payse.analysis_jobs.user_id IS '현재 인증 사용자; 모든 결과·시도·세션 참조에 동일 소유권 적용';
COMMENT ON COLUMN payse.analysis_jobs.semantic_kind IS '거래 의미 또는 로컬 반복 후보 의미의 작업 종류';
COMMENT ON COLUMN payse.analysis_jobs.trigger_kind IS 'A/B 동작 또는 만료 작업의 명시 recovery';
COMMENT ON COLUMN payse.analysis_jobs.descriptor_hash IS '최소 접수 항목의 정규 지문; 본문 검증 완료를 뜻하지 않음';
COMMENT ON COLUMN payse.analysis_jobs.input_hash IS '본문 검증 이후 확정한 지문; null은 검증 전';
COMMENT ON COLUMN payse.analysis_jobs.accepted_at IS '최초 접수 시각; 재시도·합류로 변경 금지';
COMMENT ON COLUMN payse.analysis_jobs.guard_expires_at IS '최초 접수부터 달력 3개월의 고정 복구 식별 기한';
COMMENT ON COLUMN payse.analysis_jobs.execution_expires_at IS '최초 접수 또는 명시 재시도의 180초 실행창; 복구 보관 기한과 별도';
COMMENT ON COLUMN payse.analysis_jobs.state IS '서버 작업 진행 상태; 결과의 현재 유효성과 별도';
COMMENT ON COLUMN payse.analysis_jobs.attempt_count IS '누적 실행 시도 수; 최대 재시도 횟수 정책이 아님';
COMMENT ON COLUMN payse.analysis_jobs.selected_result_id IS '먼저 검증·채택한 같은 사용자 결과; 이후 응답으로 교체 금지';
COMMENT ON COLUMN payse.analysis_jobs.canonical_job_id IS '같은 사용자 진행 작업에 합류한 대표 ID; 자기 참조·순환 금지';
COMMENT ON COLUMN payse.analysis_jobs.execution_session_id IS '대기·실행 권한 재검증 세션; 결과 재조회에 같은 세션을 강제하지 않음';
COMMENT ON COLUMN payse.analysis_jobs.finished_at IS '작업 종료 및 7일 상세 정리 기준; 외부 비용 정산 완료를 뜻하지 않음';
COMMENT ON COLUMN payse.analysis_jobs.permit_expires_at IS '일회성 입력 제출 허용의 60초 만료 시각';
COMMENT ON COLUMN payse.analysis_jobs.permit_hash IS '입력 제출 허용 원문의 검증값; 원문·세션 토큰을 저장하지 않음';
COMMENT ON COLUMN payse.analysis_jobs.detail IS '본문 없는 항목 ID·진행 수·운영 오류; 종료 후 7일 상세 정리 대상';

COMMENT ON COLUMN payse.analysis_attempts.id IS '외부 실행 시도 식별; 결과 채택 ID와 별도';
COMMENT ON COLUMN payse.analysis_attempts.user_id IS '같은 사용자 작업만 연결하기 위한 소유자';
COMMENT ON COLUMN payse.analysis_attempts.job_id IS '시도가 속한 기존 분석 작업';
COMMENT ON COLUMN payse.analysis_attempts.attempt_no IS '작업 내부 1부터 증가하는 시도 번호';
COMMENT ON COLUMN payse.analysis_attempts.dispatch_state IS '전송 전·전송됨·결과 불명·종료 확인의 구분';
COMMENT ON COLUMN payse.analysis_attempts.created_at IS '시도 최소 식별 생성 시각';
COMMENT ON COLUMN payse.analysis_attempts.finished_at IS '시도 상세의 종료 시각; 미정산 비용을 없애는 근거가 아님';
COMMENT ON COLUMN payse.analysis_attempts.detail IS '본문 없는 공급자 요청 ID·오류·관측 근거; 원문 요청/응답 금지';

COMMENT ON COLUMN payse.analysis_commands.user_id IS '명령 멱등 키를 분리하는 인증 사용자';
COMMENT ON COLUMN payse.analysis_commands.request_key IS '1~128 ASCII 영숫자·점·밑줄·하이픈의 사용자별 요청 키';
COMMENT ON COLUMN payse.analysis_commands.operation IS 'intake/input/retry/delete; 금융 쓰기 영수증과 별도';
COMMENT ON COLUMN payse.analysis_commands.request_hash IS '명령 경로·정규 본문의 검증값; Bearer 원문 저장 금지';
COMMENT ON COLUMN payse.analysis_commands.job_id IS '접수·입력·재시도가 관찰할 같은 사용자 작업';
COMMENT ON COLUMN payse.analysis_commands.attempt_id IS '실제 등록된 시도가 있는 경우 같은 작업의 시도 식별';
COMMENT ON COLUMN payse.analysis_commands.item_id IS '개별 기억 삭제 명령의 대상; 다른 기억을 포함하지 않음';
COMMENT ON COLUMN payse.analysis_commands.created_at IS '명령의 최초 커밋 기준 시각';
COMMENT ON COLUMN payse.analysis_commands.expires_at IS '작업 고정 복구 기한 또는 삭제일부터 달력 3개월의 명령 식별 기한';

COMMENT ON COLUMN payse.analysis_items.id IS '독립 삭제·암호화의 기억 식별; 암호문 AAD에 사용자와 함께 포함';
COMMENT ON COLUMN payse.analysis_items.user_id IS '기억 소유자; 결과·명령·삭제 차단의 사용자 범위';
COMMENT ON COLUMN payse.analysis_items.result_id IS '같은 소유자의 본문 없는 결과 묶음';
COMMENT ON COLUMN payse.analysis_items.item_key IS '입력/출력 대응 키; 결과 묶음 내부에서만 유일';
COMMENT ON COLUMN payse.analysis_items.semantic_kind IS '허용된 의미 작업 종류';
COMMENT ON COLUMN payse.analysis_items.memory_key IS '묶음·모델·문장과 독립된 서버 검증 기억 식별';
COMMENT ON COLUMN payse.analysis_items.evidence_hash IS '해당 기억에 실제 관련된 당시 근거의 불변 정규 지문';
COMMENT ON COLUMN payse.analysis_items.stored_at IS '같은 기억·근거의 최초 보존 시각; 재조회·재저장으로 연장 금지';
COMMENT ON COLUMN payse.analysis_items.normal_expires_at IS 'Asia/Seoul 기준 최초 저장부터 달력 3개월; 중요보존 해제 후 재기산 금지';
COMMENT ON COLUMN payse.analysis_items.ciphertext IS 'AES-256-GCM 본문과 태그; 삭제/폐기 시 crypto_meta와 함께 NULL 제거하며 복원·교체 금지';
COMMENT ON COLUMN payse.analysis_items.crypto_meta IS 'nonce·KMS 키 참조·감싼 데이터 키; 삭제/폐기 시 암호문과 함께 NULL 제거하며 평문 키 금지';
COMMENT ON COLUMN payse.analysis_items.active IS '현재 참조 활성 상태; 유효성·사용자 정정·삭제 검증을 대체하지 않음';
COMMENT ON COLUMN payse.analysis_items.is_reference IS 'AI 참고자료 여부';
COMMENT ON COLUMN payse.analysis_items.important IS 'AI 참고자료의 일반 3개월 폐기 예외; 탈퇴 후 최종 파쇄 예외가 아님';
COMMENT ON COLUMN payse.analysis_items.reference_policy IS 'optional/required; required도 원천·사용자 정정·만료·삭제를 우회하지 않음';
COMMENT ON COLUMN payse.analysis_items.metadata_version IS '개별 기억 갱신마다 1 증가; 금융 dataVersion과 별도';
COMMENT ON COLUMN payse.analysis_items.policy_version IS '검증한 기억 보존 정책 버전';
COMMENT ON COLUMN payse.analysis_items.policy_actor IS 'ai/server/user 중 보존 메타 변경 주체';
COMMENT ON COLUMN payse.analysis_items.deleted_at IS '사용자 삭제의 최초 효력 시각; 본문 파쇄 완료를 뜻하지 않음';
COMMENT ON COLUMN payse.analysis_items.purge_requested_at IS '암호문·키·백업 사본의 폐기 요청 시각; 실제 폐기 검증은 별도';

COMMENT ON COLUMN payse.analysis_suppressions.user_id IS '재보존을 차단한 사용자; 다른 사용자에게 전파 금지';
COMMENT ON COLUMN payse.analysis_suppressions.semantic_kind IS '차단 대상 의미 작업 종류';
COMMENT ON COLUMN payse.analysis_suppressions.memory_key IS '삭제 대상에 저장돼 있던 동일 기억 식별';
COMMENT ON COLUMN payse.analysis_suppressions.evidence_hash IS '삭제 대상의 당시 근거 지문; 현재 원천으로 다시 만들지 않음';
COMMENT ON COLUMN payse.analysis_suppressions.blocked_at IS '최초 차단 시각; 일반 3개월 결과 청소와 별개';
