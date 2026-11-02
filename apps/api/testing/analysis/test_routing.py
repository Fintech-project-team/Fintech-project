"""2026-11-01: 원천 확인/유효 결과 재사용의 오프라인 실패 조건을 검사한다. 사용: unittest."""
import copy
import unittest
from build_cases import answer, identity, request
from efficiency import select_items
from routing import evidence_key, plan


class RoutingTest(unittest.TestCase):
    """2026-11-01: 검증 권위를 가정한 계획기 경계를 증명한다. 사용: unittest; 실제 DB 아님."""

    def setUp(self):
        """2026-11-01: 원천·기간·검증 결과를 독립 준비한다. 사용: unittest."""
        self.payload = request('routing-first', {'recordKind': 'account_entry', 'direction': 'in',
                               'merchantName': '가상 고용주', 'description': '근로 급여 입금'})
        self.item = self.payload['items'][0]['itemKey']
        self.owner = 'authenticated-scope-a'
        self.now = '2026-11-01T12:00:00+09:00'
        self.versions = {'policy': 'PAYSE-MEANING-1', 'model': 'offline-model-version',
                         'prompt': 'offline-prompt-version', 'schema': 'PAYSE-ANALYSIS-1'}
        self.record = {'verified': True, 'route': 'reused_result', 'ownerScope': self.owner,
                       'targetKey': self.payload['items'][0]['targetTransactionId'],
                       'evidenceFingerprint': evidence_key(self.payload, self.item),
                       'versions': copy.deepcopy(self.versions), 'active': True, 'deleted': False,
                       'expired': False, 'sourceValid': True, 'userCorrected': False,
                       'isReference': False, 'important': False, 'accountPurgeAt': None,
                       'storedAt': '2026-10-31T12:00:00+09:00', 'normalExpiresAt': '2027-01-31T12:00:00+09:00',
                       'result': answer(self.payload, 'salary', 'income')['items'][0]}

    def evaluate(self, records=None, payload=None, now=None):
        """2026-11-01: 테스트 입력을 오프라인 계획기에 전달한다. 사용: RoutingTest."""
        return plan(payload or self.payload, self.owner, self.versions,
                    [self.record] if records is None else records, now or self.now)

    def test_valid_reuse_preserves_expiry_and_input(self):
        """2026-11-01: 재사용 성공에도 최초 저장·만료와 원천을 바꾸지 않는다. 사용: unittest."""
        before = copy.deepcopy((self.payload, self.record))
        result = self.evaluate()
        self.assertEqual(result['unresolvedItemKeys'], [])
        self.assertEqual(result['resolved'][self.item]['normalExpiresAt'], self.record['normalExpiresAt'])
        self.assertEqual(result['resolved'][self.item]['storedAt'], self.record['storedAt'])
        self.assertEqual(before, (self.payload, self.record))
        self.assertEqual(result['externalCalls'], 0)
        self.assertFalse(result['productionAuthorityVerified'])
        self.assertFalse(result['effectivePersistedClassificationImplemented'])

    def test_rejections_preserve_denominator(self):
        """2026-11-01: 소유권·원천·삭제·활성·정정·만료 위반을 미해결로 남긴다. 사용: unittest."""
        mutations = [('ownerScope', 'different-owner'), ('verified', False), ('sourceValid', False),
                     ('active', False), ('deleted', True), ('expired', True), ('userCorrected', True),
                     ('evidenceFingerprint', 'different-evidence')]
        for field, value in mutations:
            changed = {**self.record, field: value}
            result = self.evaluate([changed])
            with self.subTest(field=field):
                self.assertEqual(result['totalItems'], 1)
                self.assertEqual(result['resolved'], {})
                self.assertEqual(result['unresolvedItemKeys'], [self.item])
                self.assertTrue(result['rejectedProofs'][self.item])

    def test_all_version_changes_invalidate_reuse(self):
        """2026-11-01: 정책·모델·프롬프트·스키마 변경은 기존 결과를 무효화한다. 사용: unittest."""
        for field in self.versions:
            changed = copy.deepcopy(self.record)
            changed['versions'][field] = 'changed-version'
            with self.subTest(field=field):
                self.assertEqual(self.evaluate([changed])['unresolvedItemKeys'], [self.item])

    def test_exact_expiry_and_future_storage(self):
        """2026-11-01: 만료 직전만 허용하고 경계·미래 저장·잘못된 기간을 거절한다. 사용: unittest."""
        before = self.evaluate(now='2027-01-31T11:59:59+09:00')
        self.assertIn(self.item, before['resolved'])
        self.assertEqual(self.evaluate(now=self.record['normalExpiresAt'])['unresolvedItemKeys'], [self.item])
        for field, value in [('storedAt', '2026-11-02T12:00:00+09:00'),
                             ('normalExpiresAt', self.record['storedAt']), ('normalExpiresAt', '2027-01-31T12:00:00')]:
            with self.subTest(field=field, value=value):
                self.assertEqual(self.evaluate([{**self.record, field: value}])['unresolvedItemKeys'], [self.item])

    def test_important_reference_exception_and_account_retention(self):
        """2026-11-01: 중요 AI 참고자료 예외만 적용하고 해제·탈퇴 보관 종료를 우회하지 않는다. 사용: unittest."""
        later = '2027-02-01T12:00:00+09:00'
        important = {**self.record, 'isReference': True, 'important': True}
        result = self.evaluate([important], now=later)
        self.assertIn(self.item, result['resolved'])
        self.assertTrue(result['resolved'][self.item]['importantReference'])
        self.assertEqual(result['resolved'][self.item]['normalExpiresAt'], self.record['normalExpiresAt'])
        for changed in ({**important, 'important': False}, {**important, 'isReference': False},
                        {**important, 'accountPurgeAt': later}, {**important, 'deleted': True}):
            with self.subTest(record=changed):
                self.assertEqual(self.evaluate([changed], now=later)['unresolvedItemKeys'], [self.item])

    def test_changed_source_or_relationship_invalidates_reuse(self):
        """2026-11-01: 같은 ID라도 적요·참조 관계가 바뀌면 예전 결과를 쓰지 않는다. 사용: unittest."""
        changed = copy.deepcopy(self.payload)
        changed['transactions'][0]['description'] = '직원 대출 실행금'
        self.assertEqual(self.evaluate(payload=changed)['unresolvedItemKeys'], [self.item])
        partner = {**self.payload['transactions'][0], 'transactionId': identity('routing-related'), 'direction': 'out'}
        related = copy.deepcopy(self.payload)
        related['transactions'].append(partner)
        related['items'][0]['evidenceTransactionIds'].append(partner['transactionId'])
        related['relations'] = [{'kind': 'internal_transfer', 'fromId': partner['transactionId'],
                                'toId': self.payload['transactions'][0]['transactionId']}]
        record = {**self.record, 'evidenceFingerprint': evidence_key(related, self.item)}
        changed = copy.deepcopy(related)
        changed['relations'][0]['kind'] = 'card_account_pair'
        changed['transactions'][1].update(recordKind='card_purchase', status='approved', reflectionReason='not_applicable')
        self.assertEqual(self.evaluate([record], changed)['unresolvedItemKeys'], [self.item])

    def test_unproven_existing_classification_or_text_does_not_resolve(self):
        """2026-11-01: 이름·적요·기존 분류만으로 원천 확인 권위를 만들지 않는다. 사용: unittest."""
        self.payload['currentClassifications'] = [{
            'transactionId': self.payload['items'][0]['targetTransactionId'], 'value': 'income'}]
        result = self.evaluate([])
        self.assertEqual(result['unresolvedItemKeys'], [self.item])
        self.assertEqual(result['resolved'], {})

    def test_partial_or_manual_unknown_does_not_skip_analysis(self):
        """2026-11-01: 기본 분류만 알려졌거나 사용자가 모른다고 한 항목을 완료로 세지 않는다. 사용: unittest."""
        for route, meaning, basic in [('source_fact', None, 'income'),
                                      ('source_fact', 'salary', None),
                                      ('user_confirmed', None, None)]:
            changed = {**self.record, 'route': route,
                       'result': answer(self.payload, meaning, basic)['items'][0]}
            with self.subTest(route=route, meaning=meaning):
                result = self.evaluate([changed])
                self.assertEqual(result['unresolvedItemKeys'], [self.item])
                self.assertIn('incomplete_result', result['rejectedProofs'][self.item])

    def test_valid_saved_unknown_is_reused_without_becoming_a_fact(self):
        """2026-11-01: 정상 unknown 저장 결과를 재조회 때문에 재호출하지 않는다. 사용: unittest."""
        cached = {**self.record, 'result': answer(self.payload, None, None)['items'][0]}
        result = self.evaluate([cached])
        self.assertEqual(result['unresolvedItemKeys'], [])
        self.assertIsNone(result['resolved'][self.item]['result']['meaning']['value'])
        self.assertEqual(result['resolved'][self.item]['route'], 'reused_result')
        self.assertEqual(result['externalCalls'], 0)

    def test_source_priority_and_conflict(self):
        """2026-11-01: 원천 확인을 우선하며 같은 권위의 충돌만 미해결로 둔다. 사용: unittest."""
        source = {**self.record, 'route': 'source_fact'}
        result = self.evaluate([self.record, source])
        self.assertEqual(result['resolved'][self.item]['route'], 'source_fact')
        conflict = {**source, 'result': answer(self.payload, 'bonus', 'income')['items'][0]}
        result = self.evaluate([source, conflict])
        self.assertEqual(result['unresolvedItemKeys'], [self.item])
        self.assertIn('conflicting_verified_results', result['rejectedProofs'][self.item])

    def test_source_fact_supersedes_cached_unknown_or_old_model(self):
        """2026-11-01: 이전 unknown·모델 버전 때문에 확인된 원천을 재분석하지 않는다. 사용: unittest."""
        source = copy.deepcopy(self.record)
        source['route'] = 'source_fact'
        source['versions']['model'] = 'previous-model'
        source['versions']['prompt'] = 'previous-prompt'
        cached = {**self.record, 'result': answer(self.payload, None, None)['items'][0]}
        result = self.evaluate([cached, source])
        self.assertEqual(result['unresolvedItemKeys'], [])
        self.assertEqual(result['resolved'][self.item]['route'], 'source_fact')
        self.assertEqual(result['resolved'][self.item]['result']['meaning']['value'], 'salary')

    def test_unresolved_subset_retains_all_requested_items(self):
        """2026-11-01: 재사용 항목을 제외해도 평가 분모와 미해결 근거는 유지한다. 사용: unittest."""
        second = request('routing-second', {'recordKind': 'account_entry', 'direction': 'in',
                         'merchantName': '가상 기관', 'description': '대출 실행금'})
        batch = copy.deepcopy(self.payload)
        batch['items'] += second['items']
        batch['transactions'] += second['transactions']
        result = self.evaluate(payload=batch)
        self.assertEqual(result['totalItems'], 2)
        self.assertEqual(len(result['resolved']) + len(result['unresolvedItemKeys']), 2)
        self.assertEqual(result['unresolvedItemKeys'], [second['items'][0]['itemKey']])
        pending = select_items(batch, result['unresolvedItemKeys'])
        self.assertEqual(pending['transactions'], second['transactions'])

    def test_invalid_output_never_reused(self):
        """2026-11-01: 저장된 결과라도 잘못된 참조·계약을 그대로 반환하지 않는다. 사용: unittest."""
        changed = copy.deepcopy(self.record)
        changed['result']['evidenceTransactionIds'] = [identity('not-owned-evidence')]
        self.assertEqual(self.evaluate([changed])['unresolvedItemKeys'], [self.item])

    def test_dependent_batch_does_not_lose_relation_evidence(self):
        """2026-11-01: 분리할 수 없는 미해결 관계는 배치 전체를 유지한다. 사용: unittest."""
        second = request('routing-dependent', {'recordKind': 'account_entry', 'direction': 'out',
                         'merchantName': '본인 다른 계좌', 'description': '본인 계좌 이체'})
        batch = copy.deepcopy(self.payload)
        second_id = second['transactions'][0]['transactionId']
        batch['transactions'] += second['transactions']
        batch['items'][0]['evidenceTransactionIds'].append(second_id)
        batch['items'] += second['items']
        batch['relations'] = [{'kind': 'internal_transfer', 'fromId': second_id,
                               'toId': self.payload['transactions'][0]['transactionId']}]
        record = {**self.record, 'evidenceFingerprint': evidence_key(batch, self.item),
                  'result': answer(batch, 'self_transfer', 'internal_transfer')['items'][0]}
        result = self.evaluate([record], batch)
        self.assertEqual(result['resolved'], {})
        self.assertEqual(len(result['unresolvedItemKeys']), 2)
        self.assertEqual(select_items(batch, result['unresolvedItemKeys']), batch)


if __name__ == '__main__':
    unittest.main()
