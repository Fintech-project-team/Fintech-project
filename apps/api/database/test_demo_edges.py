"""2026-10-28: 새 소유 PostgreSQL에서 세 계정의 할부·예외 자료를 검사한다.

기존 DB 주소를 받지 않는다. --work-dir은 아직 없는 폴더여야 한다.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import unittest

from auth_test_support import Cluster, SqlError, quote

DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
sys.path.insert(0, str(API))
sys.path.insert(0, str(API / 'fixtures'))
from demo_cases import one
from export_sql import export as initial_sql, load_sources
from reference_data.export_sql import export as institution_sql
from testing.scenarios.export_state import export as scenario_sql

CASES = ('demo-installments', 'beta-cashflow-edge', 'gamma-ai-misread')


class DemoEdgeTests(unittest.TestCase):
    """2026-10-28: 일반 테이블 적재·거절·롤백을 검사한다. 사용: main."""

    cluster = None
    database = 'payse_fixture_auth_edges'
    initial_database = 'payse_fixture_auth_edges_initial'

    @classmethod
    def setUpClass(cls):
        """2026-10-28: 선택 사례와 기본 적재를 별도 새 DB에 준비한다. 사용: unittest."""
        if cls.cluster is None:
            raise unittest.SkipTest('Use --pg-bin and a new --work-dir')
        directory = API / 'fixtures/generated'
        snapshots, _ = load_sources(directory, list(CASES))
        catalog = json.loads((directory / 'catalog.json').read_text(encoding='utf-8'))
        cls.snapshots = {}
        cls.roles = {}
        for name in CASES:
            case = one((row for row in catalog['cases'] if row['id'] == name), name)
            snapshot = json.loads((directory / case['file']).read_text(encoding='utf-8'))
            cls.snapshots[name] = one((row for row in snapshots if row['userId'] == snapshot['userId']), name)
            cls.roles[name] = {}
            for key, identity in case['expected']['preparationTransactionIds'].items():
                row = one((row for row in snapshot['transactions'] if row['transactionId'] == identity), key)
                if row['userId'] != snapshot['userId']:
                    raise ValueError('Foreign test source')
                cls.roles[name][key] = row
        cls.seed = scenario_sql(directory, list(CASES))
        for database, seed in [(cls.database, cls.seed), (cls.initial_database, initial_sql(directory, list(CASES)))]:
            cls.cluster.sql('CREATE DATABASE ' + database + ';')
            cls.cluster.load(DIRECTORY / '001_initial.sql', database)
            cls.cluster.load(DIRECTORY / '002_storage_guards.sql', database)
            cls.cluster.sql(institution_sql(), database)
            with cls.cluster.connect(database, name='demo_edges_preparation') as connection:
                connection.sql("SET statement_timeout = '120s';\n" + seed, timeout=130)
        cls.baseline = cls.fingerprint()
        if len(cls.baseline) != 22:
            raise AssertionError('Expected 22 ordinary tables without an analysis/test-only table')

    @classmethod
    def fingerprint(cls):
        """2026-10-28: 모든 일반 테이블의 내용을 비교한다. 사용: 준비·롤백 검사."""
        tables = cls.cluster.sql("""
        -- 테이블 전체를 검사하여 실패한 쓰기의 잔여 변경을 확인한다.
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'payse'
        ORDER BY tablename;
        """, cls.database)
        queries = []
        for table in tables:
            if re.fullmatch('[a-z_]+', table) is None:
                raise ValueError('Unexpected schema identifier')
            queries.append(f"""
            SELECT {quote(table)} || ':' || count(*)::text || ':' ||
                   md5(coalesce(string_agg(value, E'\\n' ORDER BY value), ''))
            FROM (
              SELECT to_jsonb(record)::text AS value
              FROM payse.{table} record
            ) rows
            """)
        return cls.cluster.sql('\nUNION ALL\n'.join(queries) + ';', cls.database)

    def tearDown(self):
        """2026-10-28: 각 검사 뒤 모든 기존 행이 보존되는지 확인한다. 사용: unittest."""
        self.assertEqual(self.fingerprint(), self.baseline)

    def sql(self, statement, database=None):
        """2026-10-28: 소유 테스트 DB에서만 명령을 실행한다. 사용: 각 검사."""
        return self.cluster.sql(statement, database or self.database)

    def rejected(self, statement, state):
        """2026-10-28: 오류 코드와 저장 영향 없음은 별도로 확인한다. 사용: 제약 검사."""
        with self.assertRaises(SqlError) as failure:
            self.sql(statement)
        self.assertEqual(failure.exception.state, state)
        self.assertEqual(self.fingerprint(), self.baseline)

    def test_installment_rows_and_balances(self):
        """2026-10-28: 세 계정의 할부 원문과 선택 잔액이 정확히 적재된다. 사용: unittest."""
        for name, expected_balance in zip(CASES, (2000000, 2079800, 5000000)):
            snapshot = self.snapshots[name]
            owner = quote(snapshot['userId'])
            self.assertEqual(self.sql(f"""
            -- 계정별 관계를 검증하고 원천 잔액을 확인한다. 가용액 계산이 아니다.
            SELECT sum(balance_krw)::text
            FROM payse.financial_accounts
            WHERE user_id = {owner}
              AND included;
            """), [str(expected_balance)])
            for key, expected in [('appliance', '1/3:180000'), ('computer', '2/6:360000')]:
                transaction = self.roles[name][key]
                self.assertEqual(self.sql(f"""
                -- 준비 단계에서 식별한 거래와 같은 사용자 카드의 참조를 조회한다.
                SELECT t.installment_current || '/' || t.installment_total || ':' || t.amount_krw
                FROM payse.financial_transactions t
                JOIN payse.financial_cards c
                  ON c.user_id = t.user_id
                 AND c.id = t.card_id
                WHERE t.user_id = {owner}
                  AND t.id = {quote(transaction['transactionId'])};
                """), [expected])

    def test_initial_export_has_no_user_plans(self):
        """2026-10-28: 초기 적재는 할부 원천만 추가하고 사용자 설정을 만들지 않는다. 사용: unittest."""
        self.assertEqual(self.sql("""
        -- 기본 적재의 사용자 속성은 미입력 상태이며 임의 계획이 없다.
        SELECT count(*)::text
        FROM payse.user_attributes
        WHERE salary_day IS NULL
          AND salary_amount_krw IS NULL
          AND salary_account_id IS NULL;
        SELECT count(*)::text FROM payse.obligations;
        SELECT count(*)::text FROM payse.reserves;
        SELECT count(*)::text FROM payse.financial_transactions
        WHERE installment_current IS NOT NULL;
        """, self.initial_database), ['3', '0', '0', '6'])

    def test_gamma_remains_unconfirmed_source(self):
        """2026-10-28: 대출 정답이나 모의 오판을 급여 원천에 쓰지 않는다. 사용: unittest."""
        snapshot = self.snapshots['gamma-ai-misread']
        row = self.roles['gamma-ai-misread']['ambiguous-income']
        self.assertEqual(self.sql(f"""
        -- 실제 일반 금융 행과 원천 급여 근거를 독립 확인한다.
        SELECT payse_transaction_type || ':' || amount_krw || ':' || reflection_reason
        FROM payse.financial_transactions
        WHERE user_id = {quote(snapshot['userId'])}
          AND id = {quote(row['transactionId'])};
        SELECT salary_evidence::text
        FROM payse.source_contexts
        WHERE user_id = {quote(snapshot['userId'])};
        """), ['income:3000000:reflected', '[]'])

    def test_invalid_counts_rollback(self):
        """2026-10-28: 회차 역전으로 실패한 거래 수정이 남지 않는다. 사용: unittest."""
        row = self.roles['demo-installments']['appliance']
        self.rejected(f"""
        -- 잘못된 할부 회차는 CHECK 위반으로 전체 명령을 취소한다.
        BEGIN;
        UPDATE payse.financial_transactions
        SET installment_current = 4
        WHERE user_id = {quote(row['userId'])}
          AND id = {quote(row['transactionId'])};
        COMMIT;
        """, '23514')

    def test_foreign_card_is_rejected(self):
        """2026-10-28: 다른 사용자 카드로 거래를 이동할 수 없다. 사용: unittest."""
        row = self.roles['demo-installments']['appliance']
        foreign_card = self.roles['beta-cashflow-edge']['appliance']['cardId']
        self.rejected(f"""
        -- 지연 FK를 즉시 확인하여 소유권 위반과 롤백을 검사한다.
        BEGIN;
        UPDATE payse.financial_transactions
        SET card_id = {quote(foreign_card)}
        WHERE user_id = {quote(row['userId'])}
          AND id = {quote(row['transactionId'])};
        SET CONSTRAINTS ALL IMMEDIATE;
        COMMIT;
        """, '23503')

    def test_duplicate_seed_is_atomic(self):
        """2026-10-28: 기존 사용자에 시나리오를 다시 적재하면 덮어쓰지 않는다. 사용: unittest."""
        self.rejected(self.seed, '23505')

    def test_explicit_rollback(self):
        """2026-10-28: 정상 수정도 명시 취소 시 저장되지 않는다. 사용: unittest."""
        row = self.roles['beta-cashflow-edge']['purchase-a']
        self.assertEqual(self.sql(f"""
        -- 유효한 행을 수정했어도 커밋 전 취소이면 원문을 유지한다.
        BEGIN;
        UPDATE payse.financial_transactions
        SET merchant_name = '변경된 매장'
        WHERE user_id = {quote(row['userId'])}
          AND id = {quote(row['transactionId'])}
        RETURNING id;
        ROLLBACK;
        """), [row['transactionId']])


def main():
    """2026-10-28: 소유 클러스터 생명주기와 검사 결과를 기록한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    args = parser.parse_args()
    with Cluster(args.pg_bin, args.work_dir) as cluster:
        DemoEdgeTests.cluster = cluster
        result = unittest.TextTestRunner(verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(DemoEdgeTests))
        cluster.report.update({'passed': result.wasSuccessful(), 'testsRun': result.testsRun,
                               'failures': len(result.failures), 'errors': len(result.errors),
                               'skipped': len(result.skipped), 'actualHttpTested': False,
                               'analysisStorageTested': False, 'flutterCalculationTested': False})
    if not result.wasSuccessful():
        raise SystemExit(1)


if __name__ == '__main__':
    main()
