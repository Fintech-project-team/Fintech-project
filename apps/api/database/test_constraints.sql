-- Disposable database only; the runner supplies a validated temporary test context.
-- Test-created rows, grants and role are rolled back.
BEGIN;
SELECT pg_temp.assert_test_context();
SET CONSTRAINTS ALL IMMEDIATE;

CREATE FUNCTION pg_temp.expect_failure(command text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE command;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = expected_state THEN RETURN; END IF;
    RAISE EXCEPTION 'Expected %, got %: %', expected_state, SQLSTATE, SQLERRM;
  END;
  RAISE EXCEPTION 'Expected failure %, command succeeded', expected_state;
END $$;

DO $$
DECLARE
  owner uuid := pg_temp.ctx_uuid('owner_id');
  owner_account uuid := pg_temp.ctx_uuid('owner_account_id');
  other_account uuid := pg_temp.ctx_uuid('other_account_id');
  reserve_id uuid := pg_temp.ctx_uuid('reserve_id');
  allocation_id uuid := pg_temp.ctx_uuid('allocation_id');
  obligation_id uuid; revision_id uuid; changed_id uuid;
  session_id uuid := gen_random_uuid();
  receipt_id uuid := pg_temp.ctx_uuid('write_receipt_id');
  prior_user jsonb; prior_session_count bigint; prior_account_count bigint;
  deletion_rejected boolean := false;
BEGIN
  IF (SELECT count(*) FROM payse.demo_users) <> pg_temp.ctx_int('expected_user_count') THEN RAISE EXCEPTION 'seed user count'; END IF;
  IF (SELECT count(*) FROM payse.financial_accounts) <> pg_temp.ctx_int('expected_account_count') THEN RAISE EXCEPTION 'seed account count'; END IF;

  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.reserves VALUES (%L,%L,%L,%L,100,NULL)',gen_random_uuid(),owner,other_account,'foreign-owner'),'23503');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.reserves SET amount_krw=-1 WHERE id=%L',reserve_id),'23514');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.financial_accounts SET balance_krw=9000000000001 WHERE id=%L',owner_account),'23514');
  UPDATE payse.financial_accounts SET balance_krw=-1 WHERE id=owner_account RETURNING id INTO STRICT changed_id;

  INSERT INTO payse.demo_sessions (id,user_id,token_digest,issued_at,ended_at) VALUES(session_id,owner,'test-digest-1',now(),NULL);
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.demo_sessions (id,user_id,token_digest,issued_at,ended_at) VALUES (gen_random_uuid(),%L,%L,now(),NULL)',owner,'test-digest-2'),'23505');
  UPDATE payse.demo_sessions SET ended_at=now() WHERE id=session_id RETURNING id INTO STRICT changed_id;
  INSERT INTO payse.demo_sessions (id,user_id,token_digest,issued_at,ended_at) VALUES(gen_random_uuid(),owner,'test-digest-3',now(),NULL);
  IF (SELECT count(*) FROM payse.reserves WHERE user_id=owner) <> pg_temp.ctx_int('owner_reserve_count') THEN RAISE EXCEPTION 'session end changed settings'; END IF;

  obligation_id := pg_temp.ctx_uuid('statement_obligation_id');
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.obligations SELECT gen_random_uuid(),user_id,label,withdrawal_account_id,amount_krw,due_date,status,statement_id,plan_id,plan_revision_id,occurrence_month FROM payse.obligations WHERE id=%L',obligation_id),'23505');
  obligation_id := pg_temp.ctx_uuid('recurring_obligation_id');
  SELECT o.plan_revision_id INTO STRICT revision_id FROM payse.obligations o WHERE o.id=obligation_id;
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.obligations SELECT gen_random_uuid(),user_id,label,withdrawal_account_id,amount_krw,due_date,status,statement_id,plan_id,plan_revision_id,occurrence_month FROM payse.obligations WHERE id=%L',obligation_id),'23505');
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.recurring_plan_revisions SELECT gen_random_uuid(),user_id,plan_id,effective_from_month,label,amount_krw,monthly_day,payment_timing,schedule_basis,withdrawal_account_id,card_id,status,schedule_overrides,is_current FROM payse.recurring_plan_revisions WHERE id=%L',revision_id),'23505');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.financial_accounts SET source_version=%L WHERE id=%L','nonexistent-version',owner_account),'23503');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.reserve_allocations SET released_krw=amount_krw+1 WHERE id=%L',allocation_id),'23514');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.financial_transactions SET original_transaction_id=id WHERE id=%L',pg_temp.ctx_uuid('partial_transaction_id')),'23514');
  SELECT to_jsonb(u) INTO STRICT prior_user FROM payse.demo_users u WHERE id=owner;
  SELECT count(*) INTO prior_session_count FROM payse.demo_sessions WHERE user_id=owner;
  SELECT count(*) INTO prior_account_count FROM payse.financial_accounts WHERE user_id=owner;
  BEGIN
    DELETE FROM payse.demo_users WHERE id=owner;
  EXCEPTION WHEN foreign_key_violation OR restrict_violation THEN
    -- PostgreSQL may report 23503 or 23001 according to the first referencing FK.
    deletion_rejected := true;
  END;
  IF NOT deletion_rejected OR
     (SELECT to_jsonb(u) FROM payse.demo_users u WHERE id=owner) IS DISTINCT FROM prior_user OR
     (SELECT count(*) FROM payse.demo_sessions WHERE user_id=owner) <> prior_session_count OR
     (SELECT count(*) FROM payse.financial_accounts WHERE user_id=owner) <> prior_account_count THEN
    RAISE EXCEPTION 'Referenced user deletion must fail without changing user/session/accounts';
  END IF;
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.write_receipts SELECT gen_random_uuid(),user_id,operation_key,request_digest,action,changed_refs,before_after,result_version,created_at FROM payse.write_receipts WHERE id=%L',receipt_id),'23505');
  INSERT INTO payse.demo_event_receipts VALUES(owner,'event-once','before','after',receipt_id);
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.demo_event_receipts SELECT user_id,event_id,source_version_before,source_version_after,receipt_id FROM payse.demo_event_receipts WHERE user_id=%L AND event_id=%L',owner,'event-once'),'23505');
  RAISE NOTICE 'PASS row/fk/unique checks: 14 rejection cases + seed/session/source invariants';
END $$;

-- Roles are cluster-wide, so parallel test databases need distinct probe roles.
DO $$
DECLARE probe_role text := 'payse_fixture_probe_' || replace(gen_random_uuid()::text,'-','');
BEGIN
  EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOBYPASSRLS',probe_role);
  EXECUTE format('GRANT USAGE ON SCHEMA payse TO %I',probe_role);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA payse TO %I',probe_role);
  EXECUTE format('GRANT INSERT ON payse.reserves TO %I',probe_role);
  EXECUTE format('GRANT UPDATE ON payse.demo_users TO %I',probe_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION payse.assert_user_storage(uuid) TO %I',probe_role);
  PERFORM set_config('payse.test_probe_role',probe_role,true);
END $$;
-- Copy validated values before switching roles; the probe needs no context-table access.
SELECT set_config('payse.test_other_user',pg_temp.ctx_uuid('other_owner_id')::text,true);
SELECT set_config('payse.test_other_account',pg_temp.ctx_uuid('other_account_id')::text,true);
SELECT set_config('payse.test_owner_account',pg_temp.ctx_uuid('owner_account_id')::text,true);
SELECT set_config('payse.test_owner_accounts',array_to_json(pg_temp.ctx_uuid_array('owner_account_ids'))::text,true);
SELECT set_config('payse.user_id',pg_temp.ctx_uuid('owner_id')::text,true);
DO $$ BEGIN
  EXECUTE format('SET LOCAL ROLE %I',current_setting('payse.test_probe_role'));
END $$;
DO $$
DECLARE actual_ids uuid[]; expected_ids uuid[]; visible_user uuid;
BEGIN
  SELECT array_agg(id ORDER BY id) INTO actual_ids FROM payse.financial_accounts;
  SELECT array_agg(value::uuid ORDER BY value::uuid) INTO expected_ids
    FROM jsonb_array_elements_text(current_setting('payse.test_owner_accounts')::jsonb);
  IF actual_ids IS DISTINCT FROM expected_ids THEN RAISE EXCEPTION 'RLS owner account set differs'; END IF;
  SELECT id INTO STRICT visible_user FROM payse.demo_users;
  IF visible_user IS DISTINCT FROM current_setting('payse.user_id')::uuid THEN RAISE EXCEPTION 'RLS leaked other user'; END IF;
  INSERT INTO payse.reserves VALUES(gen_random_uuid(),visible_user,current_setting('payse.test_owner_account')::uuid,'RLS own write',1,NULL);
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.reserves VALUES (gen_random_uuid(),%L,%L,%L,1,NULL)',current_setting('payse.test_other_user'),current_setting('payse.test_other_account'),'foreign write'),'42501');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.financial_accounts SET balance_krw=0 WHERE id=%L',current_setting('payse.test_owner_account')),'42501');
  RAISE NOTICE 'PASS RLS owner reads';
END $$;
SELECT set_config('payse.user_id','',true);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM payse.financial_accounts) THEN RAISE EXCEPTION 'RLS exposed anonymous rows'; END IF;
  RAISE NOTICE 'PASS RLS no owner reads';
END $$;
RESET ROLE;
ROLLBACK;
