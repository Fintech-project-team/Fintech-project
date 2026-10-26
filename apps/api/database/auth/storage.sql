-- 비활성 시각·요청 제한 테이블·RLS·테이블 권한을 정의한다.
-- 2026-10-26: 003_auth_access.sql에서 목적별로 분리. 해당 진입점의 단일 트랜잭션에서만 실행한다.
-- 순서: 2/5. 단독 실행하거나 트랜잭션 제어 BEGIN/COMMIT을 추가하지 않는다.

-- 비활성/파쇄 예정 시각을 추가하되 기존 행은 둘 다 null로 유지한다.
-- 두 값의 null 쌍·유한성·선후관계만 강제하며 서울 달력상 1년 계산과 실제 파쇄는 수행하지 않는다.
ALTER TABLE payse.users
  ADD COLUMN deactivated_at timestamptz,
  ADD COLUMN purge_after timestamptz,
  ADD CONSTRAINT user_deactivation_dates CHECK (
    (deactivated_at IS NULL AND purge_after IS NULL) OR
    (deactivated_at IS NOT NULL AND purge_after IS NOT NULL AND
      isfinite(deactivated_at) AND isfinite(purge_after) AND purge_after>deactivated_at));
-- 비활성 시각의 접근 차단 용도를 DB 컬럼 설명에 기록한다.
COMMENT ON COLUMN payse.users.deactivated_at IS '접근 거절 기준; 탈퇴 처리 서비스에서만 확정';
-- 파쇄 가능 시각과 후속 서비스의 책임을 DB 컬럼 설명에 기록한다.
COMMENT ON COLUMN payse.users.purge_after IS '파쇄 가능 시각; 서울 달력상 1년 산정·파쇄 실행은 후속 서비스';

-- 2026-10-25: 제한 사건 배열의 유한성·정렬·차원·최대 건수를 검사한다.
-- 사용: auth_rate_limits의 CHECK. 비어 있지 않으면 1차원·1기반 배열이어야 한다.
CREATE FUNCTION payse.auth_events_valid(events timestamptz[], maximum integer)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, payse, pg_temp
AS $$
  -- null·상한·차원·하한 인덱스·사건별 유한성·시간순 정렬을 하나의 boolean으로 반환한다.
  SELECT events IS NOT NULL AND cardinality(events) <= maximum AND
    (cardinality(events) = 0 OR (array_ndims(events) = 1 AND array_lower(events, 1) = 1)) AND
    NOT EXISTS (SELECT 1
      FROM unnest(events) WITH ORDINALITY AS e(at, position)
      WHERE at IS NULL OR NOT isfinite(at) OR (position>1 AND at<events[position-1]));
$$;

-- 인증 제한 종류와 HMAC 키를 복합 PK로 묶어 개인정보 원문 없이 요청/실패 이력을 저장한다.
CREATE TABLE payse.auth_rate_limits (
  kind text NOT NULL CHECK (kind IN ('combo', 'ip')),
  key_digest text NOT NULL CHECK (key_digest COLLATE "C" ~ '^[0-9a-f]{64}$'),
  event_times timestamptz[] NOT NULL,
  blocked_until timestamptz,
  PRIMARY KEY (kind, key_digest),
  -- 조합 실패는 최대 5개, IP 요청은 최대 60개만 저장하고 사건 배열의 형식을 검증한다.
  CHECK (payse.auth_events_valid(event_times, CASE WHEN kind = 'combo' THEN 5 ELSE 60 END)),
  -- 조합 실패가 5개라면 차단 시각도 반드시 존재해야 한다.
  CHECK (kind <> 'combo' OR cardinality(event_times)<5 OR blocked_until IS NOT NULL),
  -- 차단 시각은 조합의 다섯 번째 실패+5분과 일치해야 하며 IP에는 별도 차단 시각을 저장하지 않는다.
  CHECK (blocked_until IS NULL OR
    (kind = 'combo' AND isfinite(blocked_until) AND cardinality(event_times) = 5 AND
      blocked_until = event_times[5]+interval '5 minutes'))
);
-- 제한 상태의 용도와 개인정보 원문을 저장하지 않는다는 의미를 DB 설명에 기록한다.
COMMENT ON TABLE payse.auth_rate_limits IS '인증 요청 제한; HMAC 식별자만 저장, IP·이름·전화번호·코드 원문 없음';
-- 사건 수 상한과 행 잠금 후 갱신 원칙을 DB 컬럼 설명에 기록한다.
COMMENT ON COLUMN payse.auth_rate_limits.event_times IS 'combo 실패 최대 5개 / IP 요청 최대 60개; 같은 키 행 잠금 후 갱신';

-- 요청 제한 테이블에 행 수준 접근 정책을 활성화한다.
ALTER TABLE payse.auth_rate_limits ENABLE ROW LEVEL SECURITY;
-- 테이블 소유자도 일반 실행 시 행 정책의 적용 대상이 되게 한다.
ALTER TABLE payse.auth_rate_limits FORCE ROW LEVEL SECURITY;
-- 인증 함수 소유 역할에만 제한 상태의 조회·입력·갱신을 허용할 행 정책을 부여한다.
CREATE POLICY auth_owner_rows
  ON payse.auth_rate_limits TO payse_auth_owner
  USING (true)
  WITH CHECK (true);
-- 사용자 문맥을 만들기 전 인증 후보를 조회하도록 인증 소유 역할의 SELECT 정책을 연다.
CREATE POLICY auth_owner_read
  ON payse.users FOR SELECT TO payse_auth_owner
  USING (true);
-- 사용자 FOR UPDATE 잠금에 필요한 UPDATE 정책이다. 인증 함수가 data_version을 바꾸지는 않는다.
CREATE POLICY auth_owner_lock
  ON payse.users FOR UPDATE TO payse_auth_owner
  USING (true)
  WITH CHECK (true);
-- 토큰 digest로 세션 소유자와 종료 상태를 찾을 수 있게 인증 소유 역할의 SELECT 정책을 연다.
CREATE POLICY auth_owner_read
  ON payse.demo_sessions FOR SELECT TO payse_auth_owner
  USING (true);

-- PUBLIC·runtime·인증 소유 역할이 스키마에 객체를 만들어 함수 조회 경로를 바꾸지 못하게 한다.
REVOKE CREATE ON SCHEMA payse FROM PUBLIC, payse_runtime, payse_auth_owner;
-- 두 역할이 허용받은 스키마 객체를 이름으로 참조하도록 사용 권한만 준다.
GRANT USAGE ON SCHEMA payse TO payse_runtime, payse_auth_owner;
-- 인증 소유 역할에 후보 조회와 계정 상태 재검증에 필요한 사용자 열만 공개한다.
GRANT SELECT (id, name, phone, code_verifier, deactivated_at) ON payse.users TO payse_auth_owner;
-- FOR UPDATE의 권한 요건을 충족하는 최소 열 권한이다. 제공 함수에는 버전 변경 SQL이 없다.
GRANT UPDATE (data_version) ON payse.users TO payse_auth_owner;
-- 인증 소유 역할이 토큰·발급·종료 상태를 확인할 수 있게 필요한 세션 열만 연다.
GRANT SELECT (id, user_id, token_digest, issued_at, ended_at) ON payse.demo_sessions TO payse_auth_owner;
-- 인증 함수의 제한 상태 읽기·최초 생성·갱신만 허용한다. 삭제와 TRUNCATE는 부여하지 않는다.
GRANT SELECT, INSERT, UPDATE ON payse.auth_rate_limits TO payse_auth_owner;
-- runtime의 사용자 식별/버전 조회와 기존 저장 트리거의 사용자 잠금·버전 갱신을 지원한다.
GRANT SELECT (id, data_version), UPDATE (data_version) ON payse.users TO payse_runtime;
-- runtime에 아래 명시한 기준정보·금융/설정 테이블의 조회만 허용한다.
-- 사용자 자료는 기존 소유자 RLS를 따르며 원천 금액·날짜 쓰기 권한은 추가하지 않는다.
GRANT SELECT ON payse.institutions, payse.source_contexts, payse.institution_links,
  payse.financial_accounts, payse.financial_cards, payse.transaction_references,
  payse.financial_transactions, payse.card_statements, payse.statement_items,
  payse.transaction_relations, payse.user_attributes, payse.recurring_plans,
  payse.recurring_plan_revisions, payse.obligations, payse.occurrence_overrides,
  payse.recurring_decisions, payse.settlement_links, payse.reserves,
  payse.reserve_allocations, payse.write_receipts TO payse_runtime;
-- runtime이 기존 저장 트리거의 최종 정합성 검사를 호출할 수 있게 한다.
GRANT EXECUTE ON FUNCTION payse.assert_user_storage(uuid) TO payse_runtime;
