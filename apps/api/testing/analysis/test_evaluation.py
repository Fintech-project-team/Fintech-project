"""2026-11-01: 정답·경로·분할·누락 채점의 과대평가를 막는다. 사용: unittest/Gradle."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from build_cases import answer, identity, recurring, request
from evaluate import compare, read_cases, read_json, score
from partitions import assert_final, families, split_report, transaction_fingerprints


def sample(index, description='근로 급여 입금', meaning='salary', basic='income'):
    """2026-11-01: 소형 채점 반례를 독립 준비한다. 사용: EvaluationTest."""
    payload = request(index, {'recordKind': 'account_entry', 'direction': 'in',
                              'merchantName': '가상 고용주', 'description': description})
    truth = {'groupId': f'family-{index}', 'split': 'calibration', 'items': [{
        'itemKey': payload['items'][0]['itemKey'], 'inputSufficient': meaning is not None,
        'meaning': meaning, 'basicType': basic}]}
    return payload, truth, answer(payload, meaning, basic)


class EvaluationTest(unittest.TestCase):
    """2026-11-01: 오류 숨김과 사례군 누출을 검사한다. 사용: unittest."""

    def setUp(self):
        """2026-11-01: 각 검사의 기준 입력·정답·응답을 만든다. 사용: unittest."""
        payload, truth, response = sample('audit-first')
        self.inputs, self.expected, self.responses = {'a': payload}, {'a': truth}, {'a': response}

    def test_label_keys_and_duplicates(self):
        """2026-11-01: 정답 추가·누락·중복을 분모에 숨기지 않는다. 사용: unittest."""
        extra = {**self.expected, 'unexpected': self.expected['a']}
        duplicate = copy.deepcopy(self.expected)
        duplicate['a']['items'].append(copy.deepcopy(duplicate['a']['items'][0]))
        for labels in ({}, extra, duplicate):
            with self.subTest(labels=len(labels)), self.assertRaises(ValueError):
                score(self.inputs, labels, self.responses)

    def test_label_values_and_json_duplicates(self):
        """2026-11-01: 모순된 정답과 중복 JSON 필드로 성능을 왜곡하지 않는다. 사용: unittest."""
        for field, value in [('meaning', 'invented'), ('basicType', 'salary'), ('inputSufficient', False)]:
            labels = copy.deepcopy(self.expected)
            labels['a']['items'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                score(self.inputs, labels, self.responses)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'duplicate.json'
            path.write_text('{"a":{"value":1,"value":2}}', encoding='utf-8')
            with self.assertRaises(ValueError):
                read_json(path)

    def test_route_keys_and_failures(self):
        """2026-11-01: 경로 기록 누락·과잉과 성공처럼 보이는 처리 실패를 구분한다. 사용: unittest."""
        item = self.inputs['a']['items'][0]['itemKey']
        invalid_routes = [{}, {'a': {}}, {'a': {item: 'invented'}},
                          {'a': {item: 'llm', 'extra': 'llm'}},
                          {'a': {item: 'llm'}, 'extra': {item: 'llm'}}]
        for routes in invalid_routes:
            with self.subTest(routes=routes), self.assertRaises(ValueError):
                score(self.inputs, self.expected, self.responses, routes)
        result = score(self.inputs, self.expected, self.responses, {'a': {item: 'processing_failure'}})
        self.assertEqual(result['jointError']['numerator'], 1)
        self.assertEqual(result['failureReasons']['processing_failure'], 1)

    def test_missing_invalid_and_coverage(self):
        """2026-11-01: 누락·무효 응답·분류표 부족을 같은 분모에 남긴다. 사용: unittest."""
        self.expected['a']['items'][0]['coverageGap'] = True
        missing = score(self.inputs, self.expected, {})
        invalid = score(self.inputs, self.expected, {'a': None})
        self.assertEqual(missing['jointError']['numerator'], 1)
        self.assertEqual(missing['failureReasons'], {'missing_response': 1, 'taxonomy_gap': 1})
        self.assertEqual(invalid['failureReasons'], {'invalid_response': 1, 'taxonomy_gap': 1})

    def test_coverage_gap_is_not_mislabeled_as_needless_abstention(self):
        """2026-11-01: 표현 불가로 필요한 유보와 불필요 유보를 구분하되 전체 오류에는 남긴다. 사용: unittest."""
        self.expected['a']['items'][0].update(meaning=None, inputSufficient=True, coverageGap=True)
        result = score(self.inputs, self.expected, {'a': answer(self.inputs['a'], None, 'income')})
        self.assertEqual(result['jointError']['numerator'], 1)
        self.assertEqual(result['taxonomyCoverageGaps'], 1)
        self.assertEqual(result['unnecessaryAbstention']['numerator'], 0)
        self.assertEqual(result['failureReasons'], {'taxonomy_gap': 1})

    def test_basic_abstention_is_visible(self):
        """2026-11-01: 세부 의미 유보가 맞아도 기존 기본분류 누락을 센다. 사용: unittest."""
        payload, truth, _ = sample('basic-known', '온라인 결제', None, 'expense')
        result = score({'a': payload}, {'a': truth}, {'a': answer(payload, None, None)})
        self.assertEqual(result['jointError']['numerator'], 1)
        self.assertEqual(result['failureReasons'], {'unnecessary_basic_abstention': 1})

    def test_llm_transactions_exclude_recurring(self):
        """2026-11-01: 반복 후보 오류가 거래 10만건 지표로 섞이지 않게 한다. 사용: unittest."""
        payload = recurring('audit-recurring', 'rent', {'recordKind': 'account_entry',
                            'direction': 'out', 'merchantName': '가상 임대인', 'description': '주거 월세 납부'})
        self.inputs['r'] = payload
        self.expected['r'] = {'items': [{'itemKey': payload['items'][0]['itemKey'],
                                        'inputSufficient': True, 'meaning': 'rent', 'basicType': None}]}
        self.responses['r'] = answer(payload, None, None)
        routes = {case: {item['itemKey']: 'llm' for item in value['items']}
                  for case, value in self.inputs.items()}
        result = score(self.inputs, self.expected, self.responses, routes)
        self.assertEqual(result['byDecisionSource']['llm']['items'], 2)
        self.assertEqual(result['llmTransactionError'], {'numerator': 0, 'denominator': 1, 'rate': 0.0})
        self.assertEqual(result['jointError']['numerator'], 1)

    def test_regressions_not_cancelled_by_improvements(self):
        """2026-11-01: 같은 총점이어도 서로 바뀐 개선·악화를 보인다. 사용: unittest."""
        payload, truth, response = sample('audit-second', '별도 성과 상여 입금', 'bonus', 'income')
        self.inputs['b'], self.expected['b'], self.responses['b'] = payload, truth, response
        baseline = copy.deepcopy(self.responses)
        baseline['a'] = answer(self.inputs['a'], None, None)
        changed = copy.deepcopy(self.responses)
        changed['b'] = answer(payload, None, None)
        result = compare(self.inputs, self.expected, baseline, changed)
        self.assertEqual(result['beforeJointError'], result['afterJointError'])
        self.assertEqual([row['caseId'] for row in result['improvedItems']], ['a'])
        self.assertEqual([row['caseId'] for row in result['regressedItems']], ['b'])

    def test_transitive_family_links(self):
        """2026-11-01: 부모군·별칭군의 간접 연결도 한 분할로 묶는다. 사용: unittest."""
        for key, desc in [('b', '성과 상여 지급'), ('c', '대출 실행금')]:
            payload, truth, _ = sample(key, desc)
            self.inputs[key], self.expected[key] = payload, truth
        self.expected['a']['familyLinks'] = ['shared-template']
        self.expected['b']['alsoCoversGroups'] = ['shared-template', 'other-template']
        self.expected['c']['familyLinks'] = ['other-template']
        self.assertEqual(families(self.inputs, self.expected), [['a', 'b', 'c']])
        self.expected['b']['split'] = 'development'
        self.assertFalse(split_report(self.inputs, self.expected)['relatedSplitOverlap'])
        self.expected['c']['split'] = 'final'
        with self.assertRaises(ValueError):
            split_report(self.inputs, self.expected)

    def test_shared_source_and_id_only_duplicates(self):
        """2026-11-01: 다른 군 이름을 붙여도 같은 원천·ID 변형은 분리하지 않는다. 사용: unittest."""
        payload, truth, _ = sample('audit-renamed')
        truth['split'] = 'final'
        self.inputs['b'], self.expected['b'] = payload, truth
        with self.assertRaises(ValueError):
            split_report(self.inputs, self.expected)
        self.inputs['b']['transactions'][0]['description'] = '서로 다른 근거 문구'
        prior = self.inputs['b']['transactions'][0]['transactionId']
        shared = self.inputs['a']['transactions'][0]['transactionId']
        self.inputs['b'] = json.loads(json.dumps(self.inputs['b']).replace(prior, shared))
        with self.assertRaises(ValueError):
            split_report(self.inputs, self.expected)

    def test_final_rejects_calibration_and_shortfall(self):
        """2026-11-01: 개발 자료나 10만건 미달을 최종 실행으로 바꾸지 않는다. 사용: unittest."""
        development, labels, _ = sample('development', '대출 실행금')
        with self.assertRaises(ValueError):
            assert_final(self.inputs, self.expected, {'dev': development}, {'dev': labels})
        self.expected['a']['split'] = 'final'
        with self.assertRaises(ValueError):
            assert_final(self.inputs, self.expected, {'dev': development}, {'dev': labels})

    def test_batch_wrapping_does_not_create_a_new_transaction(self):
        """2026-11-01: 같은 거래 근거를 다른 배치에 넣어 표본으로 늘리지 않는다. 사용: unittest."""
        original = self.inputs['a']
        payload, truth, _ = sample('batch-extra', '성과 상여 입금', 'bonus', 'income')
        batch = copy.deepcopy(original)
        batch['items'] += payload['items']
        batch['transactions'] += payload['transactions']
        self.assertIn(transaction_fingerprints(original)[0], transaction_fingerprints(batch))
        labels = {'groupId': 'new-batch', 'split': 'final',
                  'items': self.expected['a']['items'] + truth['items']}
        with self.assertRaises(ValueError):
            split_report({'a': original, 'batch': batch}, {'a': self.expected['a'], 'batch': labels})

    def test_export_never_reads_labels(self):
        """2026-11-01: 존재하지 않는 정답 파일로도 공개 입력만 내보낸다. 사용: unittest."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs, output = root / 'inputs.jsonl', root / 'model.json'
            inputs.write_text(json.dumps({'caseId': 'a', 'input': self.inputs['a']}) + '\n', encoding='utf-8')
            command = [sys.executable, '-B', str(Path(__file__).with_name('evaluate.py')),
                       '--inputs', str(inputs), '--labels', str(root / 'absent-private.json'),
                       '--export-input', str(output)]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(set(json.loads(output.read_text(encoding='utf-8'))), {'a'})

    def test_duplicate_jsonl_ids(self):
        """2026-11-01: JSONL 중복 ID를 마지막 행으로 덮어쓰지 않는다. 사용: unittest."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'inputs.jsonl'
            line = json.dumps({'caseId': 'a', 'input': self.inputs['a']}) + '\n'
            path.write_text(line + line, encoding='utf-8')
            with self.assertRaises(ValueError):
                read_cases(path, 'input')

    def test_usage_cli_preserves_unmeasured_totals(self):
        """2026-11-01: 오프라인 사용량 수집이 실제 측정/성능 인증으로 바뀌지 않는다. 사용: unittest."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = {}
            for name, value in [('inputs', self.inputs), ('labels', self.expected),
                                ('responses', self.responses), ('usage', [])]:
                paths[name] = root / f'{name}.json'
                paths[name].write_text(json.dumps(value), encoding='utf-8')
            command = [sys.executable, '-B', str(Path(__file__).with_name('evaluate.py'))]
            for name, path in paths.items():
                command += [f'--{name}', str(path)]
            result = subprocess.run(command, capture_output=True, encoding='utf-8', check=False,
                                    env={**os.environ, 'PYTHONIOENCODING': 'utf-8'})
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertIsNone(report['actualTokens'])
            self.assertIsNone(report['recordedUsage']['tokens']['input']['total'])
            self.assertFalse(report['recordedUsage']['providerSourceVerified'])
            self.assertFalse(report['wholePipelineMeasured'])


if __name__ == '__main__':
    unittest.main()
