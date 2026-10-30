"""2026-10-30: 새 PostgreSQL에서 회차별 급여 안내 저장·격리·경합·롤백을 검사한다.

기존 DB 주소를 받지 않는다. --sql-only는 DB 검사만 실행하며 HTTP 검증을 뜻하지 않는다.
전체 실행은 기존 인증·금융 회귀와 SalaryNoticeHttpTest를 함께 요구한다.
"""
from pathlib import Path
import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
import time
import unittest
import uuid

from auth_test_support import Cluster, PROCESS_FLAGS, SqlError, quote
from test_financial_service import prepare_database as prepare_financial
from test_session_service import fingerprint as session_fingerprint
from test_auth_jdbc import java_results, fingerprint as jdbc_fingerprint


DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
DATABASE = 'payse_auth_test_salary'
MIGRATIONS = ('001_initial.sql', '002_storage_guards.sql', '003_auth_access.sql',
              '004_auth_sessions.sql', '007_financial_access.sql')


def prepare_database(cluster):
    """2026-10-30: 회귀 DB와 별개 안내 DB·기존 합성 원천·검사 전용 자격을 만든다. 사용: main."""
    environment = prepare_financial(cluster)
    cluster.sql('CREATE DATABASE ' + DATABASE + ';')
    for filename in (*MIGRATIONS, '009_salary_notices.sql'):
        cluster.load(DIRECTORY / filename, DATABASE)
    sys.path.insert(0, str(API))
    from reference_data.export_sql import export as institution_sql
    from testing.scenarios.export_state import export as scenario_sql
    cluster.sql(institution_sql(), DATABASE)
    seed = cluster.work / 'salary-seed.sql'
    seed.write_text(scenario_sql(API / 'fixtures/generated',
        ['alpha-ready', 'beta-ready', 'gamma-month-end']), encoding='utf-8')
    cluster.load(seed, DATABASE)
    suffix = uuid.uuid4().hex
    login = 'payse_salary_' + suffix
    admin = 'payse_salary_setup_' + suffix
    password = secrets.token_urlsafe(48)
    admin_password = secrets.token_urlsafe(48)
    cluster.sql(f'''
    CREATE ROLE {login}
      LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE
      PASSWORD {quote(password)};

    GRANT payse_runtime TO {login};

    GRANT CONNECT ON DATABASE {DATABASE} TO {login};

    CREATE ROLE {admin}
      LOGIN NOINHERIT SUPERUSER PASSWORD {quote(admin_password)};
    ''', DATABASE)
    if cluster.sql('''
        SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolinherit
        FROM pg_roles
        WHERE rolname = ''' + quote(login) + ';', DATABASE) != ['t']:
        raise AssertionError('Salary notice runtime exceeded its role boundary')
    environment.update({
        'PAYSE_SALARY_TEST_JDBC_URL': 'jdbc:postgresql://127.0.0.1:' + cluster.env['PGPORT'] + '/' + DATABASE,
        'PAYSE_SALARY_TEST_DB_USER': login,
        'PAYSE_SALARY_TEST_DB_PASSWORD': password,
        'PAYSE_SALARY_TEST_ADMIN_USER': admin,
        'PAYSE_SALARY_TEST_ADMIN_PASSWORD': admin_password,
        'PAYSE_SALARY_TEST_SEED_FILE': str(seed),
    })
    return environment


def fingerprint(cluster):
    """2026-10-30: 안내 저장 전후 모든 사용자·금융 원천·설정·버전·영수증을 대조한다. 사용: main."""
    tables = cluster.sql('''
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'payse'
      AND tablename NOT IN ('salary_notice_dismissals', 'demo_sessions', 'auth_rate_limits')
    ORDER BY tablename;
    ''', DATABASE)
    result = {}
    for table in tables:
        if not table.isascii() or not table.replace('_', '').isalnum():
            raise RuntimeError('Unexpected salary notice test table identifier')
        result[table] = cluster.sql('''
        SELECT count(*)::text || ':' || md5(coalesce(string_agg(value, E'\\n' ORDER BY value), ''))
        FROM (
          SELECT to_jsonb(record)::text AS value
          FROM payse.''' + table + ' record\n) rows;', DATABASE)[0]
    return result


class SalaryNoticeStorageTests(unittest.TestCase):
    """2026-10-30: 실제 PG의 최소 권한·회차 독립성·트랜잭션을 검사한다. 사용: main."""
    cluster = None

    @classmethod
    def setUpClass(cls):
        """2026-10-30: fixture에서 사용자 ID와 모든 계좌 관계를 검증해 준비한다. 사용: unittest."""
        cls.owners = []
        for scenario in ('alpha-ready', 'beta-ready', 'gamma-month-end'):
            source = json.loads((API / 'fixtures/generated/snapshots' / (scenario + '.json')).read_text('utf-8'))
            owner = str(uuid.UUID(source['userId']))
            if cls.cluster.sql('''
                SELECT count(*)
                FROM payse.users
                WHERE id = ''' + quote(owner) + ';', DATABASE) != ['1']:
                raise AssertionError('Fixture owner must exist exactly once')
            expected = {entry['accountId'] for entry in source['accounts']}
            actual = set(cls.cluster.sql('''
                SELECT id
                FROM payse.financial_accounts
                WHERE user_id = ''' + quote(owner) + ';', DATABASE))
            if expected != actual:
                raise AssertionError('Fixture owner and account relationships differ')
            cls.owners.append(owner)
        if len(set(cls.owners)) != len(cls.owners):
            raise AssertionError('Scenario users must be distinct')

    def setUp(self):
        """2026-10-30: 검사별 닫기 행과 새 세션을 준비하며 금융 행은 보존한다. 사용: unittest."""
        self.cluster.sql('DELETE FROM payse.salary_notice_dismissals;', DATABASE)
        self.digests = []
        for owner in self.owners:
            digest = 'sha256:' + secrets.token_hex(32)
            session = str(uuid.uuid4())
            self.cluster.sql(f'''
            UPDATE payse.demo_sessions
            SET ended_at = clock_timestamp()
            WHERE user_id = {quote(owner)}
              AND ended_at IS NULL;

            INSERT INTO payse.demo_sessions (
              id,
              user_id,
              token_digest,
              issued_at
            ) VALUES (
              {quote(session)},
              {quote(owner)},
              {quote(digest)},
              clock_timestamp()
            );
            ''', DATABASE)
            self.digests.append(digest)

    def begin(self, index=0, authenticate=True):
        """2026-10-30: 실제 인증 함수로 사용자 잠금·RLS 문맥을 만든다. 사용: runtime/경합 검사."""
        statement = 'BEGIN;\nSET LOCAL ROLE payse_runtime;\n'
        if authenticate:
            statement += 'SELECT count(*) FROM payse.auth_authorize(' + quote(self.digests[index]) + ');\n'
        return statement

    def runtime(self, sql, index=0, authenticate=True):
        """2026-10-30: 최소 역할에서 작업을 커밋하고 인증 성공 건수를 확인한다. 사용: 각 검사."""
        rows = self.cluster.sql(self.begin(index, authenticate) + sql + '\n;\nCOMMIT;', DATABASE)
        if authenticate:
            self.assertEqual('1', rows[0])
            return rows[1:]
        return rows

    def insert_sql(self, month, index=0):
        """2026-10-30: 검증한 사용자 ID와 회차 입력으로 시각 없는 멱등 INSERT를 만든다. 사용: 각 검사."""
        return f'''
        INSERT INTO payse.salary_notice_dismissals (
          user_id,
          pay_month
        ) VALUES (
          {quote(self.owners[index])},
          {quote(month)}
        )
        ON CONFLICT (user_id, pay_month) DO NOTHING;
        '''

    def count_sql(self, month):
        """2026-10-30: RLS 적용 후 지정 회차의 건수만 조회한다. 사용: 각 검사."""
        return '''
        SELECT count(*)
        FROM payse.salary_notice_dismissals
        WHERE pay_month = ''' + quote(month) + ';'

    def rejected(self, sql, state='42501', index=0, authenticate=True):
        """2026-10-30: 예상 SQLSTATE만 확인하며 실패를 정상 결과로 숨기지 않는다. 사용: 각 검사."""
        with self.assertRaises(SqlError) as error:
            self.runtime(sql, index, authenticate)
        self.assertEqual(state, error.exception.state)

    def test_rls_and_owner_isolation(self):
        """2026-10-30: 같은 회차도 사용자별로 격리하고 무인증·타 사용자 쓰기를 거절한다. 사용: unittest."""
        self.runtime(self.insert_sql('2026-10'))
        self.assertEqual(['1'], self.runtime(self.count_sql('2026-10')))
        self.assertEqual(['0'], self.runtime(self.count_sql('2026-10'), index=1))
        self.assertEqual(['0'], self.runtime(self.count_sql('2026-10'), authenticate=False))
        self.rejected(self.insert_sql('2026-10', index=1))
        self.rejected(self.insert_sql('2026-11'), authenticate=False)
        self.runtime(self.insert_sql('2026-10', index=1), index=1)
        self.assertEqual(['2'], self.cluster.sql(self.count_sql('2026-10'), DATABASE))
        self.assertEqual(['t'], self.cluster.sql('''
        SELECT c.relrowsecurity AND c.relforcerowsecurity
        FROM pg_class c
        WHERE c.oid = 'payse.salary_notice_dismissals'::regclass;
        ''', DATABASE))

    def test_column_permissions_preserve_first_timestamp(self):
        """2026-10-30: 최초 시각은 DB만 지정하며 runtime 수정·삭제·TRUNCATE를 막는다. 사용: unittest."""
        self.runtime(self.insert_sql('2026-10'))
        statements = (
            "UPDATE payse.salary_notice_dismissals SET dismissed_at = clock_timestamp()",
            "UPDATE payse.salary_notice_dismissals SET pay_month = '2026-11'",
            'DELETE FROM payse.salary_notice_dismissals',
            'TRUNCATE payse.salary_notice_dismissals',
            f'''INSERT INTO payse.salary_notice_dismissals (user_id, pay_month, dismissed_at)
                VALUES ({quote(self.owners[0])}, '2026-11', clock_timestamp())''',
            "UPDATE payse.source_contexts SET salary_evidence = '[]'::jsonb",
        )
        for statement in statements:
            with self.subTest(statement=statement.split()[0]):
                self.rejected(statement)
        self.assertEqual(['t'], self.cluster.sql('''
        SELECT has_table_privilege('payse_runtime', 'payse.salary_notice_dismissals', 'SELECT')
          AND has_column_privilege('payse_runtime', 'payse.salary_notice_dismissals', 'user_id', 'INSERT')
          AND has_column_privilege('payse_runtime', 'payse.salary_notice_dismissals', 'pay_month', 'INSERT')
          AND NOT has_column_privilege('payse_runtime', 'payse.salary_notice_dismissals', 'dismissed_at', 'INSERT')
          AND NOT has_table_privilege('payse_runtime', 'payse.salary_notice_dismissals', 'UPDATE')
          AND NOT has_table_privilege('payse_runtime', 'payse.salary_notice_dismissals', 'DELETE')
          AND NOT has_table_privilege('payse_runtime', 'payse.salary_notice_dismissals', 'TRUNCATE');
        ''', DATABASE))

    def test_month_and_timestamp_constraints(self):
        """2026-10-30: 명목 회차 형식·연도 경계·유한 시각·사용자 FK를 검사한다. 사용: unittest."""
        for month in ('0001-01', '9999-12'):
            self.runtime(self.insert_sql(month))
        for month in ('0000-01', '2026-00', '2026-13', '2026-1', '26-10', '10000-01',
                      '2026-10-01', ' 2026-10', '2026-10 ', '2026-10\n', ''):
            with self.subTest(month=month):
                self.rejected(self.insert_sql(month), '23514')
        self.rejected(self.insert_sql(None), '23502')
        for timestamp in ("'infinity'", "'-infinity'", 'NULL'):
            with self.assertRaises(SqlError) as error:
                self.cluster.sql(f'''
                INSERT INTO payse.salary_notice_dismissals (user_id, pay_month, dismissed_at)
                VALUES ({quote(self.owners[0])}, '2026-09', {timestamp});
                ''', DATABASE)
            self.assertEqual('23502' if timestamp == 'NULL' else '23514', error.exception.state)
        missing_owner = str(uuid.uuid4())
        with self.assertRaises(SqlError) as error:
            self.cluster.sql(f'''
            INSERT INTO payse.salary_notice_dismissals (user_id, pay_month)
            VALUES ({quote(missing_owner)}, '2026-10');
            ''', DATABASE)
        self.assertEqual('23503', error.exception.state)

    def test_idempotent_month_without_source(self):
        """2026-10-30: 원천 없는 회차도 저장하고 반복 요청·다른 회차를 독립 처리한다. 사용: unittest."""
        month = '9000-01'
        self.assertEqual(['0'], self.cluster.sql('''
        SELECT count(*)
        FROM payse.source_contexts context
        CROSS JOIN LATERAL jsonb_array_elements(context.salary_evidence) evidence
        WHERE context.user_id = ''' + quote(self.owners[0]) + '''
          AND evidence->>'payMonth' = ''' + quote(month) + ';', DATABASE))
        timestamp_sql = '''
        SELECT dismissed_at::text
        FROM payse.salary_notice_dismissals
        WHERE pay_month = ''' + quote(month) + ';'
        first = self.runtime(self.insert_sql(month) + timestamp_sql)
        self.assertEqual(1, len(first))
        second = self.runtime(self.insert_sql(month) + timestamp_sql)
        self.assertEqual(first, second)
        self.assertEqual(['1'], self.runtime(self.count_sql(month)))
        self.assertEqual(['0'], self.runtime(self.count_sql('9000-02')))
        self.runtime(self.insert_sql('9000-02'))
        self.assertEqual(['1'], self.runtime(self.count_sql('9000-02')))
        self.assertEqual(first, self.runtime(timestamp_sql))

    def test_concurrent_dismissal_keeps_first_commit(self):
        """2026-10-30: 두 연결의 사용자 잠금 경합 후 한 행·최초 닫기 시각을 유지한다. 사용: unittest."""
        month = '2026-10'
        name = 'salary_notice_race_' + uuid.uuid4().hex
        timestamp_sql = '''
        SELECT dismissed_at::text
        FROM payse.salary_notice_dismissals
        WHERE pay_month = ''' + quote(month) + ';'
        with self.cluster.connect(DATABASE) as leader, self.cluster.connect(DATABASE, name) as follower:
            self.assertEqual(['1'], leader.sql(self.begin()))
            leader.sql(self.insert_sql(month))
            first = leader.sql(timestamp_sql)
            marker = follower.submit(self.begin() + self.insert_sql(month) + timestamp_sql + 'COMMIT;')
            self.cluster.wait_for_lock(name)
            leader.sql('COMMIT;')
            self.assertEqual(['1', *first], follower.receive(marker))
        self.assertEqual(['1'], self.runtime(self.count_sql(month)))
        self.assertEqual(first, self.runtime(timestamp_sql))

    def test_transaction_rollback_and_error(self):
        """2026-10-30: 명시 롤백·중간 SQL 오류는 안내 닫기 행을 남기지 않는다. 사용: unittest."""
        self.assertEqual(['1'], self.cluster.sql(self.begin() + self.insert_sql('2026-10') + 'ROLLBACK;', DATABASE))
        self.assertEqual(['0'], self.runtime(self.count_sql('2026-10')))
        self.rejected(self.insert_sql('2026-11') + 'SELECT 1/0;', '22012')
        self.assertEqual(['0'], self.runtime(self.count_sql('2026-11')))

    def test_cancelled_transaction_leaves_no_dismissal(self):
        """2026-10-30: 실제 PG 취소가 미커밋 안내 기록을 롤백함을 확인한다. 사용: unittest."""
        name = 'salary_notice_cancel_' + uuid.uuid4().hex
        with self.cluster.connect(DATABASE, name) as connection:
            self.assertEqual(['1'], connection.sql(self.begin() + self.insert_sql('2026-10')))
            marker = connection.submit('SELECT pg_sleep(8);\nCOMMIT;')
            deadline = time.monotonic() + 4
            while self.cluster.sql('''
                SELECT count(*)
                FROM pg_stat_activity
                WHERE application_name = ''' + quote(name) + " AND wait_event = 'PgSleep';") != ['1']:
                if time.monotonic() >= deadline:
                    self.fail('Cancel target did not enter pg_sleep')
                time.sleep(0.02)
            self.assertEqual(['t'], self.cluster.sql('''
            SELECT pg_cancel_backend(pid)
            FROM pg_stat_activity
            WHERE application_name = ''' + quote(name) + ';'))
            with self.assertRaises(SqlError) as error:
                connection.receive(marker)
            self.assertEqual('57014', error.exception.state)
        self.assertEqual(['0'], self.runtime(self.count_sql('2026-10')))

    def test_logout_wins_before_waiting_request(self):
        """2026-10-30: 먼저 커밋한 로그아웃 뒤 대기 요청은 인증되지 않고 행을 쓰지 못한다. 사용: unittest."""
        name = 'salary_notice_logout_' + uuid.uuid4().hex
        with self.cluster.connect(DATABASE) as logout, self.cluster.connect(DATABASE, name) as request:
            self.assertEqual(['t'], logout.sql(self.begin(authenticate=False)
                + 'SELECT payse.auth_end_session(' + quote(self.digests[0]) + ');'))
            marker = request.submit(self.begin() + self.insert_sql('2026-10') + 'COMMIT;')
            self.cluster.wait_for_lock(name)
            logout.sql('COMMIT;')
            with self.assertRaises(SqlError) as error:
                request.receive(marker)
            self.assertEqual('42501', error.exception.state)
        self.assertEqual(['0'], self.cluster.sql(self.count_sql('2026-10'), DATABASE))
        self.assertEqual(['0'], self.cluster.sql(self.begin() + 'COMMIT;', DATABASE))

    def test_migration_prerequisite_reapply_and_rollback(self):
        """2026-10-30: 007 선행·008 독립성·재적용 차단·중간 DDL 실패의 원자성을 검사한다. 사용: unittest."""
        self.assertEqual(['t'], self.cluster.sql("SELECT to_regclass('payse.analysis_jobs') IS NULL;", DATABASE))
        with self.assertRaises(SqlError) as error:
            self.cluster.load(DIRECTORY / '009_salary_notices.sql', DATABASE)
        self.assertEqual('55000', error.exception.state)
        database = 'payse_auth_test_salary_rollback'
        self.cluster.sql('CREATE DATABASE ' + database + ';')
        for filename in MIGRATIONS[:-1]:
            self.cluster.load(DIRECTORY / filename, database)
        with self.assertRaises(SqlError) as error:
            self.cluster.load(DIRECTORY / '009_salary_notices.sql', database)
        self.assertEqual('55000', error.exception.state)
        self.cluster.load(DIRECTORY / MIGRATIONS[-1], database)
        broken = self.cluster.work / 'broken-salary-notices'
        broken.mkdir()
        shutil.copyfile(DIRECTORY / '009_salary_notices.sql', broken / '009_salary_notices.sql')
        shutil.copytree(DIRECTORY / 'salary_notices', broken / 'salary_notices')
        with (broken / 'salary_notices/permissions.sql').open('a', encoding='utf-8') as output:
            output.write('\nSELECT 1/0;\n')
        with self.assertRaises(SqlError) as error:
            self.cluster.load(broken / '009_salary_notices.sql', database)
        self.assertEqual('22012', error.exception.state)
        self.assertEqual(['t'], self.cluster.sql("SELECT to_regclass('payse.salary_notice_dismissals') IS NULL;", database))
        self.cluster.load(DIRECTORY / '009_salary_notices.sql', database)
        self.assertEqual(['t'], self.cluster.sql("SELECT to_regclass('payse.salary_notice_dismissals') IS NOT NULL;", database))


def main():
    """2026-10-30: 소유한 임시 PG에서 SQL 및 선택적 전체 Java·필수 HTTP 회귀를 검사한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--sql-only', action='store_true')
    arguments = parser.parse_args()
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        credentials = prepare_database(cluster)
        before = fingerprint(cluster)
        jdbc_before = jdbc_fingerprint(cluster)
        session_before = session_fingerprint(cluster)
        SalaryNoticeStorageTests.cluster = cluster
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SalaryNoticeStorageTests)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        financial_preserved = before == fingerprint(cluster)
        passed = result.wasSuccessful() and financial_preserved
        cluster.report.update({'salarySqlChecks': result.testsRun, 'salarySqlPassed': passed,
            'financialSourcesUnchanged': financial_preserved, 'analysisStorageRequired': False,
            'runtimeCredentialsPersisted': False})
        if not arguments.sql_only and passed:
            environment = {key: value for key, value in os.environ.items()
                           if not key.upper().startswith(('PAYSE_', 'SPRING_', 'PG'))}
            environment.update(credentials)
            environment['PYTHONDONTWRITEBYTECODE'] = '1'
            launcher = ['cmd.exe', '/d', '/c', 'gradlew.bat'] if os.name == 'nt' else [str(API / 'gradlew')]
            with (cluster.work / 'java-tests.log').open('w', encoding='utf-8') as output:
                # 컴파일 실패 때 이전 JUnit 결과를 이번 실행 결과로 읽지 않도록 먼저 정리한다.
                completed = subprocess.run(launcher + ['cleanTest', 'test', 'apiDocsCheck', '--rerun-tasks', '--no-daemon', '--console=plain'],
                    cwd=API, env=environment, stdout=output, stderr=subprocess.STDOUT,
                    timeout=1200, creationflags=PROCESS_FLAGS)
            suites = java_results()
            for suffix in ('.AuthHttpTest', '.SessionJdbcTest', '.FinancialHttpTest', '.SalaryNoticeHttpTest'):
                if not any(suite['name'].endswith(suffix) and int(suite['tests']) > 0 for suite in suites):
                    raise RuntimeError('Required salary notice HTTP/JPA suite did not produce a JUnit result')
            passed = completed.returncode == 0 and all(int(suite[key]) == 0
                for suite in suites for key in ('failures', 'errors', 'skipped'))
            financial_preserved = before == fingerprint(cluster)
            passed = passed and financial_preserved
            cluster.report.update({'javaExitCode': completed.returncode, 'javaSuites': suites,
                'salaryHttpVerified': passed, 'financialSourcesUnchanged': financial_preserved})
        preserved = jdbc_before == jdbc_fingerprint(cluster) and session_before == session_fingerprint(cluster)
        cluster.report.update({'passed': passed and preserved, 'authBaselineRowsUnchanged': preserved,
            'sqlOnly': arguments.sql_only})
        if not passed or not preserved:
            return 1
        print('PASS: isolated salary notice checks; no existing database or mobile files changed')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        print('Salary notice checks did not complete: ' + type(error).__name__, file=sys.stderr)
        sys.exit(2)
