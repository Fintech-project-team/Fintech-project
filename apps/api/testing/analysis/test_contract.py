"""2026-11-01: 분류 계약·평가 도구의 회귀 검사. 사용: Gradle test/check, unittest.

합성 정답 응답은 검사 도구 검증용이다. 실제 모델 정확도를 측정하지 않는다.
"""
import copy
import json
import unittest
from build_cases import CASES, answer, identity, prepare
from build_schemas import CONTRACTS, schemas
from contract import model_input, validate_input, validate_output
from evaluate import score
from schema_check import check
from diversity import fingerprint, report as diversity_report


class ContractTest(unittest.TestCase):
    """2026-11-01: 명세·자료·채점의 호환성을 검사한다. 사용: unittest."""

    def setUp(self):
        """2026-11-01: 매 검사에 독립 입력/정답을 준비한다. 사용: unittest."""
        self.inputs, self.expected = prepare()
        self.first = next(iter(self.inputs))
        self.payload = self.inputs[self.first]

    def responses(self):
        """2026-11-01: 비공개 정답으로 검사기용 대조 응답을 만든다. 사용: 테스트만."""
        return {key: answer(payload, self.expected[key]['items'][0]['meaning'],
                            self.expected[key]['items'][0]['basicType'], '통신 요금')
                for key, payload in self.inputs.items()}

    def test_generated_files(self):
        """2026-11-01: 코드/분류표/게시 JSON의 차이를 탐지한다. 사용: unittest."""
        for name, schema in schemas().items():
            self.assertEqual(schema, json.loads((CONTRACTS / name).read_text(encoding='utf-8-sig')))
        for name, expected in [('inputs.json', self.inputs), ('expected.private.json', self.expected)]:
            self.assertEqual(expected, json.loads((CASES / name).read_text(encoding='utf-8')))

    def test_cases_and_synthetic_answers(self):
        """2026-11-01: 준비 사례의 구조/기준 응답 호환성을 검사한다. 사용: unittest."""
        for key, response in self.responses().items():
            with self.subTest(case=key):
                validate_output(self.inputs[key], response)
        report = score(self.inputs, self.expected, self.responses())
        self.assertEqual(report['jointError']['numerator'], report['taxonomyCoverageGaps'])
        self.assertIsNone(report['actualTokens'])

    def test_policy_has_criteria(self):
        """2026-11-01: 41개 코드의 중복·기준 누락을 막는다. 사용: unittest."""
        policy = json.loads((CONTRACTS / 'meaning-policy.json').read_text(encoding='utf-8-sig'))
        self.assertEqual(len(policy['meanings']), 41)
        self.assertEqual(len({row['code'] for row in policy['meanings']}), 41)
        for row in policy['meanings']:
            for field in ('requiredEvidence', 'insufficientEvidence', 'counterexample', 'basicTypePolicy'):
                self.assertTrue(row[field])

    def test_no_private_labels_in_model_input(self):
        """2026-11-01: 원천 메타와 비공개 정답 유출을 막는다. 사용: unittest."""
        for payload in self.inputs.values():
            projected = json.dumps(model_input(payload), ensure_ascii=False)
            for forbidden in ('authorKnownMeaning', 'inputSufficient', 'sourceVersion', 'schemaVersion', 'expectedBasicType', 'labelOrigin'):
                self.assertNotIn(forbidden, projected)

    def test_input_is_unchanged(self):
        """2026-11-01: 검사/모델 투영이 원천/후보를 바꾸지 않는다. 사용: unittest."""
        before = copy.deepcopy(self.inputs)
        for payload in self.inputs.values():
            model_input(payload)
        self.assertEqual(before, self.inputs)

    def test_invalid_status_version_and_time(self):
        """2026-11-01: 계좌 미지원 상태·구버전·잘못된 시각을 거절한다. 사용: unittest."""
        mutations = [('status', 'approved'), ('schemaVersion', 'PAYSE-API-0.6-3'),
                     ('dataVersion', '9223372036854775808'), ('asOf', '2026-02-30T12:00:00+09:00')]
        for field, value in mutations:
            payload = copy.deepcopy(self.payload)
            target = payload['transactions'][0] if field == 'status' else payload['context']
            target[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_input(payload)

    def test_duplicate_identity(self):
        """2026-11-01: 같은 ID의 원천 덮어쓰기를 거절한다. 사용: unittest."""
        other = {**self.payload['transactions'][0], 'description': '서로 다른 원천'}
        self.payload['transactions'].append(other)
        with self.assertRaises(ValueError):
            validate_input(self.payload)

    def test_unknown_reference(self):
        """2026-11-01: 공개 입력에 없는 참조를 거절한다. 사용: unittest."""
        self.payload['items'][0]['evidenceTransactionIds'].append(identity('absent'))
        with self.assertRaises(ValueError):
            validate_input(self.payload)

    def test_evidence_limit(self):
        """2026-11-01: 승인된 60근거 상한을 조용히 잘라내지 않는다. 사용: unittest."""
        original = self.payload['transactions'][0]
        self.payload['transactions'] = [{**original, 'transactionId': identity(f'extra/{index}')}
                                         for index in range(61)]
        with self.assertRaises(ValueError):
            validate_input(self.payload)

    def test_missing_and_extra_output(self):
        """2026-11-01: 누락/추가 결과와 금융 실행 필드를 거절한다. 사용: unittest."""
        for mode in ('missing', 'extra', 'finance'):
            result = answer(self.payload, 'salary', 'income')
            if mode == 'missing':
                result['items'] = []
            elif mode == 'extra':
                result['items'].append(copy.deepcopy(result['items'][0]))
            else:
                result['items'][0]['confirmation'] = 'confirmed'
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                validate_output(self.payload, result)

    def test_wrong_evidence_and_unknown_shape(self):
        """2026-11-01: 다른 근거와 unknown/value 모순을 거절한다. 사용: unittest."""
        result = answer(self.payload, 'salary', 'income')
        result['items'][0]['evidenceTransactionIds'] = [identity('foreign')]
        with self.assertRaises(ValueError):
            validate_output(self.payload, result)
        result = answer(self.payload, 'salary', 'income')
        result['items'][0]['meaning']['status'] = 'unknown'
        with self.assertRaises(ValueError):
            validate_output(self.payload, result)

    def test_existing_classification_conflict(self):
        """2026-11-01: 기존 분류의 조용한 대체를 방지한다. 사용: unittest."""
        target = self.payload['items'][0]['targetTransactionId']
        self.payload['currentClassifications'] = [{'transactionId': target, 'value': 'expense'}]
        with self.assertRaises(ValueError):
            validate_output(self.payload, answer(self.payload, 'salary', 'income'))
        validate_output(self.payload, answer(self.payload, None, None))

    def test_relation_scope_and_card_settlement(self):
        """2026-11-01: 같은 사건 관계를 청구 정산으로 전용하지 않는다. 사용: unittest."""
        original = self.payload['transactions'][0]
        other = {**original, 'transactionId': identity('related'), 'direction': 'out'}
        self.payload['transactions'].append(other)
        relation = {'kind': 'internal_transfer', 'fromId': original['transactionId'], 'toId': other['transactionId']}
        self.payload['relations'] = [relation]
        with self.assertRaises(ValueError):
            validate_output(self.payload, answer(self.payload, 'self_transfer', 'internal_transfer'))
        self.payload['items'][0]['evidenceTransactionIds'].append(other['transactionId'])
        validate_output(self.payload, answer(self.payload, 'self_transfer', 'internal_transfer'))
        relation['kind'] = 'card_account_pair'
        other.update(recordKind='card_purchase', status='approved', reflectionReason='not_applicable')
        with self.assertRaises(ValueError):
            validate_output(self.payload, answer(self.payload, 'card_bill_payment', 'card_payment'))

    def test_source_relation_semantics_and_original_cycles(self):
        """2026-11-01: 금융 원천과 같은 관계 종류·방향·중복·순환 규칙을 검사한다. 사용: unittest."""
        first = self.payload['transactions'][0]
        second = {**first, 'transactionId': identity('invalid-peer')}
        self.payload['transactions'].append(second)
        self.payload['items'][0]['evidenceTransactionIds'].append(second['transactionId'])
        relation = {'kind': 'internal_transfer', 'fromId': first['transactionId'], 'toId': second['transactionId']}
        self.payload['relations'] = [relation]
        with self.assertRaises(ValueError):
            validate_input(self.payload)
        second['direction'] = 'out'
        validate_input(self.payload)
        self.payload['relations'].append({'kind': 'internal_transfer', 'fromId': second['transactionId'], 'toId': first['transactionId']})
        with self.assertRaises(ValueError):
            validate_input(self.payload)
        self.payload['relations'] = [{**relation, 'kind': 'card_account_pair'}]
        with self.assertRaises(ValueError):
            validate_input(self.payload)
        self.payload['relations'] = []
        first['originalTransactionId'] = second['transactionId']
        second['originalTransactionId'] = first['transactionId']
        with self.assertRaises(ValueError):
            validate_input(self.payload)

    def test_recurring_local_constraints(self):
        """2026-11-01: 로컬 미충족 후보를 의미 분석으로 승격하지 않는다. 사용: unittest."""
        candidate_payload = next(row for row in self.inputs.values() if row['semanticTaskKind'] == 'recurringMeaning')
        for field, value in [('observedMonths', ['2026-09', '2026-10']), ('amountWithinRule', None),
                             ('hasUnresolvedReversal', True)]:
            changed = copy.deepcopy(candidate_payload)
            changed['candidates'][0]['features'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_input(changed)
        changed = copy.deepcopy(candidate_payload)
        changed['candidates'][0]['suggestedAmountKRW'] = 9000000000001
        with self.assertRaises(ValueError):
            validate_input(changed)

    def test_no_all_unknown_shortcut(self):
        """2026-11-01: 모든 사례 유보를 높은 정확도로 보고하지 않는다. 사용: unittest."""
        responses = {key: answer(payload, None, None) for key, payload in self.inputs.items()}
        report = score(self.inputs, self.expected, responses)
        self.assertGreater(report['jointError']['numerator'], 10)
        self.assertEqual(report['supportedCaseCorrect']['numerator'], 0)

    def test_missing_results_count_as_errors(self):
        """2026-11-01: 실패/누락을 분모와 분류별 누락에 남긴다. 사용: unittest."""
        report = score(self.inputs, self.expected, {})
        self.assertEqual(report['jointError']['rate'], 1)
        self.assertGreater(report['perMeaning']['salary']['falseNegative'], 0)

    def test_batch_order_and_second_error(self):
        """2026-11-01: 배치의 모든 항목을 key로 채점한다. 사용: unittest."""
        keys = [key for key, case in self.expected.items() if case['items'][0]['meaning'] in ('salary', 'bonus')]
        first, second = keys[:2]
        payload = copy.deepcopy(self.inputs[first])
        payload['items'] += self.inputs[second]['items']
        payload['transactions'] += self.inputs[second]['transactions']
        labels = {'case': {'items': self.expected[first]['items'] + self.expected[second]['items']}}
        result = answer(self.inputs[first], 'salary', 'income')
        result['items'] += answer(self.inputs[second], 'medical', 'income')['items']
        report = score({'case': payload}, labels, {'case': result})
        self.assertEqual(report['jointError']['numerator'], 1)
        result['items'].reverse()
        self.assertEqual(report, score({'case': payload}, labels, {'case': result}))

    def test_schema_checker_fails_closed(self):
        """2026-11-01: 지원하지 않는 스키마 키워드와 bool 정수를 거절한다. 사용: unittest."""
        with self.assertRaises(ValueError):
            check({'type': 'integer'}, True)
        with self.assertRaises(ValueError):
            check({'type': 'string', 'futureKeyword': True}, 'text')

    def test_identifier_changes_are_not_new_meanings(self):
        """2026-11-01: ID만 바꾼 사례 증식을 새 의미 표본으로 세지 않는다. 사용: unittest."""
        changed = copy.deepcopy(self.payload)
        old = changed['transactions'][0]['transactionId']
        new = identity('renamed-transaction')
        changed = json.loads(json.dumps(changed).replace(old, new))
        changed['items'][0]['itemKey'] = identity('renamed-item')
        self.assertEqual(fingerprint(self.payload), fingerprint(changed))

    def test_pipeline_and_llm_scores_are_separate(self):
        """2026-11-01: 전체 판단과 LLM 경로를 분리하고 미기록 경로를 추정하지 않는다. 사용: unittest."""
        routes = {key: {item['itemKey']: 'llm' if index % 2 else 'source_fact' for item in payload['items']}
                  for index, (key, payload) in enumerate(self.inputs.items())}
        result = score(self.inputs, self.expected, self.responses(), routes)
        self.assertGreater(result['byDecisionSource']['llm']['items'], 0)
        self.assertGreater(result['byDecisionSource']['source_fact']['items'], 0)
        with self.assertRaises(ValueError):
            score(self.inputs, self.expected, self.responses(), {})

    def test_diversity_and_target_gaps_are_visible(self):
        """2026-11-01: 관계/누락/정정과 목록 밖 의미를 숨기지 않는다. 사용: unittest."""
        diversity = diversity_report(self.inputs, self.expected)
        self.assertFalse(diversity['holdoutReady'])
        for key in ('withRelations', 'withUnavailableReference', 'withExistingClassification', 'withMissingNameOrMemo'):
            self.assertGreater(diversity[key], 0)
        responses = self.responses()
        self.expected[self.first]['items'][0]['coverageGap'] = True
        result = score(self.inputs, self.expected, responses)
        self.assertGreater(result['taxonomyCoverageGaps'], 0)
        self.assertGreater(result['jointError']['numerator'], 0)
        self.assertEqual(result['transactionTarget']['status'], 'not_evaluated')
        self.assertEqual(diversity['duplicateInputGroups'], [])


if __name__ == '__main__':
    unittest.main()
