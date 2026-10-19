-- Run only in a disposable database whose name starts payse_fixture_.
-- Test-created rows, grants and role are rolled back. Uses synthetic seed with --ready.
BEGIN;
DO $$ BEGIN
  IF current_database() NOT LIKE 'payse_fixture_%' THEN
    RAISE EXCEPTION 'Use a disposable payse_fixture_ database';
  END IF;
END $$;
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
  alice uuid; bob uuid; alice_account uuid; bob_account uuid; reserve_id uuid;
  statement_id uuid; obligation_id uuid; revision_id uuid; plan_id uuid; nominal date;
BEGIN
  SELECT id INTO STRICT alice FROM payse.demo_users WHERE synthetic_name = 'PAYSE 합성 alpha';
  SELECT id INTO STRICT bob FROM payse.demo_users WHERE synthetic_name = 'PAYSE 합성 beta';
  SELECT id INTO alice_account FROM payse.financial_accounts WHERE user_id=alice ORDER BY id LIMIT 1;
  SELECT id INTO bob_account FROM payse.financial_accounts WHERE user_id=bob ORDER BY id LIMIT 1;
  SELECT id INTO reserve_id FROM payse.reserves WHERE user_id=alice LIMIT 1;
  IF (SELECT count(*) FROM payse.demo_users) <> 3 THEN RAISE EXCEPTION 'seed user count'; END IF;
  IF (SELECT count(*) FROM payse.financial_accounts) <> 18 THEN RAISE EXCEPTION 'seed account count'; END IF;

  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.reserves VALUES (%L,%L,%L,%L,100,NULL)',gen_random_uuid(),alice,bob_account,'foreign-owner'),'23503');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.reserves SET amount_krw=-1 WHERE id=%L',reserve_id),'23514');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.financial_accounts SET balance_krw=9000000000001 WHERE id=%L',alice_account),'23514');
  UPDATE payse.financial_accounts SET balance_krw=-1 WHERE id=alice_account;
  IF NOT FOUND THEN RAISE EXCEPTION 'negative source balance must be representable'; END IF;

  INSERT INTO payse.demo_sessions VALUES(gen_random_uuid(),alice,'test-digest-1',gen_random_uuid(),now(),NULL);
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.demo_sessions VALUES (gen_random_uuid(),%L,%L,gen_random_uuid(),now(),NULL)',alice,'test-digest-2'),'23505');
  UPDATE payse.demo_sessions SET ended_at=now() WHERE user_id=alice;
  INSERT INTO payse.demo_sessions VALUES(gen_random_uuid(),alice,'test-digest-3',gen_random_uuid(),now(),NULL);
  IF (SELECT count(*) FROM payse.reserves WHERE user_id=alice) <> 1 THEN RAISE EXCEPTION 'session end changed settings'; END IF;

  SELECT o.id,o.statement_id INTO obligation_id,statement_id FROM payse.obligations o WHERE o.user_id=alice AND o.statement_id IS NOT NULL;
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.obligations SELECT gen_random_uuid(),user_id,label,withdrawal_account_id,amount_krw,due_date,status,statement_id,plan_id,plan_revision_id,occurrence_month FROM payse.obligations WHERE id=%L',obligation_id),'23505');
  SELECT o.id,o.plan_revision_id,o.plan_id,o.occurrence_month INTO obligation_id,revision_id,plan_id,nominal FROM payse.obligations o WHERE o.user_id=alice AND o.plan_id IS NOT NULL LIMIT 1;
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.obligations SELECT gen_random_uuid(),user_id,label,withdrawal_account_id,amount_krw,due_date,status,statement_id,plan_id,plan_revision_id,occurrence_month FROM payse.obligations WHERE id=%L',obligation_id),'23505');
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.recurring_plan_revisions SELECT gen_random_uuid(),user_id,plan_id,effective_from_month,label,amount_krw,monthly_day,payment_timing,schedule_basis,withdrawal_account_id,card_id,status,schedule_overrides,is_current FROM payse.recurring_plan_revisions WHERE id=%L',revision_id),'23505');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.financial_accounts SET source_version=%L WHERE id=%L','nonexistent-version',alice_account),'23503');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.reserve_allocations SET released_krw=amount_krw+1 WHERE user_id=%L',alice),'23514');
  PERFORM pg_temp.expect_failure(format('UPDATE payse.financial_transactions SET original_transaction_id=id WHERE user_id=%L',alice),'23514');
  PERFORM pg_temp.expect_failure(format('DELETE FROM payse.demo_users WHERE id=%L',alice),'23001');
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.write_receipts SELECT gen_random_uuid(),user_id,operation_key,request_digest,action,changed_refs,before_after,result_version,created_at FROM payse.write_receipts WHERE user_id=%L LIMIT 1',alice),'23505');
  INSERT INTO payse.demo_event_receipts SELECT alice,'event-once','before','after',id FROM payse.write_receipts WHERE user_id=alice LIMIT 1;
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.demo_event_receipts SELECT user_id,event_id,source_version_before,source_version_after,receipt_id FROM payse.demo_event_receipts WHERE user_id=%L',alice),'23505');
  RAISE NOTICE 'PASS row/fk/unique checks: 14 rejection cases + seed/session/source invariants';
END $$;

CREATE ROLE payse_fixture_probe NOLOGIN NOSUPERUSER NOBYPASSRLS;
GRANT USAGE ON SCHEMA payse TO payse_fixture_probe;
GRANT SELECT ON ALL TABLES IN SCHEMA payse TO payse_fixture_probe;
GRANT INSERT ON payse.reserves TO payse_fixture_probe;
GRANT UPDATE ON payse.demo_users TO payse_fixture_probe;
GRANT EXECUTE ON FUNCTION payse.assert_user_storage(uuid) TO payse_fixture_probe;
SELECT set_config('payse.test_other_user',(SELECT id::text FROM payse.demo_users WHERE synthetic_name='PAYSE 합성 beta'),true);
SELECT set_config('payse.test_other_account',(SELECT id::text FROM payse.financial_accounts WHERE user_id=(SELECT id FROM payse.demo_users WHERE synthetic_name='PAYSE 합성 beta') LIMIT 1),true);
SELECT set_config('payse.user_id',(SELECT id::text FROM payse.demo_users WHERE synthetic_name='PAYSE 합성 alpha'),true);
SET LOCAL ROLE payse_fixture_probe;
DO $$ BEGIN
  IF (SELECT count(*) FROM payse.financial_accounts) <> 6 THEN RAISE EXCEPTION 'RLS leaked other accounts'; END IF;
  IF (SELECT count(*) FROM payse.demo_users) <> 1 THEN RAISE EXCEPTION 'RLS leaked other users'; END IF;
  INSERT INTO payse.reserves SELECT gen_random_uuid(),user_id,id,'RLS own write',1,NULL FROM payse.financial_accounts LIMIT 1;
  PERFORM pg_temp.expect_failure(format('INSERT INTO payse.reserves VALUES (gen_random_uuid(),%L,%L,%L,1,NULL)',current_setting('payse.test_other_user'),current_setting('payse.test_other_account'),'foreign write'),'42501');
  PERFORM pg_temp.expect_failure('UPDATE payse.financial_accounts SET balance_krw=0','42501');
  RAISE NOTICE 'PASS RLS owner reads';
END $$;
SELECT set_config('payse.user_id','',true);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM payse.financial_accounts) THEN RAISE EXCEPTION 'RLS exposed anonymous rows'; END IF;
  RAISE NOTICE 'PASS RLS no owner reads';
END $$;
RESET ROLE;
ROLLBACK;
