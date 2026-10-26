-- Preserve nominal salary source facts and reject invalid or duplicate cycles.
-- Entry: run_sql_tests.py after test_context.sql validates the disposable fixture DB.
-- Every source/settings probe rolls back. No HTTP replay or protection workflow is tested.
BEGIN;

SELECT pg_temp.assert_test_context();

SET CONSTRAINTS ALL DEFERRED;

-- 2026-10-23: Used by the DO probes to require a storage constraint rejection.
CREATE FUNCTION pg_temp.reject_salary(value jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  affected integer;
BEGIN
  BEGIN
    UPDATE payse.source_contexts
    SET salary_evidence = value
    WHERE user_id = pg_temp.ctx_uuid('owner_id');

    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 1 THEN
      RAISE EXCEPTION 'Salary probe target count differs';
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN check_violation THEN
    RETURN;
  END;

  RAISE EXCEPTION 'Invalid salary evidence was accepted';
END $$;

-- 2026-10-26: Used by the DO probes to verify one accepted source without rewriting it.
CREATE FUNCTION pg_temp.accept_salary(value jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  changed uuid;
  stored jsonb;
BEGIN
  UPDATE payse.source_contexts
  SET salary_evidence = value
  WHERE user_id = pg_temp.ctx_uuid('owner_id')
  RETURNING user_id
  INTO STRICT changed;

  SET CONSTRAINTS ALL IMMEDIATE;

  SELECT salary_evidence
  INTO STRICT stored
  FROM payse.source_contexts
  WHERE user_id = changed;

  IF stored IS DISTINCT FROM value THEN
    RAISE EXCEPTION 'Accepted salary source was rewritten';
  END IF;
END $$;

-- 2026-10-26: Used before/after salary probes to compare complete money/protection rows.
CREATE FUNCTION pg_temp.salary_invariants()
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'accounts', (
      SELECT jsonb_agg(to_jsonb(account) ORDER BY account.id)
      FROM payse.financial_accounts account
      WHERE account.user_id = pg_temp.ctx_uuid('owner_id')
    ),
    'transactions', (
      SELECT jsonb_agg(to_jsonb(entry) ORDER BY entry.id)
      FROM payse.financial_transactions entry
      WHERE entry.user_id = pg_temp.ctx_uuid('owner_id')
    ),
    'reserves', (
      SELECT jsonb_agg(to_jsonb(reserve) ORDER BY reserve.id)
      FROM payse.reserves reserve
      WHERE reserve.user_id = pg_temp.ctx_uuid('owner_id')
    ),
    'allocations', (
      SELECT jsonb_agg(to_jsonb(allocation) ORDER BY allocation.id)
      FROM payse.reserve_allocations allocation
      WHERE allocation.user_id = pg_temp.ctx_uuid('owner_id')
    )
  );
$$;

DO $$
DECLARE
  owner uuid := pg_temp.ctx_uuid('owner_id');
  tx uuid := pg_temp.ctx_uuid('salary_transaction_id');
  proof jsonb := jsonb_build_object(
    'payMonth', '2026-10',
    'expectedPayDate', '2026-10-25',
    'confirmation', 'unknown',
    'transactionIds', '[]'::jsonb
  );
  invalid jsonb;
  changed uuid;
  original jsonb;
  stored jsonb;
  pair jsonb;
  confirmed jsonb;
  expected text;
  received_amount bigint;
BEGIN
  original := pg_temp.salary_invariants();
  IF original->'reserves' = 'null'::jsonb THEN
    RAISE EXCEPTION 'Salary protection preservation probe requires existing reserves';
  END IF;

  -- Invalid shape/date and duplicate nominal months are source errors.
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof - 'payMonth'));
  FOR invalid IN
    SELECT e
    FROM jsonb_array_elements('[null,"",202610,true,[],{},"2026-00","2026-13","2026-1","0000-01","10000-01","2026-10 "," 2026-10","2026-10-01","２０２６-１０"]'::jsonb) e
  LOOP
    PERFORM pg_temp.reject_salary(jsonb_build_array(jsonb_set(proof, '{payMonth}', invalid)));
  END LOOP;

  PERFORM pg_temp.reject_salary(jsonb_build_array(proof, proof || '{"expectedPayDate":"2026-10-30"}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof || '{"expectedPayDate":"2026-02-30"}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof || '{"expectedPayDate":null}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof || '{"transactionIds":null}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof || '{"transactionIds":{},"confirmation":"confirmed"}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof || '{"transactionIds":[null]}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof || '{"transactionIds":["bad-id"]}'));
  PERFORM pg_temp.reject_salary('[null]'::jsonb);
  PERFORM pg_temp.reject_salary('[[]]'::jsonb);

  -- Explicit calendar-boundary schedules remain independent of deposit months.
  pair := jsonb_build_array(
    proof || '{"payMonth":"2026-11","expectedPayDate":"2026-10-30"}',
    proof || '{"payMonth":"2026-10","expectedPayDate":"2026-11-02"}'
  );
  PERFORM pg_temp.accept_salary(pair);

  -- No arbitrary distance or chronological-order limit discards valid source facts.
  FOREACH expected IN ARRAY ARRAY['2020-01-01', '2032-12-31']
  LOOP
    PERFORM pg_temp.accept_salary(jsonb_build_array(
      proof || jsonb_build_object('expectedPayDate', expected)
    ));
  END LOOP;

  pair := jsonb_build_array(
    proof || '{"payMonth":"2026-10","expectedPayDate":"2027-01-02"}',
    proof || '{"payMonth":"2026-11","expectedPayDate":"2025-12-01"}'
  );
  PERFORM pg_temp.accept_salary(pair);

  -- Same-date unknown cycles stay separate; SQL does not decide calculation windows.
  pair := jsonb_build_array(
    proof || '{"expectedPayDate":"2026-10-30"}',
    proof || '{"payMonth":"2026-11","expectedPayDate":"2026-10-30"}'
  );
  PERFORM pg_temp.accept_salary(pair);

  UPDATE payse.user_attributes
  SET salary_day = 10,
      salary_account_id = NULL
  WHERE user_id = owner
  RETURNING user_id
  INTO STRICT changed;

  SET CONSTRAINTS ALL IMMEDIATE;

  SELECT salary_evidence
  INTO STRICT stored
  FROM payse.source_contexts
  WHERE user_id = owner;

  IF stored IS DISTINCT FROM pair THEN
    RAISE EXCEPTION 'Settings changed nominal source evidence';
  END IF;

  -- Keep actual receipts intact and lower only the expected amount in this rollback test.
  SELECT amount_krw
  INTO STRICT received_amount
  FROM payse.financial_transactions
  WHERE user_id = owner
    AND id = tx
    AND record_kind = 'account_entry'
    AND direction = 'in'
    AND status = 'posted'
    AND reflection_reason = 'reflected';

  IF received_amount <= 1 THEN
    RAISE EXCEPTION 'Expected a verified receipt larger than the test salary expectation';
  END IF;

  UPDATE payse.user_attributes
  SET salary_amount_krw = 1
  WHERE user_id = owner
  RETURNING user_id
  INTO STRICT changed;

  confirmed := proof || jsonb_build_object(
    'confirmation', 'confirmed',
    'transactionIds', jsonb_build_array(tx)
  );
  PERFORM pg_temp.accept_salary(jsonb_build_array(confirmed));
  PERFORM pg_temp.accept_salary(jsonb_build_array(
    confirmed,
    proof || '{"payMonth":"2026-11"}'
  ));

  -- Revalidation without an answer leaves unknown evidence unknown; not an HTTP replay test.
  PERFORM pg_temp.accept_salary(jsonb_build_array(proof));
  PERFORM payse.assert_user_storage(owner);
  PERFORM payse.assert_user_storage(owner);

  SELECT salary_evidence
  INTO STRICT stored
  FROM payse.source_contexts
  WHERE user_id = owner;

  IF stored IS DISTINCT FROM jsonb_build_array(proof) THEN
    RAISE EXCEPTION 'Revalidation changed unknown salary evidence';
  END IF;

  -- A month-end rule is a setting, not permission to create or confirm source evidence.
  PERFORM pg_temp.accept_salary('[]'::jsonb);

  UPDATE payse.user_attributes
  SET salary_day = 31
  WHERE user_id = owner
  RETURNING user_id
  INTO STRICT changed;

  SET CONSTRAINTS ALL IMMEDIATE;

  PERFORM payse.assert_user_storage(owner);
  PERFORM payse.assert_user_storage(owner);

  SELECT salary_evidence
  INTO STRICT stored
  FROM payse.source_contexts
  WHERE user_id = owner;

  IF stored IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'Repeated validation created salary evidence';
  END IF;

  IF pg_temp.salary_invariants() IS DISTINCT FROM original THEN
    RAISE EXCEPTION 'Salary probes rewrote money, transactions or existing protection';
  END IF;

  RAISE NOTICE 'PASS salary source: format/duplicate rejection, schedule preservation, no amount heuristic or validation side effects';
END $$;

ROLLBACK;
