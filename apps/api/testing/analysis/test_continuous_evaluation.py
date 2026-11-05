"""2026-11-04: EX-B 시험 자료 동결·분리·실패 포함 지연 집계 검사. 사용: unittest."""
import json
from pathlib import Path
import tempfile
import unittest

from continuous_evaluation import freeze, latency
from gamma_evaluation import verify_bundle


class ContinuousTests(unittest.TestCase):
    """2026-11-04: 유료 호출 전에 정답과 측정 분모의 무결성을 확인한다."""

    def test_frozen_evidence_and_disjoint_ids(self):
        """2026-11-04: 공개 입력에는 정답이 없고 다른 seed의 식별자는 겹치지 않는다."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = freeze(root / 'a', 2026110441, 'development', 100)
            second = freeze(root / 'b', 2026110442, 'holdout', 100, True)
            self.assertEqual(10, first['batches'])
            self.assertEqual(0, first['modelCalls'])
            self.assertEqual(1825, first['transactions'])
            self.assertEqual(10, second['recurringCandidates'])
            self.assertEqual(110, second['analysisItems'])
            self.assertEqual(first, verify_bundle(root / 'a'))
            a = json.loads((root / 'a/inputs.json').read_text(encoding='utf-8'))
            b = json.loads((root / 'b/inputs.json').read_text(encoding='utf-8'))
            self.assertTrue(all(row['triggerKind'] == 'B' for row in a + b))
            ids_a = {item['itemKey'] for row in a for item in row['input']['items']}
            ids_b = {item['itemKey'] for row in b for item in row['input']['items']}
            self.assertFalse(ids_a & ids_b)
            self.assertNotIn('expectedReview', json.dumps(a))
            self.assertGreater(len(first['conditions']), 60)
            self.assertGreater(first['expectedReviews']['ask_user_for_missing_information'], 0)
            self.assertGreater(first['expectedReviews']['taxonomy_review'], 0)
            expected = json.loads((root / 'b/expected.private.json').read_text(encoding='utf-8'))
            by_case = {row['name']: row['input'] for row in b}
            for name, case in expected.items():
                for item in case['items']:
                    if item['condition'] == 'mixed_basket':
                        target = next(row for row in by_case[name]['transactions']
                                      if row['transactionId'] == item['targetTransactionId'])
                        self.assertIn('채소', target['description'])
                        self.assertIn('가구', target['description'])
                        self.assertEqual('taxonomy_review', item['expectedReview'])
            path = root / 'a/expected.private.json'
            path.write_text('{}', encoding='utf-8')
            with self.assertRaises(ValueError):
                verify_bundle(root / 'a')

    def test_latency_includes_failures_and_tail(self):
        """2026-11-04: 빠른 실패를 빠른 성공에 합산하거나 꼬리 지연을 평균으로 감추지 않는다."""
        result = latency({'cases': [
            {'state': 'succeeded', 'elapsedMillis': 4000},
            {'state': 'failed', 'elapsedMillis': 1000},
            {'state': 'succeeded', 'elapsedMillis': 6000}]})
        self.assertEqual(1, result['successfulWithinFiveSeconds'])
        self.assertEqual(1, result['failed'])
        self.assertEqual(6000, result['p95Millis'])
        self.assertFalse(result['allWithinFiveSeconds'])
        incomplete = {'cases': [{'state': 'succeeded', 'elapsedMillis': 1000}]}
        self.assertFalse(latency(incomplete)['allWithinFiveSeconds'])
        incomplete['evaluationComplete'] = True
        self.assertTrue(latency(incomplete)['allWithinFiveSeconds'])

    def test_fresh_wording_is_separate_before_inference(self):
        """2026-11-04: 새 표현과 개발/검증 분리를 확인하고 근거 없는 유보 정답을 방지한다."""
        from continuous_evaluation import MEMOS, AMBIGUOUS
        from continuous_cases import MEMOS as fresh, AMBIGUOUS as fresh_ambiguous
        old = {text for pair in (*MEMOS.values(), *AMBIGUOUS.values()) for text in pair}
        new = {text for pair in (*fresh.values(), *fresh_ambiguous.values()) for text in pair}
        self.assertFalse(old & new)
        self.assertEqual(set(MEMOS), set(fresh))
        self.assertEqual(set(AMBIGUOUS), set(fresh_ambiguous))
        self.assertTrue(all(pair[0] != pair[1] for pair in fresh.values()))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'fresh'
            manifest = freeze(root, 2026110460, 'holdout', 100, True, True)
            self.assertEqual('continuous-4-fresh', manifest['generator'])
            self.assertEqual(manifest, verify_bundle(root))
            self.assertEqual(0, manifest['modelCalls'])
            self.assertEqual(110, manifest['analysisItems'])
            source = json.loads((root / 'source.json').read_text(encoding='utf-8'))
            descriptions = {row['description'] for row in source['transactions']}
            self.assertTrue(descriptions & new)


if __name__ == '__main__':
    unittest.main()
