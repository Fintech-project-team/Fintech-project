-- Disposable database only. Every mutation in this file is rolled back.
BEGIN;
SELECT pg_temp.assert_test_context();
SET CONSTRAINTS ALL DEFERRED;
CREATE FUNCTION pg_temp.expect_rejected(command text, expected_state text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  BEGIN
    EXECUTE command;
    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = expected_state THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'Expected %, got %: %', expected_state, SQLSTATE, SQLERRM;
  END;
  RAISE EXCEPTION 'Unsafe mutation was accepted: %', command;
END $$;

DO $$
DECLARE
  u uuid := pg_temp.ctx_uuid('owner_id');
  other_user uuid := pg_temp.ctx_uuid('other_owner_id');
  account uuid := pg_temp.ctx_uuid('owner_account_id');
  other_account uuid := pg_temp.ctx_uuid('other_account_id');
  repair uuid := pg_temp.ctx_uuid('partial_obligation_id');
  rent uuid := pg_temp.ctx_uuid('other_obligation_id');
  link uuid := pg_temp.ctx_uuid('partial_settlement_id');
  allocation uuid := pg_temp.ctx_uuid('allocation_id');
  reserve uuid := pg_temp.ctx_uuid('reserve_id');
  txn uuid := pg_temp.ctx_uuid('partial_transaction_id');
  second_txn uuid := pg_temp.ctx_uuid('cycle_peer_transaction_id');
  revision uuid := pg_temp.ctx_uuid('referenced_revision_id');
  missing_card uuid := gen_random_uuid();
  revision_month date;
  changed_id uuid;
  old_balance bigint;
  original_amount bigint;
  n integer;
BEGIN
  SELECT effective_from_month INTO STRICT revision_month
  FROM payse.recurring_plan_revisions
  WHERE id = revision;
  IF EXISTS (
    SELECT 1
    FROM payse.financial_cards
    WHERE id = missing_card
  ) THEN
    RAISE EXCEPTION 'Missing-card probe already exists';
  END IF;

  -- Sum failures, although each individual value is within its column bounds.
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.settlement_links SET allocated_krw=40001 WHERE id=%L', link),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'INSERT INTO payse.settlement_links SELECT gen_random_uuid(),user_id,%L,transaction_id,1,method,evidence,NULL FROM payse.settlement_links WHERE id=%L',
      rent,
      link
    ),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.reserve_allocations SET amount_krw=9000000000000 WHERE id=%L', allocation),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'UPDATE payse.reserve_allocations SET amount_krw=40000 WHERE id=%L; INSERT INTO payse.reserve_allocations SELECT gen_random_uuid(),user_id,reserve_id,obligation_id,amount_krw,released_krw,release_evidence FROM payse.reserve_allocations WHERE id=%L',
      allocation,
      allocation
    ),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.settlement_links SET invalidated_at=now() WHERE id=%L', link),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.obligations SET status=%L WHERE id=%L', 'cancelled', repair),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.reserves SET cancelled_at=now() WHERE id=%L', reserve),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'UPDATE payse.recurring_plan_revisions SET effective_from_month=%L WHERE id=%L',
      (revision_month+interval '1 month')::date,
      revision
    ),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'UPDATE payse.financial_transactions SET original_transaction_id=%L WHERE id=%L; UPDATE payse.financial_transactions SET original_transaction_id=%L WHERE id=%L',
      second_txn,
      txn,
      txn,
      second_txn
    ),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'UPDATE payse.transaction_references SET resolution=%L,reason=%L WHERE user_id=%L AND transaction_id=%L',
      'unavailable',
      'not_provided',
      u,
      txn
    ),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'INSERT INTO payse.transaction_relations SELECT user_id,kind,to_id,from_id,evidence_ref FROM payse.transaction_relations WHERE user_id=%L AND kind=%L AND from_id=%L AND to_id=%L',
      u,
      pg_temp.ctx_text('relation_kind'),
      pg_temp.ctx_uuid('relation_from_id'),
      pg_temp.ctx_uuid('relation_to_id')
    ),
    '23505'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'INSERT INTO payse.occurrence_overrides SELECT user_id,plan_id,occurrence_month,plan_revision_id,amount_krw,due_date,withdrawal_account_id,status FROM payse.obligations WHERE id=%L',
      pg_temp.ctx_uuid('recurring_obligation_id')
    ),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.financial_accounts SET as_of=%L WHERE id=%L', 'infinity', account),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.obligations SET due_date=%L WHERE id=%L', 'infinity', repair),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.reserves SET label=%L WHERE id=%L', '   ', reserve),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.reserves SET amount_krw=NULL WHERE id=%L', reserve),
    '23502'
  );
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.reserves SET amount_krw=%L WHERE id=%L', '9223372036854775808', reserve),
    '22003'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'UPDATE payse.reserves SET user_id=%L,account_id=%L WHERE id=%L',
      other_user,
      other_account,
      reserve
    ),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'UPDATE payse.source_contexts SET coverage=jsonb_build_array(jsonb_build_object(%L,%L,%L,%L)) WHERE user_id=%L',
      'targetKind',
      'account',
      'targetId',
      other_account,
      u
    ),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'UPDATE payse.source_contexts SET salary_evidence=%L::jsonb WHERE user_id=%L',
      jsonb_build_array(jsonb_build_object('payMonth', pg_temp.ctx_text('salary_evidence_month'), 'expectedPayDate', pg_temp.ctx_text('salary_evidence_date'), 'confirmation', 'confirmed', 'transactionIds', '[]'::jsonb))::text,
      u
    ),
    '23514'
  );
  PERFORM pg_temp.expect_rejected(
    format(
      'UPDATE payse.user_attributes SET card_plan_overrides=jsonb_build_array(jsonb_build_object(%L,%L::uuid,%L,25)) WHERE user_id=%L',
      'cardId',
      missing_card,
      'plannedPaymentDay',
      u
    ),
    '23514'
  );

  -- A changed source version without all dependent records must roll back both edits.
  SELECT balance_krw INTO STRICT old_balance
  FROM payse.financial_accounts
  WHERE id = account;
  PERFORM pg_temp.expect_rejected(
    format(
      'UPDATE payse.financial_accounts SET balance_krw=123 WHERE id=%L; UPDATE payse.source_contexts SET source_version=%L WHERE user_id=%L',
      account,
      'unfinished-source',
      u
    ),
    '23503'
  );
  IF (SELECT balance_krw
    FROM payse.financial_accounts
    WHERE id = account) IS DISTINCT FROM old_balance THEN
    RAISE EXCEPTION 'Partial write survived failure';
  END IF;

  -- Numeric limit is inclusive and source balance decline does not shrink protected funds.
  SELECT amount_krw INTO STRICT original_amount
  FROM payse.reserves
  WHERE id = reserve;
  UPDATE payse.financial_accounts
  SET balance_krw = -9000000000000
  WHERE id = account
  RETURNING id INTO STRICT changed_id;
  SET CONSTRAINTS ALL IMMEDIATE;
  IF (SELECT amount_krw
    FROM payse.reserves
    WHERE id = reserve) IS DISTINCT FROM original_amount THEN
    RAISE EXCEPTION 'Automatic reserve shrink';
  END IF;
  UPDATE payse.financial_accounts
  SET balance_krw = old_balance
  WHERE id = account
  RETURNING id INTO STRICT changed_id;
  SET CONSTRAINTS ALL DEFERRED;

  -- 100 sequential retry attempts are not called a concurrent connection test.
  FOR n IN 1..100 LOOP
    PERFORM pg_temp.expect_rejected(
      format(
        'INSERT INTO payse.write_receipts SELECT gen_random_uuid(),user_id,operation_key,request_digest,action,changed_refs,before_after,result_version,created_at FROM payse.write_receipts WHERE id=%L',
        pg_temp.ctx_uuid('write_receipt_id')
      ),
      '23505'
    );
  END LOOP;
  RAISE NOTICE 'PASS extreme storage cases and 100 sequential duplicate-key attempts';
END $$;

-- Multi-table correction succeeds only when release evidence/state change together.
DO $$
DECLARE
  changed_id uuid;
BEGIN
  UPDATE payse.settlement_links
  SET invalidated_at = now()
  WHERE id = pg_temp.ctx_uuid('partial_settlement_id')
  RETURNING id INTO STRICT changed_id;
  UPDATE payse.reserve_allocations
  SET released_krw = 0, release_evidence = '[]'
  WHERE id = pg_temp.ctx_uuid('allocation_id')
  RETURNING id INTO STRICT changed_id;
  UPDATE payse.reserves
  SET amount_krw = amount_krw+40000
  WHERE id = pg_temp.ctx_uuid('reserve_id')
  RETURNING id INTO STRICT changed_id;
  SET CONSTRAINTS ALL IMMEDIATE;
  RAISE NOTICE 'PASS atomic correction without changing source transactions';
END $$;

-- A second edit for the SAME future starting month preserves already-pinned revisions.
DO $$
DECLARE
  u uuid := pg_temp.ctx_uuid('future_owner_id');
  old_revision uuid := pg_temp.ctx_uuid('future_revision_id');
  plan uuid := pg_temp.ctx_uuid('future_plan_id');
  new_revision uuid := gen_random_uuid();
  changed_id uuid;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM payse.recurring_plan_revisions
    WHERE id = new_revision
  ) THEN
    RAISE EXCEPTION 'New revision probe already exists';
  END IF;
  PERFORM pg_temp.expect_rejected(
    format('UPDATE payse.recurring_plan_revisions SET amount_krw=115000 WHERE id=%L', old_revision),
    '23514'
  );
  SET CONSTRAINTS ALL DEFERRED;
  UPDATE payse.recurring_plan_revisions
  SET is_current = false
  WHERE id = old_revision
  RETURNING id INTO STRICT changed_id;
  INSERT INTO payse.recurring_plan_revisions SELECT new_revision, user_id, plan_id, effective_from_month, label, 115000, monthly_day, payment_timing, schedule_basis, withdrawal_account_id, card_id, status, schedule_overrides, true
  FROM payse.recurring_plan_revisions
  WHERE id = old_revision
  RETURNING id INTO STRICT changed_id;
  SET CONSTRAINTS ALL IMMEDIATE;
  IF NOT EXISTS (
    SELECT 1
    FROM payse.occurrence_overrides
    WHERE user_id = u
      AND plan_id = plan
      AND occurrence_month = pg_temp.ctx_text('override_occurrence_month')::date
      AND plan_revision_id = old_revision
      AND amount_krw = 120000
  ) THEN
    RAISE EXCEPTION 'Pinned individual occurrence lost';
  END IF;
  IF (SELECT count(*)
    FROM payse.recurring_plan_revisions
    WHERE user_id = u
      AND plan_id = plan
      AND effective_from_month = pg_temp.ctx_text('future_revision_month')::date
      AND is_current) <> 1 THEN
    RAISE EXCEPTION 'Future authority not unique';
  END IF;
  RAISE NOTICE 'PASS repeated future-month edit preserves pinned history';
END $$;
ROLLBACK;
