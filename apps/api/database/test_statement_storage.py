"""2026-10-29: 새 소유 PostgreSQL에서 청구 항목·기존 관계 전환·권한을 검사한다.

사용: --pg-bin <PostgreSQL bin> --work-dir <존재하지 않는 새 경로>.
기존 DB 주소를 받지 않으며 실제 서비스 DB에 접속하지 않는다.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import unittest
from uuid import UUID, uuid4

from auth_test_support import Cluster, SqlError, quote

DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
sys.path.insert(0, str(API))
sys.path.insert(0, str(API / 'fixtures'))
from generate import write_files
from export_sql import export as source_sql, load_sources
from legacy_seed import export as legacy_sql
from reference_data.export_sql import export as institution_sql


class StatementItemTests(unittest.TestCase):
    """2026-10-29: 식별·관계·원금/조정액·회차·이행의 원자성을 검사한다. 사용: main."""

    cluster = None
    database = 'payse_fixture_auth_statement_items'
    cases = ('alpha-ready', 'beta-ready')

    @classmethod
    def setUpClass(cls):
        """2026-10-29: 확인된 시나리오 ID·소유·청구·거래 관계로 새 DB를 준비한다. 사용: unittest."""
        if cls.cluster is None:
            raise unittest.SkipTest('Use --pg-bin and a new --work-dir')
        cls.fixtures = cls.cluster.work / 'fixtures'
        write_files(cls.fixtures)
        snapshots, _ = load_sources(cls.fixtures, list(cls.cases))
        cls.prepared = {}
        for alias in ('alpha', 'beta'):
            matched = [snapshot for snapshot in snapshots if any(
                statement['sourceRef'] == f'fixture/{alias}/statement/paid'
                for statement in snapshot['statements'])]
            if len(matched) != 1:
                raise ValueError('Missing or duplicate selected owner')
            snapshot = matched[0]
            statements = [row for row in snapshot['statements']
                          if row['sourceRef'] == f'fixture/{alias}/statement/paid']
            purchases = [row for row in snapshot['transactions']
                         if row['sourceRef'] == f'fixture/{alias}/transaction/bill-purchase']
            if len(statements) != 1 or len(purchases) != 1:
                raise ValueError('Missing or duplicate statement preparation')
            statement, purchase = statements[0], purchases[0]
            if (statement['userId'] != snapshot['userId'] or purchase['userId'] != snapshot['userId']
                    or purchase['cardId'] != statement['cardId']
                    or purchase['transactionId'] not in statement['includedTransactionRefs']):
                raise ValueError('Prepared statement has a foreign or absent purchase')
            key = ':'.join((snapshot['userId'], statement['statementId'], purchase['transactionId']))
            identity = str(UUID(hashlib.md5(('payse:statement-item:' + key).encode('utf-8')).hexdigest()))
            cls.prepared[alias] = {'owner': snapshot['userId'], 'statement': statement,
                                   'purchase': purchase, 'id': identity}
        cls.create_database(cls.database, legacy=False)
        # NOLOGIN 읽기 역할로 RLS를 검사하며 운영 역할이나 운영 연결은 사용하지 않는다.
        cls.cluster.sql('CREATE ROLE payse_item_reader NOLOGIN;', cls.database)
        cls.cluster.sql('GRANT USAGE ON SCHEMA payse TO payse_item_reader;\n'
                        'GRANT SELECT ON payse.statement_items TO payse_item_reader;', cls.database)
        cls.baseline = cls.fingerprint(cls.database)

    @classmethod
    def create_database(cls, database, *, legacy):
        """2026-10-29: 최신 또는 005까지의 이전 공통 DB를 명시적으로 준비한다. 사용: 준비·이행 검사."""
        cls.cluster.sql('CREATE DATABASE ' + database + ';')
        schema = DIRECTORY / ('migrations/001_common_storage.v2.sql' if legacy else '001_initial.sql')
        cls.cluster.load(schema, database)
        cls.cluster.load(DIRECTORY / '002_storage_guards.sql', database)
        if legacy:
            cls.cluster.load(DIRECTORY / '005_cancellation_date.sql', database)
        cls.cluster.sql(institution_sql(), database)
        seed = legacy_sql(cls.fixtures, list(cls.cases)) if legacy else source_sql(cls.fixtures, list(cls.cases))
        with cls.cluster.connect(database, name='statement_item_preparation') as connection:
            connection.sql("SET statement_timeout = '120s';\n" + seed, timeout=130)

    @classmethod
    def fingerprint(cls, database, *, old_shape=False):
        """2026-10-29: 테이블 전체 값 또는 구 관계 4컬럼을 보존 비교한다. 사용: 준비·롤백·이행 검사."""
        tables = cls.cluster.sql("""
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'payse'
        ORDER BY tablename;
        """, database)
        queries = []
        for table in tables:
            if re.fullmatch('[a-z_]+', table) is None:
                raise ValueError('Unexpected schema identifier')
            expression = 'to_jsonb(record)'
            if old_shape and table == 'statement_items':
                expression = "jsonb_build_array(user_id, statement_id, card_id, transaction_id)"
            queries.append(f"""
            SELECT {quote(table)} || ':' || count(*)::text || ':' ||
                   md5(coalesce(string_agg(value, E'\\n' ORDER BY value), ''))
            FROM (
              SELECT ({expression})::text AS value
              FROM payse.{table} record
            ) rows
            """)
        return cls.cluster.sql("\nUNION ALL\n".join(queries) + "\nORDER BY 1;", database)

    def tearDown(self):
        """2026-10-29: 성공/거절 검사 뒤 원래 테이블 값이 유지되는지 확인한다. 사용: unittest."""
        self.assertEqual(self.fingerprint(self.database), self.baseline)

    def insert(self, *, reference=True, changes=None):
        """2026-10-29: 준비한 청구에 독립 항목 하나를 넣을 SQL을 만든다. 사용: 허용·거절 검사."""
        prepared = self.prepared['alpha']
        identity = str(uuid4())
        row = {
            'id': identity, 'user_id': prepared['owner'], 'source_ref': 'test-item/' + identity,
            'source_version': prepared['statement']['sourceVersion'],
            'statement_id': prepared['statement']['statementId'],
            'card_id': prepared['statement']['cardId'],
            'transaction_id': prepared['purchase']['transactionId'] if reference else None,
            'billed_principal_krw': None, 'fee_or_adjustment_amount_krw': None,
            'billed_amount_krw': None, 'installment_months': None, 'installment_round': None,
        }
        row.update(changes or {})
        columns = ',\n'.join('  ' + name for name in row)
        values = ',\n'.join('  ' + quote(value) for value in row.values())
        return f'INSERT INTO payse.statement_items (\n{columns}\n) VALUES (\n{values}\n)'

    def run_rollback(self, statement):
        """2026-10-29: 제약을 즉시 검증한 후 명시적으로 전체 변경을 취소한다. 사용: 정상 사례 검사."""
        return self.cluster.sql('BEGIN;\n' + statement + '\nSET CONSTRAINTS ALL IMMEDIATE;\nROLLBACK;', self.database)

    def reject(self, statement, state='23514'):
        """2026-10-29: 예상 SQLSTATE와 이후 원천 보존을 검사한다. 사용: 제약 오류 검사."""
        with self.assertRaises(SqlError) as failure:
            self.run_rollback(statement)
        self.assertEqual(failure.exception.state, state)

    def test_independent_fee_discount_and_same_purchase(self):
        """2026-10-29: 독립 연회비·감산과 같은 구매의 여러 항목을 허용한다. 사용: unittest."""
        fee = self.insert(reference=False, changes={'label': '연회비', 'billed_amount_krw': 10000})
        discount = self.insert(changes={'fee_or_adjustment_amount_krw': -5000, 'billed_amount_krw': -5000})
        principal = self.insert(changes={'billed_principal_krw': 100000, 'billed_amount_krw': 100000,
                                         'installment_months': 6, 'installment_round': 2})
        result = self.run_rollback(fee + ' RETURNING transaction_id IS NULL;\n' +
                                   discount + ' RETURNING billed_amount_krw;\n' +
                                   principal + ' RETURNING installment_round;')
        self.assertEqual(result, ['t', '-5000', '2'])

    def test_signed_bounds_unknown_and_source_mismatch(self):
        """2026-10-29: 부호 상한·미상·원천 불일치를 보존하고 자동 보정하지 않는다. 사용: unittest."""
        for amount in (-9000000000000, 0, 9000000000000):
            self.assertEqual(self.run_rollback(self.insert(changes={'billed_amount_krw': amount}) +
                                              ' RETURNING billed_amount_krw;'), [str(amount)])
        self.assertEqual(self.run_rollback(self.insert(changes={'billed_principal_krw': 100,
                                            'fee_or_adjustment_amount_krw': -10, 'billed_amount_krw': 91}) +
                                            ' RETURNING billed_amount_krw;'), ['91'])
        self.assertEqual(self.run_rollback(self.insert() + ' RETURNING billed_amount_krw IS NULL;'), ['t'])
        self.reject(self.insert(changes={'billed_amount_krw': 9000000000001}) + ';')
        self.reject(self.insert(changes={'fee_or_adjustment_amount_krw': -9000000000001}) + ';')
        self.reject(self.insert(changes={'billed_principal_krw': -1}) + ';')
        self.reject(self.insert(changes={'original_used_amount_krw': -1}) + ';')

    def test_round_and_date_constraints(self):
        """2026-10-29: 실제 날짜·양수 회차·총회차 순서만 검증한다. 사용: unittest."""
        for values in ({'installment_round': 0}, {'installment_months': -1},
                       {'installment_months': 6, 'installment_round': 7},
                       {'purchase_date': 'infinity'}, {'source_ref': '  '}):
            self.reject(self.insert(changes=values) + ';')
        self.assertEqual(self.run_rollback(self.insert(changes={'installment_round': 2}) +
                                          ' RETURNING installment_months IS NULL;'), ['t'])

    def test_foreign_owner_card_and_source_are_rejected(self):
        """2026-10-29: 타 사용자·카드·원천 버전 연결을 FK로 차단한다. 사용: unittest."""
        foreign = self.prepared['beta']
        for values in ({'user_id': foreign['owner']},
                       {'transaction_id': foreign['purchase']['transactionId']},
                       {'statement_id': foreign['statement']['statementId']},
                       {'card_id': foreign['statement']['cardId']},
                       {'source_version': 'missing-source-version'}):
            self.reject(self.insert(changes=values) + ';', '23503')
        self.reject(self.insert(changes={'id': self.prepared['alpha']['id']}) + ';', '23505')
        existing_ref = 'legacy-statement-item/' + self.prepared['alpha']['id']
        self.reject(self.insert(changes={'source_ref': existing_ref}) + ';', '23505')

    def test_rls_visibility_and_write_denial(self):
        """2026-10-29: 조회 역할은 자기 항목만 읽고 직접 저장하지 못한다. 사용: unittest."""
        owner = self.prepared['alpha']['owner']
        foreign = self.prepared['beta']['owner']
        result = self.cluster.sql(f"""
        BEGIN;
        SET LOCAL ROLE payse_item_reader;
        SELECT set_config('payse.user_id', {quote(owner)}, true);
        SELECT count(*) > 0
        FROM payse.statement_items
        WHERE user_id = {quote(owner)};
        SELECT count(*)
        FROM payse.statement_items
        WHERE user_id = {quote(foreign)};
        ROLLBACK;
        """, self.database)
        self.assertEqual(result, [owner, 't', '0'])
        self.reject('SET LOCAL ROLE payse_item_reader;\n' + self.insert() + ';', '42501')

    def test_migration_preserves_rows_and_null_facts(self):
        """2026-10-29: 구 관계를 안정 ID로 옮기고 기존 금융·설정·날짜·미상을 유지한다. 사용: unittest."""
        database = 'payse_fixture_auth_items_' + uuid4().hex
        self.create_database(database, legacy=True)
        before = self.fingerprint(database, old_shape=True)
        self.cluster.load(DIRECTORY / '006_statement_items.sql', database)
        self.assertEqual(self.fingerprint(database, old_shape=True), before)
        self.assertEqual(self.cluster.sql("""
        SELECT count(*)
        FROM payse.statement_items
        WHERE label IS NOT NULL
          OR merchant_name IS NOT NULL
          OR purchase_date IS NOT NULL
          OR original_used_amount_krw IS NOT NULL
          OR billed_principal_krw IS NOT NULL
          OR fee_or_adjustment_amount_krw IS NOT NULL
          OR billed_amount_krw IS NOT NULL
          OR installment_months IS NOT NULL
          OR installment_round IS NOT NULL;
        """, database), ['0'])
        for prepared in self.prepared.values():
            identities = self.cluster.sql(f"""
            SELECT id::text
            FROM payse.statement_items
            WHERE user_id = {quote(prepared['owner'])}
              AND statement_id = {quote(prepared['statement']['statementId'])}
              AND transaction_id = {quote(prepared['purchase']['transactionId'])};
            """, database)
            self.assertEqual(identities, [prepared['id']])
        definitions = []
        for target in (self.database, database):
            definitions.append(self.cluster.sql("""
            SELECT contype::text || ':' || pg_get_constraintdef(oid)
            FROM pg_constraint
            WHERE conrelid = 'payse.statement_items'::regclass
            ORDER BY contype, pg_get_constraintdef(oid);
            """, target))
        self.assertEqual(definitions[0], definitions[1])
        with self.assertRaises(SqlError) as failure:
            self.cluster.load(DIRECTORY / '006_statement_items.sql', database)
        self.assertEqual(failure.exception.state, '42701')
        self.assertEqual(self.fingerprint(database, old_shape=True), before)

    def test_fresh_schema_rejects_reapply(self):
        """2026-10-29: 신규 001에는 006을 중복 적용하지 않는다. 사용: unittest."""
        with self.assertRaises(SqlError) as failure:
            self.cluster.load(DIRECTORY / '006_statement_items.sql', self.database)
        self.assertEqual(failure.exception.state, '42701')

    def test_migration_failure_is_atomic(self):
        """2026-10-29: 식별 전환·키 변경 뒤 오류가 나도 구 스키마와 전체 행을 보존한다. 사용: unittest."""
        database = 'payse_fixture_auth_items_' + uuid4().hex
        self.create_database(database, legacy=True)
        before = self.fingerprint(database)
        migration = (DIRECTORY / '006_statement_items.sql').read_text(encoding='utf-8')
        marker = 'COMMENT ON COLUMN payse.statement_items.id'
        if migration.count(marker) != 1:
            raise ValueError('Migration interruption marker changed')
        with self.assertRaises(SqlError) as failure:
            self.cluster.sql(migration.replace(marker, 'SELECT 1 / 0;\n\n' + marker), database)
        self.assertEqual(failure.exception.state, '22012')
        self.assertEqual(self.fingerprint(database), before)
        self.assertEqual(self.cluster.sql("""
        SELECT count(*)
        FROM information_schema.columns
        WHERE table_schema = 'payse'
          AND table_name = 'statement_items';
        """, database), ['4'])


def main():
    """2026-10-29: 소유 클러스터 수명과 실제 검사 결과를 기록한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    arguments = parser.parse_args()
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        StatementItemTests.cluster = cluster
        result = unittest.TextTestRunner(verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(StatementItemTests))
        cluster.report.update({'passed': result.wasSuccessful(), 'testsRun': result.testsRun,
                               'failures': len(result.failures), 'errors': len(result.errors),
                               'skipped': len(result.skipped), 'operatingDatabaseModified': False})
    if not result.wasSuccessful():
        raise SystemExit(1)


if __name__ == '__main__':
    main()
