"""2026-11-03: 실제 공급자를 호출하지 않고 감마 입력·영속 예산 경계를 검사한다."""
import json
from pathlib import Path
import tempfile
import unittest
from gamma_local import inputs, reserve_run, LIMIT, RUN_RESERVE
from contract import validate_input
from testing.scenarios.gamma_year import build


class GammaLocalTests(unittest.TestCase):
    """2026-11-03: 검증 자료에 정답이 유입되지 않고 재실행 비용이 초기화되지 않음을 검사한다."""

    def test_inputs_use_only_gamma_source(self):
        """2026-11-03: 세 입력의 형식·원천 참조·정답 제외를 독립 검사한다."""
        source, _ = build()
        cases = inputs(source)
        self.assertEqual(['salary', 'transfer-insufficient', 'recurring'],
                         [case['name'] for case in cases])
        ids = {row['transactionId'] for row in source['transactions']}
        for case in cases:
            request = case['input']
            validate_input(request)
            self.assertEqual([], request['currentClassifications'])
            self.assertEqual([], request['relations'])
            self.assertTrue(all(row['transactionId'] in ids for row in request['transactions']))
            for row in request['transactions']:
                self.assertNotIn('payseTransactionType', row)
                self.assertNotIn('userId', row)
                self.assertNotIn('accountId', row)

    def test_reservations_survive_next_run(self):
        """2026-11-03: 온보딩 미확정분과 이전 실행 예약을 다음 실행에 누적한다."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.assertEqual(100_000_000, reserve_run(path, 'first'))
            self.assertEqual(100_000_000 + RUN_RESERVE, reserve_run(path, 'second'))
            ledger = json.loads((path / 'ledger.json').read_text(encoding='utf-8'))
            ledger['runs'][0]['budgetMicros'] = LIMIT
            (path / 'ledger.json').write_text(json.dumps(ledger), encoding='utf-8')
            with self.assertRaises(RuntimeError):
                reserve_run(path, 'blocked')

    def test_evaluation_reservation_keeps_cumulative_cutoff(self):
        """2026-11-03: 평가 예약 확대가 누적 차단선을 우회하거나 실패 예약을 지우지 않는다."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.assertEqual(100_000_000, reserve_run(path, 'annual', 25_000_000_000))
            with self.assertRaises(RuntimeError):
                reserve_run(path, 'another-annual', 25_000_000_000)
            with self.assertRaises(ValueError):
                reserve_run(path, 'over-limit', 25_000_000_001)
            ledger = json.loads((path / 'ledger.json').read_text(encoding='utf-8'))
            self.assertEqual(1, len(ledger['runs']))
            self.assertEqual(25_000_000_000, ledger['runs'][0]['budgetMicros'])
            self.assertEqual('reserved', ledger['runs'][0]['state'])


if __name__ == '__main__':
    unittest.main()
