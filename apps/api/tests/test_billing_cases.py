"""2026-10-29: 기존 원천 보존·v4 전환·새 청구 시나리오의 계약을 검사한다."""
import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fixtures'))
from billing_cases import build_billing, upgrade, write_files
from generate import build
from export_sql import financial_rows
from statement_items import transaction_refs
from validate import validate_snapshot, validate_directory
from test_fixtures import temporary_directory


def without_versions(value):
    """2026-10-29: 버전 표식만 제외해 원천 사실을 비교한다. 사용: 보존 검사."""
    if isinstance(value, dict):
        return {key: without_versions(child) for key, child in value.items()
                if key not in ('sourceVersion', 'schemaVersion', 'items')}
    if isinstance(value, list):
        return [without_versions(child) for child in value]
    return value


class BillingCaseTests(unittest.TestCase):
    """2026-10-29: 새 사례와 기존 자료의 기대값을 분리한다. 사용: unittest."""

    @classmethod
    def setUpClass(cls):
        """2026-10-29: 두 버전의 독립 준비 자료를 만든다. 사용: unittest."""
        cls.old, _, _ = build()
        cls.cases, cls.seeds, cls.catalog = build_billing()

    def test_old_sources_preserved(self):
        """2026-10-29: 기존 ID·금액·날짜·승인·계산 입력이 그대로임을 확인한다. 사용: unittest."""
        for name, source in self.old.items():
            with self.subTest(name=name):
                current = self.cases[name]
                self.assertEqual(without_versions(source), without_versions(current))
                self.assertEqual(source.get('recurringDecisions'), current.get('recurringDecisions'))
                self.assertNotEqual(source['sourceVersion'], current['sourceVersion'])
                self.assertEqual(current['schemaVersion'], 'PAYSE-DRAFT-4')

    def test_unknown_fields_stay_null(self):
        """2026-10-29: 구매 금액을 청구 금액으로 복사하거나 분할하지 않는다. 사용: unittest."""
        for statement in self.cases['alpha-ready']['statements']:
            self.assertEqual(statement['includedTransactionRefs'], transaction_refs(statement['items']))
            for item in statement['items']:
                for field in ('originalUsedAmountKRW', 'billedPrincipalKRW', 'feeOrAdjustmentAmountKRW',
                              'billedAmountKRW', 'installmentRound', 'installmentMonths'):
                    self.assertIsNone(item[field])

    def test_examples_preserve_one_purchase(self):
        """2026-10-29: 계정마다 한 구매가 두 청구에 연결되고 항목 회차·금액은 다르다. 사용: unittest."""
        for alias in ('alpha', 'beta', 'gamma'):
            name = alias + '-billing-items'
            snapshot = self.cases[name]
            entry = next(case for case in self.catalog['cases'] if case['id'] == name)
            expected = entry['expected']
            purchase = [t for t in snapshot['transactions'] if t['transactionId'] == expected['purchaseId']]
            self.assertEqual(len(purchase), 1)
            self.assertEqual(purchase[0]['amountKRW'], 600000)
            bills = {s['statementId']: s for s in snapshot['statements']}
            first, second = [bills[key] for key in expected['statementIds']]
            self.assertEqual([first['amountKRW'], second['amountKRW']], [105000, 100000])
            self.assertEqual([first['items'][0]['installmentRound'], second['items'][0]['installmentRound']], [2, 3])
            self.assertEqual(first['includedTransactionRefs'], second['includedTransactionRefs'])
            self.assertEqual(first['items'][0]['feeOrAdjustmentAmountKRW'], -5000)
            self.assertEqual(first['items'][2]['billedAmountKRW'], -10000)
            self.assertIsNone(first['items'][1]['transactionId'])
            self.assertIsNone(first['items'][3]['billedAmountKRW'])
            # 각 청구의 현금 의무는 한 번만 등록한다. 항목별 의무를 만들지 않는다.
            for bill in (first, second):
                obligations = [o for o in snapshot['obligations'] if o['statementId'] == bill['statementId']]
                self.assertEqual(len(obligations), 1)
                self.assertEqual(obligations[0]['amountKRW'], bill['amountKRW'])
            validate_snapshot(snapshot)

    def test_version_boundary(self):
        """2026-10-29: v3에 새 필드를 몰래 넣거나 v4에서 항목을 생략하지 않는다. 사용: unittest."""
        old = copy.deepcopy(self.old['alpha-ready'])
        old['statements'][0]['items'] = []
        with self.assertRaisesRegex(ValueError, 'v4 items in v3'):
            validate_snapshot(old)
        new = copy.deepcopy(self.cases['alpha-ready'])
        del new['statements'][0]['items']
        with self.assertRaisesRegex(ValueError, 'statement items required'):
            validate_snapshot(new)
        new['schemaVersion'] = 'PAYSE-DRAFT-5'
        with self.assertRaisesRegex(ValueError, 'unsupported contract'):
            validate_snapshot(new)

    def test_event_versions_follow_prepared_sources(self):
        """2026-10-29: 원천 전이 포인터가 구 v3 버전으로 남지 않는다. 사용: unittest."""
        for event in self.catalog['events']:
            self.assertEqual(event['sourceVersionBefore'], self.cases[event['beforeCase']]['sourceVersion'])
            self.assertEqual(event['sourceVersionAfter'], self.cases[event['afterCase']]['sourceVersion'])

    def test_sql_preserves_signed_and_null(self):
        """2026-10-29: 일반 저장 컬럼에 음수·null·동일 구매의 복수 항목을 보존한다. 사용: unittest."""
        snapshot = self.cases['alpha-billing-items']
        seed = next(s for s in self.seeds['users'] if s['userId'] == snapshot['userId'])
        rows = [row for table, row in financial_rows(snapshot, seed, True) if table == 'statement_items']
        self.assertIn(-10000, [row['billed_amount_krw'] for row in rows])
        self.assertTrue(any(row['transaction_id'] is None and row['billed_amount_krw'] == 20000 for row in rows))
        self.assertTrue(any(row['billed_amount_krw'] is None for row in rows))
        self.assertEqual(len({row['id'] for row in rows}), len(rows))

    def test_prepared_bundle(self):
        """2026-10-29: 별도 v4 묶음의 manifest·원천·저장된 생성본을 확인한다. 사용: unittest."""
        with temporary_directory() as temp:
            directory = Path(temp) / 'billing'
            write_files(directory)
            self.assertEqual(validate_directory(directory), 24)
            published = Path(__file__).resolve().parents[1] / 'fixtures/generated-v4'
            for source in directory.rglob('*.json'):
                actual = published / source.relative_to(directory)
                self.assertEqual(json.loads(source.read_text(encoding='utf-8')), json.loads(actual.read_text(encoding='utf-8')))


if __name__ == '__main__':
    unittest.main()
