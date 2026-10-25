"""Exercise reviewed v2->v3 salary migration only in an explicit local disposable DB."""
import argparse
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import migrate_common_storage as common
import migrate_salary_evidence as migration
from run_sql_tests import require_disposable_database
from test_context import build_context

API = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API))
sys.path.insert(0, str(API / 'fixtures'))
from reference_data.export_sql import export as reference_sql
from testing.scenarios.export_state import export as scenario_sql

OPTIONS = None


class SalaryEvidenceMigrationTests(unittest.TestCase):
    """2026-10-23: Check explicit nominal cycles, FK updates and complete rollback boundaries."""

    def sql(self, command):
        """2026-10-23: Run a bounded command only against the caller's disposable database."""
        return migration.run_psql(OPTIONS.psql, OPTIONS.database, command, 60)

    def setUp(self):
        """2026-10-23: Prepare v2 rows and relation-derived proof subjects without fixed IDs."""
        migration.require(OPTIONS.database.startswith('payse_fixture_salary_'), 'Dedicated salary migration DB required')
        self.temp = tempfile.TemporaryDirectory(dir=OPTIONS.temp)
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name) / 'archive.json'
        self.mapping_path = Path(self.temp.name) / 'mapping.json'
        self.sql('DROP SCHEMA IF EXISTS payse CASCADE;')
        self.sql((API / 'database/001_initial.sql').read_text(encoding='utf-8'))
        self.sql(common.FROZEN_GUARDS.read_text(encoding='utf-8'))
        self.sql(reference_sql())
        source = scenario_sql(API / 'fixtures/generated', ['alpha-ready', 'beta-ready', 'gamma-month-end'])
        self.sql(source.replace("'PAYSE-DRAFT-3'", "'PAYSE-DRAFT-2'"))
        self.context = build_context(API / 'fixtures/generated')
        self.owner = self.context['owner_id']
        self.proof = {'expectedPayDate': self.context['salary_evidence_date'], 'confirmation': 'confirmed',
                      'transactionIds': [self.context['salary_transaction_id']]}
        self.set_evidence([self.proof])
        self.mapping = self.make_mapping()

    def set_evidence(self, proofs):
        """2026-10-23: Create only a rollback-test source premise using prepared owner/transaction IDs."""
        self.sql('UPDATE payse.source_contexts SET salary_evidence=' + migration.sql_literal(json.dumps(proofs)) +
                 '::jsonb WHERE user_id=' + migration.sql_literal(self.owner) + '::uuid;')

    def state(self):
        """2026-10-23: Capture full reviewed state and invariants for before/after comparisons."""
        return json.loads(self.sql(migration.snapshot_query()))

    def make_mapping(self):
        """2026-10-23: Assign the test's explicit September cycle, never derive it from a deposit date."""
        users = []
        for source in self.state()['sourceRows']:
            users.append({'userId': source['user_id'], 'expectedSourceVersion': source['source_version'],
                          'newSourceVersion': source['source_version'] + ':salary-v3-reviewed',
                          'evidence': [{'proofSha256': migration.canonical_digest(proof), 'payMonth': '2026-09'}
                                       for proof in source['salary_evidence']]})
        return {'format': migration.MAPPING_FORMAT, 'users': users}

    def owner_mapping(self):
        """2026-10-23: Require exactly one reviewed entry for the prepared owner."""
        rows = [row for row in self.mapping['users'] if row['userId'] == self.owner]
        self.assertEqual(len(rows), 1)
        return rows[0]

    def plan(self):
        """2026-10-23: Write explicit input and invoke the read-only planning step."""
        self.mapping_path.write_text(json.dumps(self.mapping), encoding='utf-8')
        return migration.create_plan(OPTIONS.psql, OPTIONS.database, self.mapping_path, self.archive, 60, 3000)

    def apply(self, digest):
        """2026-10-23: Apply only the reviewed archive and its exact SHA-256."""
        return migration.apply_plan(OPTIONS.psql, OPTIONS.database, self.archive, digest, 60, 3000)

    def test_preserves_every_nonversion_fact_and_historical_decision(self):
        """2026-10-23: All old IDs, dates, amounts, user versions and historical source versions survive."""
        before = self.state()
        digest = self.plan()
        self.assertEqual(self.state(), before)
        archive = self.archive.read_bytes()
        self.assertEqual(self.apply(digest), 'APPLIED')
        after = self.state()
        self.assertEqual(before['invariantData'], after['invariantData'])
        self.assertEqual(after['sourceRows'], migration.transformed_sources(before, self.mapping))
        self.assertEqual(before['data']['recurring_decisions'], after['data']['recurring_decisions'])
        self.assertEqual(before['data']['users'], after['data']['users'])
        self.assertEqual(self.archive.read_bytes(), archive)
        for table in migration.CURRENT_TABLES:
            self.assertEqual(self.sql('SELECT count(*) FROM payse.' + table +
                                     ' t JOIN payse.source_contexts c USING(user_id) WHERE t.source_version<>c.source_version;'), '0')

    def test_every_owner_even_empty_evidence_requires_explicit_version_mapping(self):
        """2026-10-23: An empty-evidence owner cannot be silently left on the old schema."""
        self.mapping['users'] = [row for row in self.mapping['users'] if row['userId'] == self.owner]
        before = self.state()
        with self.assertRaises(migration.MigrationError):
            self.plan()
        self.assertFalse(self.archive.exists())
        self.assertEqual(self.state(), before)

    def test_missing_changed_duplicate_and_invalid_month_mapping_rejected(self):
        """2026-10-23: Require one exact proof hash and one valid nominal month for every source proof."""
        baseline = copy.deepcopy(self.mapping)
        for mutation in ('missing', 'hash', 'duplicate', 'month', 'year', 'unchanged_version', 'wrong_source'):
            self.mapping = copy.deepcopy(baseline)
            row = self.owner_mapping()
            if mutation == 'missing': row['evidence'] = []
            elif mutation == 'hash': row['evidence'][0]['proofSha256'] = '0' * 64
            elif mutation == 'duplicate': row['evidence'].append(copy.deepcopy(row['evidence'][0]))
            elif mutation == 'month': row['evidence'][0]['payMonth'] = '2026-13'
            elif mutation == 'year': row['evidence'][0]['payMonth'] = '0000-01'
            elif mutation == 'unchanged_version': row['newSourceVersion'] = row['expectedSourceVersion']
            else: row['expectedSourceVersion'] += ':changed'
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.plan()
            self.assertFalse(self.archive.exists())

    def test_same_date_distinct_cycles_preserved_duplicate_cycle_rejected(self):
        """2026-10-23: Preserve source schedule ties; only Flutter decides their insufficient-data result."""
        unknown = {**self.proof, 'confirmation': 'unknown', 'transactionIds': []}
        self.set_evidence([self.proof, unknown])
        self.mapping = self.make_mapping()
        with self.assertRaises(migration.MigrationError):
            self.plan()
        # The two complete proof objects differ; the explicit cycle assignment is the only change.
        unknown_hash = migration.canonical_digest(unknown)
        for assignment in self.owner_mapping()['evidence']:
            if assignment['proofSha256'] == unknown_hash:
                assignment['payMonth'] = '2026-10'
        before = self.state()
        self.assertEqual(self.apply(self.plan()), 'APPLIED')
        after = self.state()
        self.assertEqual(before['invariantData'], after['invariantData'])
        source = next(row for row in after['sourceRows'] if row['user_id'] == self.owner)
        self.assertEqual(len({p['expectedPayDate'] for p in source['salary_evidence']}), 1)
        self.assertEqual({p['payMonth'] for p in source['salary_evidence']}, {'2026-09', '2026-10'})

    def test_cross_month_schedule_mapping_does_not_infer_from_the_date(self):
        """2026-10-23: Keep the original date when an explicitly reviewed nominal month crosses it."""
        self.owner_mapping()['evidence'][0]['payMonth'] = '2026-10'
        before = self.state()
        self.assertEqual(self.apply(self.plan()), 'APPLIED')
        after = self.state()
        self.assertEqual(before['invariantData'], after['invariantData'])
        self.assertEqual(next(row for row in after['sourceRows'] if row['user_id'] == self.owner)['salary_evidence'][0],
                         {**self.proof, 'payMonth': '2026-10'})

    def test_source_change_after_plan_rejected_without_any_transition(self):
        """2026-10-23: A settings write after review invalidates the complete archived source state."""
        digest = self.plan()
        self.sql('UPDATE payse.users SET data_version=data_version+1 WHERE id=' + migration.sql_literal(self.owner) + '::uuid;')
        before = self.state()
        with self.assertRaises(migration.MigrationError):
            self.apply(digest)
        self.assertEqual(self.state(), before)

    def test_bad_archive_hash_and_repeat_application_rejected(self):
        """2026-10-23: Reject unreviewed bytes and an already-applied plan."""
        digest = self.plan()
        before = self.state()
        with self.assertRaises(migration.MigrationError): self.apply('0' * 64)
        self.assertEqual(self.state(), before)
        self.assertEqual(self.apply(digest), 'APPLIED')
        after = self.state()
        with self.assertRaises(migration.MigrationError): self.apply(digest)
        self.assertEqual(self.state(), after)

    def test_new_source_version_is_data_even_with_sql_delimiters(self):
        """2026-10-23: Quotes, backslashes and dollar delimiters cannot become executable SQL."""
        self.owner_mapping()['newSourceVersion'] += "'\\$salary_migration$; SELECT 'literal'"
        self.assertEqual(self.apply(self.plan()), 'APPLIED')
        actual = next(row for row in self.state()['sourceRows'] if row['user_id'] == self.owner)
        self.assertEqual(actual['source_version'], self.owner_mapping()['newSourceVersion'])

    def test_extra_schema_column_requires_separate_review(self):
        """2026-10-23: Do not silently migrate an unknown physical data model."""
        self.sql('ALTER TABLE payse.source_contexts ADD COLUMN extra text;')
        before = self.state()
        with self.assertRaises(migration.MigrationError): self.plan()
        self.assertFalse(self.archive.exists())
        self.assertEqual(self.state(), before)

    def test_guard_mismatch_rejected_before_writes(self):
        """2026-10-23: The target contract implementation must match the reviewed archive."""
        digest = self.plan()
        before = self.state()
        _, guards = migration.target_guards()
        with patch.object(migration, 'target_guards', return_value=('0' * 64, guards)):
            with self.assertRaises(migration.MigrationError): self.apply(digest)
        self.assertEqual(self.state(), before)

    def test_transaction_failure_rolls_back_guard_and_all_rows(self):
        """2026-10-23: A write failure restores both the original guard and every data row."""
        self.sql("CREATE FUNCTION payse.reject_salary_transition() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.schema_version='PAYSE-DRAFT-3' THEN RAISE EXCEPTION 'forced migration rollback'; END IF; RETURN NEW; END $$; CREATE TRIGGER reject_salary_transition BEFORE UPDATE ON payse.source_contexts FOR EACH ROW EXECUTE FUNCTION payse.reject_salary_transition();")
        digest = self.plan()
        before = self.state()
        with self.assertRaises(migration.MigrationError): self.apply(digest)
        self.assertEqual(self.state(), before)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', required=True)
    parser.add_argument('--psql', required=True)
    parser.add_argument('--temp', type=Path, required=True)
    OPTIONS = parser.parse_args()
    require_disposable_database(OPTIONS.database)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SalaryEvidenceMigrationTests))
    raise SystemExit(not result.wasSuccessful())
