"""2026-10-30: 별도 소유 PostgreSQL에서 계좌 상태 제한·이행·잠금·롤백을 검사한다.

사용: --pg-bin <PostgreSQL bin> --work-dir <존재하지 않는 새 검사 폴더>.
기존 DB 주소를 받지 않으며 서비스·개발 DB를 재사용하지 않는다.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import time
import unittest
from uuid import uuid4

from auth_test_support import Cluster, SqlError, quote

DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
sys.path.insert(0, str(API))
sys.path.insert(0, str(API / 'fixtures'))
from export_sql import export as source_sql, load_sources
from reference_data.export_sql import export as institution_sql


class AccountStatusTests(unittest.TestCase):
    """2026-10-30: 제품 테이블의 실제 제약을 준비 자료 관계로 검사한다. 사용: main."""

    cluster = None

    @classmethod
    def setUpClass(cls):
        """2026-10-30: 검증된 원천에서 대상 ID 집합·소유자를 확인한다. 사용: unittest."""
        if cls.cluster is None:
            raise unittest.SkipTest('Use --pg-bin and a new --work-dir')
        cls.fixtures = API / 'fixtures/generated'
        snapshots, _ = load_sources(cls.fixtures, ['alpha-ready'])
        if len(snapshots) != 1:
            raise ValueError('Expected one selected source')
        snapshot = snapshots[0]
        cls.owner = snapshot['userId']
        salary_ids = {transaction_id for receipt in snapshot['settings']['salary']['receiptEvidence']
                      for transaction_id in receipt['transactionIds']}
        cls.bank_ids = {row['transactionId'] for row in snapshot['transactions']
                        if row['recordKind'] == 'account_entry' and row['transactionId'] not in salary_ids}
        cls.card_ids = {row['transactionId'] for row in snapshot['transactions']
                        if row['recordKind'] != 'account_entry'}
        if not cls.bank_ids or not cls.card_ids:
            raise ValueError('Expected bank and card records')
        cls.database = cls.create_database(legacy=False)
        cls.baseline = cls.fingerprint(cls.database)

    @classmethod
    def create_database(cls, *, legacy):
        """2026-10-30: 새 DB에 실제 스키마·원천을 적재하고 필요한 경우 이전 제약 상태를 준비한다. 사용: 검사 준비."""
        database = 'payse_fixture_auth_account_' + uuid4().hex
        cls.cluster.sql('CREATE DATABASE ' + database + ';')
        cls.cluster.load(DIRECTORY / '001_initial.sql', database)
        cls.cluster.load(DIRECTORY / '002_storage_guards.sql', database)
        if legacy:
            cls.cluster.sql('ALTER TABLE payse.financial_transactions DROP CONSTRAINT account_entry_status_valid;', database)
        cls.cluster.sql(institution_sql(), database)
        with cls.cluster.connect(database, name='account_status_preparation') as connection:
            connection.sql("SET statement_timeout = '120s';\n" + source_sql(cls.fixtures, ['alpha-ready']), timeout=130)
        for ids, kind in ((cls.bank_ids, 'account_entry'), (cls.card_ids, 'card')):
            matches = cls.cluster.sql(f"""
            SELECT id::text
            FROM payse.financial_transactions
            WHERE user_id = {quote(cls.owner)}
              AND id IN ({', '.join(quote(value) for value in sorted(ids))})
              AND record_kind {'=' if kind == 'account_entry' else '<>'} 'account_entry';
            """, database)
            if set(matches) != ids or len(matches) != len(ids):
                raise ValueError('Prepared transaction ownership or kind mismatch')
        return database

    @classmethod
    def fingerprint(cls, database):
        """2026-10-30: 모든 공통 행의 ID·금액·날짜·상태를 포함한 비교값을 읽는다. 사용: 보존 검사."""
        tables = cls.cluster.sql("SELECT tablename FROM pg_tables WHERE schemaname = 'payse' ORDER BY tablename;", database)
        values = []
        for table in tables:
            if re.fullmatch('[a-z_]+', table) is None:
                raise ValueError('Unexpected schema identifier')
            values.extend(cls.cluster.sql(f"""
            SELECT {quote(table)} || ':' || count(*)::text || ':' ||
                   md5(coalesce(string_agg(value, E'\\n' ORDER BY value), ''))
            FROM (
              SELECT to_jsonb(record)::text AS value
              FROM payse.{table} record
            ) rows;
            """, database))
        return values

    @classmethod
    def update_sql(cls, ids, status):
        """2026-10-30: 검증된 소유자·ID 집합을 바인딩 가능한 SQL 리터럴로 전달한다. 사용: 상태 검사."""
        return f"""
        UPDATE payse.financial_transactions
        SET status = {quote(status)}
        WHERE user_id = {quote(cls.owner)}
          AND id IN ({', '.join(quote(value) for value in sorted(ids))})
        RETURNING id::text;
        """

    def definitions(self, database):
        """2026-10-30: 명명 제약의 검증 상태·정의를 확인한다. 사용: 신규·이행 동등성 검사."""
        return self.cluster.sql("""
        SELECT convalidated::text || ':' || pg_get_constraintdef(oid)
        FROM pg_constraint
        WHERE conrelid = 'payse.financial_transactions'::regclass
          AND conname = 'account_entry_status_valid';
        """, database)

    def tearDown(self):
        """2026-10-30: 검사별 트랜잭션이 신규 DB의 기존 행을 바꾸지 않았는지 확인한다. 사용: unittest."""
        self.assertEqual(self.fingerprint(self.database), self.baseline)

    def test_supported_states_and_cards(self):
        """2026-10-30: 계좌 두 상태·카드 네 상태를 허용하고 각 변경을 롤백한다. 사용: unittest."""
        for ids, states in ((self.bank_ids, ('posted', 'unknown')),
                            (self.card_ids, ('approved', 'posted', 'cancelled', 'unknown'))):
            for state in states:
                with self.subTest(state=state, bank=ids == self.bank_ids):
                    rows = self.cluster.sql('BEGIN;\n' + self.update_sql(ids, state) + '\nROLLBACK;', self.database)
                    self.assertEqual(set(rows), ids)
                    self.assertEqual(len(rows), len(ids))

    def test_unsupported_account_states(self):
        """2026-10-30: 은행 승인·취소는 DB에서도 거절하고 원천 값을 보존한다. 사용: unittest."""
        for state in ('approved', 'cancelled'):
            with self.subTest(state=state), self.assertRaises(SqlError) as failure:
                self.cluster.sql('BEGIN;\n' + self.update_sql(self.bank_ids, state) + '\nCOMMIT;', self.database)
            self.assertEqual(failure.exception.state, '23514')

    def test_fresh_schema_rejects_migration(self):
        """2026-10-30: 신규 001에 같은 010을 조용히 재적용하지 않는다. 사용: unittest."""
        with self.assertRaises(SqlError) as failure:
            self.cluster.load(DIRECTORY / '010_account_status.sql', self.database)
        self.assertEqual(failure.exception.state, '42710')

    def test_migration_preserves_rows_and_rejects_reapply(self):
        """2026-10-30: 구 DB 이행은 행을 보존하고 신규와 같은 검증 제약을 만든다. 사용: unittest."""
        database = self.create_database(legacy=True)
        before = self.fingerprint(database)
        self.cluster.load(DIRECTORY / '010_account_status.sql', database)
        self.assertEqual(self.definitions(database), self.definitions(self.database))
        self.assertEqual(len(self.definitions(database)), 1)
        self.assertEqual(self.fingerprint(database), before)
        with self.assertRaises(SqlError) as failure:
            self.cluster.load(DIRECTORY / '010_account_status.sql', database)
        self.assertEqual(failure.exception.state, '42710')
        self.assertEqual(self.fingerprint(database), before)

    def test_migration_rejects_existing_unsupported_rows(self):
        """2026-10-30: 기존 은행 미지원 상태가 있으면 변환·삭제 없이 이행 전체를 거절한다. 사용: unittest."""
        for state in ('approved', 'cancelled'):
            with self.subTest(state=state):
                database = self.create_database(legacy=True)
                rows = self.cluster.sql(self.update_sql(self.bank_ids, state), database)
                self.assertEqual(set(rows), self.bank_ids)
                before = self.fingerprint(database)
                with self.assertRaises(SqlError) as failure:
                    self.cluster.load(DIRECTORY / '010_account_status.sql', database)
                self.assertEqual(failure.exception.state, '23514')
                self.assertEqual(self.definitions(database), [])
                self.assertEqual(self.fingerprint(database), before)

    def test_mid_migration_failure_rolls_back(self):
        """2026-10-30: 제약 추가 뒤 SQL 실패해도 반쪽 이행을 남기지 않는다. 사용: unittest."""
        database = self.create_database(legacy=True)
        before = self.fingerprint(database)
        migration = (DIRECTORY / '010_account_status.sql').read_text(encoding='utf-8')
        if migration.count('COMMIT;') != 1:
            raise ValueError('Migration failure injection point changed')
        with self.assertRaises(SqlError) as failure:
            self.cluster.sql(migration.replace('COMMIT;', 'SELECT 1 / 0;\nCOMMIT;'), database)
        self.assertEqual(failure.exception.state, '22012')
        self.assertEqual(self.definitions(database), [])
        self.assertEqual(self.fingerprint(database), before)

    def test_concurrent_write_is_validated(self):
        """2026-10-30: 선행 쓰기 완료를 기다린 뒤 그 미지원 상태까지 검증하여 이행을 거절한다. 사용: unittest."""
        database = self.create_database(legacy=True)
        migration = (DIRECTORY / '010_account_status.sql').read_text(encoding='utf-8')
        name = 'account_status_migration_' + uuid4().hex
        with self.cluster.connect(database) as writer, self.cluster.connect(database, name=name) as migrating:
            rows = writer.sql('BEGIN;\n' + self.update_sql(self.bank_ids, 'approved'))
            self.assertEqual(set(rows), self.bank_ids)
            marker = migrating.submit(migration)
            self.cluster.wait_for_lock(name)
            writer.sql('COMMIT;')
            with self.assertRaises(SqlError) as failure:
                migrating.receive(marker)
            self.assertEqual(failure.exception.state, '23514')
        self.assertEqual(self.definitions(database), [])
        states = self.cluster.sql(f"""
        SELECT DISTINCT status
        FROM payse.financial_transactions
        WHERE user_id = {quote(self.owner)}
          AND id IN ({', '.join(quote(value) for value in sorted(self.bank_ids))});
        """, database)
        self.assertEqual(states, ['approved'])

    def test_cancelled_migration_rolls_back(self):
        """2026-10-30: 커밋 전 취소는 제약과 잠금을 남기지 않고 기존 행을 보존한다. 사용: unittest."""
        database = self.create_database(legacy=True)
        before = self.fingerprint(database)
        migration = (DIRECTORY / '010_account_status.sql').read_text(encoding='utf-8')
        name = 'account_status_cancel_' + uuid4().hex
        with self.cluster.connect(database, name=name) as migrating:
            pid = migrating.sql('SELECT pg_backend_pid();')
            self.assertEqual(len(pid), 1)
            if re.fullmatch('[0-9]+', pid[0]) is None:
                raise ValueError('Unexpected isolated backend PID')
            marker = migrating.submit(migration.replace('COMMIT;', 'SELECT pg_sleep(30);\nCOMMIT;'))
            deadline = time.monotonic() + 5
            while self.cluster.sql(f"""
            SELECT count(*)
            FROM pg_stat_activity
            WHERE pid = {pid[0]}
              AND application_name = {quote(name)}
              AND wait_event = 'PgSleep';
            """) != ['1']:
                if time.monotonic() >= deadline:
                    self.fail('Migration did not reach the pre-commit pause')
                time.sleep(0.025)
            self.assertEqual(self.cluster.sql(f'SELECT pg_cancel_backend({pid[0]});'), ['t'])
            with self.assertRaises(SqlError) as failure:
                migrating.receive(marker)
            self.assertEqual(failure.exception.state, '57014')
        self.assertEqual(self.definitions(database), [])
        self.assertEqual(self.fingerprint(database), before)


def main():
    """2026-10-30: 새 소유 클러스터에서만 실행하고 종료·결과를 기록한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    args = parser.parse_args()
    with Cluster(args.pg_bin, args.work_dir) as cluster:
        AccountStatusTests.cluster = cluster
        result = unittest.TextTestRunner(verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(AccountStatusTests))
        cluster.report.update({'passed': result.wasSuccessful(), 'testsRun': result.testsRun,
                               'failures': len(result.failures), 'errors': len(result.errors),
                               'skipped': len(result.skipped), 'operatingDatabaseModified': False})
    if not result.wasSuccessful():
        raise SystemExit(1)


if __name__ == '__main__':
    main()
