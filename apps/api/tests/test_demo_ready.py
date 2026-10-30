"""2026-10-26: 기존 회귀 사례를 보존하며 일상 지출 시연의 자료 관계를 검사한다."""
import copy
import sys
import unittest
from pathlib import Path

API = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API / 'fixtures'))
sys.path.insert(0, str(API))
from generate import build, make_demo_snapshot, make_snapshot, owned_row, uid, update_versions
from validate import validate_snapshot
from export_sql import financial_rows, load_sources
from testing.scenarios.export_state import state_rows


class DemoReadyTests(unittest.TestCase):
    """2026-10-26: 원천 보존·작성 관계·적재 경계를 검사한다. 사용: unittest."""

    @classmethod
    def setUpClass(cls):
        """2026-10-26: 각 검사가 참조할 독립 사례를 준비한다. 사용: unittest 준비 단계."""
        cls.cases, cls.seeds, cls.catalog = build()

    def test_base_and_existing_facts_preserved(self):
        """2026-10-26: 월세 근거 3건 추가 후에도 기존 원천과 입력이 보존되는지 검사한다. 사용: unittest."""
        base = make_snapshot('alpha')
        before = copy.deepcopy(base)
        demo = make_demo_snapshot(base)
        self.assertEqual(base, before)
        published = copy.deepcopy(self.cases['alpha-ready'])
        update_versions(published, base['sourceVersion'], base['dataVersion'])
        self.assertEqual(base, published)
        self.assertNotEqual(demo['sourceVersion'], base['sourceVersion'])
        for collection, key in [('accounts', 'accountId'), ('cards', 'cardId'),
                                ('transactions', 'transactionId'), ('statements', 'statementId')]:
            for row in base[collection]:
                observed = copy.deepcopy(owned_row(demo, collection, key, row[key]))
                observed['sourceVersion'] = row['sourceVersion']
                self.assertEqual(row, observed)
        self.assertEqual(len(demo['transactions']) - len(base['transactions']), 3)
        self.assertEqual(base['settings']['salary']['receiptEvidence'], [])

    def test_rent_uses_new_evidence_and_saved_occurrence(self):
        """2026-10-26: 월세 30만 원의 근거·승인·버전·회차 연결을 검사한다. 사용: unittest."""
        demo = self.cases['demo-ready']
        rent = owned_row(demo, 'obligations', 'obligationId', uid('alpha/obligation/rent'))
        plan = owned_row(demo, 'recurringPlans', 'planId', rent['recurringPlanId'])
        revision = owned_row(demo, 'recurringPlanRevisions', 'revisionId', rent['planRevisionId'])
        decisions = [row for row in demo['recurringDecisions'] if row['planId'] == plan['planId']]
        self.assertEqual(len(decisions), 1)
        decision = decisions[0]
        self.assertEqual(decision['decision'], 'approved')
        # 표시 개정은 원천 버전만 바꾸며 승인 당시 근거 버전은 보존한다.
        self.assertEqual(decision['sourceVersion'] + ':reversals-1:labels-1', demo['sourceVersion'])
        self.assertEqual(plan['firstOccurrenceMonth'], '2026-10')
        self.assertEqual(revision['effectiveFromMonth'], '2026-10')
        self.assertEqual((revision['amountKRW'], revision['monthlyDay']), (300000, 22))
        self.assertEqual((rent['amountKRW'], rent['dueDate']), (300000, '2026-10-22'))
        evidence = [owned_row(demo, 'transactions', 'transactionId', key)
                    for key in decision['evidenceTransactionIds']]
        self.assertEqual(len(evidence), 3)
        self.assertEqual({row['withdrawalDate'] for row in evidence},
                         {'2026-07-22', '2026-08-22', '2026-09-22'})
        self.assertTrue(all(row['amountKRW'] == 300000 and row['accountId'] == rent['withdrawalAccountId']
                            for row in evidence))
        original_ids = {row['transactionId'] for row in self.cases['alpha-ready']['transactions']}
        self.assertTrue(original_ids.isdisjoint(decision['evidenceTransactionIds']))
        links = [row for row in demo['occurrenceLinks'] if row['obligationId'] == rent['obligationId']]
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0]['recurrenceKey'], rent['recurrenceKey'])
        validate_snapshot(demo)

    def test_paid_card_and_registered_telecom_are_distinct(self):
        """2026-10-26: 카드 완납 근거를 유지하고 통신비 지급 연결을 추정하지 않는지 검사한다. 사용: unittest."""
        demo = self.cases['demo-ready']
        bill = owned_row(demo, 'obligations', 'obligationId', uid('alpha/obligation/bill'))
        telecom = owned_row(demo, 'obligations', 'obligationId', uid('alpha/obligation/telecom'))
        links = [row for row in demo['settlements'] if row['obligationId'] == bill['obligationId']]
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0]['allocatedKRW'], 110000)
        self.assertEqual(bill['dueDate'], '2026-10-10')
        self.assertEqual((telecom['amountKRW'], telecom['dueDate']), (50000, '2026-10-25'))
        self.assertFalse(any(row['obligationId'] == telecom['obligationId'] for row in demo['settlements']))
        self.assertEqual(demo['allocations'], [])
        self.assertEqual(sum(row['amountKRW'] for row in demo['reserves']), 400000)
        self.assertFalse(any(row['obligationId'] == uid('alpha/obligation/repair') for row in demo['obligations']))
        repair = owned_row(demo, 'transactions', 'transactionId', uid('alpha/transaction/repair-partial'))
        self.assertEqual((repair['amountKRW'], repair['withdrawalDate']), (40000, '2026-10-16'))

    def test_salary_proof_does_not_add_income_again(self):
        """2026-10-26: 9월 급여 근거 연결이 반영된 입금을 재가산하지 않는지 검사한다. 사용: unittest."""
        demo = self.cases['demo-ready']
        proof, = demo['settings']['salary']['receiptEvidence']
        transaction_id, = proof['transactionIds']
        transaction = owned_row(demo, 'transactions', 'transactionId', transaction_id)
        self.assertEqual((proof['payMonth'], proof['expectedPayDate'], proof['confirmation']),
                         ('2026-09', '2026-09-25', 'confirmed'))
        self.assertEqual(transaction['sourceVersion'], demo['sourceVersion'])
        self.assertEqual((transaction['direction'], transaction['status'], transaction['reflectionReason']),
                         ('in', 'posted', 'reflected'))
        self.assertEqual(sum(row['balanceKRW'] for row in demo['accounts'] if row['included']), 2000000)
        for name in ('alpha-ready', 'beta-ready', 'gamma-month-end'):
            self.assertEqual(self.cases[name]['settings']['salary']['receiptEvidence'], [])

    def test_initial_import_keeps_settings_empty(self):
        """2026-10-26: 알파 기본 원본 변경 후에도 설정 적재는 명시 선택인지 검사한다. 사용: unittest.

        2026-10-30: 앱과 같은 demo-life를 기본으로 하되 일반 초기 적재의 빈 설정 원칙을 유지한다.
        """
        snapshots, seeds = load_sources(API / 'fixtures/generated')
        alpha = [row for row in snapshots if row['userId'] == uid('alpha')]
        self.assertEqual(len(alpha), 1)
        demo = alpha[0]
        self.assertEqual(seeds[demo['userId']]['initialCase'], 'demo-life')
        self.assertEqual(demo, self.cases['demo-life'])
        rows = financial_rows(demo, seeds[demo['userId']])
        attributes, = [row for table, row in rows if table == 'user_attributes']
        self.assertIsNone(attributes['salary_day'])
        self.assertIsNone(attributes['salary_account_id'])
        self.assertFalse(any(table in {'reserves', 'obligations', 'institution_links', 'recurring_plans'}
                             for table, _ in rows))
        self.assertTrue(all(not row['included'] for table, row in rows if table == 'financial_accounts'))
        source, = [row for table, row in rows if table == 'source_contexts']
        self.assertEqual(source['salary_evidence'], demo['settings']['salary']['receiptEvidence'])
        selected = state_rows(demo)
        self.assertEqual(sum(table == 'recurring_plans' for table, _ in selected), 2)
        self.assertEqual(sum(table == 'obligations' for table, _ in selected), 3)
        self.assertFalse(any(table in {'reserve_allocations', 'write_receipts'} for table, _ in selected))

    def test_wrong_preparation_source_is_rejected(self):
        """2026-10-26: 타 사용자·누락·중복·미반영 급여로 사례를 만들지 못하게 검사한다. 사용: unittest."""
        for mode in ('foreign', 'date', 'missing', 'duplicate', 'unreflected'):
            with self.subTest(mode=mode):
                base = make_snapshot('alpha')
                salary = owned_row(base, 'transactions', 'transactionId', uid('alpha/transaction/salary/2026-09'))
                if mode == 'foreign':
                    salary['userId'] = uid('beta')
                elif mode == 'date':
                    base['asOf'] = '2026-10-20T12:00:00+09:00'
                elif mode == 'missing':
                    base['transactions'].remove(salary)
                elif mode == 'duplicate':
                    base['transactions'].append(copy.deepcopy(salary))
                else:
                    salary.update(balanceReflected=False, reflectionReason='not_reflected')
                before = copy.deepcopy(base)
                with self.assertRaises(ValueError):
                    make_demo_snapshot(base)
                self.assertEqual(before, base)


if __name__ == '__main__':
    unittest.main()
