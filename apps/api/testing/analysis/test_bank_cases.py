"""2026-11-01: 짧은 원천 적요와 관계 범위의 기준 응답을 검증한다. 사용: unittest."""
import copy
import json
import unittest

from bank_cases import add_cases, graph_case
from build_cases import answer
from build_schemas import CONTRACTS
from contract import validate_output
from diversity import fingerprint


class BankCasesTest(unittest.TestCase):
    """2026-11-01: 새 사례의 구조·정답 조건과 원천 보존을 검사한다. 사용: unittest."""

    def setUp(self):
        """2026-11-01: 금융 fixture 없이 분석용 합성 자료만 준비한다. 사용: unittest."""
        policy = {row['code']: row for row in json.loads((CONTRACTS / 'meaning-policy.json').read_text(encoding='utf-8-sig'))['meanings']}
        self.inputs, self.expected = {}, {}
        self.last = add_cases(self.inputs, self.expected, 90000, policy)

    def test_all_short_cases_match_contract_without_changes(self):
        """2026-11-01: 작성자 대조 응답의 구조를 검사하며 모델 정확도로 표시하지 않는다. 사용: unittest."""
        before = copy.deepcopy(self.inputs)
        self.assertEqual(len(self.inputs), 36)
        self.assertEqual(self.last, 90036)
        for key, payload in self.inputs.items():
            truth = self.expected[key]['items'][0]
            with self.subTest(case=key):
                validate_output(payload, answer(payload, truth['meaning'], truth['basicType']))
        self.assertEqual(self.inputs, before)
        self.assertEqual(len({fingerprint(payload) for payload in self.inputs.values()}), len(self.inputs))

    def test_relation_elsewhere_does_not_prove_target_transfer(self):
        """2026-11-01: 다른 거래끼리의 연결을 목표 거래의 관계로 오용하지 않는다. 사용: unittest."""
        payload, meaning, basic = graph_case(91000, 'relation_only_between_peers')
        self.assertIsNone(meaning)
        self.assertIsNone(basic)
        with self.assertRaises(ValueError):
            validate_output(payload, answer(payload, 'self_transfer', 'internal_transfer'))
        linked, meaning, basic = graph_case(91001, 'two_disjoint_transfer_edges')
        validate_output(linked, answer(linked, meaning, basic))
        self.assertEqual(basic, 'internal_transfer')

    def test_states_reflections_and_coverage_gaps_are_explicit(self):
        """2026-11-01: 미확정 상태와 반영 근거를 독립적으로 유지하고 목록 부족을 남긴다. 사용: unittest."""
        cases = {row['condition']: (self.inputs[key], row['items'][0]) for key, row in self.expected.items()}
        salary, salary_truth = cases['salary_unknown_state']
        self.assertEqual(salary['transactions'][0]['status'], 'unknown')
        self.assertEqual(salary['transactions'][0]['reflectionReason'], 'unknown')
        self.assertEqual(salary_truth['meaning'], 'salary')
        pension, _ = cases['pension_state_not_reflection']
        self.assertEqual(pension['transactions'][0]['status'], 'unknown')
        self.assertEqual(pension['transactions'][0]['reflectionReason'], 'reflected')
        self.assertEqual(sum(row['items'][0]['coverageGap'] for row in self.expected.values()), 2)
        self.assertIsNone(cases['employer_method_only'][1]['meaning'])
        self.assertEqual(cases['refund_over_salary_memo'][1]['meaning'], 'refund')
        self.assertEqual(cases['cancellation_over_loan_memo'][1]['meaning'], 'cancellation')


if __name__ == '__main__':
    unittest.main()
