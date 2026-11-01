"""2026-10-26: 새 PostgreSQL 클러스터에서 demo-ready의 저장 관계를 검사한다.

--pg-bin과 아직 없는 --work-dir만 받으며 기존 서버·앱 DB에는 접속하지 않는다.
가용 금액을 계산하지 않고 원천·설정·참조·롤백을 검사한다.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import re
import sys
import time
import unittest
from uuid import uuid4

from auth_test_support import Cluster, SqlError, quote
from run_sql_tests import SUITES
from test_context import build_context, context_sql, latest_income

DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
sys.path.insert(0, str(API))
sys.path.insert(0, str(API / 'fixtures'))
from export_sql import export as initial_sql, load_sources
from reference_data.export_sql import export as institution_sql
from testing.scenarios.export_state import export as scenario_sql
from validate import validate_directory


def one(rows, purpose):
    """2026-10-26: 관계로 찾은 대상이 정확히 하나인지 검사한다. 사용: prepare_roles.

    0개 또는 여러 개이면 준비를 중단하며 첫 번째 행으로 대체하지 않는다.
    """
    found = list(rows)
    if len(found) != 1:
        raise ValueError(purpose + ' must identify exactly one row')
    return found[0]


def prepare_roles(directory):
    """2026-10-26: 검증된 사례에서 검사 대상 ID를 구한다. 사용: setUpClass.

    새 월세 계획은 기존 alpha와의 관계 차이로 찾는다. 표시명·고정 UUID·
    SQL LIMIT로 대상을 고르지 않는다.
    """
    validate_directory(directory)
    catalog = json.loads((directory / 'catalog.json').read_text(encoding='utf-8'))
    paths = {case['id']: case['file'] for case in catalog['cases']}
    cases = {name: json.loads((directory / paths[name]).read_text(encoding='utf-8'))
             for name in ('demo-ready', 'alpha-ready', 'beta-ready')}
    demo, original, other = (cases[name] for name in ('demo-ready', 'alpha-ready', 'beta-ready'))
    if demo['userId'] != original['userId'] or demo['userId'] == other['userId']:
        raise ValueError('Scenario owners differ from the reviewed relationships')
    existing_plans = {row['planId'] for row in original['recurringPlans']}
    plan = one((row for row in demo['recurringPlans'] if row['planId'] not in existing_plans), 'new rent plan')
    rent = one((row for row in demo['obligations'] if row['recurringPlanId'] == plan['planId']), 'rent occurrence')
    revision = one((row for row in demo['recurringPlanRevisions'] if row['revisionId'] == rent['planRevisionId']), 'rent revision')
    decision = one((row for row in demo['recurringDecisions'] if row['planId'] == plan['planId']), 'rent approval')
    telecom = one((row for row in demo['obligations'] if row['recurringPlanId'] in existing_plans), 'existing planned telecom')
    bill = one((row for row in demo['obligations'] if row['statementId'] is not None), 'statement obligation')
    paid = one((row for row in demo['settlements'] if row['obligationId'] == bill['obligationId']
                and row['invalidatedAt'] is None), 'paid card link')
    reserve = one((row for row in demo['reserves'] if row['cancelledAt'] is None), 'unallocated reserve')
    proof = one(demo['settings']['salary']['receiptEvidence'], 'salary proof')
    salary = one((row for row in demo['transactions'] if row['transactionId'] in proof['transactionIds']), 'salary deposit')
    original_ids = {row['transactionId'] for row in original['transactions']}
    if set(decision['evidenceTransactionIds']) & original_ids:
        raise ValueError('New rent approval must not reuse the unrelated old rent history')
    if revision['planId'] != plan['planId'] or len(set(decision['evidenceTransactionIds'])) != 3:
        raise ValueError('Rent plan/revision/evidence relationship is incomplete')
    return {'demo': demo, 'original': original, 'other': other, 'owner': demo['userId'],
            'plan': plan, 'rent': rent, 'revision': revision, 'decision': decision,
            'telecom': telecom, 'bill': bill, 'paid': paid, 'reserve': reserve,
            'proof': proof, 'salary': salary, 'foreign_income': latest_income(other)}


class DemoReadyTests(unittest.TestCase):
    """2026-10-26: 일반 테이블 적재·쓰기 거절·롤백을 검사한다. 사용: main.

    새 Cluster만 사용하며 실제 HTTP와 Flutter의 계산은 검사하지 않는다.
    """

    cluster = None
    database = 'payse_fixture_auth_demo_ready'
    initial_database = 'payse_fixture_auth_demo_initial'
    regression_database = 'payse_fixture_auth_demo_regression'
    demo_database = 'payse_fixture_auth_demo_selected'

    @classmethod
    def setUpClass(cls):
        """2026-10-26: 원천·선택 시나리오를 독립 DB에 준비한다. 사용: unittest.

        2026-10-30: 신규 서버의 initialCase 시연 적재를 별도 DB에서 검사한다.
        """
        if cls.cluster is None:
            raise unittest.SkipTest('Run explicitly with --pg-bin and a new --work-dir')
        cls.fixtures = API / 'fixtures' / 'generated'
        cls.roles = prepare_roles(cls.fixtures)
        initial_sources, seeds = load_sources(cls.fixtures)
        cls.initial_sources = {source['userId']: source for source in initial_sources}
        demo_cases = [seed['initialCase'] for seed in seeds.values()]
        cls.selected_sql = scenario_sql(cls.fixtures, ['demo-ready', 'beta-ready'])
        cls.original_sql = scenario_sql(cls.fixtures, ['alpha-ready', 'beta-ready', 'gamma-month-end'])
        for database, seed in (
            (cls.initial_database, initial_sql(cls.fixtures)),
            (cls.database, cls.selected_sql),
            (cls.regression_database, cls.original_sql),
            (cls.demo_database, scenario_sql(cls.fixtures, demo_cases)),
        ):
            cls.cluster.sql('CREATE DATABASE ' + database + ';')
            cls.cluster.load(DIRECTORY / '001_initial.sql', database)
            cls.cluster.load(DIRECTORY / '002_storage_guards.sql', database)
            cls.cluster.sql(institution_sql(), database)
            cls.load_seed(seed, database)
        cls.baseline = cls.fingerprint(cls.database)
        if len(cls.baseline) != 22:
            raise AssertionError('The scenario must use the existing 22 ordinary tables')

    @classmethod
    def load_seed(cls, seed, database):
        """2026-10-26: 연간 자료 적재의 제한 시간을 분리한다. 사용: setUpClass.

        이 임시 준비 연결만 명령 제한을 120초로 둔다. 거절·롤백 본 검사는
        클러스터의 짧은 기본 제한을 유지하며 준비 시간도 보고한다.
        """
        started = time.monotonic()
        print('Preparing isolated fixture DB: ' + database, flush=True)
        with cls.cluster.connect(database, name='demo_fixture_preparation') as connection:
            connection.sql("SET statement_timeout = '120s';\n" + seed, timeout=130)
        cls.cluster.report.setdefault('seedSeconds', {})[database] = round(time.monotonic() - started, 3)

    @classmethod
    def fingerprint(cls, database):
        """2026-10-26: 전체 테이블 내용 지문을 반환한다. 사용: 변경 전후 보존 검사."""
        tables = cls.cluster.sql("""
        -- 실패한 쓰기의 영향 범위를 추정하지 않고 모든 테이블을 확인한다.
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'payse'
        ORDER BY tablename;
        """, database)
        queries = []
        for table in tables:
            if re.fullmatch(r'[a-z_]+', table) is None:
                raise ValueError('Unexpected table identifier in isolated schema')
            queries.append(f"""
            SELECT {quote(table)} || ':' || count(*)::text || ':' ||
                   md5(coalesce(string_agg(value, E'\\n' ORDER BY value), ''))
            FROM (
              SELECT to_jsonb(record)::text AS value
              FROM payse.{table} record
            ) rows
            """)
        return cls.cluster.sql('\nUNION ALL\n'.join(queries) + ';', database)

    def tearDown(self):
        """2026-10-26: 검사 뒤 저장 내용이 보존됐는지 확인한다. 사용: unittest."""
        self.assertEqual(self.fingerprint(self.database), self.baseline)

    def sql(self, statement, database=None):
        """2026-10-26: 소유한 검사 DB에서 명령을 실행한다. 사용: 각 검사 메서드."""
        return self.cluster.sql(statement, database or self.database)

    def json_row(self, statement, database=None):
        """2026-10-26: 정확히 한 JSON 결과를 반환한다. 사용: 저장 상태 검증."""
        rows = self.sql(statement, database)
        self.assertEqual(len(rows), 1)
        return json.loads(rows[0])

    def rejected(self, statement, state):
        """2026-10-26: SQLSTATE와 전체 롤백을 검사한다. 사용: 잘못된 관계 거절 검사."""
        before = self.fingerprint(self.database)
        with self.assertRaises(SqlError) as error:
            self.sql('BEGIN;\nSET CONSTRAINTS ALL DEFERRED;\n' + statement +
                     '\nSET CONSTRAINTS ALL IMMEDIATE;\nCOMMIT;')
        self.assertEqual(error.exception.state, state)
        self.assertEqual(self.fingerprint(self.database), before)

    def test_initial_export_keeps_settings_empty(self):
        """2026-10-26: 기본 적재에 사용자 계획·설정이 없는지 검사한다. 사용: unittest.

        2026-10-30: 현재 initialCase 원천과 비교하고 별도 demo-ready 회귀와 구분한다.
        """
        owner = quote(self.roles['owner'])
        state = self.json_row(f"""
        -- 기본 적재는 급여 원천 근거를 보존하지만 사용자 설정을 만들지 않는다.
        SELECT jsonb_build_object(
          'userCount', (
            SELECT count(*)
            FROM payse.users
          ),
          'attributes', (
            SELECT to_jsonb(a) - 'user_id'
            FROM payse.user_attributes a
            WHERE user_id = {owner}
          ),
          'proof', (
            SELECT salary_evidence
            FROM payse.source_contexts
            WHERE user_id = {owner}
          ),
          'sourceVersion', (
            SELECT source_version
            FROM payse.source_contexts
            WHERE user_id = {owner}
          ),
          'connections', (
            SELECT count(*)
            FROM payse.institution_links
          ),
          'selectedAccounts', (
            SELECT count(*)
            FROM payse.financial_accounts
            WHERE included
          ),
          'plans', (
            SELECT count(*)
            FROM payse.recurring_plans
          ),
          'obligations', (
            SELECT count(*)
            FROM payse.obligations
          ),
          'reserves', (
            SELECT count(*)
            FROM payse.reserves
          ),
          'settlements', (
            SELECT count(*)
            FROM payse.settlement_links
          )
        );
        """, self.initial_database)
        self.assertEqual(state['userCount'], 3)
        self.assertEqual(state['attributes'], {'salary_day': None, 'salary_amount_krw': None,
                         'salary_account_id': None, 'card_plan_overrides': []})
        initial = self.initial_sources[self.roles['owner']]
        self.assertEqual(state['proof'], initial['settings']['salary']['receiptEvidence'])
        self.assertEqual(state['sourceVersion'], initial['sourceVersion'])
        for key in ('connections', 'selectedAccounts', 'plans', 'obligations', 'reserves', 'settlements'):
            self.assertEqual(state[key], 0, key)

    def test_server_demo_matches_selected_sources(self):
        """2026-10-30: 신규 시연 DB의 계좌·거래·급여 설정·계획을 선택 원본과 대조한다. 사용: unittest."""
        before = self.fingerprint(self.demo_database)
        for user_id, source in self.initial_sources.items():
            owner = quote(user_id)
            actual = self.json_row(f"""
            -- 계산 결과를 생성하지 않고 시연에서 읽을 원천과 확정 설정만 비교한다.
            SELECT jsonb_build_object(
              'salary', (
                SELECT jsonb_build_object('salaryDay', salary_day,
                  'salaryAmountKRW', salary_amount_krw, 'salaryAccountId', salary_account_id)
                FROM payse.user_attributes WHERE user_id = {owner}
              ),
              'accounts', (
                SELECT jsonb_agg(jsonb_build_array(id, balance_krw, included) ORDER BY id)
                FROM payse.financial_accounts WHERE user_id = {owner}
              ),
              'transactions', (
                SELECT jsonb_agg(jsonb_build_array(id, amount_krw, booking_date, withdrawal_date,
                  purchase_date, refund_date, cancellation_date) ORDER BY id)
                FROM payse.financial_transactions WHERE user_id = {owner}
              ),
              'obligations', (
                SELECT coalesce(jsonb_agg(jsonb_build_array(id, amount_krw, due_date) ORDER BY id), '[]'::jsonb)
                FROM payse.obligations WHERE user_id = {owner}
              ),
              'reserves', (
                SELECT coalesce(jsonb_agg(jsonb_build_array(id, amount_krw) ORDER BY id), '[]'::jsonb)
                FROM payse.reserves WHERE user_id = {owner}
              ),
              'links', (SELECT count(*) FROM payse.institution_links WHERE user_id = {owner})
            );
            """, self.demo_database)
            self.assertEqual(actual['salary'], {key: source['settings']['salary'][key]
                for key in ('salaryDay', 'salaryAmountKRW', 'salaryAccountId')})
            self.assertEqual(actual['accounts'], sorted([row['accountId'], row['balanceKRW'], row['included']]
                for row in source['accounts']))
            transactions = source['transactions'] + source['relatedTransactions']
            self.assertEqual(actual['transactions'], sorted([row['transactionId'], row['amountKRW'],
                row['bookingDate'], row['withdrawalDate'], row['purchaseDate'], row['refundDate'],
                row.get('cancellationDate')] for row in transactions))
            self.assertEqual(actual['obligations'], sorted([row['obligationId'], row['amountKRW'], row['dueDate']]
                for row in source['obligations']))
            self.assertEqual(actual['reserves'], sorted([row['reserveId'], row['amountKRW']]
                for row in source['reserves']))
            self.assertEqual(actual['links'], len(source['institutionLinks']))
        self.assertEqual(self.fingerprint(self.demo_database), before)

    def test_selected_scenario_preserves_source_and_relations(self):
        """2026-10-26: 월세·완료 청구·통신비·보호 관계와 잔액을 검사한다. 사용: unittest."""
        roles = self.roles
        owner, rent_id = quote(roles['owner']), quote(roles['rent']['obligationId'])
        evidence = ','.join(quote(value) for value in roles['decision']['evidenceTransactionIds'])
        facts = self.json_row(f"""
        -- 소유한 FK·JSON 관계를 따라가며 표시명이나 임의 첫 행을 사용하지 않는다.
        SELECT jsonb_build_object(
          'rent', (
            SELECT jsonb_build_array(amount_krw, due_date, occurrence_month)
            FROM payse.obligations
            WHERE user_id = {owner}
              AND id = {rent_id}
          ),
          'revision', (
            SELECT jsonb_build_array(amount_krw, monthly_day, effective_from_month)
            FROM payse.recurring_plan_revisions
            WHERE user_id = {owner}
              AND id = {quote(roles['revision']['revisionId'])}
          ),
          'evidence', (
            SELECT jsonb_agg(jsonb_build_array(amount_krw, withdrawal_date) ORDER BY withdrawal_date)
            FROM payse.financial_transactions
            WHERE user_id = {owner}
              AND id IN ({evidence})
          ),
          'decision', (
            SELECT decision
            FROM payse.recurring_decisions
            WHERE user_id = {owner}
              AND id = {quote(roles['decision']['decisionId'])}
          ),
          'cardPaid', (
            SELECT allocated_krw
            FROM payse.settlement_links
            WHERE user_id = {owner}
              AND id = {quote(roles['paid']['linkId'])}
          ),
          'telecom', (
            SELECT jsonb_build_array(amount_krw, due_date)
            FROM payse.obligations
            WHERE user_id = {owner}
              AND id = {quote(roles['telecom']['obligationId'])}
          ),
          'telecomLinks', (
            SELECT count(*)
            FROM payse.settlement_links
            WHERE user_id = {owner}
              AND obligation_id = {quote(roles['telecom']['obligationId'])}
          ),
          'reserve', (
            SELECT amount_krw
            FROM payse.reserves
            WHERE user_id = {owner}
              AND id = {quote(roles['reserve']['reserveId'])}
          ),
          'allocations', (
            SELECT count(*)
            FROM payse.reserve_allocations
            WHERE user_id = {owner}
          ),
          'proof', (
            SELECT salary_evidence
            FROM payse.source_contexts
            WHERE user_id = {owner}
          ),
          'balances', (
            SELECT jsonb_object_agg(id, balance_krw)
            FROM payse.financial_accounts
            WHERE user_id = {owner}
          ),
          'transactionFacts', (
            SELECT jsonb_object_agg(
              id,
              jsonb_build_array(amount_krw, booking_date, withdrawal_date, source_version)
            )
            FROM payse.financial_transactions
            WHERE user_id = {owner}
          ),
          'occurrences', (
            SELECT occurrence_links
            FROM payse.source_contexts
            WHERE user_id = {owner}
          )
        );
        """)
        self.assertEqual(facts['rent'], [300000, '2026-10-22', '2026-10-01'])
        self.assertEqual(facts['revision'], [300000, 22, '2026-10-01'])
        self.assertEqual(facts['evidence'], [[300000, '2026-07-22'], [300000, '2026-08-22'], [300000, '2026-09-22']])
        self.assertEqual(facts['decision'], 'approved')
        self.assertEqual(facts['cardPaid'], 110000)
        self.assertEqual(facts['telecom'], [50000, '2026-10-25'])
        self.assertEqual(facts['telecomLinks'], 0)
        self.assertEqual(facts['reserve'], 400000)
        self.assertEqual(facts['allocations'], 0)
        self.assertEqual(facts['proof'], [roles['proof']])
        self.assertEqual(facts['balances'], {row['accountId']: row['balanceKRW'] for row in roles['original']['accounts']})
        self.assertEqual(facts['transactionFacts'], {
            row['transactionId']: [row['amountKRW'], row['bookingDate'], row['withdrawalDate'], row['sourceVersion']]
            for row in roles['demo']['transactions']
        })
        self.assertEqual(facts['occurrences'], roles['demo']['occurrenceLinks'])

    def test_duplicate_import_is_atomic(self):
        """2026-10-26: 재적재가 부분 쓰기 없이 거절되는지 검사한다. 사용: unittest."""
        before = self.fingerprint(self.database)
        with self.assertRaises(SqlError) as error:
            self.sql(self.selected_sql)
        self.assertEqual(error.exception.state, '23505')
        self.assertEqual(self.fingerprint(self.database), before)

    def test_foreign_withdrawal_account_rejected(self):
        """2026-10-26: 타 사용자 계좌의 월세 출금 연결을 거절한다. 사용: unittest."""
        self.rejected(f"""
        -- 없는 UUID 대신 실제 존재하는 타 사용자 계좌로 소유권 제약을 검사한다.
        UPDATE payse.obligations
        SET withdrawal_account_id = {quote(self.roles['other']['settings']['salary']['salaryAccountId'])}
        WHERE user_id = {quote(self.roles['owner'])}
          AND id = {quote(self.roles['rent']['obligationId'])};
        """, '23503')

    def test_invalid_salary_proof_rejected(self):
        """2026-10-26: 타 사용자 급여 근거와 같은 명목 회차 중복을 거절한다. 사용: unittest."""
        foreign = copy.deepcopy(self.roles['proof'])
        foreign['transactionIds'] = [self.roles['foreign_income']['transactionId']]
        for proof in ([foreign], [self.roles['proof'], self.roles['proof']]):
            with self.subTest(kind='foreign' if len(proof) == 1 else 'duplicate'):
                self.rejected(f"""
                -- 급여 근거의 소유권과 명목 회차 유일성을 검사한다.
                UPDATE payse.source_contexts
                SET salary_evidence = {quote(json.dumps(proof))}::jsonb
                WHERE user_id = {quote(self.roles['owner'])};
                """, '23514')

    def test_duplicate_rent_occurrence_rejected(self):
        """2026-10-26: 새 ID로도 같은 계획·월 회차를 중복할 수 없는지 검사한다. 사용: unittest."""
        new_id = str(uuid4())
        self.rejected(f"""
        -- 관계를 새 ID로 복사해 계획·회차월의 유일성 제약을 확인한다.
        INSERT INTO payse.obligations (
          id, user_id, label, withdrawal_account_id, amount_krw, due_date,
          status, statement_id, plan_id, plan_revision_id, occurrence_month
        )
        SELECT {quote(new_id)}, user_id, label, withdrawal_account_id,
               amount_krw, due_date, status, statement_id, plan_id,
               plan_revision_id, occurrence_month
        FROM payse.obligations
        WHERE user_id = {quote(self.roles['owner'])}
          AND id = {quote(self.roles['rent']['obligationId'])};
        """, '23505')

    def test_explicit_rollback_preserves_every_table(self):
        """2026-10-26: 유효한 한 행 수정도 롤백 뒤 사라지는지 검사한다. 사용: unittest."""
        result = self.sql(f"""
        -- 사용자 표시명 수정의 영향 행이 정확히 하나인지 확인한 뒤 롤백한다.
        BEGIN;
        UPDATE payse.obligations
        SET label = '변경된 예정 지출'
        WHERE user_id = {quote(self.roles['owner'])}
          AND id = {quote(self.roles['rent']['obligationId'])}
        RETURNING id;
        SET CONSTRAINTS ALL IMMEDIATE;
        ROLLBACK;
        """)
        self.assertEqual(result, [self.roles['rent']['obligationId']])

    def test_existing_sql_regressions_preserved(self):
        """2026-10-26: 기존 세 사례로 SQL 회귀 검사 다섯 개를 유지한다. 사용: unittest."""
        before = self.fingerprint(self.regression_database)
        preparation = context_sql(build_context(self.fixtures))
        for name in SUITES:
            with self.subTest(suite=name):
                self.sql(preparation + '\n' + (DIRECTORY / name).read_text(encoding='utf-8'),
                         self.regression_database)
        self.assertEqual(self.fingerprint(self.regression_database), before)


def main():
    """2026-10-26: 새 소유 클러스터에서 검사를 실행한다. 사용: 파일 직접 실행."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    options = parser.parse_args()
    with Cluster(options.pg_bin, options.work_dir) as cluster:
        DemoReadyTests.cluster = cluster
        result = unittest.TextTestRunner(verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(DemoReadyTests))
        cluster.report.update({'passed': result.wasSuccessful(), 'testsRun': result.testsRun,
                               'failures': len(result.failures), 'errors': len(result.errors),
                               'skipped': len(result.skipped), 'existingSqlSuites': list(SUITES),
                               'actualHttpTested': False, 'flutterCalculationTested': False})
    if not result.wasSuccessful():
        raise SystemExit(1)


if __name__ == '__main__':
    main()
