"""Salary source validation; no home calculation, HTTP replay or pending-protection implementation."""
import copy
import json
from pathlib import Path
import sys
import unittest

API = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API / 'fixtures'))
from validate import validate_snapshot
from export_sql import financial_rows, load_sources
from testing.scenarios.export_state import export as export_scenario


class SalaryReceiptTests(unittest.TestCase):
    """2026-10-23: Exercise nominal cycles independently of deposit/schedule dates."""

    def setUp(self):
        """2026-10-23: Load a fresh unknown receipt for each unittest case."""
        self.snapshot = json.loads((API / 'fixtures/generated/snapshots/salary-wait.json').read_text(encoding='utf-8'))

    def evidence(self):
        """2026-10-23: Return this test's isolated receipt list to the contract probes."""
        return self.snapshot['settings']['salary']['receiptEvidence']

    def test_required_nominal_month_and_invalid_types(self):
        """2026-10-23: Reject missing or malformed nominal months without inferring dates."""
        for value in (None, '', 202610, True, [], {}, '2026-00', '2026-13',
                      '2026-1', '0000-01', '10000-01', '2026-10 ', ' 2026-10',
                      '2026-10-01', '２０２６-１０'):
            with self.subTest(value=value):
                probe = copy.deepcopy(self.snapshot)
                probe['settings']['salary']['receiptEvidence'][0]['payMonth'] = value
                with self.assertRaises(ValueError):
                    validate_snapshot(probe)
        self.evidence()[0].pop('payMonth')
        with self.assertRaises(ValueError):
            validate_snapshot(self.snapshot)

    def test_same_cycle_is_rejected_even_with_different_dates(self):
        """2026-10-23: A different scheduled date cannot create a second copy of one cycle."""
        second = copy.deepcopy(self.evidence()[0])
        second['expectedPayDate'] = '2026-10-30'
        self.evidence().append(second)
        with self.assertRaisesRegex(ValueError, 'duplicate salary payMonth'):
            validate_snapshot(self.snapshot)

    def test_different_cycles_keep_identical_dates(self):
        """2026-10-23: Preserve two unknown cycles with the same explicit source date."""
        self.evidence()[0]['expectedPayDate'] = '2026-10-30'
        self.evidence().append({**self.evidence()[0], 'payMonth': '2026-11'})
        before = copy.deepcopy(self.snapshot)
        validate_snapshot(self.snapshot)
        self.assertEqual(self.snapshot, before)

    def test_holiday_schedule_crosses_calendar_months(self):
        """2026-10-23: Accept explicit month-boundary schedules without confirming a receipt."""
        for month, expected in [('2026-11', '2026-10-30'), ('2026-10', '2026-11-02')]:
            with self.subTest(month=month):
                self.evidence()[0].update(payMonth=month, expectedPayDate=expected)
                validate_snapshot(self.snapshot)

    def test_distant_schedule_is_preserved(self):
        """2026-10-26: Validation keeps source dates without an arbitrary cycle-distance limit."""
        for expected in ('2020-01-01', '2032-12-31'):
            with self.subTest(expected=expected):
                snapshot = copy.deepcopy(self.snapshot)
                snapshot['settings']['salary']['receiptEvidence'][0]['expectedPayDate'] = expected
                before = copy.deepcopy(snapshot)
                validate_snapshot(snapshot)
                self.assertEqual(snapshot, before)

    def test_reversed_schedule_is_preserved(self):
        """2026-10-26: Validation neither sorts nor rewrites reversed source schedules."""
        proof = self.evidence()[0]
        self.evidence()[:] = [
            {**proof, 'payMonth': '2026-10', 'expectedPayDate': '2027-01-02'},
            {**proof, 'payMonth': '2026-11', 'expectedPayDate': '2025-12-01'},
        ]
        before = copy.deepcopy(self.snapshot)
        validate_snapshot(self.snapshot)
        self.assertEqual(self.snapshot, before)

    def test_confirmed_cycle_keeps_shared_schedule(self):
        """2026-10-26: A shared date preserves confirmed income and an unknown next cycle."""
        snapshot = json.loads((API / 'fixtures/generated/snapshots/salary-confirmed.json').read_text(encoding='utf-8'))
        evidence = snapshot['settings']['salary']['receiptEvidence']
        self.assertEqual(len(evidence), 1)
        self.assertEqual(evidence[0]['confirmation'], 'confirmed')
        evidence.append({
            'payMonth': '2026-11',
            'expectedPayDate': evidence[0]['expectedPayDate'],
            'confirmation': 'unknown',
            'transactionIds': [],
        })
        before = copy.deepcopy(snapshot)
        validate_snapshot(snapshot)
        self.assertEqual(snapshot, before)

    def test_confirmed_amount_ignores_expected_ratio(self):
        """2026-10-26: Lower only expected salary; real confirmed transactions stay unchanged."""
        snapshot = json.loads((API / 'fixtures/generated/snapshots/salary-confirmed.json').read_text(encoding='utf-8'))
        salary = snapshot['settings']['salary']
        proof = salary['receiptEvidence'][0]
        self.assertEqual(proof['confirmation'], 'confirmed')
        ids = set(proof['transactionIds'])
        transactions = [row for row in snapshot['transactions'] if row['transactionId'] in ids]
        self.assertEqual(len(transactions), len(ids))
        self.assertTrue(transactions)
        salary['salaryAmountKRW'] = 1
        self.assertTrue(all(row['amountKRW'] > salary['salaryAmountKRW'] for row in transactions))
        before = copy.deepcopy(snapshot)
        validate_snapshot(snapshot)
        self.assertEqual(snapshot, before)

    def test_missing_evidence_stays_empty(self):
        """2026-10-26: Repeat validation cannot invent salary source, balance or protection changes."""
        snapshot = json.loads((API / 'fixtures/generated/snapshots/alpha-ready.json').read_text(encoding='utf-8'))
        snapshot['settings']['salary']['salaryDay'] = 31
        self.assertEqual(snapshot['settings']['salary']['receiptEvidence'], [])
        self.assertTrue(snapshot['reserves'])
        before = copy.deepcopy(snapshot)
        for _ in range(2):
            validate_snapshot(snapshot)
        self.assertEqual(snapshot, before)

    def test_unknown_evidence_stays_unknown(self):
        """2026-10-26: Revalidation without an answer is inert; no HTTP/protection flow is tested."""
        self.assertEqual(self.evidence()[0]['confirmation'], 'unknown')
        self.assertEqual(self.evidence()[0]['transactionIds'], [])
        self.assertTrue(self.snapshot['reserves'])
        before = copy.deepcopy(self.snapshot)
        for _ in range(2):
            validate_snapshot(self.snapshot)
        self.assertEqual(self.snapshot, before)

    def test_schedule_cases_share_financial_facts(self):
        """2026-10-26: Compare manually prepared schedule presence without computing a next date."""
        folder = API / 'fixtures/generated/snapshots'
        provided = json.loads((folder / 'salary-schedule-provided.json').read_text(encoding='utf-8'))
        absent = json.loads((folder / 'salary-schedule-absent.json').read_text(encoding='utf-8'))
        for snapshot in (provided, absent):
            validate_snapshot(snapshot)
            self.assertEqual(snapshot['asOf'], '2026-10-29T12:00:00+09:00')
            self.assertEqual(snapshot['settings']['salary']['salaryDay'], 25)
        self.assertEqual(provided['settings']['salary']['receiptEvidence'], [{
            'payMonth': '2026-11',
            'expectedPayDate': '2026-10-30',
            'transactionIds': [],
            'confirmation': 'unknown',
        }])
        self.assertEqual(absent['settings']['salary']['receiptEvidence'], [])
        self.assertNotEqual(provided['sourceVersion'], absent['sourceVersion'])

        def without_source_version(value):
            """2026-10-26: Ignore only version labels when comparing this test's two source cases."""
            if isinstance(value, dict):
                return {key: without_source_version(item) for key, item in value.items() if key != 'sourceVersion'}
            if isinstance(value, list):
                return [without_source_version(item) for item in value]
            return value

        comparable = copy.deepcopy(provided)
        comparable['settings']['salary']['receiptEvidence'] = []
        self.assertEqual(without_source_version(comparable), without_source_version(absent))

    def test_schedule_cases_export_separately(self):
        """2026-10-26: Existing ordinary storage mapping retains each source; no DB/API is executed."""
        folder = API / 'fixtures/generated'
        names = ('salary-schedule-provided', 'salary-schedule-absent')
        for name in names:
            with self.subTest(name=name):
                snapshots, seeds = load_sources(folder, [name])
                self.assertEqual(len(snapshots), 1)
                snapshot = snapshots[0]
                rows = financial_rows(snapshot, seeds[snapshot['userId']], connected=True)
                sources = [row for table, row in rows if table == 'source_contexts']
                self.assertEqual(len(sources), 1)
                self.assertEqual(sources[0]['salary_evidence'], snapshot['settings']['salary']['receiptEvidence'])
                self.assertEqual(sources[0]['as_of'], '2026-10-29T12:00:00+09:00')
                sql = export_scenario(folder, [name])
                self.assertIn('INSERT INTO payse.source_contexts', sql)
                self.assertIn('INSERT INTO payse.user_attributes', sql)
        with self.assertRaisesRegex(ValueError, 'select only one case per user'):
            export_scenario(folder, names)

    def test_unplanned_early_receipt_does_not_change_schedule(self):
        """2026-10-23: A test-only early transaction retains its explicit nominal cycle and schedule."""
        snapshot = json.loads((API / 'fixtures/generated/snapshots/salary-confirmed.json').read_text(encoding='utf-8'))
        proof = snapshot['settings']['salary']['receiptEvidence'][0]
        ids = set(proof['transactionIds'])
        transactions = [t for t in snapshot['transactions'] if t['transactionId'] in ids]
        self.assertEqual(len(transactions), len(ids))
        for transaction in transactions:
            transaction['bookingDate'] = '2026-10-24'
            transaction['occurredAt'] = transaction['occurredAt'].replace('2026-10-25', '2026-10-24')
        validate_snapshot(snapshot)
        self.assertEqual(proof['payMonth'], '2026-10')
        self.assertEqual(proof['expectedPayDate'], '2026-10-25')
        self.assertEqual(proof['confirmation'], 'confirmed')

    def test_salary_setting_change_preserves_source_proof(self):
        """2026-10-23: User salary settings do not rewrite existing source proof."""
        before = copy.deepcopy(self.evidence())
        self.snapshot['settings']['salary']['salaryDay'] = 10
        self.snapshot['settings']['salary']['salaryAccountId'] = None
        validate_snapshot(self.snapshot)
        self.assertEqual(self.evidence(), before)

    def test_invalid_receipts_are_not_repaired(self):
        """2026-10-23: Reject invalid evidence shapes and values rather than silently repairing them."""
        for replacement in (None, [], 'text', 1):
            with self.subTest(replacement=replacement):
                probe = copy.deepcopy(self.snapshot)
                probe['settings']['salary']['receiptEvidence'] = [replacement]
                with self.assertRaises(ValueError):
                    validate_snapshot(probe)
        for field, value in [('expectedPayDate', '2026-02-30'), ('expectedPayDate', None),
                             ('transactionIds', None), ('transactionIds', '[]'),
                             ('transactionIds', [None]), ('confirmation', 'paid')]:
            with self.subTest(field=field, value=value):
                probe = copy.deepcopy(self.snapshot)
                probe['settings']['salary']['receiptEvidence'][0][field] = value
                with self.assertRaises(ValueError):
                    validate_snapshot(probe)

    def test_receipt_confirmation_and_ownership(self):
        """2026-10-23: Partial and confirmed evidence requires an owned incoming transaction."""
        for name in ['salary-partial', 'salary-confirmed']:
            snapshot = json.loads((API / f'fixtures/generated/snapshots/{name}.json').read_text(encoding='utf-8'))
            validate_snapshot(snapshot)
            proof = snapshot['settings']['salary']['receiptEvidence'][0]
            self.assertEqual(proof['payMonth'], '2026-10')
            matching = [t for t in snapshot['transactions'] if t['transactionId'] == proof['transactionIds'][0]]
            self.assertEqual(len(matching), 1)
            matching[0]['direction'] = 'out'
            with self.assertRaises(ValueError):
                validate_snapshot(snapshot)

    def test_no_ready_scenario_backfill_from_issue_28(self):
        """2026-10-23: Keep unrelated normal-scenario salary backfill outside this contract change."""
        for name in ['alpha-ready', 'beta-ready', 'gamma-month-end']:
            snapshot = json.loads((API / f'fixtures/generated/snapshots/{name}.json').read_text(encoding='utf-8'))
            self.assertEqual(snapshot['settings']['salary']['receiptEvidence'], [])

    def test_old_schema_is_not_implicitly_reinterpreted(self):
        """2026-10-23: An old schema must use the explicit reviewed migration."""
        self.snapshot['schemaVersion'] = 'PAYSE-DRAFT-2'
        with self.assertRaisesRegex(ValueError, 'unsupported contract'):
            validate_snapshot(self.snapshot)


if __name__ == '__main__':
    unittest.main()
