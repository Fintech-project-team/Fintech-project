-- Identity constraints only; a disposable seeded PostgreSQL database is required.
BEGIN;
SELECT pg_temp.assert_test_context();

CREATE FUNCTION pg_temp.reject_identity(command text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE command;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE=expected_state THEN RETURN; END IF;
    RAISE EXCEPTION 'Unexpected identity rejection type';
  END;
  RAISE EXCEPTION 'Invalid identity was accepted';
END $$;

DO $$
DECLARE
  owner uuid := pg_temp.ctx_uuid('owner_id');
  invalid text; changed_id uuid; product_name text;
BEGIN
  IF (SELECT name FROM payse.users WHERE id=owner) IS DISTINCT FROM pg_temp.ctx_text('owner_name') THEN
    RAISE EXCEPTION 'Reviewed name mapping missing';
  END IF;
  FOREACH invalid IN ARRAY ARRAY['', '가', repeat('가',21), ' 가나', '가나 ', '가 나',
    E'가\t나', E'가나\n', '가'||chr(160)||'나', '가'||chr(12288)||'나',
    'ㄱㄴ', '가1', 'éé', '가-나', '😀가'] LOOP
    PERFORM pg_temp.reject_identity(format('UPDATE payse.users SET name=%L WHERE id=%L',invalid,owner),'23514');
  END LOOP;
  FOREACH invalid IN ARRAY ARRAY['010 00000001','010-0000-0001','+821000000001',
    '01100000001','0100000000','010000000001',E'01000000001\n','０１００００００００１'] LOOP
    PERFORM pg_temp.reject_identity(format('UPDATE payse.users SET phone=%L WHERE id=%L',invalid,owner),'23514');
  END LOOP;
  PERFORM pg_temp.reject_identity(format('UPDATE payse.users SET name=NULL WHERE id=%L',owner),'23502');
  PERFORM pg_temp.reject_identity(format('UPDATE payse.users SET phone=NULL WHERE id=%L',owner),'23502');
  PERFORM pg_temp.reject_identity(format('UPDATE payse.users SET name=%L,phone=%L WHERE id=%L',pg_temp.ctx_text('owner_name'),pg_temp.ctx_text('owner_phone'),pg_temp.ctx_uuid('other_owner_id')),'23505');
  UPDATE payse.users SET name='Kim' WHERE id=owner RETURNING id INTO STRICT changed_id;
  UPDATE payse.users SET name=repeat('A',20) WHERE id=owner RETURNING id INTO STRICT changed_id;
  SELECT a.product_name INTO STRICT product_name FROM payse.financial_accounts a WHERE id=pg_temp.ctx_uuid('spaced_product_account_id');
  IF product_name IS DISTINCT FROM pg_temp.ctx_text('spaced_product_name') THEN
    RAISE EXCEPTION 'Financial source product text changed';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='payse'
    AND ((table_name='users' AND column_name IN ('synthetic_name','display_name'))
      OR (table_name='demo_sessions' AND column_name='installation_id'))) THEN
    RAISE EXCEPTION 'Legacy active column remains';
  END IF;
END $$;
ROLLBACK;
