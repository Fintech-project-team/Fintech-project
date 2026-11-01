-- 2026-10-30: 기존 인증·금융 권한 및 사용자 격리를 확인하고 재적용을 차단한다.
-- 호출: 009_salary_notices.sql 첫 단계. 단독 실행하거나 기존 역할·테이블을 수정하지 않는다.

-- 기존 인증 함수와 비우회 runtime 역할이 준비된 DB에만 새 상태를 추가한다.
DO $$
DECLARE
  table_name text;
  owner_rule text;
BEGIN
  IF to_regprocedure('payse.auth_authorize(text)') IS NULL
    OR to_regprocedure('payse.auth_end_session(text)') IS NULL
    OR to_regprocedure('payse.assert_user_storage(uuid)') IS NULL
    OR to_regclass('payse.users') IS NULL
    OR to_regclass('payse.demo_sessions') IS NULL
    OR to_regclass('payse.source_contexts') IS NULL
    OR to_regclass('payse.user_attributes') IS NULL
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
    )
  THEN
    RAISE EXCEPTION 'Reviewed authentication and financial storage are required' USING ERRCODE = '55000';
  END IF;

  -- 007의 최소 금융 설정 권한이 없는 초기 DB에는 후속 SQL만 적용하지 않는다.
  IF NOT has_column_privilege('payse_runtime', 'payse.user_attributes', 'salary_day', 'UPDATE')
    OR NOT has_function_privilege('payse_runtime', 'payse.auth_authorize(text)', 'EXECUTE')
    OR NOT has_function_privilege('payse_runtime', 'payse.auth_end_session(text)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'Reviewed financial access must be installed first' USING ERRCODE = '55000';
  END IF;

  -- 원천과 설정은 기존 강제 RLS·단일 소유자 정책을 유지해야 한다.
  owner_rule := '(user_id = (NULLIF(current_setting(''payse.user_id''::text, true), ''''::text))::uuid)';
  FOREACH table_name IN ARRAY ARRAY['source_contexts', 'user_attributes'] LOOP
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
    )
    THEN
      RAISE EXCEPTION 'Financial owner isolation must be preserved' USING ERRCODE = '55000';
    END IF;
  END LOOP;

  IF to_regclass('payse.salary_notice_dismissals') IS NOT NULL THEN
    RAISE EXCEPTION 'Salary notice storage already exists; do not reapply' USING ERRCODE = '55000';
  END IF;
END $$;
