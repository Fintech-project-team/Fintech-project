"""2026-10-29: 개발 준비 도구가 기존 경로·클러스터·환경을 잘못 사용하는 것을 검사한다."""
import importlib.util
from contextlib import redirect_stderr
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('payse_dev_server', Path(__file__).parents[1] / 'tools/dev_server.py')
DEV = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEV)
sys.path[:0] = [str(DEV.API / 'fixtures'), str(DEV.API)]
import export_sql as FINANCIAL
import identity_contract as IDENTITY
from testing.scenarios import export_state as SCENARIO


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

    def prepared_rows(self, *, demo_state=False, directory=None):
        """2026-10-30: 실제 검증·적재기를 실행하고 렌더링 직전 행을 대조용으로 읽는다. 사용: 시드 검사."""
        directory = directory or DEV.API / 'fixtures/generated'
        with patch.object(FINANCIAL, 'render', wraps=FINANCIAL.render) as ordinary, \
                patch.object(SCENARIO, 'render', wraps=SCENARIO.render) as scenario:
            sql = DEV.initial_sql(directory, demo_state=demo_state)
        selected, unused = (scenario, ordinary) if demo_state else (ordinary, scenario)
        selected.assert_called_once()
        unused.assert_not_called()
        self.assertTrue(sql.rstrip().endswith('COMMIT;'))
        self.assertNotIn('TRUNCATE ', sql)
        self.assertNotIn('DELETE ', sql)
        return selected.call_args.args[0]

    def seed_copy(self):
        """2026-10-30: 잘못된 입력 검사는 소유한 임시 fixture 사본에서만 수행한다. 사용: 시드 입력 검사."""
        directory = self.root / 'fixture-copy'
        shutil.copytree(DEV.API / 'fixtures/generated', directory)
        return directory

    def write_seed(self, directory, seed):
        """2026-10-30: 테스트 입력의 manifest만 다시 계산해 의미 검증도 우회되지 않는지 확인한다. 사용: 입력 검사."""
        (directory / 'server-seeds.json').write_text(json.dumps(seed, ensure_ascii=False), encoding='utf-8')
        manifest_path = directory / 'manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        canonical = json.dumps(seed, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')
        manifest['sha256']['server-seeds.json'] = hashlib.sha256(canonical).hexdigest()
        manifest_path.write_text(json.dumps(manifest), encoding='utf-8')

    def test_default_initialization_keeps_user_state_empty(self):
        """2026-10-30: 일반 init은 원천만 적재하고 연결·선택·계획·보호 설정은 비워 둔다. 사용: unittest."""
        rows = self.prepared_rows()
        snapshots, seeds = FINANCIAL.load_sources(DEV.API / 'fixtures/generated')
        self.assertEqual(set(seeds), {row['id'] for table, row in rows if table == 'users'})
        self.assertFalse({table for table, _ in rows} & {
            'institution_links', 'obligations', 'reserves', 'recurring_plans',
            'reserve_allocations', 'settlement_links', 'write_receipts'})
        for table, row in rows:
            if table == 'financial_accounts':
                self.assertFalse(row['included'])
            elif table == 'user_attributes':
                self.assertEqual(row, {'user_id': row['user_id'], 'salary_day': None,
                    'salary_amount_krw': None, 'salary_account_id': None, 'card_plan_overrides': []})
        self.assertEqual(len(snapshots), sum(table == 'user_attributes' for table, _ in rows))

    def test_demo_initialization_imports_explicit_user_state(self):
        """2026-10-30: 명시 시연은 계정별 initialCase의 선택·연결·설정·예정 지출·보호금을 보존한다. 사용: unittest."""
        rows = self.prepared_rows(demo_state=True)
        snapshots, seeds = FINANCIAL.load_sources(DEV.API / 'fixtures/generated')
        self.assertEqual(set(seeds), {row['id'] for table, row in rows if table == 'users'})
        for snapshot in snapshots:
            owner = snapshot['userId']
            settings, = [row for table, row in rows if table == 'user_attributes' and row['user_id'] == owner]
            salary = snapshot['settings']['salary']
            self.assertEqual(settings, {'user_id': owner, 'salary_day': salary['salaryDay'],
                'salary_amount_krw': salary['salaryAmountKRW'], 'salary_account_id': salary['salaryAccountId'],
                'card_plan_overrides': snapshot['settings']['cardPlans']})
            accounts = {row['id']: row['included'] for table, row in rows
                        if table == 'financial_accounts' and row['user_id'] == owner}
            self.assertEqual({row['accountId']: row['included'] for row in snapshot['accounts']}, accounts)
            for table, key, identity in (
                    ('institution_links', 'institutionLinks', 'linkId'),
                    ('obligations', 'obligations', 'obligationId'),
                    ('reserves', 'reserves', 'reserveId'),
                    ('recurring_plans', 'recurringPlans', 'planId')):
                self.assertEqual({row[identity] for row in snapshot[key]},
                    {row['id'] for actual, row in rows if actual == table and row.get('user_id') == owner})
        for _, row in rows:
            self.assertFalse(any(key.startswith(('demo_', 'test_', 'scenario_', 'fixture_')) for key in row))

    def test_demo_mode_preserves_financial_source_values(self):
        """2026-10-30: 시연 설정을 추가해도 기존 ID·금액·날짜·원천은 일반 적재와 같다. 사용: unittest."""
        ordinary = self.prepared_rows()
        prepared = self.prepared_rows(demo_state=True)
        source_tables = {table for table, _ in ordinary} - {'user_attributes'}
        def facts(rows):
            """2026-10-30: 명시 사용자 선택·회차 연결만 제외하고 금융 원천 전체를 대조한다. 사용: 현재 검사."""
            return [(table, {key: value for key, value in row.items() if key not in ('included', 'occurrence_links')})
                    for table, row in rows if table in source_tables]
        self.assertEqual(facts(ordinary), facts(prepared))

    def test_demo_mode_follows_seed_case_mapping(self):
        """2026-10-30: 목록 순서와 알파의 승인된 initialCase 변경을 별도 고정 목록 없이 따른다. 사용: unittest."""
        directory = self.seed_copy()
        seed = json.loads((directory / 'server-seeds.json').read_text(encoding='utf-8'))
        source = json.loads((directory / 'snapshots/demo-life.json').read_text(encoding='utf-8'))
        matching = [row for row in seed['users'] if row['userId'] == source['userId']]
        self.assertEqual(1, len(matching))
        matching[0]['initialCase'] = 'demo-life'
        seed['users'].reverse()
        self.write_seed(directory, seed)
        identities = tuple({**row, 'initial_case': 'demo-life'} if row['user_id'] == source['userId'] else row
                           for row in IDENTITY.IDENTITY_USERS)
        with patch.object(IDENTITY, 'IDENTITY_USERS', identities):
            rows = self.prepared_rows(demo_state=True, directory=directory)
        imported, = [row for table, row in rows if table == 'source_contexts' and row['user_id'] == source['userId']]
        self.assertEqual(imported['source_version'], source['sourceVersion'])
        self.assertEqual(imported['salary_evidence'], source['settings']['salary']['receiptEvidence'])
        self.assertEqual({row['obligationId'] for row in source['obligations']},
            {row['id'] for table, row in rows if table == 'obligations' and row['user_id'] == source['userId']})

    def test_invalid_seed_mapping_is_rejected(self):
        """2026-10-30: 재해시한 잘못된 사례·다른 사용자 연결·중복 계정도 기존 검증으로 거절한다. 사용: unittest."""
        directory = self.seed_copy()
        original = json.loads((directory / 'server-seeds.json').read_text(encoding='utf-8'))
        cases = ('missing-case', original['users'][1]['initialCase'])
        for case in cases:
            seed = json.loads(json.dumps(original))
            seed['users'][0]['initialCase'] = case
            self.write_seed(directory, seed)
            with self.subTest(case=case), self.assertRaises(ValueError):
                DEV.initial_sql(directory, demo_state=True)
        seed = json.loads(json.dumps(original))
        seed['users'].append(seed['users'][0])
        self.write_seed(directory, seed)
        with self.assertRaises(ValueError):
            DEV.initial_sql(directory, demo_state=True)

    def test_invalid_preparation_never_creates_database(self):
        """2026-10-30: 시드 검증 실패는 폴더·프로세스·DB 생성 전 중단된다. 사용: unittest."""
        binaries = self.root / 'binaries'
        binaries.mkdir()
        for name in ('postgres', 'initdb', 'pg_ctl', 'pg_controldata', 'psql'):
            (binaries / (name + '.exe')).touch()
        with patch.object(DEV, 'initial_sql', side_effect=ValueError('invalid seed')) as prepare, \
                patch.object(DEV, 'port_free'), patch.object(DEV, 'run') as run, \
                self.assertRaises(ValueError):
            DEV.DevServer(self.home).init(binaries, 15432, 18080, demo_state=True)
        prepare.assert_called_once_with(DEV.API / 'fixtures/generated', demo_state=True)
        run.assert_not_called()
        self.assertFalse(self.home.exists())

    def test_demo_state_option_is_init_only(self):
        """2026-10-30: 시연 옵션은 새 init에서만 받고 재시작·검증 등 기존 DB 명령은 거절한다. 사용: unittest."""
        self.assertFalse(DEV.parse_args(['init']).demo_state)
        self.assertTrue(DEV.parse_args(['init', '--demo-state']).demo_state)
        for command in ('start', 'stop', 'restart', 'status', 'verify'):
            with self.subTest(command=command), redirect_stderr(io.StringIO()) as error, \
                    patch.object(DEV, 'DevServer') as server, \
                    patch.object(sys, 'argv', ['dev_server.py', command, '--demo-state']), \
                    self.assertRaises(SystemExit) as rejected:
                DEV.main()
            self.assertEqual(2, rejected.exception.code)
            self.assertIn('--demo-state is only allowed with init', error.getvalue())
            server.assert_not_called()

    def test_demo_mode_does_not_reseed_existing_home(self):
        """2026-10-30: 시연 모드도 기존 빈 폴더나 저장 DB를 재사용·초기화하지 못한다. 사용: unittest."""
        self.home.mkdir(parents=True)
        with patch.object(DEV, 'initial_sql') as prepare, patch.object(DEV, 'run') as run, \
                self.assertRaises(ValueError):
            DEV.DevServer(self.home).init(self.root, 15432, 18080, demo_state=True)
        prepare.assert_not_called()
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
