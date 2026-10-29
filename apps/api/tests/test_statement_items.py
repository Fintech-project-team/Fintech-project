"""2026-10-29: 청구 항목 원천·관계·구 ID 변환의 계약 검증. DB/HTTP를 실행하지 않는다."""
import copy
from pathlib import Path
import sys
import unittest
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fixtures'))
from statement_items import ITEM_KEYS, check_item, legacy_item_id, legacy_items, transaction_refs, validate_statement_items


class StatementItemTests(unittest.TestCase):
    """2026-10-29: 독립 경계값과 명시한 관계로 항목 검증을 확인한다. 사용: unittest."""

    def setUp(self):
        """2026-10-29: 사용자·카드·거래 관계를 새 ID로 준비한다. 사용: unittest."""
        self.owner, self.card, self.purchase = (str(uuid4()) for _ in range(3))
        self.version = 'prepared-statement-items'
        self.transactions = {
            self.purchase: {'transactionId': self.purchase, 'userId': self.owner,
                            'cardId': self.card, 'amountKRW': 600000},
        }
        self.statement = {
            'statementId': str(uuid4()), 'userId': self.owner, 'cardId': self.card,
            'sourceVersion': self.version, 'amountKRW': 95000,
            'includedTransactionRefs': [self.purchase],
        }
        self.statement['items'] = legacy_items(self.statement)
        self.item = self.statement['items'][0]
        self.item.update(originalUsedAmountKRW=600000, billedPrincipalKRW=100000,
                         feeOrAdjustmentAmountKRW=-5000, billedAmountKRW=95000,
                         installmentMonths=6, installmentRound=2,
                         label='월별 청구', merchantName='달여울상점 은솔점', purchaseDate='2026-09-12')

    def validate(self, statements=None):
        """2026-10-29: 준비된 사용자 문맥으로 순수 계약 검사만 실행한다. 사용: 각 테스트."""
        validate_statement_items([self.statement] if statements is None else statements,
                                 self.transactions, self.owner, self.version)

    def test_signed_adjustment_and_amount_preserve_source(self):
        """2026-10-29: 10만원 원금·5천원 할인은 원문 그대로 유지된다. 사용: unittest."""
        before = copy.deepcopy(self.statement)
        self.validate()
        self.assertEqual(self.statement, before)
        self.item['billedAmountKRW'] = -5000
        self.validate()
        self.assertEqual(self.item['billedAmountKRW'], -5000)
        self.assertEqual(self.transactions[self.purchase]['amountKRW'], 600000)

    def test_unknown_is_not_zero_or_purchase_amount(self):
        """2026-10-29: 구 참조에서 확인되지 않은 청구 금액·회차를 채우지 않는다. 사용: unittest."""
        items = legacy_items(self.statement)
        for key in ITEM_KEYS - {'itemId', 'userId', 'sourceRef', 'sourceVersion', 'transactionId'}:
            self.assertIsNone(items[0][key])
        self.statement['items'] = items
        self.validate()

    def test_unlinked_fee_and_duplicate_purchase_refs(self):
        """2026-10-29: 연회비와 동일 구매의 여러 항목을 허용하고 참조는 한 번만 제공한다. 사용: unittest."""
        fee = copy.deepcopy(self.item)
        fee.update(itemId=str(uuid4()), sourceRef='prepared/annual-fee', transactionId=None,
                   label='연회비', merchantName=None, purchaseDate=None,
                   originalUsedAmountKRW=None, billedPrincipalKRW=None,
                   feeOrAdjustmentAmountKRW=12000, billedAmountKRW=12000,
                   installmentMonths=None, installmentRound=None)
        discount = copy.deepcopy(self.item)
        discount.update(itemId=str(uuid4()), sourceRef='prepared/discount', billedAmountKRW=-5000)
        self.statement['items'].extend([fee, discount])
        self.validate()
        self.assertEqual(transaction_refs(self.statement['items']), [self.purchase])
        self.assertEqual(self.statement['amountKRW'], 95000)

    def test_one_purchase_in_two_statements(self):
        """2026-10-29: 한 구매의 청구별 금액·회차는 별개 항목이다. 사용: unittest."""
        other = copy.deepcopy(self.statement)
        other.update(statementId=str(uuid4()))
        other['items'] = legacy_items(other)
        other['items'][0].update(billedAmountKRW=100000, billedPrincipalKRW=100000,
                                 installmentMonths=6, installmentRound=3)
        self.validate([self.statement, other])
        self.assertNotEqual(self.item['itemId'], other['items'][0]['itemId'])
        self.assertEqual(self.item['installmentRound'], 2)

    def test_duplicate_item_identity_or_source_rejected(self):
        """2026-10-29: 청구가 달라도 같은 항목 ID·원천 키의 중복을 거절한다. 사용: unittest."""
        for duplicate in ('itemId', 'sourceRef'):
            with self.subTest(duplicate=duplicate):
                other = copy.deepcopy(self.statement)
                other['statementId'] = str(uuid4())
                other['items'] = legacy_items(other)
                other['items'][0][duplicate] = self.item[duplicate]
                with self.assertRaises(ValueError):
                    self.validate([self.statement, other])

    def test_owner_card_and_unavailable_reference_rejected(self):
        """2026-10-29: 타 사용자·카드·미확보 ID를 확보된 청구 관계로 꾸미지 않는다. 사용: unittest."""
        for key in ('userId', 'cardId'):
            with self.subTest(transaction_key=key):
                original = self.transactions[self.purchase][key]
                self.transactions[self.purchase][key] = str(uuid4())
                with self.assertRaises(ValueError):
                    self.validate()
                self.transactions[self.purchase][key] = original
        self.item['transactionId'] = str(uuid4())
        self.statement['includedTransactionRefs'] = [self.item['transactionId']]
        with self.assertRaisesRegex(ValueError, 'unavailable'):
            self.validate()

    def test_foreign_item_or_parent_metadata_rejected(self):
        """2026-10-29: 항목과 부모의 소유자·버전 일치를 요구한다. 사용: unittest."""
        for target in (self.item, self.statement):
            for key, value in (('userId', str(uuid4())), ('sourceVersion', 'foreign')):
                with self.subTest(target='item' if target is self.item else 'statement', key=key):
                    original = target[key]
                    target[key] = value
                    with self.assertRaises(ValueError):
                        self.validate()
                    target[key] = original

    def test_omission_shape_is_explicit_and_does_not_rewrite(self):
        """2026-10-29: 공개 제한을 별도 확인한 호출자만 거래 키 생략 형태를 검사한다. 사용: unittest."""
        visible = copy.deepcopy(self.item)
        del visible['transactionId']
        before = copy.deepcopy(visible)
        with self.assertRaisesRegex(ValueError, 'keys'):
            check_item(visible)
        check_item(visible, transaction_omitted=True)
        self.assertEqual(visible, before)
        with self.assertRaisesRegex(ValueError, 'keys'):
            check_item(self.item, transaction_omitted=True)
        self.assertEqual(self.item['transactionId'], self.purchase)

    def test_refs_are_derived_without_separate_authority(self):
        """2026-10-29: 누락·임의 추가·중복된 별도 참조 배열을 거절한다. 사용: unittest."""
        for refs in ([], [str(uuid4())], [self.purchase, self.purchase]):
            with self.subTest(refs=refs):
                self.statement['includedTransactionRefs'] = refs
                with self.assertRaisesRegex(ValueError, 'references differ'):
                    self.validate()

    def test_money_boundaries_and_invalid_types(self):
        """2026-10-29: 승인한 부호 범위·원금 비음수·정수 제약을 확인한다. 사용: unittest."""
        for key in ('originalUsedAmountKRW', 'billedPrincipalKRW',
                    'feeOrAdjustmentAmountKRW', 'billedAmountKRW'):
            signed = key in ('feeOrAdjustmentAmountKRW', 'billedAmountKRW')
            original = self.item[key]
            for value in (None, 0, 9_000_000_000_000, -9_000_000_000_000 if signed else 1):
                self.item[key] = value
                self.validate()
            for value in (True, '100', 1.5, 9_000_000_000_001,
                          -9_000_000_000_001 if signed else -1):
                with self.subTest(key=key, value=value):
                    self.item[key] = value
                    with self.assertRaisesRegex(ValueError, 'money'):
                        self.validate()
            self.item[key] = original

    def test_missing_and_unknown_item_fields_rejected(self):
        """2026-10-29: 미상 null과 필드 누락을 구분하며 임의 필드는 거절한다. 사용: unittest."""
        for key in tuple(self.item):
            with self.subTest(missing=key):
                value = self.item.pop(key)
                with self.assertRaisesRegex(ValueError, 'keys'):
                    self.validate()
                self.item[key] = value
        self.item['unknown'] = 'hidden value'
        with self.assertRaisesRegex(ValueError, 'keys'):
            self.validate()

    def test_installment_count_and_order(self):
        """2026-10-29: 확인된 회차만 검사하고 모르는 값을 예상하지 않는다. 사용: unittest."""
        for months, round_no in ((None, None), (6, None), (None, 2), (6, 6)):
            self.item.update(installmentMonths=months, installmentRound=round_no)
            self.validate()
        for months, round_no in ((0, 1), (6, 7), (True, 1), (6, '2'), (6, 2_147_483_648)):
            self.item.update(installmentMonths=months, installmentRound=round_no)
            with self.assertRaisesRegex(ValueError, 'installment'):
                self.validate()

    def test_date_identity_and_text_shapes(self):
        """2026-10-29: 날짜·ID·표시값 타입을 검사하고 값 자체를 응답 오류에 노출하지 않는다. 사용: unittest."""
        for key, value in (('purchaseDate', '2026-02-30'), ('purchaseDate', '20261012'),
                           ('itemId', 'hidden-invalid-id'), ('sourceRef', '  '),
                           ('merchantName', 100), ('label', False)):
            with self.subTest(key=key):
                original = self.item[key]
                self.item[key] = value
                with self.assertRaises(ValueError) as failure:
                    self.validate()
                self.assertNotIn('hidden-invalid-id', str(failure.exception))
                self.item[key] = original

    def test_source_inconsistency_is_preserved(self):
        """2026-10-29: 원천 금액의 합계 불일치를 강제로 보정하거나 정상 합계로 꾸미지 않는다. 사용: unittest."""
        self.item.update(originalUsedAmountKRW=650000, billedAmountKRW=97000)
        self.statement['amountKRW'] = 120000
        before = copy.deepcopy((self.statement, self.transactions))
        self.validate()
        self.assertEqual((self.statement, self.transactions), before)

    def test_legacy_id_is_stable_and_ignores_value_changes(self):
        """2026-10-29: 구 PK 관계가 같으면 변경된 표시·금액과 무관하게 ID를 유지한다. 사용: unittest."""
        expected = self.item['itemId']
        self.assertEqual(legacy_item_id(self.owner, self.statement['statementId'], self.purchase), expected)
        self.assertEqual(self.item['sourceRef'], 'legacy-statement-item/' + expected)
        self.assertNotIn(self.purchase, self.item['sourceRef'])
        self.assertNotIn(self.statement['statementId'], self.item['sourceRef'])
        self.statement.update(amountKRW=99999, dueDate='2026-12-25')
        self.assertEqual(legacy_items(self.statement)[0]['itemId'], expected)
        self.assertNotEqual(legacy_item_id(self.owner, str(uuid4()), self.purchase), expected)
        self.assertEqual(transaction_refs([{'transactionId': self.purchase}, {'transactionId': None},
                                           {'transactionId': self.purchase}]), [self.purchase])


if __name__ == '__main__':
    unittest.main()
