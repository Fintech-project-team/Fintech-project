"""2026-10-28: 할부·생활 예외·AI 오판 자료의 원천/판단 경계를 검사한다."""
import copy
import json
from pathlib import Path
import sys
import unittest

API = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API))
sys.path.insert(0, str(API / 'fixtures'))
from demo_cases import add_transaction, one
from generate import build, make_snapshot, uid
from validate import validate_snapshot
from export_sql import financial_rows, load_sources
from testing.scenarios.prepare_ai_case import prepare

CASES = ('demo-installments', 'beta-cashflow-edge', 'gamma-ai-misread')


class DemoEdgeTests(unittest.TestCase):
    """2026-10-28: 실제 금융 필드와 별도 평가 자료의 관계를 검사한다. 사용: unittest."""

    @classmethod
    def setUpClass(cls):
        """2026-10-28: ID 목록을 생성 자료의 명시 관계에서 읽는다. 사용: unittest."""
        cls.cases, cls.seeds, catalog = build()
        cls.metadata = {row['id']: row['expected'] for row in catalog['cases']}

    def transactions(self, name):
        """2026-10-28: 준비 키별 단일 거래·소유권을 확인한다. 사용: 각 검사."""
        snapshot = self.cases[name]
        rows = {}
        for key, identity in self.metadata[name]['preparationTransactionIds'].items():
            row = one((row for row in snapshot['transactions'] if row['transactionId'] == identity), key)
            self.assertEqual(row['userId'], snapshot['userId'])
            rows[key] = row
        return rows

    def test_installments_are_source_metadata(self):
        """2026-10-28: 2개 할부 원문과 기존 청구·잔액의 분리를 검사한다. 사용: unittest."""
        for name in CASES:
            with self.subTest(case=name):
                snapshot = self.cases[name]
                validate_snapshot(snapshot)
                rows = self.transactions(name)
                for key, counts, amount in [('appliance', (1, 3), 180000), ('computer', (2, 6), 360000)]:
                    row = rows[key]
                    self.assertEqual((row['installmentCurrent'], row['installmentTotal']), counts)
                    self.assertEqual(row['amountKRW'], amount)
                    self.assertEqual(row['recordKind'], 'card_purchase')
                    self.assertIsNone(row['balanceReflected'])
                    card = one((card for card in snapshot['cards'] if card['cardId'] == row['cardId']), key)
                    self.assertEqual(card['cardType'], 'credit')
                    self.assertTrue(all(row['transactionId'] not in bill['includedTransactionRefs']
                                        for bill in snapshot['statements']))
                self.assertEqual(sum(row['installmentCurrent'] is not None
                                     for row in snapshot['transactions']), 2)

    def test_existing_facts_are_preserved(self):
        """2026-10-28: 추가 거래 이외 기존 ID·금액·날짜·설정을 보존한다. 사용: unittest."""
        baselines = {'demo-installments': self.cases['demo-ready'],
                     'beta-cashflow-edge': self.cases['beta-ready'],
                     'gamma-ai-misread': make_snapshot('gamma')}
        for name, original in baselines.items():
            changed = self.cases[name]
            for collection, key in [('transactions', 'transactionId'), ('cards', 'cardId'),
                                    ('statements', 'statementId')]:
                for before in original[collection]:
                    after = copy.deepcopy(one((row for row in changed[collection]
                                               if row[key] == before[key]), key))
                    after['sourceVersion'] = before['sourceVersion']
                    self.assertEqual(after, before)
            self.assertEqual(changed['settings'], original['settings'])
            self.assertEqual(changed['obligations'], original['obligations'])
        self.assertEqual([a['balanceKRW'] for a in self.cases['demo-installments']['accounts']],
                         [a['balanceKRW'] for a in self.cases['demo-ready']['accounts']])

    def test_beta_distinct_purchases_and_balance(self):
        """2026-10-28: 같은 표시의 별도 거래와 원천 순증가 79,800원을 검사한다. 사용: unittest."""
        rows = self.transactions('beta-cashflow-edge')
        first, second = rows['purchase-a'], rows['purchase-b']
        self.assertNotEqual(first['transactionId'], second['transactionId'])
        for field in ('amountKRW', 'bookingDate', 'merchantName', 'accountId'):
            self.assertEqual(first[field], second[field])
        snapshot = self.cases['beta-cashflow-edge']
        account_id = snapshot['settings']['salary']['salaryAccountId']
        before = one((a for a in self.cases['beta-ready']['accounts'] if a['accountId'] == account_id), 'before')
        after = one((a for a in snapshot['accounts'] if a['accountId'] == account_id), 'after')
        self.assertEqual(after['balanceKRW'] - before['balanceKRW'], 79800)
        self.assertEqual(sum(a['balanceKRW'] for a in snapshot['accounts'] if a['included']), 2079800)

    def test_gamma_truth_is_not_model_input_or_source(self):
        """2026-10-28: 정답 유출·가짜 입금 확인·실제 저장 완료 표시를 차단한다. 사용: unittest."""
        payloads = prepare(API / 'fixtures/generated')
        model_input, mock, truth = (payloads[key] for key in ('model-input.json', 'mock-output.json', 'expected.json'))
        self.assertNotIn('loan', json.dumps(model_input))
        self.assertNotIn('gamma-ai-misread', json.dumps(model_input))
        self.assertNotIn('sourceVersion', model_input)
        self.assertEqual(truth['sourceVersion'], self.cases['gamma-ai-misread']['sourceVersion'])
        self.assertNotIn('authorKnownMeaning', json.dumps(self.cases['gamma-ai-misread']))
        self.assertEqual(truth['authorKnownMeaning'], 'loan')
        self.assertFalse(truth['inputSufficientToEstablishMeaning'])
        self.assertFalse(truth['runtimeChecksExecuted'])
        self.assertFalse(mock['storedInDatabase'])
        self.assertEqual(mock['items'][0]['evidenceTransactionIds'], [truth['transactionId']])
        self.assertEqual(truth['sourceSalaryEvidence'], [])
        self.assertEqual(self.transactions('gamma-ai-misread')['ambiguous-income']['payseTransactionType'], 'income')

    def test_invalid_installments_and_owner_are_rejected(self):
        """2026-10-28: 회차 역전·음수·다른 사용자 카드 참조를 거절한다. 사용: unittest."""
        for current, total in [(4, 3), (-1, 3), (1, 0)]:
            invalid = copy.deepcopy(self.cases['demo-installments'])
            identity = self.transactions('demo-installments')['appliance']['transactionId']
            row = one((r for r in invalid['transactions'] if r['transactionId'] == identity), 'installment')
            row['installmentCurrent'], row['installmentTotal'] = current, total
            with self.assertRaises(ValueError):
                validate_snapshot(invalid)
        invalid = copy.deepcopy(self.cases['demo-installments'])
        identity = self.transactions('demo-installments')['appliance']['transactionId']
        row = one((row for row in invalid['transactions'] if row['transactionId'] == identity), 'owned purchase')
        row['cardId'] = self.transactions('beta-cashflow-edge')['computer']['cardId']
        with self.assertRaises(ValueError):
            validate_snapshot(invalid)

    def test_preparation_rejects_duplicate_and_future(self):
        """2026-10-28: 준비 도구도 중복 ID·미래 실제 거래 생성을 거절한다. 사용: unittest."""
        snapshot = copy.deepcopy(self.cases['demo-installments'])
        card_id = self.transactions('demo-installments')['appliance']['cardId']
        for key, day in [('appliance', '2026-10-18'), ('future', '2026-10-20')]:
            with self.assertRaises(ValueError):
                add_transaction(snapshot, 'alpha', uid, key, 100, day, '매장', card_id=card_id)

    def test_selected_initial_export_uses_ordinary_structure(self):
        """2026-10-28: 새 사례도 일반 사용자·속성·거래 구조만 사용한다. 사용: unittest."""
        snapshots, seeds = load_sources(API / 'fixtures/generated', list(CASES))
        for snapshot in snapshots:
            rows = financial_rows(snapshot, seeds[snapshot['userId']])
            self.assertFalse(any('analysis' in table or 'fixture' in table for table, _ in rows))
            attributes = one((row for table, row in rows if table == 'user_attributes'), 'attributes')
            self.assertIsNone(attributes['salary_day'])
            installments = [row for table, row in rows if table == 'financial_transactions'
                            and row['installment_current'] is not None]
            self.assertEqual(len(installments), 2)


if __name__ == '__main__':
    unittest.main()
