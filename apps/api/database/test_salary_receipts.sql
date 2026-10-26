-- Explicit nominal-month probes are contract inputs, not inferred payroll facts.
-- All source/settings mutations are rolled back; IDs come from validated context.
BEGIN;
SELECT pg_temp.assert_test_context();
SET CONSTRAINTS ALL DEFERRED;

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

DO $$
DECLARE
  owner uuid := pg_temp.ctx_uuid('owner_id');
  tx uuid := pg_temp.ctx_uuid('salary_transaction_id');
  proof jsonb := jsonb_build_object('payMonth', '2026-10', 'expectedPayDate', '2026-10-25', 'confirmation', 'unknown', 'transactionIds', '[]'::jsonb);
  invalid jsonb;
  changed uuid;
  original jsonb;
  pair jsonb;
BEGIN
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof-'payMonth'));
  FOR invalid IN SELECT e
  FROM jsonb_array_elements('[null,"",202610,true,[],{},"2026-00","2026-13","2026-1","0000-01","10000-01","2026-10 "," 2026-10","2026-10-01","２０２６-１０"]'::jsonb) e LOOP
    PERFORM pg_temp.reject_salary(jsonb_build_array(jsonb_set(proof, '{payMonth}', invalid)));
  END LOOP;
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof, proof||'{"expectedPayDate":"2026-10-30"}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof||'{"expectedPayDate":"2026-02-30"}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof||'{"expectedPayDate":null}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof||'{"transactionIds":null}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof||'{"transactionIds":{},"confirmation":"confirmed"}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof||'{"transactionIds":[null]}'));
  PERFORM pg_temp.reject_salary(jsonb_build_array(proof||'{"transactionIds":["bad-id"]}'));
  PERFORM pg_temp.reject_salary('[null]'::jsonb);
  PERFORM pg_temp.reject_salary('[[]]'::jsonb);

  -- Both authorized calendar-boundary schedules are valid source facts.
  pair := jsonb_build_array(
    proof||'{"payMonth":"2026-11","expectedPayDate":"2026-10-30"}',
    proof||'{"payMonth":"2026-10","expectedPayDate":"2026-11-02"}');
  UPDATE payse.source_contexts
  SET salary_evidence = pair
  WHERE user_id = owner
  RETURNING user_id INTO STRICT changed;
  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT salary_evidence INTO STRICT original
  FROM payse.source_contexts
  WHERE user_id = owner;
  IF original <> pair THEN
    RAISE EXCEPTION 'Moved schedule was rewritten';
  END IF;

  -- Distinct nominal cycles sharing one date stay intact; the server does not calculate periods.
  pair := jsonb_build_array(proof||'{"expectedPayDate":"2026-10-30"}', proof||'{"payMonth":"2026-11","expectedPayDate":"2026-10-30"}');
  UPDATE payse.source_contexts
  SET salary_evidence = pair
  WHERE user_id = owner
  RETURNING user_id INTO STRICT changed;
  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT salary_evidence INTO STRICT original
  FROM payse.source_contexts
  WHERE user_id = owner;
  IF original <> pair THEN
    RAISE EXCEPTION 'Same-date cycles were merged or discarded';
  END IF;

  UPDATE payse.user_attributes
  SET salary_day = 10, salary_account_id = NULL
  WHERE user_id = owner
  RETURNING user_id INTO STRICT changed;
  SET CONSTRAINTS ALL IMMEDIATE;
  IF (SELECT salary_evidence
    FROM payse.source_contexts
    WHERE user_id = owner) <> pair THEN
    RAISE EXCEPTION 'Settings changed nominal source evidence';
  END IF;
  -- An independently selected posted incoming transaction may precede its schedule.
  proof := proof||jsonb_build_object('confirmation', 'confirmed', 'transactionIds', jsonb_build_array(tx));
  UPDATE payse.source_contexts
  SET salary_evidence = jsonb_build_array(proof)
  WHERE user_id = owner
  RETURNING user_id INTO STRICT changed;
  SET CONSTRAINTS ALL IMMEDIATE;
  RAISE NOTICE 'PASS salary nominal month: invalid/duplicate rejection, moved/same-date source preservation, setting independence';
END $$;
ROLLBACK;
