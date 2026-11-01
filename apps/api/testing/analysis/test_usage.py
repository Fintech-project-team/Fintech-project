"""2026-11-01: 사용량 누락·미정산·재시도를 숨기지 않는 집계를 검사한다. 사용: unittest."""
import copy
from decimal import Decimal
from pathlib import Path
import tempfile
import unittest
from build_cases import request
from usage import decimal_total, read_usage, summarize


class UsageTest(unittest.TestCase):
    """2026-11-01: 합성 사용량 장부로 집계기만 검증한다. 사용: unittest; 유료 호출 아님."""

    def setUp(self):
        """2026-11-01: 식별 가능한 거래와 가상의 정산 기록을 준비한다. 사용: unittest."""
        payload = request('usage-case', {'recordKind': 'account_entry', 'direction': 'in',
                          'merchantName': '가상 고용주', 'description': '근로 급여 입금'})
        self.inputs = {'a': payload}
        self.record = {'requestId': 'local-request-one', 'attemptId': 'ledger-attempt-one',
                       'items': [{'caseId': 'a', 'itemKey': payload['items'][0]['itemKey']}],
                       'state': 'succeeded', 'adopted': True, 'inputTokens': 100, 'outputTokens': 30,
                       'latencyMs': 1500, 'costState': 'settled', 'settledCostKRW': '1.25',
                       'pendingCostKRW': None, 'costLedgerRef': 'synthetic-ledger-entry-one'}

    def test_all_retries_and_unadopted_attempts_are_counted(self):
        """2026-11-01: 실패·수동 재시도·미채택 응답도 사용량에서 제외하지 않는다. 사용: unittest."""
        failed = {**self.record, 'requestId': 'local-request-two', 'attemptId': 'ledger-attempt-two',
                  'state': 'failed', 'adopted': False, 'settledCostKRW': '2.10'}
        late = {**self.record, 'requestId': 'local-request-three', 'attemptId': 'ledger-attempt-three',
                'adopted': False, 'settledCostKRW': '0.15'}
        result = summarize(self.inputs, [self.record, failed, late])
        self.assertEqual(result['requestCount'], 3)
        self.assertEqual(result['uniqueEvaluationItems'], 1)
        self.assertEqual(result['itemsWithMultipleAttempts'], 1)
        self.assertEqual(result['tokens']['input']['total'], 300)
        self.assertEqual(result['tokens']['output']['total'], 90)
        self.assertEqual(result['cost']['totalCostKRW'], '3.50')
        self.assertEqual(result['unadoptedAttempts'], 2)
        self.assertEqual(result['externalCalls'], 0)
        self.assertFalse(result['providerSourceVerified'])
        self.assertFalse(result['ledgerSourceVerified'])
        self.assertIsNone(result['globalBudgetRemainingKRW'])

    def test_missing_usage_is_not_zero(self):
        """2026-11-01: 응답 유실로 모르는 사용량·지연·비용을 null로 남긴다. 사용: unittest."""
        unknown = {**self.record, 'inputTokens': None, 'outputTokens': None, 'latencyMs': None,
                   'state': 'outcome_unknown', 'adopted': False, 'costState': 'unknown',
                   'settledCostKRW': None, 'costLedgerRef': None}
        result = summarize(self.inputs, [unknown])
        self.assertIsNone(result['tokens']['input']['total'])
        self.assertIsNone(result['tokens']['input']['knownSubtotal'])
        self.assertEqual(result['tokens']['input']['missingRequests'], 1)
        self.assertIsNone(result['cost']['settledCostKRW'])
        self.assertIsNone(result['cost']['totalCostKRW'])
        self.assertIsNone(result['latency']['meanMeasuredMs'])
        self.assertEqual(result['cost']['unknownCostRequests'], 1)

    def test_pending_cost_and_partial_measurement_are_separate(self):
        """2026-11-01: 미정산 장부 금액을 확정 실비로 합치지 않는다. 사용: unittest."""
        pending = {**self.record, 'requestId': 'local-request-pending', 'attemptId': 'ledger-attempt-pending',
                   'inputTokens': None, 'outputTokens': None, 'latencyMs': None, 'state': 'outcome_unknown',
                   'adopted': False, 'costState': 'pending', 'settledCostKRW': None, 'pendingCostKRW': '3.50'}
        result = summarize(self.inputs, [self.record, pending])
        self.assertEqual(result['tokens']['input']['knownSubtotal'], 100)
        self.assertIsNone(result['tokens']['input']['total'])
        self.assertEqual(result['cost']['settledCostKRW'], '1.25')
        self.assertEqual(result['cost']['knownPendingCostKRW'], '3.50')
        self.assertIsNone(result['cost']['totalCostKRW'])
        self.assertEqual(result['latency']['meanMeasuredMs'], 1500)
        self.assertEqual(result['latency']['missingRequests'], 1)
        pending['pendingCostKRW'] = None
        result = summarize(self.inputs, [pending])
        self.assertEqual(result['cost']['pendingAmountMissingRequests'], 1)
        self.assertIsNone(result['cost']['knownPendingCostKRW'])

    def test_zero_requires_explicit_evidence(self):
        """2026-11-01: 장부가 확인한 0과 미측정 값을 구분한다. 사용: unittest."""
        zero = {**self.record, 'inputTokens': 0, 'outputTokens': 0, 'settledCostKRW': '0', 'latencyMs': 0}
        result = summarize(self.inputs, [zero])
        self.assertEqual(result['tokens']['input']['total'], 0)
        self.assertEqual(result['cost']['totalCostKRW'], '0')
        empty = summarize(self.inputs, [])
        self.assertIsNone(empty['tokens']['input']['total'])
        self.assertIsNone(empty['cost']['totalCostKRW'])
        self.assertIsNone(empty['latency']['meanMeasuredMs'])

    def test_duplicate_request_and_attempt_ids_are_rejected(self):
        """2026-11-01: 중복 읽은 시도·응답으로 비용을 두 번 합산하지 않는다. 사용: unittest."""
        for duplicate in ({**self.record, 'attemptId': 'different-attempt'},
                          {**self.record, 'requestId': 'different-request'}):
            with self.assertRaises(ValueError):
                summarize(self.inputs, [self.record, duplicate])

    def test_unknown_and_duplicate_references_are_rejected(self):
        """2026-11-01: 평가 범위 밖 거래·중복 참조·빈 요청을 거절한다. 사용: unittest."""
        for refs in ([], [{'caseId': 'absent', 'itemKey': 'missing'}],
                     self.record['items'] * 2, [{'caseId': 'a', 'itemKey': 'wrong-item'}]):
            with self.subTest(refs=refs), self.assertRaises(ValueError):
                summarize(self.inputs, [{**self.record, 'items': refs}])

    def test_multiple_adopted_results_are_rejected(self):
        """2026-11-01: 같은 평가 항목에 재시도 결과 둘이 채택됐다는 모순을 거절한다. 사용: unittest."""
        other = {**self.record, 'requestId': 'second-local-request', 'attemptId': 'second-ledger-attempt'}
        with self.assertRaises(ValueError):
            summarize(self.inputs, [self.record, other])

    def test_invalid_tokens_and_latency(self):
        """2026-11-01: bool·문자열·음수·비정수 사용량을 묵시 변환하지 않는다. 사용: unittest."""
        for field in ('inputTokens', 'outputTokens', 'latencyMs'):
            for value in (True, -1, 1.5, '10', float('nan'), float('inf')):
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    summarize(self.inputs, [{**self.record, field: value}])

    def test_invalid_costs_and_cost_states(self):
        """2026-11-01: 비유한 수·숫자 변환·정산 모순·장부 누락을 거절한다. 사용: unittest."""
        for value in ('NaN', 'Infinity', '-1', '1e2', ' 1', '', 1.5, True):
            with self.subTest(cost=value), self.assertRaises(ValueError):
                summarize(self.inputs, [{**self.record, 'settledCostKRW': value}])
        invalid = [{'settledCostKRW': None}, {'pendingCostKRW': '1'}, {'costLedgerRef': None},
                   {'costState': 'pending'}, {'costState': 'unknown'}, {'state': 'failed'}]
        for change in invalid:
            with self.subTest(change=change), self.assertRaises(ValueError):
                summarize(self.inputs, [{**self.record, **change}])

    def test_cost_decimal_precision_and_budget_are_unchanged(self):
        """2026-11-01: 소수 장부 합계와 기존 예산 수치를 보존한다. 사용: unittest."""
        values = [Decimal('0.1'), Decimal('0.2')]
        self.assertEqual(decimal_total(values), '0.3')
        mixed = decimal_total([Decimal('100000000000000000000'), Decimal('0.00000000000000000001')])
        self.assertEqual(mixed, '100000000000000000000.00000000000000000001')
        result = summarize(self.inputs, [self.record])
        self.assertEqual(result['budgetPolicy'], {'totalBudgetKRW': '50000',
                                                 'newPaidCallCutoffKRW': '45000', 'marginKRW': '5000'})

    def test_no_input_mutation_or_unexpected_fields(self):
        """2026-11-01: 원천/장부를 그대로 두고 비허용 본문 필드를 받지 않는다. 사용: unittest."""
        before = copy.deepcopy((self.inputs, self.record))
        summarize(self.inputs, [self.record])
        self.assertEqual(before, (self.inputs, self.record))
        with self.assertRaises(ValueError):
            summarize(self.inputs, [{**self.record, 'promptBody': 'not permitted'}])

    def test_duplicate_json_fields_are_rejected(self):
        """2026-11-01: 파일 중복 필드가 사용량을 조용히 덮어쓰지 못하게 한다. 사용: unittest."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'usage.json'
            path.write_text('[{"requestId":"first","requestId":"second"}]', encoding='utf-8')
            with self.assertRaises(ValueError):
                read_usage(path)


if __name__ == '__main__':
    unittest.main()
