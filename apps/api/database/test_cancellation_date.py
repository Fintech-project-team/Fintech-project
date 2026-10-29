"""2026-10-29: 소유한 새 PostgreSQL에서 취소일 제약·기존 DB 이행을 검사한다.

사용: --pg-bin <실행 파일 폴더> --work-dir <존재하지 않는 새 경로>.
기존 DB 주소를 받지 않으며 실제 서비스 DB에 접속하지 않는다.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import unittest
from uuid import uuid4

from auth_test_support import Cluster, SqlError, quote

DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
sys.path.insert(0, str(API))
sys.path.insert(0, str(API / 'fixtures'))
from generate import write_files
from export_sql import export as source_sql, load_sources
from legacy_seed import export as legacy_sql
from reference_data.export_sql import export as institution_sql


class CancellationDateTests(unittest.TestCase):
    """2026-10-29: 실제 자료 관계를 확인하고 날짜 계약과 원자적 이행을 검사한다. 사용: main."""

    cluster = None
    database = 'payse_fixture_auth_cancellation'

    @classmethod
    def setUpClass(cls):
        """2026-10-29: 새 자료·DB를 준비하고 취소/원결제 ID와 소유 관계를 확인한다. 사용: unittest."""
        if cls.cluster is None:
            raise unittest.SkipTest('Use --pg-bin and a new --work-dir')
        cls.fixtures = cls.cluster.work / 'fixtures'
        write_files(cls.fixtures)
        snapshots, _ = load_sources(cls.fixtures, ['alpha-ready'])
        if len(snapshots) != 1:
            raise ValueError('Expected one selected owner')
        snapshot = snapshots[0]
        catalog = json.loads((cls.fixtures / 'catalog.json').read_text(encoding='utf-8'))
        cases = [row for row in catalog['cases'] if row['id'] == 'alpha-ready']
        if len(cases) != 1:
            raise ValueError('Missing or duplicate prepared case')
        targets = [row for row in snapshot['transactions']
                   if row['transactionId'] in cases[0]['preparedReversalIds']
                   and row['recordKind'] == 'card_cancellation']
        if len(targets) != 1:
            raise ValueError('Expected exactly one prepared cancellation')
        cls.row = targets[0]
        originals = [row for row in snapshot['transactions']
                     if row['transactionId'] == cls.row['originalTransactionId']]
        if (len(originals) != 1 or cls.row['userId'] != snapshot['userId']
                or originals[0]['userId'] != snapshot['userId']
                or originals[0]['cardId'] != cls.row['cardId']):
            raise ValueError('Invalid cancellation owner or original relation')
        cls.original = originals[0]
        cls.create_database(cls.database, legacy=False)
        cls.baseline = cls.fingerprint(cls.database)

    @classmethod
    def create_database(cls, database, *, legacy):
        """2026-10-29: 소유 클러스터 안에 최신/이전 스키마와 일반 자료를 적재한다. 사용: 준비·이행 검사."""
        cls.cluster.sql('CREATE DATABASE ' + database + ';')
        schema = DIRECTORY / ('migrations/001_common_storage.v2.sql' if legacy else '001_initial.sql')
        cls.cluster.load(schema, database)
        cls.cluster.load(DIRECTORY / '002_storage_guards.sql', database)
        cls.cluster.sql(institution_sql(), database)
        seed = legacy_sql(cls.fixtures, ['alpha-ready']) if legacy else source_sql(cls.fixtures, ['alpha-ready'])
        with cls.cluster.connect(database, name='cancellation_preparation') as connection:
            connection.sql("SET statement_timeout = '120s';\n" + seed, timeout=130)

    @classmethod
    def fingerprint(cls, database):
        """2026-10-29: 새 취소일 외의 모든 일반 테이블 값을 비교한다. 사용: 보존·롤백 검사."""
        tables = cls.cluster.sql("""
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'payse'
        ORDER BY tablename;
        """, database)
        values = []
        for table in tables:
            if re.fullmatch('[a-z_]+', table) is None:
                raise ValueError('Unexpected schema identifier')
            expression = "to_jsonb(record) - 'cancellation_date'" if table == 'financial_transactions' else 'to_jsonb(record)'
            values.extend(cls.cluster.sql(f"""
            -- 날짜 컬럼 추가가 다른 저장값을 변경하지 않았는지 확인한다.
            SELECT {quote(table)} || ':' || count(*)::text || ':' ||
                   md5(coalesce(string_agg(value, E'\\n' ORDER BY value), ''))
            FROM (
              SELECT ({expression})::text AS value
              FROM payse.{table} record
            ) rows;
            """, database))
        return values

    def tearDown(self):
        """2026-10-29: 최신 스키마 검사가 기존 원천을 바꾸지 않았는지 검사한다. 사용: unittest."""
        self.assertEqual(self.fingerprint(self.database), self.baseline)
        self.assertEqual(self.cluster.sql(f"""
        SELECT cancellation_date::text
        FROM payse.financial_transactions
        WHERE user_id = {quote(self.row['userId'])}
          AND id = {quote(self.row['transactionId'])};
        """, self.database), ['2026-10-13'])

    def update(self, assignment):
        """2026-10-29: 준비한 취소 한 건만 수정해 결과를 읽고 항상 롤백한다. 사용: 날짜 제약 검사."""
        return self.cluster.sql(f"""
        BEGIN;
        UPDATE payse.financial_transactions
        SET {assignment}
        WHERE user_id = {quote(self.row['userId'])}
          AND id = {quote(self.row['transactionId'])}
        RETURNING coalesce(cancellation_date::text, 'unknown');
        ROLLBACK;
        """, self.database)

    def reject_update(self, assignment, state='23514'):
        """2026-10-29: 제약 거절 SQLSTATE와 다음 조회의 보존 결과를 분리해 확인한다. 사용: 오류 검사."""
        with self.assertRaises(SqlError) as failure:
            self.update(assignment)
        self.assertEqual(failure.exception.state, state)

    def test_date_only_and_unknown(self):
        """2026-10-29: 날짜만 제공하거나 과거 자료에 새 날짜가 없는 경우를 허용한다. 사용: unittest."""
        self.assertEqual(self.update('occurred_at = NULL, occurred_at_basis = NULL'), ['2026-10-13'])
        self.assertEqual(self.update('cancellation_date = NULL'), ['unknown'])

    def test_timezone_and_timestamp_agreement(self):
        """2026-10-29: 한국 날짜와 일치하는 UTC 시각만 허용한다. 사용: unittest."""
        self.assertEqual(self.update("occurred_at = '2026-10-12T15:30:00Z'"), ['2026-10-13'])
        self.reject_update("occurred_at = '2026-10-12T14:30:00Z'")
        self.reject_update("occurred_at_basis = 'purchase'")

    def test_invalid_kind_and_date(self):
        """2026-10-29: 취소가 아닌 사건·무한 날짜·존재하지 않는 날짜를 거절한다. 사용: unittest."""
        self.reject_update("record_kind = 'card_refund'")
        self.reject_update("cancellation_date = 'infinity'")
        self.reject_update("cancellation_date = '2026-10-32'", '22008')

    def test_fresh_schema_rejects_migration(self):
        """2026-10-29: 신규 001에 005를 중복 적용하지 않는다. 사용: unittest."""
        with self.assertRaises(SqlError) as failure:
            self.cluster.load(DIRECTORY / '005_cancellation_date.sql', self.database)
        self.assertEqual(failure.exception.state, '42701')

    def test_existing_rows_and_reapply(self):
        """2026-10-29: 구 DB의 모든 행을 유지하고 취소일을 역산하지 않으며 재적용을 거절한다. 사용: unittest."""
        database = 'payse_fixture_auth_date_' + uuid4().hex
        self.create_database(database, legacy=True)
        before = self.fingerprint(database)
        self.cluster.load(DIRECTORY / '005_cancellation_date.sql', database)
        self.assertEqual(self.fingerprint(database), before)
        self.assertEqual(self.cluster.sql("""
        SELECT count(*)
        FROM payse.financial_transactions
        WHERE cancellation_date IS NOT NULL;
        """, database), ['0'])
        with self.assertRaises(SqlError) as failure:
            self.cluster.load(DIRECTORY / '005_cancellation_date.sql', database)
        self.assertEqual(failure.exception.state, '42701')
        self.assertEqual(self.fingerprint(database), before)
        for target in (self.database, database):
            definitions = self.cluster.sql("""
            SELECT pg_get_constraintdef(oid)
            FROM pg_constraint
            WHERE conrelid = 'payse.financial_transactions'::regclass
              AND conname = 'cancellation_date_valid';
            """, target)
            self.assertEqual(len(definitions), 1)
            if target == self.database:
                current = definitions
            else:
                self.assertEqual(definitions, current)

    def test_mid_migration_failure_rolls_back(self):
        """2026-10-29: 컬럼·제약 추가 뒤 실패해도 둘 다 남지 않는다. 사용: unittest."""
        database = 'payse_fixture_auth_date_' + uuid4().hex
        self.create_database(database, legacy=True)
        before = self.fingerprint(database)
        migration = (DIRECTORY / '005_cancellation_date.sql').read_text(encoding='utf-8')
        marker = 'COMMENT ON COLUMN payse.financial_transactions.cancellation_date'
        if migration.count(marker) != 1:
            raise ValueError('Migration failure injection point changed')
        interrupted = migration.replace(marker, 'SELECT 1 / 0;\n\n' + marker)
        with self.assertRaises(SqlError) as failure:
            self.cluster.sql(interrupted, database)
        self.assertEqual(failure.exception.state, '22012')
        self.assertEqual(self.cluster.sql("""
        SELECT count(*)
        FROM information_schema.columns
        WHERE table_schema = 'payse'
          AND table_name = 'financial_transactions'
          AND column_name = 'cancellation_date';
        """, database), ['0'])
        self.assertEqual(self.cluster.sql("""
        SELECT count(*)
        FROM pg_constraint
        WHERE conrelid = 'payse.financial_transactions'::regclass
          AND conname = 'cancellation_date_valid';
        """, database), ['0'])
        self.assertEqual(self.fingerprint(database), before)


def main():
    """2026-10-29: 소유 클러스터를 종료하고 실제 실행 수와 실패 수를 기록한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    args = parser.parse_args()
    with Cluster(args.pg_bin, args.work_dir) as cluster:
        CancellationDateTests.cluster = cluster
        result = unittest.TextTestRunner(verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(CancellationDateTests))
        cluster.report.update({'passed': result.wasSuccessful(), 'testsRun': result.testsRun,
                               'failures': len(result.failures), 'errors': len(result.errors),
                               'skipped': len(result.skipped), 'operatingDatabaseModified': False})
    if not result.wasSuccessful():
        raise SystemExit(1)


if __name__ == '__main__':
    main()
