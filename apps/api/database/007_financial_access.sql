-- 2026-10-29: #22 연결과 #23 확정 설정 API에 필요한 최소 쓰기 권한을 연다.
-- 001~004 이후 관리자가 검토해 명시 실행한다. 기존 행·원천·RLS는 변경하지 않는다.
-- 실행: psql -X -v ON_ERROR_STOP=1 -f 007_financial_access.sql
\set ON_ERROR_STOP on
BEGIN;

-- 검토한 사용자 격리와 인증 함수가 없는 DB에는 쓰기 권한을 부여하지 않는다.
DO $$
DECLARE
  table_name text;
  owner_rule text;
BEGIN
  owner_rule := '(user_id = (NULLIF(current_setting(''payse.user_id''::text, true), ''''::text))::uuid)';
  IF to_regprocedure('payse.auth_authorize(text)') IS NULL
    OR to_regprocedure('payse.assert_user_storage(uuid)') IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM pg_roles
      WHERE rolname = 'payse_runtime'
        AND NOT rolcanlogin
        AND NOT rolsuper
        AND NOT rolbypassrls
        AND NOT rolcreatedb
        AND NOT rolcreaterole
        AND NOT rolinherit
    ) THEN
    RAISE EXCEPTION 'Reviewed authentication and runtime role are required' USING ERRCODE = '55000';
  END IF;

  -- 쓰기 대상마다 강제 RLS와 기존 소유자 정책이 있어야 한다.
  FOREACH table_name IN ARRAY ARRAY[
    'financial_accounts', 'user_attributes', 'institution_links',
    'obligations', 'reserves', 'reserve_allocations', 'write_receipts'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_policy p ON p.polrelid = c.oid
      WHERE n.nspname = 'payse'
        AND c.relname = table_name
        AND c.relrowsecurity
        AND c.relforcerowsecurity
        AND p.polname = 'own_rows'
        AND p.polcmd = '*'
        AND p.polpermissive
        AND p.polroles = ARRAY[0::oid]
        AND regexp_replace(pg_get_expr(p.polqual, p.polrelid), '[[:space:]]', '', 'g')
          = regexp_replace(owner_rule, '[[:space:]]', '', 'g')
        AND regexp_replace(pg_get_expr(p.polwithcheck, p.polrelid), '[[:space:]]', '', 'g')
          = regexp_replace(owner_rule, '[[:space:]]', '', 'g')
        AND (SELECT count(*) FROM pg_policy existing WHERE existing.polrelid = c.oid) = 1
    ) THEN
      RAISE EXCEPTION 'Financial owner policy must be present' USING ERRCODE = '55000';
    END IF;
  END LOOP;
END $$;

-- 계좌 원천 잔액·명칭·기관은 수정하지 않고 사용자 선택·별칭만 저장한다.
GRANT UPDATE (included, nickname)
  ON payse.financial_accounts TO payse_runtime;

-- 사전 준비된 사용자 속성에서 급여·카드 계획 설정만 변경한다.
GRANT UPDATE (salary_day, salary_amount_krw, salary_account_id, card_plan_overrides)
  ON payse.user_attributes TO payse_runtime;

-- 연결 재동의는 새 행으로 남기고 이전 연결은 종료 시각만 변경한다.
GRANT INSERT (id, user_id, institution_code, consented_at, disconnected_at)
  ON payse.institution_links TO payse_runtime;
GRANT UPDATE (disconnected_at)
  ON payse.institution_links TO payse_runtime;

-- 수동 예정 지출 생성 및 허용 설정 변경·취소에 필요한 열만 공개한다.
-- 청구·반복 연결과 정산 사실의 변경은 이 API 권한에 포함하지 않는다.
GRANT INSERT (id, user_id, label, withdrawal_account_id, amount_krw, due_date, status)
  ON payse.obligations TO payse_runtime;
GRANT UPDATE (label, withdrawal_account_id, amount_krw, due_date, status)
  ON payse.obligations TO payse_runtime;

-- 모아둘 돈 설정 생성·수정·취소를 허용하며 실제 계좌 금액은 변경하지 않는다.
GRANT INSERT (id, user_id, account_id, label, amount_krw, cancelled_at)
  ON payse.reserves TO payse_runtime;
GRANT UPDATE (account_id, label, amount_krw, cancelled_at)
  ON payse.reserves TO payse_runtime;

-- 미지급 배정 생성·금액 조정·명시 해제만 허용한다.
-- released_krw와 release_evidence의 기존 지급 이력 갱신 권한은 부여하지 않는다.
GRANT INSERT (id, user_id, reserve_id, obligation_id, amount_krw, released_krw, release_evidence)
  ON payse.reserve_allocations TO payse_runtime;
GRANT UPDATE (amount_krw)
  ON payse.reserve_allocations TO payse_runtime;
GRANT DELETE ON payse.reserve_allocations TO payse_runtime;

-- 성공 영수증은 설정·버전과 같은 트랜잭션에 새로 기록하며 수정·삭제하지 않는다.
GRANT INSERT (id, user_id, operation_key, request_digest, action, changed_refs,
  before_after, result_version, created_at)
  ON payse.write_receipts TO payse_runtime;

COMMIT;
