-- Source/setting and pinned-revision regressions with validated test role IDs.
-- The runner supplies context; every mutation is rolled back.
BEGIN;
SELECT pg_temp.assert_test_context();
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
  u uuid := pg_temp.ctx_uuid('future_owner_id');
  plan uuid := pg_temp.ctx_uuid('future_plan_id');
  pinned uuid := pg_temp.ctx_uuid('future_revision_id');
  next_revision uuid := gen_random_uuid();
  too_late_revision uuid := gen_random_uuid();
  changed_id uuid;
  first_month date := pg_temp.ctx_text('future_first_month')::date;
  override_month date := pg_temp.ctx_text('override_occurrence_month')::date;
BEGIN
  IF next_revision=too_late_revision OR EXISTS(SELECT 1 FROM payse.recurring_plan_revisions WHERE id IN (next_revision,too_late_revision)) THEN
    RAISE EXCEPTION 'New revision probes must be absent and distinct';
  END IF;
  PERFORM pg_temp.expect_integrity_rejection(format(
    'UPDATE payse.occurrence_overrides SET occurrence_month=%L WHERE user_id=%L AND plan_id=%L AND occurrence_month=%L',
    (first_month-interval '1 month')::date,u,plan,override_month),'23514');
  PERFORM pg_temp.expect_integrity_rejection(format(
    'UPDATE payse.obligations SET occurrence_month=%L WHERE id=%L',
    (first_month-interval '1 month')::date,pg_temp.ctx_uuid('pinned_obligation_id')),'23514');

  -- Existing older pins stay valid; a replacement starting at the override month is valid.
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  INSERT INTO payse.recurring_plan_revisions
    SELECT next_revision,user_id,plan_id,override_month,label,amount_krw,monthly_day,payment_timing,schedule_basis,
      withdrawal_account_id,card_id,status,schedule_overrides,true
    FROM payse.recurring_plan_revisions WHERE id=pinned
    RETURNING id INTO STRICT changed_id;
  UPDATE payse.occurrence_overrides SET plan_revision_id=next_revision
    WHERE user_id=u AND plan_id=plan AND occurrence_month=override_month
    RETURNING user_id INTO STRICT changed_id;
  SET CONSTRAINTS ALL IMMEDIATE;

  -- A later version cannot be used by the earlier occurrence, even with a valid FK.
  PERFORM pg_temp.expect_integrity_rejection(format(
    'INSERT INTO payse.recurring_plan_revisions SELECT %L,user_id,plan_id,%L,label,amount_krw,monthly_day,payment_timing,schedule_basis,withdrawal_account_id,card_id,status,schedule_overrides,true FROM payse.recurring_plan_revisions WHERE id=%L; UPDATE payse.occurrence_overrides SET plan_revision_id=%L WHERE user_id=%L AND plan_id=%L AND occurrence_month=%L',
    too_late_revision,(override_month+interval '1 month')::date,pinned,too_late_revision,u,plan,override_month),'23514');
  RAISE NOTICE 'PASS revision boundary: 3 rejected; old and equal-month pins accepted';
END $$;

DO $$
DECLARE
  u uuid := pg_temp.ctx_uuid('future_owner_id');
  plan uuid := pg_temp.ctx_uuid('future_plan_id');
  initial uuid := pg_temp.ctx_uuid('initial_revision_id');
  replacement uuid := gen_random_uuid();
  before_start_revision uuid := gen_random_uuid();
  orphan_plan uuid := gen_random_uuid(); changed_id uuid;
  first_month date := pg_temp.ctx_text('future_first_month')::date;
  override_month date := pg_temp.ctx_text('override_occurrence_month')::date;
  original_occurrences jsonb; original_overrides jsonb; wrong_month date;
BEGIN
  IF replacement=before_start_revision OR EXISTS(SELECT 1 FROM payse.recurring_plan_revisions WHERE id IN (replacement,before_start_revision))
    OR EXISTS(SELECT 1 FROM payse.recurring_plans WHERE id=orphan_plan) THEN
    RAISE EXCEPTION 'New plan/revision probes already exist';
  END IF;
  FOREACH wrong_month IN ARRAY ARRAY[(first_month-interval '1 month')::date,
      (first_month+interval '1 month')::date,(first_month+interval '2 months')::date,(first_month+interval '3 months')::date] LOOP
    PERFORM pg_temp.expect_integrity_rejection(format(
      'UPDATE payse.recurring_plans SET first_occurrence_month=%L WHERE id=%L',wrong_month,plan),'23514');
  END LOOP;
  PERFORM pg_temp.expect_integrity_rejection(format(
    'INSERT INTO payse.recurring_plan_revisions SELECT %L,user_id,plan_id,%L,label,amount_krw,monthly_day,payment_timing,schedule_basis,withdrawal_account_id,card_id,status,schedule_overrides,true FROM payse.recurring_plan_revisions WHERE id=%L',
    before_start_revision,(first_month-interval '1 month')::date,initial),'23514');
  PERFORM pg_temp.expect_integrity_rejection(format(
    'INSERT INTO payse.recurring_plans (id,user_id,first_occurrence_month) VALUES (%L,%L,%L)',
    orphan_plan,u,first_month),'23514');
  PERFORM pg_temp.expect_integrity_rejection(format(
    'UPDATE payse.obligations SET occurrence_month=%L WHERE id=%L',
    (first_month-interval '1 month')::date,pg_temp.ctx_uuid('future_initial_obligation_id')),'23514');
  PERFORM pg_temp.expect_integrity_rejection(format(
    'UPDATE payse.occurrence_overrides SET occurrence_month=%L WHERE user_id=%L AND plan_id=%L AND occurrence_month=%L',
    (first_month-interval '1 month')::date,u,plan,override_month),'23514');

  -- Equality stays valid, and retired history contributes to the minimum too.
  UPDATE payse.recurring_plans SET first_occurrence_month=first_month WHERE id=plan RETURNING id INTO STRICT changed_id;
  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT jsonb_agg(to_jsonb(o) ORDER BY id) INTO original_occurrences FROM payse.obligations o WHERE user_id=u;
  SELECT jsonb_agg(to_jsonb(o) ORDER BY plan_id,occurrence_month) INTO original_overrides FROM payse.occurrence_overrides o WHERE user_id=u;
  SET CONSTRAINTS ALL DEFERRED;
  UPDATE payse.recurring_plan_revisions SET is_current=false WHERE id=initial RETURNING id INTO STRICT changed_id;
  INSERT INTO payse.recurring_plan_revisions
    SELECT replacement,user_id,plan_id,effective_from_month,label,amount_krw+1,monthly_day,payment_timing,schedule_basis,
      withdrawal_account_id,card_id,status,schedule_overrides,true
    FROM payse.recurring_plan_revisions WHERE id=initial RETURNING id INTO STRICT changed_id;
  SET CONSTRAINTS ALL IMMEDIATE;
  IF (SELECT jsonb_agg(to_jsonb(o) ORDER BY id) FROM payse.obligations o WHERE user_id=u) IS DISTINCT FROM original_occurrences OR
     (SELECT jsonb_agg(to_jsonb(o) ORDER BY plan_id,occurrence_month) FROM payse.occurrence_overrides o WHERE user_id=u) IS DISTINCT FROM original_overrides THEN
    RAISE EXCEPTION 'First-month validation changed pinned occurrences';
  END IF;
  RAISE NOTICE 'PASS plan first month: 8 invalid boundaries rejected; equality and retired pinned history accepted';
END $$;

DO $$
DECLARE
  u uuid := pg_temp.ctx_uuid('owner_id');
  account uuid := pg_temp.ctx_uuid('owner_account_id');
  next_account uuid := pg_temp.ctx_uuid('alternate_salary_account_id');
  salary_tx uuid := pg_temp.ctx_uuid('salary_transaction_id');
  other_tx uuid := pg_temp.ctx_uuid('other_salary_transaction_id');
  outgoing_tx uuid := pg_temp.ctx_uuid('outgoing_transaction_id');
  missing_tx uuid := gen_random_uuid(); invalid_tx uuid; changed_id uuid;
  invalid_proof_count integer := 0;
  proof jsonb; source_before jsonb; transactions_before jsonb; state text;
BEGIN
  IF EXISTS(SELECT 1 FROM payse.financial_transactions WHERE id=missing_tx)
    OR EXISTS(SELECT 1 FROM payse.transaction_references WHERE transaction_id=missing_tx) THEN
    RAISE EXCEPTION 'Missing-transaction probe already exists';
  END IF;
  proof:=jsonb_build_array(jsonb_build_object('expectedPayDate',pg_temp.ctx_text('salary_evidence_date'),'confirmation','confirmed','transactionIds',jsonb_build_array(salary_tx)));
  UPDATE payse.source_contexts SET salary_evidence=proof WHERE user_id=u RETURNING user_id INTO STRICT changed_id;
  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT to_jsonb(s) INTO STRICT source_before FROM payse.source_contexts s WHERE user_id=u;
  SELECT jsonb_agg(to_jsonb(t) ORDER BY id) INTO transactions_before FROM payse.financial_transactions t WHERE user_id=u;

  UPDATE payse.user_settings SET salary_account_id=next_account WHERE user_id=u RETURNING user_id INTO STRICT changed_id;
  SET CONSTRAINTS ALL IMMEDIATE;
  UPDATE payse.user_settings SET salary_account_id=NULL WHERE user_id=u RETURNING user_id INTO STRICT changed_id;
  SET CONSTRAINTS ALL IMMEDIATE;
  IF (SELECT to_jsonb(s) FROM payse.source_contexts s WHERE user_id=u) IS DISTINCT FROM source_before OR
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM payse.financial_transactions t WHERE user_id=u) IS DISTINCT FROM transactions_before THEN
    RAISE EXCEPTION 'Salary account setting changed source evidence or transactions';
  END IF;

  -- Each prepared invalid reference is checked, including every statement purchase.
  FOREACH state IN ARRAY ARRAY['approved','cancelled','unknown'] LOOP
    PERFORM pg_temp.expect_integrity_rejection(format(
      'UPDATE payse.financial_transactions SET status=%L WHERE id=%L',state,salary_tx),'23514');
  END LOOP;
  PERFORM pg_temp.expect_integrity_rejection(format(
    'UPDATE payse.financial_transactions SET reflection_reason=%L WHERE id=%L','not_reflected',salary_tx),'23514');
  FOREACH invalid_tx IN ARRAY ARRAY[other_tx,outgoing_tx] || pg_temp.ctx_uuid_array('card_transaction_ids') || ARRAY[missing_tx] LOOP
    PERFORM pg_temp.expect_integrity_rejection(format(
      'UPDATE payse.source_contexts SET salary_evidence=jsonb_build_array(jsonb_build_object(%L,%L,%L,%L,%L,jsonb_build_array(%L::uuid))) WHERE user_id=%L',
      'expectedPayDate',pg_temp.ctx_text('salary_evidence_date'),'confirmation','confirmed','transactionIds',invalid_tx,u),'23514');
    invalid_proof_count:=invalid_proof_count+1;
  END LOOP;
  UPDATE payse.user_settings SET salary_account_id=account WHERE user_id=u RETURNING user_id INTO STRICT changed_id;
  SET CONSTRAINTS ALL IMMEDIATE;
  RAISE NOTICE 'PASS salary source independence: 2 setting changes accepted; % invalid proofs rejected',4+invalid_proof_count;
END $$;
ROLLBACK;
