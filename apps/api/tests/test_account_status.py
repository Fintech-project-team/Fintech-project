"""2026-10-30: 계좌 상태 제한과 기존 카드·잔액 반영 계약을 검사한다. 사용: unittest discover."""
import copy
import json
from pathlib import Path
import sys
import unittest

API = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API / 'fixtures'))
from validate import validate_snapshot


class AccountStatusTests(unittest.TestCase):
    """2026-10-30: 원천을 복사해 상태만 바꾸고 원본 파일은 보존한다. 사용: unittest."""

    @classmethod
    def setUpClass(cls):
        """2026-10-30: 기존 정상 자료에서 급여·정산 근거 밖의 은행 거래 집합을 확인한다. 사용: unittest."""
        cls.source = json.loads((API / 'fixtures/generated/snapshots/alpha-ready.json').read_text(encoding='utf-8'))
        protected = {row['transactionId'] for row in cls.source['settlements']}
        protected.update(transaction_id for receipt in cls.source['settings']['salary']['receiptEvidence']
                         for transaction_id in receipt['transactionIds'])
        cls.bank_ids = {row['transactionId'] for row in cls.source['transactions']
                        if row['recordKind'] == 'account_entry' and row['transactionId'] not in protected}
        if not cls.bank_ids:
            raise ValueError('Expected independent account entries')
        validate_snapshot(cls.source)

    def bank_copy(self, status):
        """2026-10-30: 준비한 ID 집합의 상태만 바꾸며 선택 건수를 대조한다. 사용: 계좌 상태 검사."""
        snapshot = copy.deepcopy(self.source)
        rows = [row for row in snapshot['transactions'] if row['transactionId'] in self.bank_ids]
        self.assertEqual(len(rows), len(self.bank_ids))
        for row in rows:
            row['status'] = status
        return snapshot

    def test_supported_account_states(self):
        """2026-10-30: 확정·미확인 은행 상태는 반영 상태를 재작성하지 않고 허용한다. 사용: unittest."""
        for status in ('posted', 'unknown'):
            with self.subTest(status=status):
                snapshot = self.bank_copy(status)
                before = copy.deepcopy(snapshot)
                validate_snapshot(snapshot)
                self.assertEqual(snapshot, before)

    def test_unsupported_account_states(self):
        """2026-10-30: 은행 승인·취소 상태를 다른 상태로 바꾸지 않고 거절한다. 사용: unittest."""
        for status in ('approved', 'cancelled'):
            with self.subTest(status=status):
                snapshot = self.bank_copy(status)
                before = copy.deepcopy(snapshot)
                with self.assertRaisesRegex(ValueError, 'unsupported account status'):
                    validate_snapshot(snapshot)
                self.assertEqual(snapshot, before)

    def test_related_account_entries_are_checked(self):
        """2026-10-30: relatedTransactions로 옮겨도 같은 은행 상태 제한을 적용한다. 사용: unittest."""
        snapshot = self.bank_copy('approved')
        selected = [row for row in snapshot['transactions'] if row['transactionId'] in self.bank_ids]
        snapshot['transactions'] = [row for row in snapshot['transactions'] if row['transactionId'] not in self.bank_ids]
        snapshot['relatedTransactions'].extend(selected)
        with self.assertRaisesRegex(ValueError, 'unsupported account status'):
            validate_snapshot(snapshot)

    def test_card_statuses_are_unchanged(self):
        """2026-10-30: 카드 사건의 기존 네 상태는 계좌 제한으로 축소하지 않는다. 사용: unittest."""
        for status in ('approved', 'posted', 'cancelled', 'unknown'):
            with self.subTest(status=status):
                snapshot = copy.deepcopy(self.source)
                cards = [row for row in snapshot['transactions'] if row['recordKind'] != 'account_entry']
                self.assertTrue(cards)
                for row in cards:
                    row['status'] = status
                validate_snapshot(snapshot)

    def test_reflection_is_not_inferred_from_status(self):
        """2026-10-30: 지원 은행 상태와 잔액 반영 상태의 기존 독립 규칙을 유지한다. 사용: unittest."""
        for status in ('posted', 'unknown'):
            for reason, value in (('reflected', True), ('not_reflected', False),
                                  ('not_applicable', None), ('unknown', None)):
                with self.subTest(status=status, reason=reason):
                    snapshot = self.bank_copy(status)
                    for row in snapshot['transactions']:
                        if row['transactionId'] in self.bank_ids:
                            row['reflectionReason'] = reason
                            row['balanceReflected'] = value
                    before = copy.deepcopy(snapshot)
                    validate_snapshot(snapshot)
                    self.assertEqual(snapshot, before)


if __name__ == '__main__':
    unittest.main()
