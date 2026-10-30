"""2026-10-29: 이 PC 전용 개발 DB와 API의 최초 준비·기동·종료·검증을 분리한다.

사용: CLI. 기존 PostgreSQL 주소를 받지 않고 소유 표식이 있는 별도 클러스터만 다룬다.
"""
from __future__ import annotations

import argparse
import base64
import csv
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


API = Path(__file__).resolve().parents[1]
REPO = API.parents[1]
KIND = 'payse-local-development-v1'
DATABASE = 'payse_dev'
ADMIN = 'payse_dev_owner'
LOGIN = 'payse_dev_api'
FLAGS = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
DEMO_CODES = {'데모알파': '000001', '데모베타': '000002', '데모감마': '000003'}


def clean_environment():
    """2026-10-29: 외부 DB·Spring·Java 주입값을 상속하지 않는다. 사용: 모든 자식 실행."""
    return {key: value for key, value in os.environ.items()
            if not key.upper().startswith(('PG', 'PAYSE_', 'SPRING_'))
            and key.upper() not in ('JAVA_TOOL_OPTIONS', 'JDK_JAVA_OPTIONS', '_JAVA_OPTIONS')}


def run(args, *, content=None, environment=None, timeout=60, cwd=None):
    """2026-10-29: 인자 배열·파이프로 실행하고 오류 원문 노출을 막는다. 사용: 준비·제어."""
    result = subprocess.run([str(value) for value in args], input=content,
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        env=environment or clean_environment(), cwd=cwd or REPO,
        timeout=timeout, creationflags=FLAGS)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} failed (exit {result.returncode}); sensitive output withheld')
    return result.stdout.strip()


def quote(value):
    """2026-10-29: 검증된 준비 자료의 SQL 문자열을 인코딩한다. 사용: 최초 적재·검사."""
    return "'" + str(value).replace("'", "''") + "'"


def port_free(port):
    """2026-10-29: 지정 loopback 포트 점유를 거절한다. 사용: init·start."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        if os.name == 'nt':
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        probe.bind(('127.0.0.1', port))


def validate_home(home):
    """2026-10-29: 개발 전용 부모 아래 실경로만 허용한다. 사용: DevServer 생성자."""
    base = (Path(os.environ['LOCALAPPDATA']) / 'PAYSE' / 'development').resolve()
    requested = Path(home).absolute()
    if '..' in requested.parts:
        raise ValueError('Parent traversal is not allowed for the development home')
    target = requested
    if target == base or not target.is_relative_to(base):
        raise ValueError('Development home must be below LOCALAPPDATA/PAYSE/development')
    for part in (target, *target.parents):
        if part.exists() and (part.is_symlink() or bool(getattr(part.stat(follow_symlinks=False),
                'st_file_attributes', 0) & 0x400)):
            raise ValueError('Reparse points are not allowed for the development home')
    if not target.resolve().is_relative_to(base):
        raise ValueError('Resolved development home is outside its boundary')
    return target


def protect(mode, content):
    """2026-10-29: 현재 사용자 DPAPI 파이프를 호출한다. 사용: init·read_secrets."""
    shell = shutil.which('pwsh')
    if not shell:
        raise ValueError('PowerShell 7 is required; execution policy is not changed')
    return run([shell, '-NoProfile', '-NonInteractive', '-File', API / 'tools/dev_secrets.ps1', mode],
               content=content)


class DevServer:
    """2026-10-29: 소유한 개발 폴더의 DB·JAR·비밀만 관리한다. 사용: main."""

    def __init__(self, home):
        """2026-10-29: 허용 경로만 보관하며 즉시 접속하지 않는다. 사용: main·검사."""
        self.home = validate_home(home)
        self.data = self.home / 'postgres'
        self.state_file = self.home / 'owner.json'
        self.state = None

    def save(self):
        """2026-10-29: 비밀 없는 소유·실행 상태를 원자 교체한다. 사용: 초기화·시작·종료."""
        pending = self.home / 'owner.next.json'
        pending.write_text(json.dumps(self.state, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        pending.replace(self.state_file)

    def load(self, *, ready=True):
        """2026-10-29: 위치·소유 종류·단계가 맞는 표식만 받는다. 사용: CLI 제어."""
        state = json.loads(self.state_file.read_text(encoding='utf-8'))
        if state.get('kind') != KIND or state.get('home') != str(self.home) \
                or state.get('data') != str(self.data) or (ready and state.get('phase') != 'ready'):
            raise ValueError('Development owner marker or preparation state differs')
        self.state = state
        self.check_data()

    def read_secrets(self):
        """2026-10-29: 저장소 밖 DPAPI 자료를 현재 사용자로만 복호화한다. 사용: DB·API 시작."""
        return json.loads(protect('unprotect', (self.home / 'secrets.dpapi').read_text(encoding='ascii')))

    def binary(self, name):
        """2026-10-29: 기록된 PostgreSQL 도구를 사용한다. 사용: DB 준비·제어."""
        binary = Path(self.state['pgBin']) / (name + '.exe')
        if not binary.is_file():
            raise ValueError('Recorded PostgreSQL binary is missing')
        return binary

    def check_data(self):
        """2026-10-29: 시작 전에 데이터 실경로·제어파일의 소유 ID를 확인한다. 사용: load·DB 제어."""
        if self.data.exists():
            if validate_home(self.data) != self.data or self.data.resolve() != self.data:
                raise ValueError('Database directory was redirected')
            control = run([self.binary('pg_controldata'), '-D', self.data],
                          environment={**clean_environment(), 'LC_ALL': 'C'})
            match = re.search(r'Database system identifier:\s*(\d+)', control)
            if not match:
                raise RuntimeError('Could not read owned database control identity')
            if self.state.get('systemId') is None and self.state['phase'] == 'preparing':
                self.state['systemId'] = match.group(1)
                self.save()
            elif self.state.get('systemId') != match.group(1):
                raise RuntimeError('Database control identity differs; no server was started')
        elif self.state['phase'] == 'ready':
            raise RuntimeError('Owned database directory is missing')

    def db_environment(self):
        """2026-10-29: 소유한 loopback DB 자격만 자식 환경에 넣는다. 사용: sql·load_sql."""
        values = self.read_secrets()
        return {**clean_environment(), 'PGHOST': '127.0.0.1', 'PGPORT': str(self.state['pgPort']),
            'PGUSER': ADMIN, 'PGPASSWORD': values['adminPassword'], 'PGDATABASE': DATABASE,
            'PGCLIENTENCODING': 'UTF8', 'PGCONNECT_TIMEOUT': '5', 'PGAPPNAME': 'payse-dev-manager'}

    def sql(self, sql=None, *, filename=None, database=DATABASE):
        """2026-10-29: 식별한 전용 클러스터에만 SQL을 보낸다. 사용: 최초 적재·소유 확인."""
        if database not in ('postgres', DATABASE) or (sql is None) == (filename is None):
            raise ValueError('Invalid development SQL request')
        args = [self.binary('psql'), '-X', '-w', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1',
                '-v', 'VERBOSITY=sqlstate', '-d', database]
        if filename is not None:
            args += ['-f', filename]
        return run(args, content=sql, environment=self.db_environment(), timeout=120)

    def db_identity(self):
        """2026-10-29: 접속의 실경로·loopback·system ID를 대조한다. 사용: 모든 DB 제어."""
        row = json.loads(self.sql("SELECT json_build_object("
            "'directory',current_setting('data_directory'),'host',current_setting('listen_addresses'),"
            "'port',current_setting('port'),'owner',current_user,'cluster',current_setting('cluster_name'),"
            "'system',(SELECT system_identifier::text FROM pg_control_system()));", database='postgres'))
        if Path(row['directory']).resolve() != self.data.resolve() or row['host'] != '127.0.0.1' \
                or row['port'] != str(self.state['pgPort']) or row['owner'] != ADMIN \
                or row['cluster'] != self.state['marker']:
            raise RuntimeError('Database identity does not match the owned development cluster')
        if self.state.get('systemId') not in (None, row['system']):
            raise RuntimeError('Database system identifier changed')
        return row['system']

    def db_running(self):
        """2026-10-29: 지정 데이터 경로의 pg_ctl 상태만 읽는다. 사용: 시작·종료·상태."""
        self.check_data()
        result = subprocess.run([str(self.binary('pg_ctl')), '-D', str(self.data), 'status'],
            capture_output=True, creationflags=FLAGS, timeout=10, env=clean_environment())
        if result.returncode not in (0, 3):
            raise RuntimeError('Could not inspect the owned PostgreSQL process')
        return result.returncode == 0

    def start_db(self):
        """2026-10-29: 소유 클러스터만 시작하고 기존 서버 재사용은 거절한다. 사용: init·start."""
        if not self.db_running():
            port_free(self.state['pgPort'])
            # Windows 자식 postgres가 캡처 파이프를 상속하면 pg_ctl 종료 뒤에도 EOF가 오지 않는다.
            with (self.home / 'control.log').open('ab') as log:
                result = subprocess.run([str(self.binary('pg_ctl')), '-D', str(self.data), '-l',
                    str(self.home / 'postgres.log'), '-w', '-t', '30', 'start'],
                    stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=clean_environment(),
                    creationflags=FLAGS, timeout=40)
            if result.returncode:
                raise RuntimeError('Owned PostgreSQL startup failed; inspect the private control.log')
        self.state['systemId'] = self.db_identity()
        self.save()

    def stop_db(self):
        """2026-10-29: 식별된 개발 DB에만 fast 종료한다. 사용: stop; 데이터·키 보존."""
        if self.db_running():
            self.db_identity()
            run([self.binary('pg_ctl'), '-D', self.data, '-w', '-t', '30', '-m', 'fast', 'stop'], timeout=40)

    def init(self, pg_bin, pg_port, api_port):
        """2026-10-29: 새 경로에만 초기 DB·일반 시드·키를 준비한다. 사용: init CLI."""
        if self.home.exists() or pg_port == api_port or not all(1024 <= p <= 65535 for p in (pg_port, api_port)):
            raise ValueError('Initialization requires a new directory and two distinct nonprivileged ports')
        pg_bin = Path(pg_bin).resolve(strict=True)
        for name in ('postgres', 'initdb', 'pg_ctl', 'pg_controldata', 'psql'):
            if not (pg_bin / (name + '.exe')).is_file():
                raise ValueError('PostgreSQL binaries are incomplete')
        port_free(pg_port)
        port_free(api_port)
        self.home.parent.mkdir(parents=True, exist_ok=True)
        self.home.mkdir()
        sid = next(csv.reader(run(['whoami', '/user', '/fo', 'csv', '/nh']).splitlines()))[1]
        run(['icacls', self.home, '/inheritance:r', '/grant:r', f'*{sid}:(OI)(CI)F'])
        self.state = {'kind': KIND, 'phase': 'preparing', 'home': str(self.home), 'data': str(self.data),
            'pgBin': str(pg_bin), 'pgPort': pg_port, 'apiPort': api_port,
            'marker': 'payse-dev-' + uuid.uuid4().hex, 'systemId': None, 'apiPid': None}
        self.save()
        values = {'adminPassword': secrets.token_urlsafe(48), 'apiPassword': secrets.token_urlsafe(48),
            'PAYSE_AUTH_CODE_KEY_ID': 'local_dev_1',
            **{key: base64.b64encode(secrets.token_bytes(32)).decode('ascii') for key in (
                'PAYSE_AUTH_CODE_KEY_BASE64', 'PAYSE_AUTH_LIMIT_KEY_BASE64', 'PAYSE_FINANCE_CURSOR_KEY_BASE64')}}
        (self.home / 'secrets.dpapi').write_text(protect('protect', json.dumps(values)), encoding='ascii')
        password_file = self.home / 'init-password.tmp'
        try:
            password_file.write_text(values['adminPassword'] + '\n', encoding='ascii')
            run([self.binary('initdb'), '-D', self.data, '--username=' + ADMIN,
                 '--encoding=UTF8', '--locale=C', '--auth=scram-sha-256', '--pwfile', password_file])
        finally:
            password_file.unlink(missing_ok=True)
        with (self.data / 'postgresql.conf').open('a', encoding='utf-8') as config:
            config.write(f"\nlisten_addresses='127.0.0.1'\nport={pg_port}\ncluster_name='{self.state['marker']}'\n"
                "log_statement='none'\nlog_min_error_statement='panic'\nlog_error_verbosity='terse'\n"
                "log_parameter_max_length_on_error=0\n")
        try:
            self.start_db()
            self.sql('CREATE DATABASE ' + DATABASE + ';', database='postgres')
            for name in ('001_initial.sql', '002_storage_guards.sql', '003_auth_access.sql',
                         '004_auth_sessions.sql', '007_financial_access.sql'):
                self.sql(filename=API / 'database' / name)
            sys.path[:0] = [str(API / 'fixtures'), str(API)]
            from reference_data.export_sql import export as institutions
            from export_sql import export as financial
            self.sql(institutions())
            self.sql(financial(API / 'fixtures/generated'))
            self.sql(f"""
                BEGIN;
                CREATE ROLE {LOGIN}
                    LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS
                    NOCREATEDB NOCREATEROLE NOREPLICATION
                    PASSWORD {quote(values['apiPassword'])};
                GRANT payse_runtime TO {LOGIN};
                REVOKE ALL ON DATABASE {DATABASE} FROM PUBLIC;
                GRANT CONNECT ON DATABASE {DATABASE} TO {LOGIN};
                COMMIT;
            """)
            self.provision(values)
            self.state['phase'] = 'ready'
            self.state['serverVersion'] = self.sql('SHOW server_version;')
            self.save()
        except BaseException:
            self.stop_db()
            raise

    def java(self):
        """2026-10-29: 설치된 JDK 21만 사용한다. 사용: 코드 준비·API 시작."""
        java = Path(shutil.which('java') or '')
        if not java.is_file() or not (java.parent / 'javac.exe').is_file():
            raise ValueError('JDK 21 is required')
        probe = subprocess.run([str(java), '-version'], capture_output=True, text=True, creationflags=FLAGS)
        if 'version "21.' not in probe.stderr + probe.stdout:
            raise ValueError('JDK 21 is required')
        return java

    def provision(self, values):
        """2026-10-29: 기존 AuthCrypto로 확인한 세 합성 계정만 활성화한다. 사용: 최초 init."""
        seeds = json.loads((API / 'fixtures/generated/server-seeds.json').read_text(encoding='utf-8'))['users']
        if {row['name'] for row in seeds} != set(DEMO_CODES) or len(seeds) != 3:
            raise ValueError('Reviewed synthetic accounts differ')
        java = self.java()
        output = self.home / 'provision-classes'
        output.mkdir()
        sources = [API / 'src/main/java/com/payse/api' / name for name in (
            'auth/crypto/AuthCrypto.java', 'auth/crypto/AuthSecrets.java',
            'auth/vo/AuthCredentials.java', 'auth/vo/IssuedToken.java')]
        run([java.parent / 'javac.exe', '-encoding', 'UTF-8', '-d', output,
             *sources, API / 'tools/PrepareDemo.java'])
        environment = {**clean_environment(), **{key: value for key, value in values.items() if key.startswith('PAYSE_AUTH_')}}
        result = run([java, '-cp', output, 'PrepareDemo'], environment=environment,
            content=''.join(row['userId'] + '\t' + DEMO_CODES[row['name']] + '\n' for row in seeds))
        verifiers = dict(line.split('\t', 1) for line in result.splitlines())
        if set(verifiers) != {row['userId'] for row in seeds}:
            raise RuntimeError('Prepared credential ownership differs')
        statements = ['BEGIN;']
        for row in seeds:
            statements.append(f"""
                DO $$
                DECLARE
                    changed integer;
                BEGIN
                    UPDATE payse.users
                    SET code_verifier = {quote(verifiers[row['userId']])}
                    WHERE id = {quote(row['userId'])}::uuid
                      AND name = {quote(row['name'])}
                      AND phone = {quote(row['phone'])}
                      AND code_verifier = {quote(row['codeVerifier'])};
                    GET DIAGNOSTICS changed = ROW_COUNT;
                    IF changed <> 1 THEN
                        RAISE EXCEPTION 'Synthetic credential owner did not match exactly once';
                    END IF;
                END $$;
            """)
        self.sql('\n'.join(statements + ['COMMIT;']))

    def process_info(self, *, starting=False):
        """2026-10-29: PID·실행파일·JAR·시작시각으로 API 소유를 확인한다. 사용: stop·status."""
        pid = self.state.get('apiPid')
        if pid is None:
            return None
        command = (f"$p=Get-CimInstance Win32_Process -Filter 'ProcessId = {int(pid)}'; "
            "if ($p) { [pscustomobject]@{ pid=$p.ProcessId; path=$p.ExecutablePath; "
            "command=$p.CommandLine; started=$p.CreationDate.ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress }")
        result = run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', command])
        if not result:
            return None
        process = json.loads(result)
        if not starting and not self.state.get('apiStarted'):
            raise RuntimeError('API start identity is incomplete; refusing PID reuse')
        shell32 = ctypes.WinDLL('shell32', use_last_error=True)
        shell32.CommandLineToArgvW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]
        shell32.CommandLineToArgvW.restype = ctypes.POINTER(ctypes.c_wchar_p)
        count = ctypes.c_int()
        arguments = shell32.CommandLineToArgvW(process['command'], ctypes.byref(count))
        if not arguments:
            raise RuntimeError('Could not inspect the API command line')
        try:
            command = [arguments[index] for index in range(count.value)]
        finally:
            kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel32.LocalFree.argtypes = [ctypes.c_void_p]
            kernel32.LocalFree(ctypes.cast(arguments, ctypes.c_void_p))
        if process['path'].lower() != self.state['java'].lower() \
                or command != [self.state['java'], '-jar', str(self.home / 'server.jar')] \
                or (self.state.get('apiStarted') and process['started'] != self.state['apiStarted']):
            raise RuntimeError('Recorded PID is not the owned API; no process was stopped')
        return process

    def start_api(self):
        """2026-10-29: 보존한 DB·키와 비관리자 역할로 JAR를 시작한다. 사용: start·restart."""
        self.db_identity()
        if self.process_info():
            return
        port_free(self.state['apiPort'])
        jars = list((API / 'build/libs').glob('*.jar'))
        if len(jars) != 1:
            raise ValueError('Build exactly one API bootJar before starting')
        java = self.java()
        jar = self.home / 'server.jar'
        shutil.copyfile(jars[0], jar)
        values = self.read_secrets()
        environment = {**clean_environment(), **{k: v for k, v in values.items() if k.startswith('PAYSE_')},
            'SPRING_PROFILES_ACTIVE': 'database,auth,finance', 'PAYSE_AUTH_PEER_MODE': 'direct',
            'PAYSE_JDBC_URL': f"jdbc:postgresql://127.0.0.1:{self.state['pgPort']}/{DATABASE}",
            'PAYSE_DB_USER': LOGIN, 'PAYSE_DB_PASSWORD': values['apiPassword'],
            'PAYSE_DB_MAX_POOL_SIZE': '8', 'PAYSE_DB_CONNECTION_TIMEOUT_MS': '5000',
            'PAYSE_DB_VALIDATION_TIMEOUT_MS': '1000',
            'PAYSE_BIND_ADDRESS': '127.0.0.1', 'PAYSE_PORT': str(self.state['apiPort'])}
        with (self.home / 'api.log').open('ab') as log:
            process = subprocess.Popen([str(java), '-jar', str(jar)], cwd=self.home,
                env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                creationflags=FLAGS | subprocess.DETACHED_PROCESS)
        self.state.update(apiPid=process.pid, apiStarted=None, java=str(java),
                          jarSha256=hashlib.sha256(jar.read_bytes()).hexdigest())
        self.save()
        info = self.process_info(starting=True)
        if info is None:
            raise RuntimeError('API exited before process ownership could be recorded')
        self.state['apiStarted'] = info['started']
        self.save()
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('API stopped before readiness; inspect the private api.log')
            try:
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open(self.base_url + '/internal/health/live', timeout=2) as response:
                    if response.status == 200 and json.load(response).get('status') == 'UP':
                        return
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.4)
        self.stop_api()
        raise RuntimeError('API readiness timed out')

    @property
    def base_url(self):
        """2026-10-29: 외부 주소를 받지 않는 loopback URL이다. 사용: 준비 확인·HTTP 검사."""
        return f"http://127.0.0.1:{self.state['apiPort']}"

    def stop_api(self):
        """2026-10-29: 소유 검증한 API 프로세스만 정지한다. 사용: stop·restart."""
        info = self.process_info()
        if info:
            run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
                 f"Stop-Process -Id {int(info['pid'])} -ErrorAction Stop; "
                 f"Wait-Process -Id {int(info['pid'])} -Timeout 15 -ErrorAction SilentlyContinue"])
        self.state.update(apiPid=None, apiStarted=None)
        self.save()

    def restart_api(self):
        """2026-10-29: 세션·DB·키를 보존한 API 재시작 콜백이다. 사용: verify."""
        self.stop_api()
        self.start_api()

    def fingerprint(self):
        """2026-10-29: 변경 금지 원천 컬럼을 정렬해 지문만 반환한다. 사용: verify 전후."""
        collections = {
            'institutions': 'to_jsonb(t)', 'source_contexts': 'to_jsonb(t)',
            'financial_accounts': "to_jsonb(t) - 'included' - 'nickname'",
            'financial_cards': 'to_jsonb(t)', 'financial_transactions': 'to_jsonb(t)',
            'card_statements': 'to_jsonb(t)', 'statement_items': 'to_jsonb(t)',
            'transaction_references': 'to_jsonb(t)', 'transaction_relations': 'to_jsonb(t)'}
        digest = hashlib.sha256()
        for table, expression in collections.items():
            rows = self.sql(f'SELECT ({expression})::text FROM payse.{table} t ORDER BY ({expression})::text;')
            digest.update((table + '\n' + rows + '\n').encode('utf-8'))
        return digest.hexdigest()

    def verify(self):
        """2026-10-29: 이전 PASS를 재사용하지 않고 이번 실행 결과를 기록한다. 사용: verify CLI."""
        path = self.home / 'verification.json'
        started = datetime.now(timezone.utc).isoformat()
        path.write_text(json.dumps({'ok': False, 'status': 'RUNNING', 'startedAt': started}), encoding='utf-8')
        try:
            result = self.verify_checks()
        except Exception as failure:
            result = json.loads(path.read_text(encoding='utf-8'))
            result.update(ok=False, status='FAIL', startedAt=started, failureType=type(failure).__name__)
            path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            raise
        result.update(status='PASS', startedAt=started, finishedAt=datetime.now(timezone.utc).isoformat(),
                      jarSha256=self.state['jarSha256'])
        path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        return result

    def verify_checks(self):
        """2026-10-29: 실제 HTTP·재시작·최소 권한·원천 보존을 확인한다. 사용: verify CLI."""
        from dev_verify import verify, VerificationError
        self.db_identity()
        before = self.fingerprint()
        role = self.sql(f"SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolinherit "
            f"AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication "
            f"AND pg_has_role({quote(LOGIN)},'payse_runtime','MEMBER') "
            f"AND NOT pg_has_role({quote(LOGIN)},'payse_auth_owner','MEMBER') "
            f"FROM pg_roles WHERE rolname={quote(LOGIN)};")
        if role != 't':
            raise RuntimeError('API login role exceeds its boundary')
        try:
            result = verify(self.base_url, API / 'fixtures/generated', self.restart_api)
        except VerificationError as failure:
            report = failure.report or {}
            report['failure'] = str(failure)
            (self.home / 'verification.json').write_text(
                json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            raise
        if before != self.fingerprint():
            raise RuntimeError('Financial source changed during HTTP verification')
        stored = self.stored_fingerprint()
        self.stop_api()
        self.stop_db()
        self.start_db()
        self.start_api()
        if stored != self.stored_fingerprint() or before != self.fingerprint():
            raise RuntimeError('Stored state changed across the owned database restart')
        result.update(sourceUnchanged=True, runtimeRoleVerified=True,
                      databaseRestartPreserved=True, serverVersion=self.state['serverVersion'], apiUrl=self.base_url)
        (self.home / 'verification.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        return result

    def stored_fingerprint(self):
        """2026-10-29: 설정·영수증·세션의 DB 재시작 보존을 지문으로 확인한다. 사용: verify."""
        digest = hashlib.sha256()
        for table in ('users', 'user_attributes', 'institution_links', 'obligations', 'reserves',
                      'reserve_allocations', 'settlement_links', 'write_receipts', 'demo_sessions'):
            rows = self.sql(f'SELECT to_jsonb(t)::text FROM payse.{table} t ORDER BY to_jsonb(t)::text;')
            digest.update((table + '\n' + rows + '\n').encode('utf-8'))
        return digest.hexdigest()

    def status(self):
        """2026-10-29: 비밀 없는 실행 상태만 반환한다. 사용: status CLI."""
        running = self.db_running()
        if running:
            self.db_identity()
        return {'home': str(self.home), 'database': DATABASE, 'postgresRunning': running,
                'postgresPort': self.state['pgPort'], 'apiRunning': self.process_info() is not None,
                'apiUrl': self.base_url, 'phase': self.state['phase']}


def main():
    """2026-10-29: 초기화와 반복 실행을 명시적으로 구분한다. 사용: 직접 CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('init', 'start', 'stop', 'restart', 'status', 'verify'))
    parser.add_argument('--home', type=Path, default=Path(os.environ.get('LOCALAPPDATA', '.')) / 'PAYSE/development/api-v3')
    parser.add_argument('--pg-bin', type=Path)
    parser.add_argument('--pg-port', type=int, default=15432)
    parser.add_argument('--api-port', type=int, default=18080)
    args = parser.parse_args()
    if os.name != 'nt':
        raise ValueError('This local manager is for Windows only')
    server = DevServer(args.home)
    if args.command == 'init':
        if args.pg_bin is None:
            raise ValueError('--pg-bin is required for initialization')
        server.init(args.pg_bin, args.pg_port, args.api_port)
    else:
        server.load()
    if args.command in ('start', 'restart'):
        if args.command == 'restart':
            server.stop_api()
        server.start_db()
        server.start_api()
    elif args.command == 'stop':
        server.stop_api()
        server.stop_db()
    elif args.command == 'verify':
        print(json.dumps(server.verify(), ensure_ascii=False, indent=2))
    print(json.dumps(server.status(), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, OSError, KeyError, subprocess.TimeoutExpired) as error:
        # 실패 인자·SQL·HTTP 원문에는 자격이나 금융 값이 포함될 수 있어 출력하지 않는다.
        print('Development operation failed: ' + type(error).__name__ + '. No existing DB was selected.', file=sys.stderr)
        sys.exit(1)
