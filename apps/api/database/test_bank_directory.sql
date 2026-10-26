-- 2026-10-23: Verify the reviewed directory seed; run with the existing test context.
-- Counts are independent expectations for the reviewed release, not product limits.
BEGIN;
SELECT pg_temp.assert_test_context();
DO $$
BEGIN
  IF (SELECT count(*) FROM payse.institutions WHERE kind='bank') <> 20
     OR (SELECT count(*) FROM payse.institutions WHERE kind='card') <> 4 THEN
    RAISE EXCEPTION 'Reviewed bank/card directory seed count differs';
  END IF;
  IF (SELECT count(DISTINCT institution_code) FROM payse.financial_accounts) <> 5
     OR (SELECT count(DISTINCT institution_code) FROM payse.financial_cards) <> 4 THEN
    RAISE EXCEPTION 'Directory membership created unsupported user products';
  END IF;
  IF EXISTS (
    SELECT 1 FROM payse.institution_links l
    JOIN payse.institutions i ON i.code=l.institution_code AND i.kind='bank'
    WHERE NOT EXISTS (
      SELECT 1 FROM payse.financial_accounts a
      WHERE a.user_id=l.user_id AND a.institution_code=l.institution_code
    )
  ) THEN
    RAISE EXCEPTION 'Reference-only bank was incorrectly consented';
  END IF;
  IF (SELECT count(*) FROM information_schema.tables
      WHERE table_schema='payse' AND table_type='BASE TABLE') <> 22
     OR (SELECT count(*) FROM information_schema.columns WHERE table_schema='payse') <> 175 THEN
    RAISE EXCEPTION 'Fixture reference data unexpectedly changed physical schema';
  END IF;
END $$;
ROLLBACK;
