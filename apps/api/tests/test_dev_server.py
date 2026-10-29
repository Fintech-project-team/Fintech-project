"""2026-10-29: 개발 준비 도구가 기존 경로·클러스터·환경을 잘못 사용하는 것을 검사한다."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('payse_dev_server', Path(__file__).parents[1] / 'tools/dev_server.py')
DEV = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEV)


class DevServerTests(unittest.TestCase):
    """2026-10-29: 실제 DB를 시작하지 않고 시작 전 거절 경계를 확인한다. 사용: unittest."""

    def setUp(self):
        """2026-10-29: 소유한 임시 폴더를 개발 루트로 주입한다. 사용: unittest."""
        self.directory = tempfile.TemporaryDirectory(prefix='payse-dev-guard-')
        self.root = Path(self.directory.name).resolve()
        self.environment = patch.dict(os.environ, {'LOCALAPPDATA': str(self.root)})
        self.environment.start()
        self.home = self.root / 'PAYSE/development/check'

    def tearDown(self):
        """2026-10-29: 검증한 임시 경로만 정리하고 환경을 복원한다. 사용: unittest."""
        self.environment.stop()
        if Path(self.directory.name).resolve() != self.root or not self.root.name.startswith('payse-dev-guard-'):
            raise AssertionError('Temporary cleanup boundary differs')
        self.directory.cleanup()

    def test_parent_traversal_is_rejected(self):
        """2026-10-29: ..로 전용 부모 밖으로 나가는 경로를 거절한다. 사용: unittest."""
        with self.assertRaises(ValueError):
            DEV.validate_home(self.root / 'PAYSE/development/../existing-db')

    def test_unrelated_and_parent_directories_are_rejected(self):
        """2026-10-29: 일반 폴더·전용 부모 자체를 초기화 대상으로 받지 않는다. 사용: unittest."""
        for path in (self.root / 'postgres-existing', self.home.parent):
            with self.subTest(path=path), self.assertRaises(ValueError):
                DEV.validate_home(path)

    def test_existing_directory_never_initializes(self):
        """2026-10-29: 빈 폴더도 기존 것이면 모든 프로세스 실행 전에 거절한다. 사용: unittest."""
        self.home.mkdir(parents=True)
        with patch.object(DEV, 'run') as run, self.assertRaises(ValueError):
            DEV.DevServer(self.home).init(self.root, 15432, 18080)
        run.assert_not_called()

    def test_external_database_and_java_injection_are_removed(self):
        """2026-10-29: 외부 접속값과 JVM 옵션이 개발 자식 프로세스로 이어지지 않는다. 사용: unittest."""
        with patch.dict(os.environ, {'PGHOST': 'existing-db', 'PGPASSWORD': 'private',
                'PAYSE_JDBC_URL': 'existing-url', 'SPRING_PROFILES_ACTIVE': 'other',
                'JAVA_TOOL_OPTIONS': '-agentlib:other', 'JDK_JAVA_OPTIONS': '-Dother',
                '_JAVA_OPTIONS': '-Dother'}):
            environment = DEV.clean_environment()
        for key in ('PGHOST', 'PGPASSWORD', 'PAYSE_JDBC_URL', 'SPRING_PROFILES_ACTIVE',
                    'JAVA_TOOL_OPTIONS', 'JDK_JAVA_OPTIONS', '_JAVA_OPTIONS'):
            self.assertNotIn(key, environment)

    def test_incomplete_marker_is_not_startable(self):
        """2026-10-29: 중단된 최초 준비를 일반 재시작으로 우회하지 못한다. 사용: unittest."""
        self.home.mkdir(parents=True)
        server = DEV.DevServer(self.home)
        marker = {'kind': DEV.KIND, 'home': str(self.home), 'data': str(server.data), 'phase': 'preparing'}
        server.state_file.write_text(json.dumps(marker), encoding='utf-8')
        with patch.object(DEV, 'run') as run, self.assertRaises(ValueError):
            server.load()
        run.assert_not_called()

    def test_replaced_cluster_is_rejected_before_start(self):
        """2026-10-29: 시스템 ID가 바뀌면 pg_ctl이나 SQL에 도달하지 않는다. 사용: unittest."""
        server = DEV.DevServer(self.home)
        server.data.mkdir(parents=True)
        server.state = {'phase': 'ready', 'systemId': '111'}
        with patch.object(server, 'binary', return_value=Path('pg_controldata.exe')), \
                patch.object(DEV, 'run', return_value='Database system identifier: 222') as run, \
                self.assertRaises(RuntimeError):
            server.start_db()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][0], Path('pg_controldata.exe'))

    def test_ready_marker_requires_system_identifier(self):
        """2026-10-29: 준비 완료 표식에 ID가 없으면 기존 데이터로 간주해 거절한다. 사용: unittest."""
        server = DEV.DevServer(self.home)
        server.data.mkdir(parents=True)
        server.state = {'phase': 'ready', 'systemId': None}
        with patch.object(server, 'binary', return_value=Path('pg_controldata.exe')), \
                patch.object(DEV, 'run', return_value='Database system identifier: 222'), \
                self.assertRaises(RuntimeError):
            server.check_data()

    def test_failed_verification_replaces_previous_pass(self):
        """2026-10-29: 재검증 실패 때 과거 PASS가 현행 결과로 남지 않는다. 사용: unittest."""
        server = DEV.DevServer(self.home)
        self.home.mkdir(parents=True)
        report = self.home / 'verification.json'
        report.write_text(json.dumps({'ok': True, 'status': 'PASS'}), encoding='utf-8')
        with patch.object(server, 'verify_checks', side_effect=RuntimeError('blocked')), \
                self.assertRaises(RuntimeError):
            server.verify()
        result = json.loads(report.read_text(encoding='utf-8'))
        self.assertFalse(result['ok'])
        self.assertEqual(result['status'], 'FAIL')


if __name__ == '__main__':
    unittest.main()
