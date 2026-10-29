"""2026-10-29: 청구 v4 공개·제한·페이지 계약의 독립 벡터를 검사한다."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fixtures'))
from billing_projection import API_SCHEMA, BillingContractError, project_statements, validate_fragment
from statement_items import legacy_items


def prepared_source():
    """2026-10-29: 동적 ID와 명시 소유 관계로 최소 청구 근거를 만든다. 사용: 각 검사."""
    ids = {key: str(uuid4()) for key in ('user', 'card', 'purchase', 'bill', 'fee')}
    version = 'projection-vector-4'
    statement = {
        'statementId': ids['bill'], 'userId': ids['user'], 'cardId': ids['card'],
        'sourceRef': 'fixture/billing/statement', 'sourceVersion': version,
        'amountKRW': 115000, 'dueDate': '2026-11-10', 'periodStart': None, 'periodEnd': None,
        'detailCompleteness': 'complete', 'includedTransactionRefs': [ids['purchase']],
    }
    statement['items'] = legacy_items(statement)
    installment = statement['items'][0]
    ids['item'] = installment['itemId']
    installment.update(label='청구 할부', merchantName='별초가전 달솔점',
                       originalUsedAmountKRW=600000, billedPrincipalKRW=100000,
                       feeOrAdjustmentAmountKRW=-5000, billedAmountKRW=95000,
                       installmentMonths=6, installmentRound=2)
    statement['items'].append({**deepcopy(installment), 'itemId': ids['fee'],
                               'sourceRef': 'fixture/billing/annual-fee', 'transactionId': None,
                               'label': '연회비', 'merchantName': None, 'originalUsedAmountKRW': None,
                               'billedPrincipalKRW': None, 'feeOrAdjustmentAmountKRW': 20000,
                               'billedAmountKRW': 20000, 'installmentMonths': None,
                               'installmentRound': None})
    source = {
        'schemaVersion': 'PAYSE-DRAFT-4', 'userId': ids['user'], 'sourceVersion': version,
        'cards': [{'cardId': ids['card'], 'userId': ids['user'], 'sourceVersion': version}],
        'transactions': [{'transactionId': ids['purchase'], 'userId': ids['user'],
                          'cardId': ids['card'], 'sourceVersion': version}],
        'relatedTransactions': [], 'statements': [statement],
    }
    return source, ids


def add_hidden_bill(source):
    """2026-10-29: 다른 카드의 청구와 무거래 항목을 독립 ID로 추가한다. 사용: 누출 회귀 검사."""
    ids = {key: str(uuid4()) for key in ('card', 'bill', 'item')}
    source['cards'].append({'cardId': ids['card'], 'userId': source['userId'],
                            'sourceVersion': source['sourceVersion']})
    statement = deepcopy(source['statements'][0])
    statement.update(statementId=ids['bill'], cardId=ids['card'],
                     sourceRef='fixture/billing/hidden-statement', includedTransactionRefs=[])
    statement['items'] = [deepcopy(next(item for item in statement['items']
                                      if item['transactionId'] is None))]
    statement['items'][0].update(itemId=ids['item'], sourceRef='fixture/billing/hidden-item')
    source['statements'].append(statement)
    return ids


class BillingProjectionTests(unittest.TestCase):
    """2026-10-29: 금융 원천·별도 계산 없이 공개 fragment와 오류를 검증한다. 사용: unittest."""

    def test_invalid_identity_uses_contract_error(self):
        """2026-10-29: 잘못된 원천/공개 ID를 지정 계약 오류로 통일한다. 사용: unittest."""
        for kind in ('owner', 'card', 'statement'):
            with self.subTest(kind=kind):
                source, ids = prepared_source()
                if kind == 'owner':
                    source['userId'] = 'invalid'
                elif kind == 'card':
                    source['cards'][0]['cardId'] = 'invalid'
                else:
                    source['statements'][0]['statementId'] = 'invalid'
                with self.assertRaises(BillingContractError):
                    project_statements(source, {ids['card']}, {ids['purchase']})
        source, ids = prepared_source()
        fragment = project_statements(source, {ids['card']}, {ids['purchase']})
        fragment['statements'][0]['cardId'] = 'invalid'
        with self.assertRaises(BillingContractError):
            validate_fragment(fragment)

    def test_discount_null_and_unlinked_fee(self):
        """2026-10-29: 음수 할인·미상·거래 없는 연회비를 그대로 유지한다. 사용: unittest."""
        source, ids = prepared_source()
        before = deepcopy(source)
        result = project_statements(source, {ids['card']}, {ids['purchase']}, {ids['purchase']})
        self.assertEqual(result['schemaVersion'], API_SCHEMA)
        self.assertEqual(result['statements'], source['statements'])
        self.assertEqual(result['accessRestrictions'], [])
        self.assertEqual(source, before)

    def test_negative_charge_does_not_change_parent_total(self):
        """2026-10-29: 음수 청구 항목을 총액 계산/수정 없이 전달한다. 사용: unittest."""
        source, ids = prepared_source()
        item = next(row for row in source['statements'][0]['items'] if row['itemId'] == ids['fee'])
        item.update(label='환불 조정', feeOrAdjustmentAmountKRW=-20000, billedAmountKRW=-20000)
        result = project_statements(source, {ids['card']}, {ids['purchase']})
        returned = next(row for row in result['statements'][0]['items'] if row['itemId'] == ids['fee'])
        self.assertEqual(returned['billedAmountKRW'], -20000)
        self.assertEqual(result['statements'][0]['amountKRW'], 115000)

    def test_next_page_reference_is_kept(self):
        """2026-10-29: 권한 있는 다음 페이지 거래를 미확보/미연결로 만들지 않는다. 사용: unittest."""
        source, ids = prepared_source()
        result = project_statements(source, {ids['card']}, {ids['purchase']}, set())
        self.assertEqual(result['statements'][0]['includedTransactionRefs'], [ids['purchase']])
        self.assertEqual(result['accessRestrictions'], [])
        self.assertNotIn('referenceResolutions', result)
        self.assertNotIn('relatedTransactions', result)

    def test_same_purchase_in_multiple_bills_keeps_distinct_items(self):
        """2026-10-29: 한 구매의 여러 청구 연결과 항목별 금액을 복제 거래 없이 유지한다. 사용: unittest."""
        source, ids = prepared_source()
        later = deepcopy(source['statements'][0])
        later.update(statementId=str(uuid4()), sourceRef='fixture/billing/later',
                     amountKRW=100000, dueDate='2026-12-10')
        later['items'] = [deepcopy(source['statements'][0]['items'][0])]
        later['items'][0].update(itemId=str(uuid4()), sourceRef='fixture/billing/later-item',
                                 installmentRound=3, billedAmountKRW=100000,
                                 feeOrAdjustmentAmountKRW=0)
        source['statements'].append(later)
        result = project_statements(source, {ids['card']}, {ids['purchase']})
        self.assertEqual([row['includedTransactionRefs'] for row in result['statements']],
                         [[ids['purchase']], [ids['purchase']]])
        self.assertEqual([row['items'][0]['installmentRound'] for row in result['statements']], [2, 3])
        self.assertEqual(len(source['transactions']), 1)

    def test_hidden_reference_is_omitted_but_null_is_not(self):
        """2026-10-29: 숨김 연결의 생략과 실제 null을 구분해 항목별 표식을 전달한다. 사용: unittest."""
        source, ids = prepared_source()
        result = project_statements(source, {ids['card']}, set())
        rows = {row['itemId']: row for row in result['statements'][0]['items']}
        self.assertNotIn('transactionId', rows[ids['item']])
        self.assertIsNone(rows[ids['fee']]['transactionId'])
        self.assertEqual(rows[ids['item']]['billedAmountKRW'], 95000)
        self.assertEqual(result['statements'][0]['includedTransactionRefs'], [])
        self.assertEqual({(r['ownerType'], r['ownerId'], r['field'], r['targetKind'])
                          for r in result['accessRestrictions']}, {
            ('statementItem', ids['item'], 'transactionId', 'transaction'),
            ('statement', ids['bill'], 'includedTransactionRefs', 'transaction'),
        })
        self.assertNotIn(ids['purchase'], str(result))

    def test_hidden_card_removes_whole_statement(self):
        """2026-10-29: 미연결 카드의 청구/항목/금액을 노출하지 않는다. 사용: unittest."""
        source, ids = prepared_source()
        result = project_statements(source, set(), set())
        self.assertEqual(result['statements'], [])
        self.assertEqual(result['accessRestrictions'], [{
            'ownerType': 'response', 'ownerId': None, 'field': 'statements',
            'targetKind': 'card', 'reason': 'not_connected'}])

    def test_unavailable_source_is_not_inferred_from_id(self):
        """2026-10-29: 거래 ID만 있고 소유/카드 근거가 없으면 정상 처리하지 않는다. 사용: unittest."""
        source, ids = prepared_source()
        source['transactions'] = []
        with self.assertRaises(BillingContractError):
            project_statements(source, {ids['card']}, set())

    def test_foreign_owner_and_card_are_rejected(self):
        """2026-10-29: 다른 사용자/카드 관계는 not_connected로 감추지 않고 거절한다. 사용: unittest."""
        for key in ('userId', 'cardId'):
            with self.subTest(key=key):
                source, ids = prepared_source()
                source['transactions'][0][key] = str(uuid4())
                with self.assertRaises(BillingContractError):
                    project_statements(source, {ids['card']}, {ids['purchase']})

    def test_different_source_version_is_rejected(self):
        """2026-10-29: 페이지/캐시의 다른 원천 버전을 섞지 않는다. 사용: unittest."""
        source, ids = prepared_source()
        source['transactions'][0]['sourceVersion'] = 'previous-source'
        with self.assertRaises(BillingContractError):
            project_statements(source, {ids['card']}, {ids['purchase']})

    def test_related_evidence_can_verify_reference(self):
        """2026-10-29: 기간 밖 확보 원천으로도 소유/카드 관계를 검증한다. 사용: unittest."""
        source, ids = prepared_source()
        source['relatedTransactions'] = source.pop('transactions')
        result = project_statements(source, {ids['card']}, {ids['purchase']})
        self.assertEqual(result['statements'][0]['includedTransactionRefs'], [ids['purchase']])

    def test_old_version_is_not_silently_upgraded(self):
        """2026-10-29: v4 전용 경로가 구 원천/응답 버전을 묵시 수용하지 않는다. 사용: unittest."""
        source, ids = prepared_source()
        source['schemaVersion'] = 'PAYSE-DRAFT-3'
        with self.assertRaises(BillingContractError):
            project_statements(source, {ids['card']}, {ids['purchase']})
        with self.assertRaises(BillingContractError):
            validate_fragment({'schemaVersion': 'PAYSE-API-0.6-3', 'statements': [], 'accessRestrictions': []})

    def test_restriction_registry_and_omission_are_checked(self):
        """2026-10-29: 버전뿐 아니라 표식 조합·부모·생략 관계까지 검사한다. 사용: unittest."""
        for mode in ('unknown', 'missing', 'wrong-owner', 'duplicate', 'extra-field'):
            with self.subTest(mode=mode):
                source, ids = prepared_source()
                result = project_statements(source, {ids['card']}, set())
                if mode == 'unknown':
                    result['accessRestrictions'][0]['field'] = 'items[0].transactionId'
                elif mode == 'missing':
                    result['accessRestrictions'] = []
                elif mode == 'wrong-owner':
                    result['accessRestrictions'][0]['ownerId'] = str(uuid4())
                elif mode == 'duplicate':
                    result['accessRestrictions'].append(deepcopy(result['accessRestrictions'][0]))
                else:
                    result['accessRestrictions'][0]['hiddenTransactionId'] = ids['purchase']
                with self.assertRaises(BillingContractError):
                    validate_fragment(result)

    def test_invalid_money_and_item_format_are_rejected(self):
        """2026-10-29: 원금 음수·문자 금액·불명 필드를 정상 투영하지 않는다. 사용: unittest."""
        for update in ({'billedPrincipalKRW': -1}, {'billedAmountKRW': '-1'}, {'unknown': 1}):
            source, ids = prepared_source()
            source['statements'][0]['items'][0].update(update)
            with self.assertRaises(BillingContractError):
                project_statements(source, {ids['card']}, {ids['purchase']})

    def test_public_item_format_and_parent_are_checked(self):
        """2026-10-29: 버전 표기만 맞춘 변조 응답도 금액·형식·부모 관계로 거절한다. 사용: unittest."""
        for update in ({'billedPrincipalKRW': -1}, {'billedAmountKRW': '-1'}, {'unknown': 1},
                       {'merchantName': 15}, {'installmentRound': 7},
                       {'userId': str(uuid4())}, {'sourceVersion': 'old-source'}):
            with self.subTest(update=update):
                source, ids = prepared_source()
                result = project_statements(source, {ids['card']}, {ids['purchase']})
                result['statements'][0]['items'][0].update(update)
                with self.assertRaises(BillingContractError):
                    validate_fragment(result)

    def test_visibility_page_and_source_ref_leak_are_rejected(self):
        """2026-10-29: 불명 권한·페이지 혼동·숨김 ID 원천키 노출을 거절한다. 사용: unittest."""
        source, ids = prepared_source()
        with self.assertRaises(BillingContractError):
            project_statements(source, {ids['card']}, {str(uuid4())})
        with self.assertRaises(BillingContractError):
            project_statements(source, {ids['card']}, set(), {ids['purchase']})
        source['statements'][0]['items'][0]['sourceRef'] = 'legacy/' + ids['purchase']
        with self.assertRaises(BillingContractError):
            project_statements(source, {ids['card']}, set())

    def test_hidden_statement_id_in_public_source_ref_is_rejected(self):
        """2026-10-29: 공개 청구 원천키로 숨긴 다른 청구 ID가 새지 않게 한다. 사용: unittest."""
        source, ids = prepared_source()
        hidden = add_hidden_bill(source)
        source['statements'][0]['sourceRef'] = 'statement-link/' + hidden['bill']
        before = deepcopy(source)
        with self.assertRaises(BillingContractError):
            project_statements(source, {ids['card']}, {ids['purchase']})
        self.assertEqual(source, before)

    def test_hidden_item_id_in_public_source_ref_is_rejected(self):
        """2026-10-29: 공개 항목 원천키로 숨긴 다른 항목 ID가 새지 않게 한다. 사용: unittest."""
        source, ids = prepared_source()
        hidden = add_hidden_bill(source)
        source['statements'][0]['items'][0]['sourceRef'] = 'item-link/' + hidden['item']
        before = deepcopy(source)
        with self.assertRaises(BillingContractError):
            project_statements(source, {ids['card']}, {ids['purchase']})
        self.assertEqual(source, before)


if __name__ == '__main__':
    unittest.main()
