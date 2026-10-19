-- Disposable database only. Every mutation in this file is rolled back.
BEGIN;
DO $$ BEGIN
  IF current_database() NOT LIKE 'payse_fixture_%' THEN RAISE EXCEPTION 'Disposable database required'; END IF;
END $$;
SET CONSTRAINTS ALL DEFERRED;
CREATE FUNCTION pg_temp.expect_rejected(command text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE command;
    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE=expected_state THEN RETURN; END IF;
    RAISE EXCEPTION 'Expected %, got %: %',expected_state,SQLSTATE,SQLERRM;
  END;
  RAISE EXCEPTION 'Unsafe mutation was accepted: %',command;
END $$;

DO $$
DECLARE
  u uuid; other_user uuid; account uuid; other_account uuid; repair uuid; rent uuid;
  link uuid; allocation uuid; reserve uuid; txn uuid; second_txn uuid; revision uuid;
  old_balance bigint; original_amount bigint; n integer;
BEGIN
  SELECT id INTO u FROM payse.demo_users WHERE synthetic_name='PAYSE 합성 alpha';
  SELECT id INTO other_user FROM payse.demo_users WHERE synthetic_name='PAYSE 합성 beta';
  SELECT id INTO account FROM payse.financial_accounts WHERE user_id=u AND source_ref LIKE '%/account/0';
  SELECT id INTO other_account FROM payse.financial_accounts WHERE user_id=other_user LIMIT 1;
  SELECT id INTO repair FROM payse.obligations WHERE user_id=u AND label='수리비';
  SELECT id INTO rent FROM payse.obligations WHERE user_id=u AND label='월세';
  SELECT id,transaction_id INTO link,txn FROM payse.settlement_links WHERE user_id=u AND obligation_id=repair;
  SELECT id INTO second_txn FROM payse.financial_transactions WHERE user_id=u AND id<>txn LIMIT 1;
  SELECT id,reserve_id INTO allocation,reserve FROM payse.reserve_allocations WHERE user_id=u LIMIT 1;
  SELECT id INTO revision FROM payse.recurring_plan_revisions WHERE user_id=u LIMIT 1;

  -- Sum failures, although each individual value is within its column bounds.
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.settlement_links SET allocated_krw=40001 WHERE id=%L',link),'23514');
  PERFORM pg_temp.expect_rejected(format('INSERT INTO payse.settlement_links SELECT gen_random_uuid(),user_id,%L,transaction_id,1,method,evidence,NULL FROM payse.settlement_links WHERE id=%L',rent,link),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.reserve_allocations SET amount_krw=9000000000000 WHERE id=%L',allocation),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.reserve_allocations SET amount_krw=40000 WHERE id=%L; INSERT INTO payse.reserve_allocations SELECT gen_random_uuid(),user_id,reserve_id,obligation_id,amount_krw,released_krw,release_evidence FROM payse.reserve_allocations WHERE id=%L',allocation,allocation),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.settlement_links SET invalidated_at=now() WHERE id=%L',link),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.obligations SET status=%L WHERE id=%L','cancelled',repair),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.reserves SET cancelled_at=now() WHERE id=%L',reserve),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.recurring_plan_revisions SET effective_from_month=%L WHERE id=%L','2026-11-01',revision),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.financial_transactions SET original_transaction_id=%L WHERE id=%L; UPDATE payse.financial_transactions SET original_transaction_id=%L WHERE id=%L',second_txn,txn,txn,second_txn),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.transaction_references SET resolution=%L,reason=%L WHERE user_id=%L AND transaction_id=%L','unavailable','not_provided',u,txn),'23514');
  PERFORM pg_temp.expect_rejected(format('INSERT INTO payse.transaction_relations SELECT user_id,kind,to_id,from_id,evidence_ref FROM payse.transaction_relations WHERE user_id=%L LIMIT 1',u),'23505');
  PERFORM pg_temp.expect_rejected(format('INSERT INTO payse.occurrence_overrides SELECT user_id,plan_id,occurrence_month,plan_revision_id,amount_krw,due_date,withdrawal_account_id,status FROM payse.obligations WHERE user_id=%L AND plan_id IS NOT NULL',u),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.financial_accounts SET as_of=%L WHERE id=%L','infinity',account),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.obligations SET due_date=%L WHERE id=%L','infinity',repair),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.reserves SET label=%L WHERE id=%L','   ',reserve),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.reserves SET amount_krw=NULL WHERE id=%L',reserve),'23502');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.reserves SET amount_krw=%L WHERE id=%L','9223372036854775808',reserve),'22003');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.reserves SET user_id=%L,account_id=%L WHERE id=%L',other_user,other_account,reserve),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.source_contexts SET coverage=jsonb_build_array(jsonb_build_object(%L,%L,%L,%L)) WHERE user_id=%L','targetKind','account','targetId',other_account,u),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.source_contexts SET salary_evidence=%L::jsonb WHERE user_id=%L','[{"expectedPayDate":"2026-10-25","confirmation":"confirmed","transactionIds":[]}]',u),'23514');
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.user_settings SET card_plan_overrides=jsonb_build_array(jsonb_build_object(%L,gen_random_uuid(),%L,25)) WHERE user_id=%L','cardId','plannedPaymentDay',u),'23514');

  -- A changed source version without all dependent records must roll back both edits.
  SELECT balance_krw INTO old_balance FROM payse.financial_accounts WHERE id=account;
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.financial_accounts SET balance_krw=123 WHERE id=%L; UPDATE payse.source_contexts SET source_version=%L WHERE user_id=%L',account,'unfinished-source',u),'23503');
  IF (SELECT balance_krw FROM payse.financial_accounts WHERE id=account)<>old_balance THEN RAISE EXCEPTION 'Partial write survived failure'; END IF;

  -- Numeric limit is inclusive and source balance decline does not shrink protected funds.
  SELECT amount_krw INTO original_amount FROM payse.reserves WHERE id=reserve;
  UPDATE payse.financial_accounts SET balance_krw=-9000000000000 WHERE id=account;
  SET CONSTRAINTS ALL IMMEDIATE;
  IF (SELECT amount_krw FROM payse.reserves WHERE id=reserve)<>original_amount THEN RAISE EXCEPTION 'Automatic reserve shrink'; END IF;
  UPDATE payse.financial_accounts SET balance_krw=old_balance WHERE id=account;
  SET CONSTRAINTS ALL DEFERRED;

  -- 100 sequential retry attempts are not called a concurrent connection test.
  FOR n IN 1..100 LOOP
    PERFORM pg_temp.expect_rejected(format('INSERT INTO payse.write_receipts SELECT gen_random_uuid(),user_id,operation_key,request_digest,action,changed_refs,before_after,result_version,created_at FROM payse.write_receipts WHERE user_id=%L LIMIT 1',u),'23505');
  END LOOP;
  RAISE NOTICE 'PASS extreme storage cases and 100 sequential duplicate-key attempts';
END $$;

-- Multi-table correction succeeds only when release evidence/state change together.
DO $$ DECLARE u uuid; BEGIN
  SELECT id INTO u FROM payse.demo_users WHERE synthetic_name='PAYSE 합성 alpha';
  UPDATE payse.settlement_links SET invalidated_at=now() WHERE user_id=u AND obligation_id IN (SELECT id FROM payse.obligations WHERE user_id=u AND label='수리비');
  UPDATE payse.reserve_allocations SET released_krw=0,release_evidence='[]' WHERE user_id=u;
  UPDATE payse.reserves SET amount_krw=amount_krw+40000 WHERE user_id=u;
  SET CONSTRAINTS ALL IMMEDIATE;
  RAISE NOTICE 'PASS atomic correction without changing source transactions';
END $$;

-- A second edit for the SAME future starting month preserves already-pinned revisions.
DO $$ DECLARE u uuid; old_revision uuid; new_revision uuid:=gen_random_uuid(); BEGIN
  SELECT id INTO u FROM payse.demo_users WHERE synthetic_name='PAYSE 합성 gamma';
  SELECT id INTO old_revision FROM payse.recurring_plan_revisions WHERE user_id=u AND effective_from_month='2027-03-01';
  PERFORM pg_temp.expect_rejected(format('UPDATE payse.recurring_plan_revisions SET amount_krw=115000 WHERE id=%L',old_revision),'23514');
  SET CONSTRAINTS ALL DEFERRED;
  UPDATE payse.recurring_plan_revisions SET is_current=false WHERE id=old_revision;
  INSERT INTO payse.recurring_plan_revisions SELECT new_revision,user_id,plan_id,effective_from_month,label,115000,monthly_day,payment_timing,schedule_basis,withdrawal_account_id,card_id,status,schedule_overrides,true FROM payse.recurring_plan_revisions WHERE id=old_revision;
  SET CONSTRAINTS ALL IMMEDIATE;
  IF NOT EXISTS(SELECT 1 FROM payse.occurrence_overrides WHERE user_id=u AND plan_revision_id=old_revision AND amount_krw=120000) THEN RAISE EXCEPTION 'Pinned individual occurrence lost'; END IF;
  IF (SELECT count(*) FROM payse.recurring_plan_revisions WHERE user_id=u AND effective_from_month='2027-03-01' AND is_current)<>1 THEN RAISE EXCEPTION 'Future authority not unique'; END IF;
  RAISE NOTICE 'PASS repeated future-month edit preserves pinned history';
END $$;
ROLLBACK;
