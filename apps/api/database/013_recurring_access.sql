-- 2026-11-04: 반복 후보의 명시 승인·제외에 필요한 INSERT 권한만 추가한다.
-- 007 이후 관리자 명시 실행. 기존 행·원천·RLS·수정/삭제 권한은 바꾸지 않는다.
\set ON_ERROR_STOP on
BEGIN;

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
    'recurring_plans', 'recurring_plan_revisions', 'recurring_decisions'
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

GRANT INSERT (id, user_id, first_occurrence_month)
  ON payse.recurring_plans TO payse_runtime;

GRANT INSERT (id, user_id, plan_id, effective_from_month, label, amount_krw,
  monthly_day, payment_timing, schedule_basis, withdrawal_account_id, card_id,
  status, schedule_overrides, is_current)
  ON payse.recurring_plan_revisions TO payse_runtime;

GRANT INSERT (id, user_id, candidate_key, rule_version, source_version,
  evidence_refs, normalized_name, decision, plan_id)
  ON payse.recurring_decisions TO payse_runtime;

COMMIT;
