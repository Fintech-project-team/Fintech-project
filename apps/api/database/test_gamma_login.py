"""2026-11-03: 폐기 DB에서 연간 원천과 첫 로그인 전용 연결을 검증한다. 사용: 격리 CI·CLI."""
import argparse
import json
from pathlib import Path
import sys
import unittest
import uuid

DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
sys.path.insert(0, str(API))
sys.path.insert(0, str(API / 'fixtures'))
from export_sql import financial_rows, render, literal
from testing.scenarios.gamma_year import build
from testing.scenarios.first_login_links import install, uninstall


class GammaLoginTests(unittest.TestCase):
    """2026-11-03: 성공·실패·재로그인·다른 사용자와 롤백을 실제 DB로 검사한다."""

    @classmethod
    def setUpClass(cls):
        """2026-11-03: 별도 원본 DB에만 연간 자료를 한 번 준비한다. 사용: unittest."""
        from reference_data.export_sql import export
        cls.template = 'payse_auth_test_gamma_base_' + uuid.uuid4().hex[:12]
        cls.cluster.sql('CREATE DATABASE ' + cls.template + ';')
        for name in ('001_initial.sql', '002_storage_guards.sql', '003_auth_access.sql',
                     '004_auth_sessions.sql', '007_financial_access.sql'):
            cls.cluster.load(cls.base_sql_root / name, cls.template)
        cls.cluster.sql(export(), cls.template)
        cls.source, _ = build()
        cls.owner = cls.source['userId']
        seeds = json.loads((API / 'fixtures/generated-v4/server-seeds.json').read_text(encoding='utf-8'))
        seeds = {r['userId']: r for r in seeds['users']}
        beta = json.loads((API / 'fixtures/generated-v4/snapshots/beta-ready.json').read_text(encoding='utf-8'))
        cls.foreign = beta['userId']
        rows = financial_rows(cls.source, seeds[cls.owner]) + financial_rows(beta, seeds[cls.foreign])
        seed = render(rows).replace('SET CONSTRAINTS ALL IMMEDIATE;',
                                    'ANALYZE;\nSET CONSTRAINTS ALL IMMEDIATE;')
        with cls.cluster.connect(cls.template, name='gamma_fixture_preparation') as connection:
            connection.sql("SET statement_timeout='120s';\n" + seed, timeout=130)

    def setUp(self):
        """2026-11-03: 독립 복제 DB에 테스트 연결 기능만 설치한다. 사용: unittest."""
        self.database = 'payse_auth_test_gamma_' + uuid.uuid4().hex[:12]
        self.cluster.sql('CREATE DATABASE ' + self.database + ' TEMPLATE ' + self.template + ';')
        self.cluster.sql(install(self.source, self.database), self.database)

    def scalar(self, query):
        """2026-11-03: 테스트 소유 DB의 단일 결과만 받는다. 사용: 검사."""
        result = self.cluster.sql(query, self.database)
        self.assertEqual(len(result), 1)
        return result[0]

    def login(self, owner, char='a', end='COMMIT'):
        """2026-11-03: 기존 인증 함수의 성공 세션 삽입을 사용한다. HTTP 자격 검증 대체가 아니다."""
        return self.cluster.sql('BEGIN; SET LOCAL ROLE payse_runtime; SELECT count(*) FROM payse.auth_open_session('
            + literal(owner) + "::uuid, 'sha256:" + char * 64 + "'); " + end + ';', self.database)

    def test_first_success_is_once_and_preserves_later_settings(self):
        """2026-11-03: 연결 전 비공개·첫 로그인·재로그인·사용자 설정 보존을 검증한다."""
        owner = literal(self.owner) + '::uuid'
        self.assertEqual('1825', self.scalar('SELECT count(*) FROM payse.financial_transactions WHERE user_id=' + owner))
        self.assertEqual('0', self.scalar('SELECT count(*) FROM payse.institution_links WHERE user_id=' + owner))
        self.assertEqual(['1'], self.login(self.owner))
        self.assertEqual('9', self.scalar('SELECT count(*) FROM payse.institution_links WHERE user_id=' + owner))
        self.assertEqual('2', self.scalar('SELECT data_version FROM payse.users WHERE id=' + owner))
        self.assertEqual(['0'], self.login(self.owner, 'b'))
        self.cluster.sql("BEGIN; SELECT payse.auth_end_session('sha256:" + 'a' * 64 + "'); COMMIT;", self.database)
        self.cluster.sql('BEGIN; UPDATE payse.financial_accounts SET included=true, nickname=\'확인 별칭\' '
            'WHERE user_id=' + owner + " AND source_ref='fixture/gamma/account/0'; "
            'UPDATE payse.users SET data_version=3 WHERE id=' + owner + '; COMMIT;', self.database)
        self.assertEqual(['1'], self.login(self.owner, 'b'))
        self.assertEqual('3', self.scalar('SELECT data_version FROM payse.users WHERE id=' + owner))
        self.assertEqual('1', self.scalar('SELECT count(*) FROM payse.financial_accounts WHERE user_id='
            + owner + " AND included AND nickname='확인 별칭'"))
        self.assertEqual('0', self.scalar('SELECT count(*) FROM payse_test_login.pending'))

    def test_other_user_and_rollback_do_not_connect_gamma(self):
        """2026-11-03: 타 사용자 로그인과 커밋 실패는 감마 연결·버전을 바꾸지 않는다."""
        self.assertEqual(['1'], self.login(self.foreign, 'c'))
        self.assertEqual(['1'], self.login(self.owner, end='ROLLBACK'))
        self.assertEqual('0', self.scalar('SELECT count(*) FROM payse.institution_links'))
        self.assertEqual('1', self.scalar('SELECT data_version FROM payse.users WHERE id=' + literal(self.owner)))
        self.assertEqual('1', self.scalar('SELECT count(*) FROM payse_test_login.pending'))

    def test_wrong_source_rejects_session_atomically(self):
        """2026-11-03: 준비 원천이 달라지면 새 세션까지 롤백하고 다른 사용자는 계속 로그인한다."""
        from auth_test_support import SqlError
        self.cluster.sql("UPDATE payse_test_login.pending SET source_version='changed-review';", self.database)
        with self.assertRaises(SqlError):
            self.login(self.owner)
        self.assertEqual('0', self.scalar('SELECT count(*) FROM payse.demo_sessions'))
        self.assertEqual('0', self.scalar('SELECT count(*) FROM payse.institution_links'))
        self.assertEqual(['1'], self.login(self.foreign))

    def test_uninstall_keeps_financial_data_and_sessions(self):
        """2026-11-03: 테스트 동작 제거는 이미 연결한 자료·인증 세션을 삭제하지 않는다."""
        self.assertEqual(['1'], self.login(self.owner))
        self.cluster.sql(uninstall(), self.database)
        self.assertEqual('9', self.scalar('SELECT count(*) FROM payse.institution_links'))
        self.assertEqual('1', self.scalar('SELECT count(*) FROM payse.demo_sessions'))
        self.assertEqual('1825', self.scalar('SELECT count(*) FROM payse.financial_transactions WHERE user_id=' + literal(self.owner)))

    def test_runtime_cannot_read_or_arm_test_configuration(self):
        """2026-11-03: 일반 앱 역할은 테스트 설정을 읽거나 다른 계정을 준비할 수 없다."""
        from auth_test_support import SqlError
        for statement in ('SELECT * FROM payse_test_login.pending',
                          'DELETE FROM payse_test_login.pending'):
            with self.assertRaises(SqlError):
                self.cluster.sql('BEGIN; SET LOCAL ROLE payse_runtime; ' + statement + '; COMMIT;', self.database)
        self.assertEqual('1', self.scalar('SELECT count(*) FROM payse_test_login.pending'))


def run_checks(cluster, base_sql_root=DIRECTORY):
    """2026-11-03: 기존 격리 실행기가 소유한 클러스터만 사용한다. 사용: CLI·CI."""
    GammaLoginTests.cluster = cluster
    GammaLoginTests.base_sql_root = base_sql_root
    return unittest.TextTestRunner(verbosity=2, failfast=True).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(GammaLoginTests))


if __name__ == '__main__':
    from auth_test_support import Cluster
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    args = parser.parse_args()
    with Cluster(args.pg_bin, args.work_dir) as cluster:
        result = run_checks(cluster)
        cluster.report.update(gammaLoginChecks=result.testsRun, passed=result.wasSuccessful())
    sys.exit(0 if result.wasSuccessful() else 1)
