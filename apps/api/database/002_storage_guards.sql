-- Storage invariants only. No U, annual consumption, recurrence generation or simulation.
-- Apply after 001 in the same empty test database, before initial seed.
BEGIN;

CREATE FUNCTION payse.lock_storage_owner() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE owner uuid;
BEGIN
  owner := CASE WHEN TG_OP='DELETE' THEN OLD.user_id ELSE NEW.user_id END;
  IF TG_OP='UPDATE' AND (NEW.user_id<>OLD.user_id OR
     (to_jsonb(OLD) ? 'id' AND to_jsonb(NEW)->>'id' IS DISTINCT FROM to_jsonb(OLD)->>'id')) THEN
    RAISE EXCEPTION 'Immutable owner/entity ID' USING ERRCODE='23514';
  END IF;
  IF TG_TABLE_NAME='recurring_plan_revisions' AND TG_OP='UPDATE' AND
     (to_jsonb(NEW)-'is_current') IS DISTINCT FROM (to_jsonb(OLD)-'is_current') AND
     (EXISTS (SELECT 1 FROM payse.obligations WHERE user_id=owner AND plan_revision_id=(to_jsonb(OLD)->>'id')::uuid) OR
      EXISTS (SELECT 1 FROM payse.occurrence_overrides WHERE user_id=owner AND plan_revision_id=(to_jsonb(OLD)->>'id')::uuid)) THEN
    RAISE EXCEPTION 'Pinned revision payload is immutable; insert replacement and retire old authority' USING ERRCODE='23514';
  END IF;
  PERFORM 1 FROM payse.users WHERE id=owner FOR UPDATE;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION payse.assert_user_storage(owner uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE salary_proof jsonb; proof_date date;
BEGIN
  -- The first nominal month must equal the earliest revision, including retained history.
  IF EXISTS (
    SELECT 1 FROM payse.recurring_plans p
    LEFT JOIN payse.recurring_plan_revisions r ON (r.user_id,r.plan_id)=(p.user_id,p.id)
    WHERE p.user_id=owner GROUP BY p.id,p.first_occurrence_month
    HAVING min(r.effective_from_month) IS DISTINCT FROM p.first_occurrence_month
  ) OR EXISTS (
    SELECT 1 FROM payse.obligations o JOIN payse.recurring_plans p ON (p.user_id,p.id)=(o.user_id,o.plan_id)
    WHERE o.user_id=owner AND o.occurrence_month<p.first_occurrence_month
  ) OR EXISTS (
    SELECT 1 FROM payse.occurrence_overrides o JOIN payse.recurring_plans p ON (p.user_id,p.id)=(o.user_id,o.plan_id)
    WHERE o.user_id=owner AND o.occurrence_month<p.first_occurrence_month
  ) THEN RAISE EXCEPTION 'Invalid plan first month or occurrence before plan start' USING ERRCODE='23514'; END IF;
  IF EXISTS (SELECT 1 FROM payse.recurring_plan_revisions WHERE user_id=owner GROUP BY plan_id,effective_from_month HAVING count(*) FILTER (WHERE is_current)=0)
  THEN RAISE EXCEPTION 'Revision authority retired without replacement' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.transaction_references r
    LEFT JOIN payse.financial_transactions t ON (t.user_id,t.id)=(r.user_id,r.transaction_id)
    WHERE r.user_id=owner AND ((r.resolution='resolved' AND t.id IS NULL) OR (r.resolution='unavailable' AND t.id IS NOT NULL))
  ) THEN RAISE EXCEPTION 'Reference availability disagrees with stored transaction' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    WITH RECURSIVE chain AS (
      SELECT id,original_transaction_id,ARRAY[id] AS seen,false AS cycle
      FROM payse.financial_transactions WHERE user_id=owner
      UNION ALL
      SELECT t.id,t.original_transaction_id,c.seen||t.id,t.id=ANY(c.seen)
      FROM chain c JOIN payse.financial_transactions t ON t.user_id=owner AND t.id=c.original_transaction_id
      WHERE NOT c.cycle
    ) SELECT 1 FROM chain WHERE cycle
  ) THEN RAISE EXCEPTION 'Original transaction cycle' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.settlement_links l
    JOIN payse.financial_transactions t ON (t.user_id,t.id)=(l.user_id,l.transaction_id)
    JOIN payse.obligations o ON (o.user_id,o.id)=(l.user_id,l.obligation_id)
    WHERE l.user_id=owner AND l.invalidated_at IS NULL AND
      (t.record_kind<>'account_entry' OR t.direction<>'out' OR t.status<>'posted' OR
       t.reflection_reason<>'reflected' OR t.account_id IS DISTINCT FROM o.withdrawal_account_id OR o.status<>'active')
  ) THEN RAISE EXCEPTION 'Settlement is not a matching confirmed withdrawal' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.settlement_links l JOIN payse.obligations o ON (o.user_id,o.id)=(l.user_id,l.obligation_id)
    WHERE l.user_id=owner AND l.invalidated_at IS NULL
    GROUP BY o.id,o.amount_krw HAVING sum(l.allocated_krw)>o.amount_krw OR sum(l.allocated_krw)>9000000000000
  ) OR EXISTS (
    SELECT 1 FROM payse.settlement_links l JOIN payse.financial_transactions t ON (t.user_id,t.id)=(l.user_id,l.transaction_id)
    WHERE l.user_id=owner AND l.invalidated_at IS NULL
    GROUP BY t.id,t.amount_krw HAVING sum(l.allocated_krw)>t.amount_krw OR sum(l.allocated_krw)>9000000000000
  ) THEN RAISE EXCEPTION 'Settlement total exceeds obligation or withdrawal' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.reserve_allocations a JOIN payse.reserves r ON (r.user_id,r.id)=(a.user_id,a.reserve_id)
    WHERE a.user_id=owner GROUP BY r.id,r.amount_krw,r.cancelled_at
    HAVING sum(a.amount_krw-a.released_krw)>r.amount_krw OR sum(a.amount_krw-a.released_krw)>9000000000000
      OR (r.cancelled_at IS NOT NULL AND sum(a.amount_krw-a.released_krw)>0)
  ) OR EXISTS (
    SELECT 1 FROM payse.reserve_allocations a JOIN payse.obligations o ON (o.user_id,o.id)=(a.user_id,a.obligation_id)
    WHERE a.user_id=owner GROUP BY o.id,o.user_id,o.amount_krw,o.status
    HAVING sum(a.amount_krw-a.released_krw)>o.amount_krw-COALESCE((
      SELECT sum(l.allocated_krw) FROM payse.settlement_links l WHERE l.user_id=o.user_id AND l.obligation_id=o.id AND l.invalidated_at IS NULL
    ),0) OR sum(a.amount_krw-a.released_krw)>9000000000000
      OR (o.status<>'active' AND sum(a.amount_krw-a.released_krw)>0)
  ) THEN RAISE EXCEPTION 'Unreleased allocation exceeds reserve or unpaid obligation' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.reserve_allocations a WHERE a.user_id=owner AND a.released_krw IS DISTINCT FROM
    COALESCE((SELECT sum((e->>'amountKRW')::bigint) FROM jsonb_array_elements(a.release_evidence) e),0)
  ) OR EXISTS (
    SELECT 1 FROM payse.reserve_allocations a CROSS JOIN LATERAL jsonb_array_elements(a.release_evidence) e
    LEFT JOIN payse.settlement_links l ON l.user_id=a.user_id AND l.id=(e->>'settlementLinkId')::uuid
    LEFT JOIN payse.write_receipts w ON w.user_id=a.user_id AND w.id=(e->>'writeReceiptId')::uuid
    WHERE a.user_id=owner AND (l.id IS NULL OR w.id IS NULL OR l.invalidated_at IS NOT NULL OR
      l.obligation_id<>a.obligation_id OR COALESCE((e->>'amountKRW')::bigint,0)<=0 OR (e->>'amountKRW')::bigint>l.allocated_krw)
  ) THEN RAISE EXCEPTION 'Release evidence missing, foreign or inconsistent' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.reserve_allocations a CROSS JOIN LATERAL jsonb_array_elements(a.release_evidence) e
    JOIN payse.settlement_links l ON l.user_id=a.user_id AND l.id=(e->>'settlementLinkId')::uuid
    WHERE a.user_id=owner GROUP BY l.id,l.allocated_krw
    HAVING sum((e->>'amountKRW')::bigint)>l.allocated_krw
  ) THEN RAISE EXCEPTION 'Same settlement released multiple allocations beyond its amount' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.obligations o
    JOIN payse.card_statements s ON (s.user_id,s.id)=(o.user_id,o.statement_id)
    JOIN payse.financial_cards c ON (c.user_id,c.id)=(s.user_id,s.card_id)
    WHERE o.user_id=owner AND o.status='active' AND
      (s.due_date IS DISTINCT FROM o.due_date OR s.amount_krw<>o.amount_krw OR c.withdrawal_account_id IS DISTINCT FROM o.withdrawal_account_id)
  ) THEN RAISE EXCEPTION 'Statement obligation differs from confirmed source' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.occurrence_overrides x JOIN payse.obligations o
    ON (o.user_id,o.plan_id,o.occurrence_month)=(x.user_id,x.plan_id,x.occurrence_month)
    WHERE x.user_id=owner
  ) THEN RAISE EXCEPTION 'Occurrence exists as both obligation and override' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.recurring_plan_revisions r LEFT JOIN payse.financial_cards c ON (c.user_id,c.id)=(r.user_id,r.card_id)
    WHERE r.user_id=owner AND r.payment_timing='card_bill' AND c.withdrawal_account_id IS DISTINCT FROM r.withdrawal_account_id
  ) OR EXISTS (
    SELECT 1 FROM payse.obligations o JOIN payse.recurring_plan_revisions r ON (r.user_id,r.id)=(o.user_id,o.plan_revision_id)
    WHERE o.user_id=owner AND (r.payment_timing<>'immediate' OR r.effective_from_month>o.occurrence_month)
  ) OR EXISTS (
    -- Accepted individual edits cannot pin a revision that starts after the occurrence.
    SELECT 1 FROM payse.occurrence_overrides o JOIN payse.recurring_plan_revisions r ON (r.user_id,r.id)=(o.user_id,o.plan_revision_id)
    WHERE o.user_id=owner AND r.effective_from_month>o.occurrence_month
  ) THEN RAISE EXCEPTION 'Invalid recurring payment basis or pinned revision' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.transaction_relations r
    JOIN payse.financial_transactions a ON (a.user_id,a.id)=(r.user_id,r.from_id)
    JOIN payse.financial_transactions b ON (b.user_id,b.id)=(r.user_id,r.to_id)
    WHERE r.user_id=owner AND (a.amount_krw<>b.amount_krw OR
      (r.kind='internal_transfer' AND (a.record_kind<>'account_entry' OR b.record_kind<>'account_entry' OR a.direction=b.direction OR a.account_id=b.account_id)) OR
      (r.kind='card_account_pair' AND NOT ((a.record_kind='card_purchase' AND b.record_kind='account_entry') OR (b.record_kind='card_purchase' AND a.record_kind='account_entry'))))
  ) THEN RAISE EXCEPTION 'Invalid explicit transaction relation' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.financial_accounts a JOIN payse.source_contexts c USING (user_id)
    JOIN payse.institutions i ON i.code=a.institution_code
    WHERE a.user_id=owner AND (a.as_of<>c.as_of OR i.kind<>'bank')
  ) OR EXISTS (
    SELECT 1 FROM payse.financial_cards c JOIN payse.institutions i ON i.code=c.institution_code
    WHERE c.user_id=owner AND i.kind<>'card'
  ) THEN RAISE EXCEPTION 'Institution kind or snapshot time disagreement' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.source_contexts c CROSS JOIN LATERAL jsonb_array_elements(c.coverage) e
    WHERE c.user_id=owner AND NOT (
      (e->>'targetKind'='account' AND EXISTS (SELECT 1 FROM payse.financial_accounts a WHERE a.user_id=owner AND a.id=(e->>'targetId')::uuid)) OR
      (e->>'targetKind'='card' AND EXISTS (SELECT 1 FROM payse.financial_cards a WHERE a.user_id=owner AND a.id=(e->>'targetId')::uuid))
    ) IS TRUE
  ) THEN RAISE EXCEPTION 'Coverage references foreign or missing entity' USING ERRCODE='23514'; END IF;
  -- Validate each user's small source array before applying array/UUID operations.
  -- A nominal month is not inferred from the scheduled date or current settings.
  FOR salary_proof IN SELECT e FROM payse.source_contexts c
    CROSS JOIN LATERAL jsonb_array_elements(c.salary_evidence) e WHERE c.user_id=owner LOOP
    IF jsonb_typeof(salary_proof) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Salary evidence must be an object' USING ERRCODE='23514';
    END IF;
    IF NOT (salary_proof ?& ARRAY['payMonth','expectedPayDate','confirmation','transactionIds']) OR
       (salary_proof-ARRAY['payMonth','expectedPayDate','confirmation','transactionIds']::text[]) <> '{}'::jsonb OR
       jsonb_typeof(salary_proof->'payMonth') IS DISTINCT FROM 'string' OR
       (salary_proof->>'payMonth') !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' OR
       left(salary_proof->>'payMonth',4)='0000' OR
       jsonb_typeof(salary_proof->'expectedPayDate') IS DISTINCT FROM 'string' OR
       (salary_proof->>'expectedPayDate') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR
       (salary_proof->>'confirmation') IS NULL OR
       (salary_proof->>'confirmation') NOT IN ('unknown','partial','confirmed') OR
       jsonb_typeof(salary_proof->'transactionIds') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Invalid salary evidence contract' USING ERRCODE='23514';
    END IF;
    BEGIN
      proof_date := (salary_proof->>'expectedPayDate')::date;
      IF to_char(proof_date,'YYYY-MM-DD') <> salary_proof->>'expectedPayDate' THEN
        RAISE EXCEPTION 'Invalid salary scheduled date' USING ERRCODE='23514';
      END IF;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
      RAISE EXCEPTION 'Invalid salary scheduled date' USING ERRCODE='23514';
    END;
    IF (salary_proof->>'confirmation' IN ('partial','confirmed') AND jsonb_array_length(salary_proof->'transactionIds')=0) OR
       EXISTS (SELECT 1 FROM jsonb_array_elements(salary_proof->'transactionIds') ref
         WHERE jsonb_typeof(ref) IS DISTINCT FROM 'string' OR
           (ref #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
      RAISE EXCEPTION 'Invalid salary transaction references' USING ERRCODE='23514';
    END IF;
  END LOOP;
  IF EXISTS (
    SELECT 1 FROM payse.source_contexts c CROSS JOIN LATERAL jsonb_array_elements(c.salary_evidence) proof
    WHERE c.user_id=owner GROUP BY proof->>'payMonth' HAVING count(*)>1
  ) THEN RAISE EXCEPTION 'Duplicate salary nominal month' USING ERRCODE='23514'; END IF;
  -- Different nominal months may share a date. Preserve facts; Flutter reports insufficient periods.
  IF EXISTS (
    -- A past source deposit is independent of the user's current salary-account setting.
    SELECT 1 FROM payse.source_contexts c CROSS JOIN LATERAL jsonb_array_elements(c.salary_evidence) proof
    CROSS JOIN LATERAL jsonb_array_elements_text(proof->'transactionIds') ref
    LEFT JOIN payse.financial_transactions t ON t.user_id=owner AND t.id=ref::uuid
    WHERE c.user_id=owner AND (t.id IS NULL OR t.direction<>'in' OR t.record_kind<>'account_entry' OR
      t.status<>'posted' OR t.reflection_reason<>'reflected')
  ) THEN RAISE EXCEPTION 'Salary evidence references unconfirmed or foreign deposit' USING ERRCODE='23514'; END IF;
  IF EXISTS (
    SELECT 1 FROM payse.user_attributes s CROSS JOIN LATERAL jsonb_array_elements(s.card_plan_overrides) e
    LEFT JOIN payse.financial_cards c ON c.user_id=owner AND c.id=(e->>'cardId')::uuid
    WHERE s.user_id=owner AND c.id IS NULL
  ) OR EXISTS (
    SELECT 1 FROM payse.recurring_decisions d CROSS JOIN LATERAL jsonb_array_elements_text(d.evidence_refs) e
    LEFT JOIN payse.transaction_references r ON r.user_id=owner AND r.transaction_id=e::uuid
    WHERE d.user_id=owner AND r.transaction_id IS NULL
  ) THEN RAISE EXCEPTION 'JSON setting evidence references foreign entity' USING ERRCODE='23514'; END IF;
END $$;

CREATE FUNCTION payse.check_storage_owner() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM payse.assert_user_storage(CASE WHEN TG_OP='DELETE' THEN OLD.user_id ELSE NEW.user_id END);
  RETURN NULL;
END $$;

-- Fixed allowlist: checks run against final transaction state, never infer paid state from dates.
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['source_contexts','financial_accounts','financial_cards','transaction_references','financial_transactions','card_statements','statement_items','transaction_relations','user_attributes','recurring_plans','recurring_plan_revisions','recurring_decisions','obligations','occurrence_overrides','settlement_links','reserves','reserve_allocations','write_receipts'] LOOP
    EXECUTE format('CREATE TRIGGER lock_owner BEFORE INSERT OR UPDATE OR DELETE ON payse.%I FOR EACH ROW EXECUTE FUNCTION payse.lock_storage_owner()',t);
    EXECUTE format('CREATE CONSTRAINT TRIGGER verify_owner AFTER INSERT OR UPDATE OR DELETE ON payse.%I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION payse.check_storage_owner()',t);
  END LOOP;
END $$;

CREATE UNIQUE INDEX relation_pair_once ON payse.transaction_relations(user_id,kind,LEAST(from_id,to_id),GREATEST(from_id,to_id));
REVOKE ALL ON FUNCTION payse.lock_storage_owner(),payse.check_storage_owner(),payse.assert_user_storage(uuid) FROM PUBLIC;
COMMIT;
