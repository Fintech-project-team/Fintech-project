"""2026-11-01: 최소 입력·짧은 ID·정답 분리를 오프라인 검사한다. 사용: unittest."""
import copy
import json
import unittest

from build_cases import answer, identity, request
from efficiency import byte_metrics, compact_criteria, criteria_only, pack, select_items, transform_ids, unpack
from build_schemas import CONTRACTS


class EfficiencyTest(unittest.TestCase):
    """2026-11-01: 입력 절감이 근거·소유 ID·정답을 훼손하지 않도록 검사한다. 사용: unittest."""

    def setUp(self):
        """2026-11-01: 기존 생성기의 작은 독립 입력만 준비한다. 사용: unittest."""
        self.payload = request('efficiency', {'recordKind': 'account_entry', 'direction': 'in',
                                               'merchantName': '고용주', 'description': '급여 입금'})

    def encoded_response(self, packed):
        """2026-11-01: 역매핑 검사용 짧은 ID 응답을 만든다. 사용: 로컬 단위 검사만."""
        aliases = {tuple(value): alias for alias, value in packed.ids.items()}
        return transform_ids(answer(packed.payload, 'salary', 'income'),
                             lambda kind, value: aliases[(kind, value)])

    def test_round_trip_preserves_text_and_source(self):
        """2026-11-01: 본문의 UUID 모양 텍스트와 원래 입력을 바꾸지 않는다. 사용: unittest."""
        self.payload['transactions'][0]['description'] += ' ' + identity('text-not-id')
        before = copy.deepcopy(self.payload)
        packed = pack(self.payload)
        self.assertEqual(packed.input['transactions'][0]['description'], before['transactions'][0]['description'])
        self.assertEqual(unpack(packed, self.encoded_response(packed)), answer(before, 'salary', 'income'))
        self.assertEqual(self.payload, before)
        self.assertEqual(len(packed.ids), len(set(packed.ids.values())))

    def test_unissued_wrong_type_and_raw_ids_are_rejected(self):
        """2026-11-01: ID 주입·타입 혼용·원래 UUID 직접 반환을 거절한다. 사용: unittest."""
        packed = pack(self.payload)
        for forged in ('t999', 'i1', self.payload['transactions'][0]['transactionId']):
            response = self.encoded_response(packed)
            response['items'][0]['evidenceTransactionIds'] = [forged]
            with self.subTest(id=forged), self.assertRaises(ValueError):
                unpack(packed, response)

    def test_output_contract_still_applies(self):
        """2026-11-01: 압축 복원 후 누락·금융 실행 필드도 기존 계약으로 거절한다. 사용: unittest."""
        packed = pack(self.payload)
        missing = self.encoded_response(packed)
        missing['items'] = []
        with self.assertRaises(ValueError):
            unpack(packed, missing)
        extra = self.encoded_response(packed)
        extra['items'][0]['balance'] = 1
        with self.assertRaises(ValueError):
            unpack(packed, extra)

    def test_select_independent_item_without_mutation(self):
        """2026-11-01: 독립 항목만 분리하고 원본과 선택 항목 근거를 보존한다. 사용: unittest."""
        other = request('efficiency-other', {'recordKind': 'account_entry', 'direction': 'in',
                                             'merchantName': '고용주', 'description': '성과급 지급'})
        payload = copy.deepcopy(self.payload)
        payload['items'] += other['items']
        payload['transactions'] += other['transactions']
        before = copy.deepcopy(payload)
        selected = select_items(payload, [payload['items'][0]['itemKey']])
        self.assertEqual(selected, self.payload)
        self.assertEqual(payload, before)
        for keys in ([], ['missing'], [payload['items'][0]['itemKey']] * 2):
            with self.subTest(keys=keys), self.assertRaises(ValueError):
                select_items(payload, keys)

    def test_connected_items_cannot_be_split(self):
        """2026-11-01: 작은 요청을 만들기 위해 연결 근거를 버리거나 새로 추가하지 않는다. 사용: unittest."""
        other = request('efficiency-peer', {'recordKind': 'account_entry', 'direction': 'out',
                                            'merchantName': '본인', 'description': '본인 계좌 이체'})
        payload = copy.deepcopy(self.payload)
        payload['items'] += other['items']
        payload['transactions'] += other['transactions']
        first, second = [row['transactionId'] for row in payload['transactions']]
        payload['relations'] = [{'kind': 'internal_transfer', 'fromId': first, 'toId': second}]
        with self.assertRaises(ValueError):
            select_items(payload, [payload['items'][0]['itemKey']])
        self.assertEqual(select_items(payload, [row['itemKey'] for row in payload['items']]), payload)
        payload['relations'] = []
        payload['transactions'][0]['originalTransactionId'] = second
        with self.assertRaises(ValueError):
            select_items(payload, [payload['items'][0]['itemKey']])

    def test_unavailable_original_is_retained(self):
        """2026-11-01: 공개되지 않은 원거래의 사유를 압축이나 선택에서 제거하지 않는다. 사용: unittest."""
        original = identity('unavailable')
        self.payload['transactions'][0]['originalTransactionId'] = original
        self.payload['unavailableReferences'] = [{'transactionId': original, 'reason': 'outside_retention'}]
        selected = select_items(self.payload, [self.payload['items'][0]['itemKey']])
        self.assertEqual(selected, self.payload)
        packed = pack(selected)
        self.assertEqual(packed.input['transactions'][0]['originalTransactionId'],
                         packed.input['unavailableReferences'][0]['transactionId'])

    def test_policy_export_is_allowlisted(self):
        """2026-11-01: 분류 기준만 내보내고 정답·반례·알 수 없는 메타는 버린다. 사용: unittest."""
        policy = {'version': 'v', 'private': 'secret', 'meanings': [{
            'code': 'salary', 'label': '급여', 'requiredEvidence': ['근로 대가'],
            'insufficientEvidence': ['이름만 있음'], 'basicTypePolicy': '원천 유지',
            'positive': {'expectedBasicType': 'income'}, 'contrast': {'expectedMeaning': None},
            'counterexample': '검증용 비공개 사례', 'unknownPrivateKey': 'secret'}]}
        exported = criteria_only(policy)
        self.assertEqual(set(exported), {'version', 'meanings'})
        self.assertEqual(set(exported['meanings'][0]), {'code', 'label', 'requiredEvidence',
                                                      'insufficientEvidence'})
        exported['meanings'][0]['requiredEvidence'].clear()
        self.assertEqual(policy['meanings'][0]['requiredEvidence'], ['근로 대가'])

    def test_size_report_does_not_claim_tokens_or_cost(self):
        """2026-11-01: JSON 바이트 감소와 미측정 토큰·비용을 구분한다. 사용: unittest."""
        report = byte_metrics(self.payload, pack(self.payload))
        self.assertLess(report['packedBytes'], report['projectedBytes'])
        self.assertLess(report['projectedBytes'], report['requestBytes'])
        self.assertIsNone(report['actualTokens'])
        self.assertIsNone(report['actualCost'])
        self.assertEqual(report['providerCalls'], 0)

    def test_factored_policy_preserves_every_criterion(self):
        """2026-11-01: 중복 문장 압축이 기준이나 순서를 빼먹지 않게 복원한다. 사용: unittest."""
        policy = json.loads((CONTRACTS / 'meaning-policy.json').read_text(encoding='utf-8-sig'))
        compact = compact_criteria(policy)
        restored = {'version': compact['version'], 'meanings': []}
        for row in compact['meanings']:
            restored['meanings'].append({**row, **{
                field: [compact['rules'][key] for key in row[field]]
                for field in ('requiredEvidence', 'insufficientEvidence')}})
        self.assertEqual(restored, criteria_only(policy))
        self.assertLess(len(json.dumps(compact)), len(json.dumps(restored)))


if __name__ == '__main__':
    unittest.main()
