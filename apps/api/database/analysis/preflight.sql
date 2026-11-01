-- 2026-11-01: 기존 인증·금융 권한을 검증하고 분석 제한 집계 전용 역할을 준비한다.
-- 호출: 008_analysis_storage.sql 첫 단계. 기존 사용자 역할·데이터를 수정하지 않는다.

-- 기존 DB의 소유권과 최소 권한이 검증된 상태에서만 새 저장 단위를 추가한다.
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
    RAISE EXCEPTION 'Reviewed authentication and financial storage are required'
      USING ERRCODE = '55000';
  END IF;

  IF NOT has_column_privilege('payse_runtime', 'payse.user_attributes', 'salary_day', 'UPDATE')
    OR NOT has_function_privilege('payse_runtime', 'payse.auth_authorize(text)', 'EXECUTE')
    OR NOT has_function_privilege('payse_runtime', 'payse.auth_end_session(text)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'Reviewed financial access must be installed first'
      USING ERRCODE = '55000';
  END IF;

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
      RAISE EXCEPTION 'Financial owner isolation must be preserved'
        USING ERRCODE = '55000';
    END IF;
  END LOOP;

  FOREACH table_name IN ARRAY ARRAY[
    'analysis_jobs',
    'analysis_attempts',
    'analysis_commands',
    'analysis_results',
    'analysis_items',
    'analysis_suppressions'
  ] LOOP
    IF to_regclass('payse.' || table_name) IS NOT NULL THEN
      RAISE EXCEPTION 'Analysis storage already exists; do not reapply'
        USING ERRCODE = '55000';
    END IF;
  END LOOP;

  IF to_regprocedure('payse.analysis_capacity()') IS NOT NULL
    OR to_regprocedure('payse.analysis_cancel_waiting()') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Analysis lifecycle function already exists; do not replace'
      USING ERRCODE = '55000';
  END IF;

  -- 제한 집계는 인증 함수 소유자의 권한을 늘리지 않는 별도 비로그인 역할로 실행한다.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'payse_analysis_guard') THEN
    CREATE ROLE payse_analysis_guard
      NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'payse_analysis_guard'
      AND NOT rolcanlogin
      AND NOT rolinherit
      AND NOT rolsuper
      AND NOT rolbypassrls
      AND NOT rolcreatedb
      AND NOT rolcreaterole
      AND NOT rolreplication
  )
    OR EXISTS (
      SELECT 1
      FROM pg_auth_members membership
      JOIN pg_roles role ON role.oid IN (membership.roleid, membership.member)
      WHERE role.rolname = 'payse_analysis_guard'
    )
  THEN
    RAISE EXCEPTION 'Analysis guard role must have no login, bypass or memberships'
      USING ERRCODE = '55000';
  END IF;
END $$;
