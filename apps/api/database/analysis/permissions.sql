-- 2026-11-01: 사용자별 강제 RLS, 불변 열을 제외한 갱신 권한, 집계 전용 역할을 설정한다.
-- 호출: 008_analysis_storage.sql 마지막 단계. 기존 인증/금융 테이블 권한은 유지하고 분석 최소 권한만 추가한다.

-- runtime의 모든 분석 자료 접근은 인증 함수가 설정한 같은 사용자 문맥을 요구한다.
DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'analysis_jobs',
    'analysis_attempts',
    'analysis_commands',
    'analysis_results',
    'analysis_items',
    'analysis_suppressions'
  ] LOOP
    EXECUTE format('ALTER TABLE payse.%I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('ALTER TABLE payse.%I FORCE ROW LEVEL SECURITY', table_name);
    EXECUTE format(
      'CREATE POLICY own_rows ON payse.%I TO payse_runtime '
      || 'USING (user_id = NULLIF(current_setting(''payse.user_id'', true), '''')::uuid) '
      || 'WITH CHECK (user_id = NULLIF(current_setting(''payse.user_id'', true), '''')::uuid)',
      table_name
    );
    EXECUTE format('REVOKE ALL ON payse.%I FROM PUBLIC, payse_runtime, payse_analysis_guard', table_name);
    EXECUTE format('GRANT SELECT ON payse.%I TO payse_runtime', table_name);
  END LOOP;
END $$;

-- 신규 행은 인증된 소유자에만 만들며 생성 후 식별·최초 시각·암호문은 일반 요청으로 바꾸지 않는다.
GRANT INSERT (
  id,
  user_id,
  semantic_kind,
  trigger_kind,
  descriptor_hash,
  input_hash,
  accepted_at,
  guard_expires_at,
  execution_expires_at,
  state,
  attempt_count,
  selected_result_id,
  canonical_job_id,
  execution_session_id,
  finished_at,
  permit_expires_at,
  permit_hash,
  detail
)
  ON payse.analysis_jobs TO payse_runtime;

GRANT UPDATE (
  input_hash,
  execution_expires_at,
  state,
  attempt_count,
  selected_result_id,
  canonical_job_id,
  execution_session_id,
  finished_at,
  permit_expires_at,
  permit_hash,
  detail
)
  ON payse.analysis_jobs TO payse_runtime;

GRANT INSERT (
  id,
  user_id,
  job_id,
  attempt_no,
  dispatch_state,
  created_at,
  finished_at,
  detail
)
  ON payse.analysis_attempts TO payse_runtime;

GRANT UPDATE (dispatch_state, finished_at, detail)
  ON payse.analysis_attempts TO payse_runtime;

GRANT INSERT (
  user_id,
  request_key,
  operation,
  request_hash,
  job_id,
  attempt_id,
  item_id,
  created_at,
  expires_at
)
  ON payse.analysis_commands TO payse_runtime;

GRANT INSERT (
  id,
  user_id,
  semantic_kind,
  input_hash,
  provenance,
  accepted_manifest,
  committed_at
)
  ON payse.analysis_results TO payse_runtime;

GRANT INSERT (
  id,
  user_id,
  result_id,
  item_key,
  semantic_kind,
  memory_key,
  evidence_hash,
  stored_at,
  normal_expires_at,
  ciphertext,
  crypto_meta,
  active,
  is_reference,
  important,
  reference_policy,
  metadata_version,
  policy_version,
  policy_actor,
  deleted_at,
  purge_requested_at
)
  ON payse.analysis_items TO payse_runtime;

GRANT UPDATE (
  ciphertext,
  crypto_meta,
  active,
  is_reference,
  important,
  reference_policy,
  metadata_version,
  policy_version,
  policy_actor,
  deleted_at,
  purge_requested_at
)
  ON payse.analysis_items TO payse_runtime;

GRANT INSERT (
  user_id,
  semantic_kind,
  memory_key,
  evidence_hash,
  blocked_at
)
  ON payse.analysis_suppressions TO payse_runtime;

-- 집계 역할은 행 내용을 출력하는 경로가 없고 전역 제한에 필요한 다섯 열만 읽는다.
GRANT USAGE ON SCHEMA payse TO payse_analysis_guard;

GRANT SELECT (
  user_id,
  state,
  canonical_job_id,
  guard_expires_at,
  execution_expires_at
)
  ON payse.analysis_jobs TO payse_analysis_guard;

CREATE POLICY capacity_rows
  ON payse.analysis_jobs
  FOR SELECT
  TO payse_analysis_guard
  USING (true);

ALTER FUNCTION payse.analysis_capacity() OWNER TO payse_analysis_guard;

-- 트리거는 선언된 테이블 갱신에서만 실행한다. runtime은 집계 진입 함수 하나만 직접 호출한다.
REVOKE ALL ON FUNCTION payse.analysis_job_guard() FROM PUBLIC, payse_runtime, payse_analysis_guard;
REVOKE ALL ON FUNCTION payse.analysis_item_guard() FROM PUBLIC, payse_runtime, payse_analysis_guard;
REVOKE ALL ON FUNCTION payse.analysis_capacity() FROM PUBLIC, payse_runtime;

GRANT EXECUTE ON FUNCTION payse.analysis_capacity() TO payse_runtime;

-- 인증 함수는 이미 사용자 행을 잠그고 payse.user_id를 설정한 뒤 세션을 종료한다.
-- 그 역할에는 해당 사용자의 대기 작업 취소에 필요한 열만 추가하며 전역 RLS 우회를 주지 않는다.
GRANT SELECT (
  id,
  user_id,
  execution_session_id,
  state,
  canonical_job_id
)
  ON payse.analysis_jobs TO payse_auth_owner;

GRANT UPDATE (
  state,
  finished_at,
  permit_hash,
  permit_expires_at
)
  ON payse.analysis_jobs TO payse_auth_owner;

CREATE POLICY session_end_read
  ON payse.analysis_jobs
  FOR SELECT
  TO payse_auth_owner
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

CREATE POLICY session_end_update
  ON payse.analysis_jobs
  FOR UPDATE
  TO payse_auth_owner
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

-- 직접 호출용 함수가 아니다. 권한 상승 없이 검증된 세션 종료 트리거에서만 실행한다.
REVOKE ALL ON FUNCTION payse.analysis_cancel_waiting()
  FROM PUBLIC, payse_runtime, payse_auth_owner, payse_analysis_guard;

-- 삭제/폐기는 트리거가 허용한 기존 암호문·감싼 키의 NULL 제거와 참조 차단으로 집행한다.
-- 외부 KMS/백업 파쇄 완료는 별도 검증한다. DELETE/TRUNCATE/역할 전환·전체 UPDATE는 부여하지 않는다.
