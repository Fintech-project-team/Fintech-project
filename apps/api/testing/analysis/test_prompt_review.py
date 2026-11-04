"""2026-11-04: 사례 분류·동결 표본·동일 분모 비교의 오프라인 경계를 검사한다."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

from gamma_evaluation import freeze, verify_bundle

ROOT = Path(__file__).resolve().parents[4]
SPEC = importlib.util.spec_from_file_location('prompt_review', ROOT / 'apps/ai/testing/prompt_review.py')
review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review)


class PromptReviewTests(unittest.TestCase):
    """2026-11-04: 실제 합성 계약과 채점기를 사용하며 외부 모델은 호출하지 않는다."""

    @classmethod
    def setUpClass(cls):
        """2026-11-04: 입력/정답을 한 번 고정하고 테스트 간 수정하지 않는다."""
        (ROOT / '.harness').mkdir(exist_ok=True)
        cls.folder = tempfile.TemporaryDirectory(dir=ROOT / '.harness')
        cls.dataset = Path(cls.folder.name) / 'frozen'
        cls.manifest = freeze(cls.dataset)

    @classmethod
    def tearDownClass(cls):
        """2026-11-04: 이 테스트가 소유한 임시 자료만 정리한다."""
        cls.folder.cleanup()

    def test_catalog_keeps_all_cases_and_excludes_identifiers(self):
        """2026-11-04: 실패를 제외하지 않고 유형·원천 예시만 공유한다."""
        result = review.catalog(self.dataset, {'cases': []})
        self.assertEqual(1837, result['items'])
        self.assertEqual(1837, sum(row['items'] for row in result['cases']))
        self.assertFalse(result['runtimePromptInput'])
        self.assertFalse(result['independentHoldout'])
        source = review.read(self.dataset / 'source.json')
        self.assertNotIn(source['userId'], str(result))
        self.assertNotIn(source['transactions'][0]['transactionId'], str(result))
        self.assertEqual(self.manifest, verify_bundle(self.dataset))

    def test_selection_and_labels_are_stable_before_any_result(self):
        """2026-11-04: 결과·오답을 읽지 않는 선택과 원본 정답 보존을 검사한다."""
        cases = review.read(self.dataset / 'inputs.json')
        gold = review.read(self.dataset / 'expected.private.json')
        chosen = review.select_cases(cases, gold, 16)
        self.assertEqual(chosen, review.select_cases(list(reversed(cases)), gold, 16)[::-1])
        destination = Path(self.folder.name) / 'sample'
        manifest = review.subset(self.dataset, destination, 16)
        self.assertEqual(16, manifest['batches'])
        self.assertEqual(self.manifest['sha256']['source.json'], manifest['sha256']['source.json'])
        self.assertEqual({case['name']: gold[case['name']] for case in chosen},
                         review.read(destination / 'expected.private.json'))
        self.assertEqual(set(self.manifest['categories']), set(manifest['categories']))
        with self.assertRaises(ValueError):
            review.subset(self.dataset, destination, 16)

    def test_missing_results_remain_failures_in_same_denominator(self):
        """2026-11-04: 실행 누락을 정상 unknown으로 세지 않고 낯선 배치도 거절한다."""
        report = review.compare(self.dataset, {'cases': []}, {'cases': []})
        self.assertEqual(1837, report['revised']['overall']['failures'])
        self.assertEqual(1837, report['valueTransitions']['wrong_to_wrong'])
        self.assertIsNone(report['revisedLatency']['meanSeconds'])
        with self.assertRaises(ValueError):
            review.compare(self.dataset, {'cases': []}, {'cases': [{'name': 'not-selected'}]})

    def test_changed_source_is_not_accepted_as_the_same_evaluation(self):
        """2026-11-04: 원본을 건드리지 않고 별도 표본의 변조를 검사한다."""
        destination = Path(self.folder.name) / 'tampered'
        review.subset(self.dataset, destination, 2)
        changed = copy.deepcopy(review.read(destination / 'inputs.json'))
        changed[0]['input']['items'].pop()
        review.write(destination / 'inputs.json', changed)
        with self.assertRaises(ValueError):
            review.compare(destination, {'cases': []}, {'cases': []})


if __name__ == '__main__':
    unittest.main()
