"""2026-11-01: 5000개 이상 조건 사례와 압축·사례군 경계를 검사한다. 사용: Gradle/unittest."""
import copy
import json
import unittest

from build_cases import answer, identity, request
from diversity import fingerprint
from efficiency import byte_metrics, pack, transform_ids, unpack
from expansion import prepare_expanded, inspect_corpus
from partitions import split_report


class ExpansionTest(unittest.TestCase):
    """2026-11-01: 합성 개발 전건 검증과 독립 평가 주장 방지를 담당한다. 사용: unittest."""

    @classmethod
    def setUpClass(cls):
        """2026-11-01: 대용량 불변 입력을 한 번 생성해 반복 준비 비용을 줄인다. 사용: unittest."""
        cls.inputs, cls.expected = prepare_expanded()

    def test_all_cases_validate_and_gaps_remain_errors(self):
        """2026-11-01: 전건 계약 검사와 범위 부족 오류를 함께 확인한다. 사용: unittest."""
        report = inspect_corpus(self.inputs, self.expected)
        self.assertGreaterEqual(report['diversity']['cases'], 5000)
        self.assertEqual(report['diversity']['duplicateInputGroups'], [])
        self.assertGreaterEqual(report['diversity']['surfaceBlindDistinctInputs'], 5000)
        self.assertGreaterEqual(report['diversity']['distinctTransactionTargets'], 5000)
        failures = report['oracleHarnessCheck']
        self.assertGreater(failures['taxonomyCoverageGaps'], 0)
        self.assertEqual(failures['jointError']['numerator'], failures['taxonomyCoverageGaps'])
        self.assertEqual(report['finalHoldoutCases'], 0)
        self.assertIsNone(report['measuredTokens'])

    def test_generated_families_cannot_be_promoted_to_final(self):
        """2026-11-01: 공유 생성 문법을 쓴 전건을 개발 영역으로 묶는다. 사용: unittest."""
        report = split_report(self.inputs, self.expected)
        self.assertEqual(report['familyComponents'], 1)
        self.assertFalse(report['independenceProven'])
        first = next(iter(self.expected))
        altered = {**self.expected, first: {**self.expected[first], 'split': 'final'}}
        with self.assertRaises(ValueError):
            split_report(self.inputs, altered)

    def test_compression_round_trip_for_every_case(self):
        """2026-11-01: 모든 근거·원거래·후보 ID를 압축 후 원래 계약으로 복원한다. 사용: unittest."""
        for key, payload in self.inputs.items():
            with self.subTest(case=key):
                truth = self.expected[key]['items'][0]
                response = answer(payload, truth['meaning'], truth['basicType'], '반복 비용')
                compressed = pack(payload)
                aliases = {tuple(value): alias for alias, value in compressed.ids.items()}
                short = transform_ids(response, lambda kind, value: aliases[(kind, value)])
                self.assertEqual(unpack(compressed, short), response)
                metrics = byte_metrics(payload, compressed)
                self.assertLess(metrics['packedBytes'], metrics['projectedBytes'])

    def test_reference_topology_is_not_erased(self):
        """2026-11-01: 타깃 관계와 다른 거래 사이의 관계를 다르게 식별한다. 사용: unittest."""
        payload = request('topology', {'recordKind': 'account_entry', 'direction': 'out',
                                       'merchantName': None, 'description': '자금 이동'})
        target = payload['transactions'][0]
        peers = [{**target, 'transactionId': identity(f'topology/{i}')} for i in range(2)]
        peers[0]['direction'] = 'in'
        payload['transactions'] += peers
        payload['items'][0]['evidenceTransactionIds'] += [row['transactionId'] for row in peers]
        payload['relations'] = [{'kind': 'internal_transfer', 'fromId': target['transactionId'], 'toId': peers[0]['transactionId']}]
        different = copy.deepcopy(payload)
        different['relations'][0]['fromId'] = peers[1]['transactionId']
        self.assertNotEqual(fingerprint(payload), fingerprint(different))
        reordered = copy.deepcopy(payload)
        reordered['transactions'].reverse()
        reordered['items'][0]['evidenceTransactionIds'].reverse()
        reordered['items'][0]['itemKey'] = 'not-a-uuid'
        self.assertEqual(fingerprint(payload), fingerprint(reordered))

    def test_name_and_number_changes_do_not_increase_final_count(self):
        """2026-11-01: 상호·숫자 표기만 다른 거래를 독립 최종 표본으로 세지 않는다. 사용: unittest."""
        payload = request('surface', {'recordKind': 'account_entry', 'direction': 'out',
                                      'merchantName': '상점 가', 'description': '물품 대금 10000원'})
        changed = copy.deepcopy(payload)
        changed['transactions'][0].update(merchantName='상점 나', description='물품 대금 70000원')
        self.assertNotEqual(fingerprint(payload), fingerprint(changed))
        self.assertEqual(fingerprint(payload, ignore_surface=True), fingerprint(changed, ignore_surface=True))

    def test_labels_and_target_metadata_stay_private(self):
        """2026-11-01: 조건·사례군·기대 답을 압축 모델 본문에 넣지 않는다. 사용: unittest."""
        for payload in self.inputs.values():
            text = json.dumps(pack(payload).input)
            for field in ('coverageGap', 'inputSufficient', 'purposePair', 'familyLinks', 'expectedBasicType'):
                self.assertNotIn(field, text)


if __name__ == '__main__':
    unittest.main()
