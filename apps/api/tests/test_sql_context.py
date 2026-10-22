"""2026-10-22: Offline role-resolution tests; no PostgreSQL connection or source writes."""
import copy
import json
from pathlib import Path
import random
import re
import sys
import unittest
from unittest.mock import patch
from uuid import NAMESPACE_URL, uuid4, uuid5

API = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API / 'database'))
import test_context as context
from run_sql_tests import require_disposable_database


class SqlContextTests(unittest.TestCase):
    """2026-10-22: Require stable relationships rather than names, IDs, or row order."""

    @classmethod
    def setUpClass(cls):
        """2026-10-22: Read canonical private fixtures once, without changing them."""
        cls.directory = API / 'fixtures/generated'
        cls.cases = {case: json.loads((cls.directory / 'snapshots' / f'{case}.json').read_text(encoding='utf-8')) for case in context.CASES}
        cls.seeds = json.loads((cls.directory / 'server-seeds.json').read_text(encoding='utf-8'))['users']
        cls.baseline = context.build_context(cls.directory)

    def derive(self, cases=None, seeds=None):
        """2026-10-22: Resolve isolated copies through the relationship-only entry point."""
        return context.build_from_snapshots(copy.deepcopy(self.cases) if cases is None else cases,
                                            copy.deepcopy(self.seeds) if seeds is None else seeds)

    def test_canonical_context_and_input_preservation(self):
        before = copy.deepcopy((self.cases, self.seeds))
        actual = context.build_from_snapshots(self.cases, self.seeds)
        self.assertEqual(actual, self.baseline)
        self.assertEqual((self.cases, self.seeds), before)
        self.assertEqual(len(actual['card_transaction_ids']), 2)
        self.assertEqual(len(actual['owner_account_ids']), actual['owner_account_count'])
        self.assertNotEqual(actual['owner_id'], actual['other_owner_id'])
        self.assertEqual(actual['owner_name'], '데모알파')

    def test_display_rename_source_rename_and_shuffle_preserve_roles(self):
        cases = copy.deepcopy(self.cases)
        rng = random.Random(22)
        # sourceRef remains unique; changing its formatting is safe but duplicates are not.
        def rename_sources(value):
            if isinstance(value, dict):
                if isinstance(value.get('sourceRef'), str):
                    value['sourceRef'] = 'fixture/renamed/' + value['sourceRef']
                for item in value.values():
                    rename_sources(item)
            elif isinstance(value, list):
                for item in value:
                    rename_sources(item)
        rename_sources(cases)
        # Rename only display values in the recursive pass.
        def rename_displays(value):
            if isinstance(value, dict):
                for key, item in value.items():
                    if key in {'label', 'merchantName', 'productName', 'description'} and isinstance(item, str):
                        value[key] = "changed display ' value"
                    else:
                        rename_displays(item)
            elif isinstance(value, list):
                for item in value:
                    rename_displays(item)
                rng.shuffle(value)
        rename_displays(cases)
        actual = self.derive(cases)
        for key in context.UUID_KEYS | context.ARRAY_KEYS:
            self.assertEqual(actual[key], self.baseline[key], key)
        self.assertEqual(actual['spaced_product_name'], "changed display ' value")
        self.assertIn("changed display ' value", context.context_sql(actual))

    def test_consistent_remap_all_uuids_preserves_relationships(self):
        pattern = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
        mapping = {}
        def remap(value):
            if isinstance(value, str):
                def replace(match):
                    original = match[0]
                    return mapping.setdefault(original, str(uuid5(NAMESPACE_URL, 'sql-context-remap/' + original)))
                return pattern.sub(replace, value)
            if isinstance(value, list):
                return [remap(item) for item in value]
            if isinstance(value, dict):
                return {key: remap(item) for key, item in value.items()}
            return value
        actual = self.derive(remap(self.cases), remap(self.seeds))
        for key in context.UUID_KEYS:
            self.assertEqual(actual[key], mapping[self.baseline[key]], key)
        for key in context.ARRAY_KEYS:
            self.assertEqual(set(actual[key]), {mapping[v] for v in self.baseline[key]}, key)
        self.assertNotEqual(actual['owner_id'], self.baseline['owner_id'])
        # The private canonical seed validator is deliberately not relaxed.
        self.assertEqual(context.build_context(self.directory), self.baseline)

    def test_missing_case_and_duplicate_seed_owner_rejected(self):
        cases = copy.deepcopy(self.cases)
        del cases['alpha-ready']
        with self.assertRaises(ValueError):
            self.derive(cases)
        with self.assertRaises(ValueError):
            self.derive(seeds=[self.seeds[0], self.seeds[0], self.seeds[2]])

    def test_missing_required_role_rejected(self):
        cases = copy.deepcopy(self.cases)
        cases['alpha-ready']['transactionRelations'] = [r for r in cases['alpha-ready']['transactionRelations'] if r['kind'] != 'internal_transfer']
        with self.assertRaisesRegex(ValueError, 'internal transfer requires exactly one'):
            self.derive(cases)

    def test_two_manual_candidates_rejected(self):
        cases = copy.deepcopy(self.cases)
        source = next(o for o in cases['alpha-ready']['obligations'] if o['obligationId'] == self.baseline['other_obligation_id'])
        extra = {**source, 'obligationId': str(uuid4())}
        cases['alpha-ready']['obligations'].append(extra)
        with self.assertRaisesRegex(ValueError, 'other manual obligation requires exactly one'):
            self.derive(cases)

    def test_two_latest_income_candidates_rejected(self):
        cases = copy.deepcopy(self.cases)
        source = next(t for t in cases['alpha-ready']['transactions'] if t['transactionId'] == self.baseline['salary_transaction_id'])
        cases['alpha-ready']['transactions'].append({**source, 'transactionId': str(uuid4()), 'sourceRef': 'fixture/extra-confirmed-income'})
        with self.assertRaisesRegex(ValueError, 'latest income requires exactly one'):
            self.derive(cases)

    def test_wrong_owner_and_relation_rejected(self):
        for field in ('userId', 'reserveId', 'obligationId'):
            cases = copy.deepcopy(self.cases)
            allocation = cases['alpha-ready']['allocations'][0]
            if field == 'userId':
                allocation[field] = cases['beta-ready']['userId']
            elif field == 'reserveId':
                allocation[field] = cases['beta-ready']['reserves'][0]['reserveId']
            else:
                allocation[field] = self.baseline['other_obligation_id']
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.derive(cases)

    def test_missing_and_foreign_receipt_evidence_rejected(self):
        cases = copy.deepcopy(self.cases)
        cases['alpha-ready']['allocations'][0]['releaseEvidence'] = []
        with self.assertRaises(ValueError):
            self.derive(cases)
        cases = copy.deepcopy(self.cases)
        cases['alpha-ready']['allocations'][0]['releaseEvidence'][0]['settlementLinkId'] = cases['beta-ready']['settlements'][0]['linkId']
        with self.assertRaises(ValueError):
            self.derive(cases)

    def test_partial_boundary_changes_rejected(self):
        cases = copy.deepcopy(self.cases)
        cases['alpha-ready']['reserves'][0]['amountKRW'] += 1
        with self.assertRaisesRegex(ValueError, 'partial settlement boundary changed'):
            self.derive(cases)

    def test_future_boundary_changes_rejected(self):
        for field, value in [('amountKRW', 110001), ('effectiveFromMonth', '2027-02')]:
            cases = copy.deepcopy(self.cases)
            revision = next(r for r in cases['gamma-month-end']['recurringPlanRevisions'] if r['revisionId'] == self.baseline['future_revision_id'])
            revision[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.derive(cases)

    def test_context_rejects_missing_wrong_type_and_duplicate_values(self):
        changes = [lambda c: c.pop('owner_id'), lambda c: c.update(owner_id=None),
                   lambda c: c.update(owner_id='not-a-uuid'), lambda c: c.update(expected_user_count=True),
                   lambda c: c.update(card_transaction_ids=[]),
                   lambda c: c.update(card_transaction_ids=[c['card_transaction_ids'][0]] * 2),
                   lambda c: c.update(_meta=None), lambda c: c['_rows'].pop('write_receipts'),
                   lambda c: c['_rows']['reserves'].append(copy.deepcopy(c['_rows']['reserves'][0]))]
        for mutate in changes:
            value = copy.deepcopy(self.baseline)
            mutate(value)
            with self.assertRaises(ValueError):
                context.context_sql(value)

    def test_sql_prelude_is_temporary_and_has_typed_helpers(self):
        sql = context.context_sql(self.baseline)
        for function in ('ctx_uuid', 'ctx_text', 'ctx_int', 'ctx_uuid_array', 'assert_test_context'):
            self.assertIn('CREATE FUNCTION pg_temp.' + function, sql)
        self.assertIn('CREATE TEMP TABLE payse_test_context', sql)
        self.assertNotIn('SECURITY DEFINER', sql)
        self.assertNotIn('CREATE TABLE payse.', sql)
        self.assertNotIn('LIMIT 1', sql)
        self.assertNotIn('DROP SCHEMA', sql)
        self.assertNotIn('COMMIT;', sql)
        self.assertIn("current_database() !~ '^payse_fixture_[a-z0-9_]+$'", sql)

    def test_sql_payload_preserves_quotes_backslashes_and_delimiter_text(self):
        value = copy.deepcopy(self.baseline)
        value['spaced_product_name'] = "quoted ' \\ slash $payse_context$ ; SELECT 'not executed'"
        sql = context.context_sql(value)
        prefix = 'INSERT INTO pg_temp.payse_test_context(value) VALUES ('
        payload = sql.split(prefix, 1)[1].split('::jsonb);\n', 1)[0]
        tag = re.match(r'\$[A-Za-z_]+\$', payload)[0]
        self.assertNotEqual(tag, '$payse_context$')
        self.assertTrue(payload.endswith(tag))
        decoded = json.loads(payload[len(tag):-len(tag)])
        self.assertEqual(decoded, value)


class SqlRunnerSafetyTests(unittest.TestCase):
    """2026-10-22: Prevent test connections to remote or ambiguously configured hosts."""

    def test_explicit_local_fixture_database_allowed(self):
        with patch.dict('os.environ', {'PGHOST': '127.0.0.1'}, clear=True):
            require_disposable_database('payse_fixture_sql_review')

    def test_other_database_or_connection_override_rejected(self):
        cases = [
            ('payse', {'PGHOST': '127.0.0.1'}),
            ('payseXfixture_review', {'PGHOST': '127.0.0.1'}),
            ('payse_fixture_review', {}),
            ('payse_fixture_review', {'PGHOST': 'example.invalid'}),
            ('payse_fixture_review', {'PGHOST': 'localhost', 'PGHOSTADDR': '192.0.2.1'}),
            ('payse_fixture_review', {'PGHOST': 'localhost', 'PGSERVICE': 'another-database'}),
        ]
        for database, environment in cases:
            with self.subTest(database=database, environment=environment):
                with patch.dict('os.environ', environment, clear=True), self.assertRaises(ValueError):
                    require_disposable_database(database)


if __name__ == '__main__':
    unittest.main()
