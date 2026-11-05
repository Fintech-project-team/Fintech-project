"""2026-11-03: 실제 호출 전 연간 정답지·격리·채점 분모와 실패 분류를 검증한다."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from gamma_evaluation import freeze, score_run, verify_bundle


class GammaEvaluationTests(unittest.TestCase):
    """2026-11-03: 합성 응답은 채점기의 검사에만 사용한다. 실제 모델 점수와 구분한다."""

    @classmethod
    def setUpClass(cls):
        """2026-11-03: 모델 실행 전 자료를 한 번 동결하고 독립 기대 응답을 준비한다."""
        cls.temporary = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temporary.name) / 'dataset'
        cls.manifest = freeze(cls.directory)
        cls.expected = json.loads((cls.directory / 'expected.private.json').read_text(encoding='utf-8'))
        cls.inputs = json.loads((cls.directory / 'inputs.json').read_text(encoding='utf-8'))
        cls.summary = {'cases': []}
        for case in cls.inputs:
            items = []
            for truth in cls.expected[case['name']]['items']:
                decision = lambda value, code: {'value': value, 'status': 'candidate' if value else 'unknown', 'reasonCode': code}
                item = {'itemKey': truth['itemKey'],
                    'meaning': decision(truth['meaning'], truth['expectedMeaningReason']),
                    'reason': '입력에 공개된 근거만 확인한 채점기용 합성 응답입니다.',
                    'evidenceTransactionIds': truth['requiredEvidenceTransactionIds']}
                if case['input']['semanticTaskKind'] == 'transactionMeaning':
                    item['classification'] = decision(truth['basicType'], 'supported' if truth['basicType'] else 'insufficient_evidence')
                else:
                    item.update(candidateKey=truth['itemKey'], name='월간 후보')
                items.append(item)
            cls.summary['cases'].append({'name': case['name'], 'state': 'succeeded', 'interpretations': items})

    @classmethod
    def tearDownClass(cls):
        """2026-11-03: 이 검사에서 만든 임시 자료만 정리한다."""
        cls.temporary.cleanup()

    def test_source_and_labels_are_complete_and_separate(self):
        """2026-11-03: 전건 정답·분포·반례·정답 입력 제외를 고정 수치로 확인한다."""
        self.assertEqual(1825, self.manifest['transactions'])
        self.assertEqual(1837, self.manifest['analysisItems'])
        self.assertEqual(184, self.manifest['batches'])
        self.assertEqual(12, self.manifest['recurringCandidates'])
        self.assertGreater(self.manifest['expectedReviews']['ask_user_for_missing_information'], 500)
        text = (self.directory / 'inputs.json').read_text(encoding='utf-8')
        for field in ('expectedReview', 'basicType', 'scenarioTruth', 'difficulty', 'labelOrigin'):
            self.assertNotIn('"' + field + '"', text)
        source = json.loads((self.directory / 'source.json').read_text(encoding='utf-8'))
        self.assertEqual(50, sum(row['recordKind'] == 'card_refund' for row in source['transactions']))
        self.assertEqual(50, sum(row['recordKind'] == 'card_cancellation' for row in source['transactions']))
        self.assertEqual(80, len(source['transactionRelations']))

    def test_exact_answers_keep_taxonomy_gaps_separate(self):
        """2026-11-03: 정답 행동과 현재 분류표의 범위 부족을 합격으로 섞지 않는다."""
        report = score_run(self.directory, self.summary)
        self.assertEqual(0, report['overall']['failures'])
        self.assertEqual(1, report['overall']['decisionMatch']['rate'])
        self.assertEqual(1, report['overall']['valueAccuracy']['rate'])
        self.assertEqual(54, report['overall']['errorReasons']['taxonomy_gap'])
        self.assertEqual(1825, report['transactions']['items'])
        self.assertEqual(12, report['recurringCandidates']['items'])
        self.assertEqual(1, report['overall']['correctUnknown']['rate'])

    def test_wrong_assertion_abstention_and_missing_are_not_success(self):
        """2026-11-03: 오탐·불필요 유보·응답 누락을 독립적으로 집계한다."""
        summary = copy.deepcopy(self.summary)
        changed_unknown = changed_known = False
        for case in summary['cases']:
            for row in case['interpretations']:
                if not changed_unknown and row['meaning']['reasonCode'] == 'insufficient_evidence':
                    row['meaning'] = {'status': 'candidate', 'value': 'salary', 'reasonCode': 'supported'}
                    changed_unknown = True
                elif not changed_known and row['meaning']['value'] == 'salary':
                    row['meaning'] = {'status': 'unknown', 'value': None, 'reasonCode': 'insufficient_evidence'}
                    changed_known = True
        summary['cases'][-1]['interpretations'].pop()
        report = score_run(self.directory, summary)
        self.assertEqual(1, report['overall']['failures'])
        self.assertEqual(1, report['overall']['unsupportedAssertion']['numerator'])
        self.assertEqual(1, report['overall']['unnecessaryAbstention']['numerator'])
        self.assertEqual(1, report['perMeaning']['salary']['falsePositive'])

    def test_later_answer_change_is_rejected(self):
        """2026-11-03: 실제 호출 후 정답을 맞춰 고쳐 점수를 올릴 수 없게 해시를 검사한다."""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            for name in ('manifest.json', 'source.json', 'inputs.json', 'expected.private.json'):
                (path / name).write_bytes((self.directory / name).read_bytes())
            with (path / 'expected.private.json').open('a', encoding='utf-8') as stream:
                stream.write(' ')
            with self.assertRaises(ValueError):
                verify_bundle(path)

    def test_reason_mismatch_does_not_change_value_accuracy(self):
        """2026-11-03: 같은 unknown이라도 사유 코드 오류를 분류값 점수와 구별한다."""
        summary = copy.deepcopy(self.summary)
        target = next(row for case in summary['cases'] for row in case['interpretations']
                      if row['meaning']['reasonCode'] == 'insufficient_evidence')
        target['meaning']['reasonCode'] = 'conflicting_evidence'
        report = score_run(self.directory, summary)
        self.assertEqual(1, report['overall']['valueAccuracy']['rate'])
        self.assertEqual(1, report['overall']['errorReasons']['wrong_meaning_reason'])

    def test_relation_evidence_must_remain_traceable(self):
        """2026-11-03: 이체 의미가 맞아도 필수 상대 거래 근거 누락을 별도 기록한다."""
        summary = copy.deepcopy(self.summary)
        target = next(row for case in summary['cases'] for row in case['interpretations']
                      if row['meaning']['value'] == 'self_transfer')
        target['evidenceTransactionIds'] = target['evidenceTransactionIds'][:1]
        report = score_run(self.directory, summary)
        self.assertEqual(1, report['overall']['valueAccuracy']['rate'])
        self.assertEqual(1, report['overall']['errorReasons']['missing_required_evidence'])

    def test_empty_execution_is_failure_not_unknown(self):
        """2026-11-03: 미실행을 정상 판단 유보나 무료 성공으로 집계하지 않는다."""
        report = score_run(self.directory, {'cases': []})
        self.assertEqual(1837, report['overall']['failures'])
        self.assertEqual(0, report['overall']['abstention']['numerator'])
        self.assertEqual(0, report['overall']['accuracy']['numerator'])


if __name__ == '__main__':
    unittest.main()
