"""Salary source contract tests; no home/simulation calculations or source rewrites."""
import copy
import json
from pathlib import Path
import sys
import unittest

API = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API / 'fixtures'))
from validate import validate_snapshot


class SalaryReceiptTests(unittest.TestCase):
    """2026-10-23: Exercise nominal cycles independently of deposit/schedule dates."""

    def setUp(self):
        self.snapshot = json.loads((API / 'fixtures/generated/snapshots/salary-wait.json').read_text(encoding='utf-8'))

    def evidence(self):
        return self.snapshot['settings']['salary']['receiptEvidence']

    def test_required_nominal_month_and_invalid_types(self):
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
        second = copy.deepcopy(self.evidence()[0])
        second['expectedPayDate'] = '2026-10-30'
        self.evidence().append(second)
        with self.assertRaisesRegex(ValueError, 'duplicate salary payMonth'):
            validate_snapshot(self.snapshot)

    def test_different_cycles_keep_identical_dates(self):
        self.evidence()[0]['expectedPayDate'] = '2026-10-30'
        self.evidence().append({**self.evidence()[0], 'payMonth': '2026-11'})
        before = copy.deepcopy(self.snapshot)
        validate_snapshot(self.snapshot)
        self.assertEqual(self.snapshot, before)

    def test_confirmed_holiday_movement_crosses_calendar_months(self):
        for month, expected in [('2026-11', '2026-10-30'), ('2026-10', '2026-11-02')]:
            with self.subTest(month=month):
                self.evidence()[0].update(payMonth=month, expectedPayDate=expected)
                validate_snapshot(self.snapshot)

    def test_unplanned_early_receipt_does_not_change_schedule(self):
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
        before = copy.deepcopy(self.evidence())
        self.snapshot['settings']['salary']['salaryDay'] = 10
        self.snapshot['settings']['salary']['salaryAccountId'] = None
        validate_snapshot(self.snapshot)
        self.assertEqual(self.evidence(), before)

    def test_invalid_receipts_are_not_repaired(self):
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
        for name in ['alpha-ready', 'beta-ready', 'gamma-month-end']:
            snapshot = json.loads((API / f'fixtures/generated/snapshots/{name}.json').read_text(encoding='utf-8'))
            self.assertEqual(snapshot['settings']['salary']['receiptEvidence'], [])

    def test_old_schema_is_not_implicitly_reinterpreted(self):
        self.snapshot['schemaVersion'] = 'PAYSE-DRAFT-2'
        with self.assertRaisesRegex(ValueError, 'unsupported contract'):
            validate_snapshot(self.snapshot)


if __name__ == '__main__':
    unittest.main()
