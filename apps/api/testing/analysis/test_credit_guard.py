"""2026-11-04: USD 하한·실패 보류·재시작 지속 검증. 사용: unittest."""
import json
from pathlib import Path
import tempfile
import unittest
from testing.analysis import credit_guard


class CreditGuardTest(unittest.TestCase):
    """2026-11-04: 비용 승인 범위 우회를 거절한다. 사용: unittest."""

    def test_fast_prices_reserve_and_settle_double_generation(self):
        """2026-11-04: Fast의 확인/미확인 생성 모두2배 예약하며 계수 예비비를 보존한다."""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'credit.json'
            credit_guard.initialize(path, '35', '20')
            credit_guard.reserve(path, 'fast', 2, 2)
            entry = credit_guard.load(path)['runs'][0]
            self.assertEqual(220000, entry['reservedMicros'])
            result = credit_guard.settle(path, 'fast', 2, 2,
                [{'known': True, 'inputTokens': 12000, 'outputTokens': 4000}])
            self.assertEqual(.02, result['generationUpperUSD'])
            self.assertEqual(.2, result['unverifiedCountingReserveUSD'])
            for invalid in (0, 3, True, 1.5):
                with self.assertRaises(ValueError):
                    credit_guard.reserve(path, 'invalid', 1, invalid)

    def test_floor_survives_restart_and_unknown_usage(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'credit.json'
            credit_guard.initialize(path, '35', '20')
            credit_guard.reserve(path, 'one', 100)
            with self.assertRaises(RuntimeError):
                credit_guard.reserve(path, 'two', 50)
            result = credit_guard.settle(path, 'one', 100, 100, [])
            self.assertEqual(24.5, result['conservativeRemainingUSD'])
            with self.assertRaises(RuntimeError):
                credit_guard.reserve(path, 'two', 50)
            self.assertEqual(1, len(json.loads(path.read_text())['runs']))

    def test_known_usage_keeps_unknown_counting_reserve(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'credit.json'
            credit_guard.initialize(path, '35', '20')
            credit_guard.reserve(path, 'one', 10)
            result = credit_guard.settle(path, 'one', 1, 2,
                [{'known': True, 'inputTokens': 12000, 'outputTokens': 4000}])
            self.assertEqual(.005, result['generationUpperUSD'])
            self.assertEqual(.2, result['unverifiedCountingReserveUSD'])
            self.assertEqual(34.795, result['conservativeRemainingUSD'])
            with self.assertRaises(ValueError):
                credit_guard.reserve(path, 'one', 1)
            with self.assertRaises(ValueError):
                credit_guard.initialize(path, '100', '20')

    def test_lower_floor_is_not_a_config_override(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'credit.json'
            with self.assertRaises(ValueError):
                credit_guard.initialize(path, '35', '19')
            self.assertFalse(path.exists())

    def test_approved_shared_reserve_keeps_unknown_generation_and_history(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'credit.json'
            krw = Path(folder) / 'ledger.json'
            credit_guard.initialize(path, '35', '20')
            credit_guard.reserve(path, 'one', 3)
            credit_guard.settle(path, 'one', 3, 3, [])
            original = {'onboardingReserveMicros': 100_000_000,
                        'runs': [{'id': 'one', 'state': 'failed', 'budgetMicros': 400_000_000}]}
            krw.write_text(json.dumps(original), encoding='utf-8')
            reports = {'one': {'budgetUpperMicros': 400_000_000,
                               'dispatchedCalls': 6, 'modelCalls': 3}}
            credit_guard.approve_shared_counting(path, krw, reports)
            ledger = credit_guard.load(path)
            self.assertEqual(2_015_000, credit_guard.occupied_usd(ledger))
            self.assertEqual(15_000, ledger['runs'][0]['generationUpperMicros'])
            self.assertFalse(ledger['countingFeeVerified'])
            changed = json.loads(krw.read_text())
            self.assertEqual(400_000_000, changed['runs'][0]['budgetMicros'])
            self.assertEqual(6_200_000_000, credit_guard.occupied_krw(changed))
            self.assertEqual(original, json.loads(krw.with_suffix('.before-shared-counting.json').read_text()))
            with self.assertRaises(ValueError):
                credit_guard.approve_shared_counting(path, krw, reports)

    def test_shared_policy_cannot_release_a_running_reservation(self):
        with tempfile.TemporaryDirectory() as folder:
            path, krw = Path(folder) / 'credit.json', Path(folder) / 'ledger.json'
            credit_guard.initialize(path, '35', '20')
            credit_guard.reserve(path, 'active', 3)
            krw.write_text(json.dumps({'onboardingReserveMicros': 0, 'runs': []}), encoding='utf-8')
            before = path.read_bytes()
            with self.assertRaises(ValueError):
                credit_guard.approve_shared_counting(path, krw, {})
            self.assertEqual(before, path.read_bytes())
