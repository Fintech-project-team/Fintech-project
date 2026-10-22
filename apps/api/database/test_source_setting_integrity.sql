-- 2026-10-21: Source/setting and pinned-revision regressions; disposable DB only.
-- Run after the ready alpha/beta/gamma seed. Every mutation is rolled back.
BEGIN;
DO $$ BEGIN
  IF current_database() NOT LIKE 'payse_fixture_%' THEN RAISE EXCEPTION 'Disposable database required'; END IF;
END $$;
SET CONSTRAINTS ALL DEFERRED;

CREATE FUNCTION pg_temp.expect_integrity_rejection(command text, expected_state text)
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
  u uuid; plan uuid; pinned uuid; next_revision uuid:=gen_random_uuid();
BEGIN
  SELECT user_id INTO STRICT u FROM payse.financial_accounts WHERE source_ref='fixture/gamma/account/0';
  SELECT plan_id,plan_revision_id INTO STRICT plan,pinned FROM payse.occurrence_overrides WHERE user_id=u;
  PERFORM pg_temp.expect_integrity_rejection(format(
    'UPDATE payse.occurrence_overrides SET occurrence_month=%L WHERE user_id=%L',
    '2026-12-01',u),'23514');
  PERFORM pg_temp.expect_integrity_rejection(format(
    'UPDATE payse.obligations SET occurrence_month=%L WHERE user_id=%L AND occurrence_month=%L',
    '2026-12-01',u,'2027-03-01'),'23514');

  -- Existing older pinned revisions stay valid; equality at the start month is valid too.
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  INSERT INTO payse.recurring_plan_revisions
    SELECT next_revision,user_id,plan_id,'2027-04-01',label,amount_krw,monthly_day,payment_timing,schedule_basis,
      withdrawal_account_id,card_id,status,schedule_overrides,true
    FROM payse.recurring_plan_revisions WHERE id=pinned;
  UPDATE payse.occurrence_overrides SET plan_revision_id=next_revision WHERE user_id=u AND plan_id=plan;
  SET CONSTRAINTS ALL IMMEDIATE;

  -- A later version cannot be used by an earlier occurrence, even though its FK is valid.
  PERFORM pg_temp.expect_integrity_rejection(format(
    'INSERT INTO payse.recurring_plan_revisions SELECT %L,user_id,plan_id,%L,label,amount_krw,monthly_day,payment_timing,schedule_basis,withdrawal_account_id,card_id,status,schedule_overrides,true FROM payse.recurring_plan_revisions WHERE id=%L; UPDATE payse.occurrence_overrides SET plan_revision_id=%L WHERE user_id=%L',
    '11111111-1111-4111-8111-111111111111','2027-05-01',pinned,'11111111-1111-4111-8111-111111111111',u),'23514');
  RAISE NOTICE 'PASS revision boundary: 3 rejected; old and equal-month pins accepted';
END $$;

DO $$
DECLARE
  u uuid; plan uuid; initial uuid; replacement uuid:=gen_random_uuid();
  original_occurrences jsonb; original_overrides jsonb; wrong_month date;
BEGIN
  SELECT user_id INTO STRICT u FROM payse.financial_accounts WHERE source_ref='fixture/gamma/account/0';
  SELECT id INTO STRICT plan FROM payse.recurring_plans WHERE user_id=u;
  SELECT id INTO STRICT initial FROM payse.recurring_plan_revisions WHERE user_id=u AND plan_id=plan AND effective_from_month='2027-01-01';
  FOREACH wrong_month IN ARRAY ARRAY['2026-12-01'::date,'2027-02-01'::date,'2027-03-01'::date,'2027-04-01'::date] LOOP
    PERFORM pg_temp.expect_integrity_rejection(format(
      'UPDATE payse.recurring_plans SET first_occurrence_month=%L WHERE id=%L',wrong_month,plan),'23514');
  END LOOP;
  PERFORM pg_temp.expect_integrity_rejection(format(
    'INSERT INTO payse.recurring_plan_revisions SELECT %L,user_id,plan_id,%L,label,amount_krw,monthly_day,payment_timing,schedule_basis,withdrawal_account_id,card_id,status,schedule_overrides,true FROM payse.recurring_plan_revisions WHERE id=%L',
    '33333333-3333-4333-8333-333333333333','2026-12-01',initial),'23514');
  PERFORM pg_temp.expect_integrity_rejection(format(
    'INSERT INTO payse.recurring_plans (id,user_id,first_occurrence_month) VALUES (%L,%L,%L)',
    '44444444-4444-4444-8444-444444444444',u,'2027-01-01'),'23514');
  PERFORM pg_temp.expect_integrity_rejection(format(
    'UPDATE payse.obligations SET occurrence_month=%L WHERE user_id=%L AND occurrence_month=%L',
    '2026-12-01',u,'2027-01-01'),'23514');
  PERFORM pg_temp.expect_integrity_rejection(format(
    'UPDATE payse.occurrence_overrides SET occurrence_month=%L WHERE user_id=%L',
    '2026-12-01',u),'23514');

  -- Equality remains valid, and retired history contributes to the minimum too.
  UPDATE payse.recurring_plans SET first_occurrence_month='2027-01-01' WHERE id=plan;
  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT jsonb_agg(to_jsonb(o) ORDER BY id) INTO original_occurrences FROM payse.obligations o WHERE user_id=u;
  SELECT jsonb_agg(to_jsonb(o) ORDER BY occurrence_month) INTO original_overrides FROM payse.occurrence_overrides o WHERE user_id=u;
  SET CONSTRAINTS ALL DEFERRED;
  UPDATE payse.recurring_plan_revisions SET is_current=false WHERE id=initial;
  INSERT INTO payse.recurring_plan_revisions
    SELECT replacement,user_id,plan_id,effective_from_month,label,amount_krw+1,monthly_day,payment_timing,schedule_basis,
      withdrawal_account_id,card_id,status,schedule_overrides,true
    FROM payse.recurring_plan_revisions WHERE id=initial;
  SET CONSTRAINTS ALL IMMEDIATE;
  IF (SELECT jsonb_agg(to_jsonb(o) ORDER BY id) FROM payse.obligations o WHERE user_id=u) IS DISTINCT FROM original_occurrences OR
     (SELECT jsonb_agg(to_jsonb(o) ORDER BY occurrence_month) FROM payse.occurrence_overrides o WHERE user_id=u) IS DISTINCT FROM original_overrides THEN
    RAISE EXCEPTION 'First-month validation changed pinned occurrences';
  END IF;
  RAISE NOTICE 'PASS plan first month: 8 invalid boundaries rejected; equality and retired pinned history accepted';
END $$;

DO $$
DECLARE
  u uuid; account uuid; next_account uuid; salary_tx uuid; other_tx uuid; outgoing_tx uuid;
  card_tx uuid; proof jsonb; source_before jsonb; transactions_before jsonb; state text;
BEGIN
  SELECT user_id,id INTO STRICT u,account FROM payse.financial_accounts WHERE source_ref='fixture/alpha/account/0';
  SELECT id INTO STRICT next_account FROM payse.financial_accounts WHERE source_ref='fixture/alpha/account/1';
  SELECT id INTO STRICT salary_tx FROM payse.financial_transactions WHERE source_ref='fixture/alpha/transaction/salary/2026-09';
  SELECT id INTO STRICT other_tx FROM payse.financial_transactions WHERE source_ref='fixture/beta/transaction/salary/2026-09';
  SELECT id INTO STRICT outgoing_tx FROM payse.financial_transactions WHERE source_ref='fixture/alpha/transaction/account-expense/0/2026-09';
  SELECT id INTO STRICT card_tx FROM payse.financial_transactions WHERE source_ref='fixture/alpha/transaction/card-purchase/0/2026-09';
  proof:=jsonb_build_array(jsonb_build_object('expectedPayDate','2026-09-25','confirmation','confirmed','transactionIds',jsonb_build_array(salary_tx)));
  UPDATE payse.source_contexts SET salary_evidence=proof WHERE user_id=u;
  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT to_jsonb(s) INTO source_before FROM payse.source_contexts s WHERE user_id=u;
  SELECT jsonb_agg(to_jsonb(t) ORDER BY id) INTO transactions_before FROM payse.financial_transactions t WHERE user_id=u;

  UPDATE payse.user_settings SET salary_account_id=next_account WHERE user_id=u;
  SET CONSTRAINTS ALL IMMEDIATE;
  UPDATE payse.user_settings SET salary_account_id=NULL WHERE user_id=u;
  SET CONSTRAINTS ALL IMMEDIATE;
  IF (SELECT to_jsonb(s) FROM payse.source_contexts s WHERE user_id=u) IS DISTINCT FROM source_before OR
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM payse.financial_transactions t WHERE user_id=u) IS DISTINCT FROM transactions_before THEN
    RAISE EXCEPTION 'Salary account setting changed source evidence or transactions';
  END IF;

  -- Historical evidence still needs this user's actual posted incoming account entry.
  FOREACH state IN ARRAY ARRAY['approved','cancelled','unknown'] LOOP
    PERFORM pg_temp.expect_integrity_rejection(format(
      'UPDATE payse.financial_transactions SET status=%L WHERE id=%L',state,salary_tx),'23514');
  END LOOP;
  PERFORM pg_temp.expect_integrity_rejection(format(
    'UPDATE payse.financial_transactions SET reflection_reason=%L WHERE id=%L','not_reflected',salary_tx),'23514');
  FOREACH other_tx IN ARRAY ARRAY[other_tx,outgoing_tx,card_tx,'22222222-2222-4222-8222-222222222222'::uuid] LOOP
    PERFORM pg_temp.expect_integrity_rejection(format(
      'UPDATE payse.source_contexts SET salary_evidence=jsonb_build_array(jsonb_build_object(%L,%L,%L,%L,%L,jsonb_build_array(%L::uuid))) WHERE user_id=%L',
      'expectedPayDate','2026-09-25','confirmation','confirmed','transactionIds',other_tx,u),'23514');
  END LOOP;
  UPDATE payse.user_settings SET salary_account_id=account WHERE user_id=u;
  SET CONSTRAINTS ALL IMMEDIATE;
  RAISE NOTICE 'PASS salary source independence: 2 setting changes accepted; 8 invalid proofs rejected';
END $$;
ROLLBACK;
