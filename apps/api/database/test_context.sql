-- 2026-10-22: Connection-local SQL test helpers; never install in the payse schema.
CREATE FUNCTION pg_temp.ctx_value(key text)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  context jsonb;
BEGIN
  SELECT value INTO STRICT context
  FROM pg_temp.payse_test_context;
  IF NOT context ? key OR context->key = 'null'::jsonb THEN
    RAISE EXCEPTION 'Required test context key missing';
  END IF;
  RETURN context->key;
END $$;

CREATE FUNCTION pg_temp.ctx_text(key text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  value jsonb := pg_temp.ctx_value(key);
BEGIN
  IF jsonb_typeof(value) IS DISTINCT FROM 'string' OR value #>> '{}' = '' THEN
    RAISE EXCEPTION 'Test context text required';
  END IF;
  RETURN value #>> '{}';
END $$;

CREATE FUNCTION pg_temp.ctx_uuid(key text)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  value text := pg_temp.ctx_text(key);
  parsed uuid;
BEGIN
  parsed := value::uuid;
  IF parsed::text IS DISTINCT FROM value THEN
    RAISE EXCEPTION 'Canonical test UUID required';
  END IF;
  RETURN parsed;
END $$;

CREATE FUNCTION pg_temp.ctx_int(key text)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  value jsonb := pg_temp.ctx_value(key);
  parsed bigint;
BEGIN
  IF jsonb_typeof(value) IS DISTINCT FROM 'number' OR value::text !~ '^[1-9][0-9]*$' THEN
    RAISE EXCEPTION 'Positive test integer required';
  END IF;
  parsed := value::text::bigint;
  RETURN parsed;
END $$;

CREATE FUNCTION pg_temp.ctx_uuid_array(key text)
RETURNS uuid[]
LANGUAGE plpgsql
AS $$
DECLARE
  value jsonb := pg_temp.ctx_value(key);
  item jsonb;
  parsed uuid;
  result uuid[] := '{}';
BEGIN
  IF jsonb_typeof(value) IS DISTINCT FROM 'array' OR jsonb_array_length(value) = 0 THEN
    RAISE EXCEPTION 'Nonempty test UUID array required';
  END IF;
  FOR item IN SELECT *
  FROM jsonb_array_elements(value) LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'Test UUID array item must be text';
    END IF;
    parsed := (item #>> '{}')::uuid;
    IF parsed::text IS DISTINCT FROM (item #>> '{}') OR parsed = ANY(result) THEN
      RAISE EXCEPTION 'Test UUID array must contain distinct canonical IDs';
    END IF;
    result := array_append(result, parsed);
  END LOOP;
  RETURN result;
END $$;

CREATE FUNCTION pg_temp.assert_test_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  context jsonb;
  table_name text;
  expected jsonb;
  matched bigint;
  actual_ids uuid[];
  owner uuid := pg_temp.ctx_uuid('owner_id');
  other_owner uuid := pg_temp.ctx_uuid('other_owner_id');
  future_owner uuid := pg_temp.ctx_uuid('future_owner_id');
  allowed_tables text[] := ARRAY['users', 'source_contexts', 'user_attributes', 'financial_accounts',
    'financial_cards', 'financial_transactions', 'obligations', 'reserves', 'reserve_allocations',
    'settlement_links', 'write_receipts', 'card_statements', 'statement_items', 'transaction_relations',
    'recurring_plans', 'recurring_plan_revisions', 'occurrence_overrides'];
BEGIN
  IF current_database() !~ '^payse_fixture_[a-z0-9_]+$' THEN
    RAISE EXCEPTION 'Disposable payse_fixture_ database required';
  END IF;
  SELECT value INTO STRICT context
  FROM pg_temp.payse_test_context;
  IF context#>>'{_meta,format}' IS DISTINCT FROM 'PAYSE-SQL-CONTEXT-1' OR
      context#>>'{_meta,seedMode}' IS DISTINCT FROM 'ready' OR
      owner = other_owner OR owner = future_owner OR other_owner = future_owner THEN
    RAISE EXCEPTION 'Invalid test context metadata/actors';
  END IF;
  IF jsonb_typeof(context->'_rows') IS DISTINCT FROM 'object' OR
      (SELECT count(*)
        FROM jsonb_object_keys(context->'_rows')) <> cardinality(allowed_tables) THEN
    RAISE EXCEPTION 'Expected test table set differs';
  END IF;
  FOREACH table_name IN ARRAY allowed_tables LOOP
    IF jsonb_typeof(context#>ARRAY['_rows', table_name]) IS DISTINCT FROM 'array' OR
        jsonb_array_length(context#>ARRAY['_rows', table_name]) = 0 THEN
      RAISE EXCEPTION 'Expected test rows missing';
    END IF;
    FOR expected IN SELECT *
    FROM jsonb_array_elements(context#>ARRAY['_rows', table_name]) LOOP
      IF jsonb_typeof(expected) IS DISTINCT FROM 'object' OR expected = '{}'::jsonb THEN
        RAISE EXCEPTION 'Expected test row invalid';
      END IF;
      EXECUTE format('SELECT count(*) FROM payse.%I t WHERE to_jsonb(t) @> $1', table_name)
        INTO matched USING expected;
      IF matched <> 1 THEN
        RAISE EXCEPTION 'Test row missing, ambiguous, or inconsistent in %', table_name;
      END IF;
    END LOOP;
  END LOOP;
  IF (SELECT count(*)
    FROM payse.users) <> pg_temp.ctx_int('expected_user_count') OR
      (SELECT count(*)
        FROM payse.financial_accounts) <> pg_temp.ctx_int('expected_account_count') OR
      (SELECT count(*)
        FROM payse.reserves
        WHERE user_id = owner) <> pg_temp.ctx_int('owner_reserve_count') OR
      EXISTS (SELECT 1
        FROM payse.demo_sessions
        WHERE user_id = owner AND ended_at IS NULL) THEN
    RAISE EXCEPTION 'Test seed counts or initial session state differ';
  END IF;
  SELECT array_agg(id ORDER BY id) INTO actual_ids
  FROM payse.financial_accounts
  WHERE user_id = owner;
  IF actual_ids IS DISTINCT FROM (SELECT array_agg(x ORDER BY x)
    FROM unnest(pg_temp.ctx_uuid_array('owner_account_ids')) x) OR
      cardinality(actual_ids) <> pg_temp.ctx_int('owner_account_count') THEN
    RAISE EXCEPTION 'Owner account set differs';
  END IF;
  IF NOT EXISTS (SELECT 1
    FROM payse.users
    WHERE id = owner AND name = pg_temp.ctx_text('owner_name') AND phone = pg_temp.ctx_text('owner_phone')) OR
      NOT EXISTS (SELECT 1
        FROM payse.user_attributes
        WHERE user_id = owner AND salary_account_id = pg_temp.ctx_uuid('owner_account_id')) OR
      NOT EXISTS (SELECT 1
        FROM payse.user_attributes
        WHERE user_id = other_owner AND salary_account_id = pg_temp.ctx_uuid('other_account_id')) OR
      pg_temp.ctx_uuid('spaced_product_account_id') <> pg_temp.ctx_uuid('owner_account_id') OR
      NOT EXISTS (SELECT 1
        FROM payse.financial_accounts
        WHERE id = pg_temp.ctx_uuid('spaced_product_account_id')
        AND user_id = owner
          AND product_name = pg_temp.ctx_text('spaced_product_name')
          AND position(' ' in product_name)>0) THEN
    RAISE EXCEPTION 'Identity/account context roles differ';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM payse.reserve_allocations a
    JOIN payse.reserves r ON (r.user_id, r.id) = (a.user_id, a.reserve_id)
    JOIN payse.obligations o ON (o.user_id, o.id) = (a.user_id, a.obligation_id)
    JOIN payse.settlement_links s ON s.user_id = a.user_id AND s.obligation_id = o.id
    JOIN payse.financial_transactions t ON (t.user_id, t.id) = (s.user_id, s.transaction_id)
    WHERE a.id = pg_temp.ctx_uuid('allocation_id') AND a.user_id = owner AND r.id = pg_temp.ctx_uuid('reserve_id')
      AND o.id = pg_temp.ctx_uuid('partial_obligation_id') AND s.id = pg_temp.ctx_uuid('partial_settlement_id')
      AND t.id = pg_temp.ctx_uuid('partial_transaction_id')
        AND t.id = pg_temp.ctx_uuid('outgoing_transaction_id')
      AND r.account_id = pg_temp.ctx_uuid('owner_account_id')
        AND o.withdrawal_account_id = r.account_id
        AND t.account_id = r.account_id
      AND r.cancelled_at IS NULL AND o.status = 'active' AND s.invalidated_at IS NULL
      AND o.amount_krw = 100000 AND a.amount_krw = 100000 AND a.released_krw = 40000 AND r.amount_krw = 400000
      AND s.allocated_krw = 40000 AND t.amount_krw = 40000 AND t.record_kind = 'account_entry'
      AND t.direction = 'out' AND t.status = 'posted' AND t.reflection_reason = 'reflected'
      AND a.release_evidence = jsonb_build_array(jsonb_build_object('settlementLinkId', s.id,
        'amountKRW', 40000, 'writeReceiptId', pg_temp.ctx_uuid('write_receipt_id')))
  ) THEN
    RAISE EXCEPTION 'Partial settlement roles/boundaries differ';
  END IF;
  IF (SELECT count(*)
    FROM payse.reserve_allocations
    WHERE user_id = owner AND released_krw>0 AND released_krw<amount_krw) <> 1 OR
      NOT EXISTS (SELECT 1
        FROM payse.write_receipts
        WHERE id = pg_temp.ctx_uuid('write_receipt_id') AND user_id = owner) THEN
    RAISE EXCEPTION 'Partial allocation/receipt cardinality differs';
  END IF;
  IF (SELECT count(*)
    FROM payse.obligations o
    WHERE o.user_id = owner AND o.status = 'active' AND o.statement_id IS NULL AND o.plan_id IS NULL
      AND NOT EXISTS (SELECT 1
        FROM payse.reserve_allocations a
        WHERE a.user_id = owner AND a.obligation_id = o.id)
      AND NOT EXISTS (SELECT 1
        FROM payse.settlement_links s
        WHERE s.user_id = owner AND s.obligation_id = o.id AND s.invalidated_at IS NULL)) <> 1 OR
      (SELECT count(*)
        FROM payse.obligations
        WHERE user_id = owner AND statement_id IS NOT NULL AND status = 'active') <> 1 OR
      (SELECT count(*)
        FROM payse.obligations
        WHERE user_id = owner AND plan_id IS NOT NULL) <> 1 OR
      (SELECT count(*)
        FROM payse.transaction_relations
        WHERE user_id = owner AND kind = 'internal_transfer') <> 1 OR
      (SELECT count(*)
        FROM payse.occurrence_overrides
        WHERE user_id = future_owner) <> 1 THEN
    RAISE EXCEPTION 'Test role candidate cardinality differs';
  END IF;
  IF NOT EXISTS (SELECT 1
    FROM payse.obligations o
    WHERE o.id = pg_temp.ctx_uuid('other_obligation_id') AND o.user_id = owner
    AND o.status = 'active' AND o.statement_id IS NULL AND o.plan_id IS NULL
    AND NOT EXISTS (SELECT 1
      FROM payse.reserve_allocations a
      WHERE a.user_id = owner AND a.obligation_id = o.id)
    AND NOT EXISTS (SELECT 1
      FROM payse.settlement_links s
      WHERE s.user_id = owner AND s.obligation_id = o.id AND s.invalidated_at IS NULL)) THEN
    RAISE EXCEPTION 'Other manual obligation role differs';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM payse.obligations o
    JOIN payse.card_statements st ON (st.user_id, st.id) = (o.user_id, o.statement_id)
    JOIN payse.settlement_links s ON (s.user_id, s.obligation_id) = (o.user_id, o.id)
    JOIN payse.financial_transactions t ON (t.user_id, t.id) = (s.user_id, s.transaction_id)
    WHERE o.user_id = owner AND o.id = pg_temp.ctx_uuid('statement_obligation_id') AND s.invalidated_at IS NULL
      AND t.id = pg_temp.ctx_uuid('cycle_peer_transaction_id')
        AND t.id <> pg_temp.ctx_uuid('partial_transaction_id')
      AND t.account_id = pg_temp.ctx_uuid('owner_account_id')
        AND t.record_kind = 'account_entry'
        AND t.direction = 'out'
      AND (SELECT array_agg(si.transaction_id ORDER BY si.transaction_id)
        FROM payse.statement_items si
        WHERE si.user_id = owner AND si.statement_id = st.id)
        IS NOT DISTINCT FROM (SELECT array_agg(x ORDER BY x)
          FROM unnest(pg_temp.ctx_uuid_array('card_transaction_ids')) x)
  ) OR cardinality(pg_temp.ctx_uuid_array('card_transaction_ids')) <> 2 THEN
    RAISE EXCEPTION 'Card statement/withdrawal roles differ';
  END IF;
  IF EXISTS (SELECT 1
    FROM unnest(pg_temp.ctx_uuid_array('card_transaction_ids')) AS requested(transaction_id)
    WHERE NOT EXISTS (SELECT 1
      FROM payse.financial_transactions t
      WHERE t.id = requested.transaction_id AND t.user_id = owner AND t.record_kind = 'card_purchase')) THEN
    RAISE EXCEPTION 'Card proof counterexamples differ';
  END IF;
  IF NOT EXISTS (SELECT 1
    FROM payse.transaction_relations r
    JOIN payse.financial_transactions a ON (a.user_id, a.id) = (r.user_id, r.from_id)
    JOIN payse.financial_transactions b ON (b.user_id, b.id) = (r.user_id, r.to_id)
    WHERE r.user_id = owner AND r.kind = pg_temp.ctx_text('relation_kind') AND r.kind = 'internal_transfer'
      AND r.from_id = pg_temp.ctx_uuid('relation_from_id') AND r.to_id = pg_temp.ctx_uuid('relation_to_id')
      AND ((a.direction = 'out'
        AND a.account_id = pg_temp.ctx_uuid('owner_account_id')
        AND b.direction = 'in'
        AND b.account_id = pg_temp.ctx_uuid('alternate_salary_account_id'))
        OR (b.direction = 'out'
          AND b.account_id = pg_temp.ctx_uuid('owner_account_id')
          AND a.direction = 'in'
          AND a.account_id = pg_temp.ctx_uuid('alternate_salary_account_id')))
      AND a.account_id <> b.account_id AND a.amount_krw = b.amount_krw) THEN
    RAISE EXCEPTION 'Transfer role relations differ';
  END IF;
  IF NOT EXISTS (SELECT 1
    FROM payse.obligations o
    JOIN payse.recurring_plan_revisions r ON (r.user_id, r.id) = (o.user_id, o.plan_revision_id)
    WHERE o.id = pg_temp.ctx_uuid('recurring_obligation_id')
      AND o.user_id = owner
      AND r.id = pg_temp.ctx_uuid('referenced_revision_id')
      AND o.plan_id = r.plan_id AND r.effective_from_month = '2026-10-01') THEN
    RAISE EXCEPTION 'Referenced recurring revision differs';
  END IF;
  IF NOT EXISTS (SELECT 1
    FROM payse.recurring_plans p
    JOIN payse.recurring_plan_revisions i ON (i.user_id, i.plan_id) = (p.user_id, p.id)
    JOIN payse.recurring_plan_revisions f ON (f.user_id, f.plan_id) = (p.user_id, p.id)
    JOIN payse.obligations o ON (o.user_id, o.plan_id) = (p.user_id, p.id)
    JOIN payse.occurrence_overrides v ON (v.user_id, v.plan_id) = (p.user_id, p.id)
    WHERE p.user_id = future_owner AND p.id = pg_temp.ctx_uuid('future_plan_id')
      AND i.id = pg_temp.ctx_uuid('initial_revision_id') AND f.id = pg_temp.ctx_uuid('future_revision_id')
      AND o.id = pg_temp.ctx_uuid('pinned_obligation_id')
        AND o.plan_revision_id = i.id
        AND v.plan_revision_id = f.id
      AND p.first_occurrence_month = '2027-01-01'
        AND p.first_occurrence_month = pg_temp.ctx_text('future_first_month')::date
      AND i.effective_from_month = p.first_occurrence_month AND f.effective_from_month = '2027-03-01'
      AND f.effective_from_month = pg_temp.ctx_text('future_revision_month')::date
      AND o.occurrence_month = '2027-03-01'
        AND o.occurrence_month = pg_temp.ctx_text('pinned_occurrence_month')::date
      AND v.occurrence_month = '2027-04-01'
        AND v.occurrence_month = pg_temp.ctx_text('override_occurrence_month')::date
      AND i.amount_krw = 100000 AND f.amount_krw = 110000 AND o.amount_krw = 100000 AND v.amount_krw = 120000
      AND i.is_current AND f.is_current) THEN
    RAISE EXCEPTION 'Future revision roles/boundaries differ';
  END IF;
  IF NOT EXISTS (SELECT 1
    FROM payse.obligations o
    WHERE o.id = pg_temp.ctx_uuid('future_initial_obligation_id')
      AND o.user_id = future_owner AND o.plan_id = pg_temp.ctx_uuid('future_plan_id')
      AND o.plan_revision_id = pg_temp.ctx_uuid('initial_revision_id')
      AND o.occurrence_month = pg_temp.ctx_text('future_first_month')::date) OR
      (SELECT count(*)
        FROM payse.recurring_plan_revisions
        WHERE user_id = future_owner AND plan_id = pg_temp.ctx_uuid('future_plan_id')
      AND effective_from_month = pg_temp.ctx_text('future_first_month')::date) <> 1 OR
      (SELECT count(*)
        FROM payse.obligations
        WHERE user_id = future_owner AND plan_id = pg_temp.ctx_uuid('future_plan_id')
      AND plan_revision_id = pg_temp.ctx_uuid('initial_revision_id')
        AND occurrence_month >= pg_temp.ctx_text('future_revision_month')::date) <> 1 THEN
    RAISE EXCEPTION 'Future pinned occurrence cardinality differs';
  END IF;
  IF NOT EXISTS (SELECT 1
    FROM payse.financial_transactions t
    WHERE t.id = pg_temp.ctx_uuid('salary_transaction_id') AND t.user_id = owner
    AND t.account_id = pg_temp.ctx_uuid('owner_account_id')
      AND t.record_kind = 'account_entry'
      AND t.direction = 'in'
    AND t.status = 'posted'
      AND t.reflection_reason = 'reflected'
      AND t.booking_date = pg_temp.ctx_text('salary_evidence_date')::date)
      OR NOT EXISTS (SELECT 1
        FROM payse.financial_transactions t
        WHERE t.id = pg_temp.ctx_uuid('other_salary_transaction_id') AND t.user_id = other_owner
    AND t.account_id = pg_temp.ctx_uuid('other_account_id')
      AND t.record_kind = 'account_entry'
      AND t.direction = 'in'
    AND t.status = 'posted' AND t.reflection_reason = 'reflected') THEN
    RAISE EXCEPTION 'Income proof roles differ';
  END IF;
END $$;
