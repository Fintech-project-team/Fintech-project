"""2026-11-02: 새 PC의 전용 서버 설치·기동·수동 배포를 관리한다. DB·방화벽·HTTPS를 자동 변경하지 않는다."""
import argparse
import base64
from datetime import datetime, timezone
import getpass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from urllib.parse import parse_qs, urlsplit
from urllib.request import ProxyHandler, build_opener
import uuid

import javaproperties
import psutil

import ai_setup
import release_server as release
import server_runtime as runtime


FORMAT = 'payse-portable-install-v1'
TOOLS = ('portable_server.py', 'server_runtime.py', 'release_server.py', 'package_server.py', 'ai_setup.py', 'requirements.txt')
PROFILES = ('database', 'auth', 'finance', 'salary-notices')
SECRET_KEYS = ('PAYSE_DB_PASSWORD', 'PAYSE_AUTH_CODE_KEY_BASE64',
               'PAYSE_AUTH_LIMIT_KEY_BASE64', 'PAYSE_FINANCE_CURSOR_KEY_BASE64')


def java_major(executable):
    """2026-11-02: 선택한 Java 실행 파일의 major만 확인한다. 사용: 환경 탐지·기동 전 점검."""
    result = subprocess.run([str(executable), '-version'], capture_output=True, text=True, timeout=10,
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    match = re.search(r'version "(\d+)', result.stdout + result.stderr)
    return int(match[1]) if result.returncode == 0 and match else None


def detect_java():
    """2026-11-02: 환경과 OS 표준 설치 위치에서 Java 21만 후보로 찾는다. 설치하거나 설정을 변경하지 않는다."""
    executable = 'java.exe' if os.name == 'nt' else 'java'
    candidates = []
    if os.environ.get('JAVA_HOME'):
        candidates.append(Path(os.environ['JAVA_HOME']) / 'bin' / executable)
    found = shutil.which('java')
    if found:
        candidates.append(Path(found))
    if os.name == 'nt':
        program_files = Path(os.environ.get('ProgramFiles', 'C:/Program Files'))
        candidates.extend(program_files.glob('Eclipse Adoptium/jdk-21*/bin/java.exe'))
        candidates.extend(program_files.glob('Java/jdk-21*/bin/java.exe'))
    elif sys.platform == 'darwin':
        candidates.extend(Path('/Library/Java/JavaVirtualMachines').glob('*/Contents/Home/bin/java'))
    else:
        candidates.extend(Path('/usr/lib/jvm').glob('*/bin/java'))
    for candidate in dict.fromkeys(candidates):
        try:
            if candidate.is_file() and java_major(candidate) == 21:
                return str(candidate.resolve())
        except (OSError, subprocess.TimeoutExpired):
            continue
    return None


def doctor():
    """2026-11-02: OS·Java·psql·주소 후보·메모리를 조회한다. 외부 공개를 허가하거나 수행하지 않는다."""
    return {'platform': sys.platform, 'python': sys.version.split()[0], 'java21': detect_java(),
            'psql': shutil.which('psql'), 'githubCli': shutil.which('gh'),
            'addressCandidates': runtime.addresses(), 'apiBindAddress': '127.0.0.1',
            'memory': runtime.memory(), 'networkChangesMade': False}


def read_properties(path):
    """2026-11-02: Java와 같은 escape 규칙으로 현지 설정을 읽는다. 사용: 설치·호환성 검사."""
    return release.properties(path)


def validate_settings(settings, properties, schema):
    """2026-11-02: 필수 설정·키·단위와 현재 지원 프로필을 검증한다. 기본 키 생성이나 프로필 활성화는 하지 않는다."""
    profiles = [part.strip() for part in properties.get('spring.profiles.active', '').split(',')]
    if (schema.get('format') != 'payse-schema-prerequisites-v1'
            or set(profiles) not in (set(PROFILES), set(PROFILES) | {'analysis', 'gamma-local'})
            or set(profiles) - set(schema['supportedProfiles'])):
        raise ValueError('Use the base profiles or the explicitly configured analysis,gamma-local extension')
    ai_setup.validate(properties)
    if properties.get('PAYSE_BIND_ADDRESS') != '127.0.0.1':
        raise ValueError('Keep the API on loopback; configure approved HTTPS separately')
    if properties.get('spring.config.import'):
        raise ValueError('New portable installations require a self-contained private properties file')
    for key in (*SECRET_KEYS, 'PAYSE_JDBC_URL', 'PAYSE_DB_USER', 'PAYSE_AUTH_CODE_KEY_ID'):
        if not properties.get(key):
            raise ValueError('Required server configuration is missing')
    keys = []
    for name in SECRET_KEYS[1:]:
        value = properties[name]
        try:
            raw = base64.b64decode(value, validate=True)
        except ValueError as error:
            raise ValueError('A configured key is not canonical Base64') from error
        if len(raw) != 32 or base64.b64encode(raw).decode('ascii') != value:
            raise ValueError('Each configured key must be canonical Base64 for 32 bytes')
        keys.append(raw)
    if len(set(keys)) != len(keys):
        raise ValueError('Authentication, rate-limit and cursor keys must be different')
    port = int(properties.get('PAYSE_PORT', '0'))
    heap = int(settings.get('deployment.maxHeapMiB', '0'))
    minimum = int(settings.get('deployment.minFreeGiB', '0'))
    if not 1024 <= port <= 65535 or not 512 <= heap <= 4096 or not 4 <= minimum <= 32:
        raise ValueError('Port/memory configuration is outside the reviewed ranges')
    if minimum < heap / 1024 + 2:
        raise ValueError('Free memory threshold must leave at least 2 GiB beyond the Java heap')
    if properties.get('PAYSE_AUTH_PEER_MODE') not in ('direct', 'loopback-proxy'):
        raise ValueError('Unsupported peer mode')
    for name in ('PAYSE_DB_MAX_POOL_SIZE', 'PAYSE_DB_CONNECTION_TIMEOUT_MS', 'PAYSE_DB_VALIDATION_TIMEOUT_MS'):
        if int(properties.get(name, '0')) <= 0:
            raise ValueError('Configure a positive DB pool and timeout budget')
    return port, heap, minimum


def schema_query(schema):
    """2026-11-02: 원천 행을 읽거나 업무 함수를 실행하지 않는 catalog 전용 SQL을 만든다. 사용: database_check."""
    conditions = ["NOT rolsuper AND NOT rolbypassrls AND pg_has_role(session_user, 'payse_runtime', 'member')"]
    for table in schema['tables']:
        if not re.fullmatch(r'[a-z_]+', table):
            raise ValueError('Invalid schema table')
        conditions.append(f"to_regclass('payse.{table}') IS NOT NULL")
    for column in schema['columns']:
        if not re.fullmatch(r'[a-z_]+\.[a-z_]+', column):
            raise ValueError('Invalid schema column')
        table, name = column.split('.')
        conditions.append("EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid="
                          f"to_regclass('payse.{table}') AND attname='{name}' AND NOT attisdropped)")
    for function in schema['functions']:
        if not re.fullmatch(r'[a-z_]+', function):
            raise ValueError('Invalid schema function')
        conditions.append("EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid "
                          f"WHERE n.nspname='payse' AND p.proname='{function}')")
    if 'analysisPolicy' in schema:
        project, version = schema['analysisPolicy']
        if any(not re.fullmatch(r'[A-Za-z0-9_.-]{1,120}', value) for value in (project, version)):
            raise ValueError('Invalid analysis policy identity')
        policy = f"payse.analysis_cost_policy('{project}', '{version}')"
        for name, value in (('model', 'gpt-6-luna'), ('inputLimit', '12000'),
                            ('outputLimit', '4000'), ('kmsMicros', '0')):
            conditions.append(f"({policy}->>'{name}')='{value}'")
    return ("BEGIN READ ONLY; SET LOCAL ROLE payse_runtime; SELECT CASE WHEN (" + ') AND ('.join(conditions)
            + ") THEN 'READY' ELSE 'INCOMPATIBLE' END FROM pg_roles WHERE rolname=session_user; ROLLBACK;")


def database_target(jdbc):
    """2026-11-05: Java와 같은 단일 호스트·명시 TLS URL만 검사하고 자격은 반환하지 않는다."""
    try:
        return parse_database_target(jdbc)
    except (ValueError, TypeError, AttributeError):
        raise ValueError('Database URL must use one explicit host and remote TLS certificate verification') from None


def parse_database_target(jdbc):
    """2026-11-05: 내부 파싱 예외는 database_target에서 값 없는 진단으로 바꾼다."""
    if not jdbc.startswith('jdbc:postgresql://'):
        raise ValueError('Expected a PostgreSQL JDBC URL')
    if any(ord(char) <= 32 or ord(char) == 127 for char in jdbc):
        raise ValueError('Unsupported database URL')
    target = urlsplit(jdbc[5:])
    database = target.path.removeprefix('/')
    authority = r'(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(?::[0-9]{1,5})?'
    if (not re.fullmatch(authority, target.netloc) or target.port == 0
            or '#' in jdbc or not re.fullmatch(r'[A-Za-z0-9_]+', database)):
        raise ValueError('Unsupported database URL')
    allowed = {'sslmode', 'sslrootcert', 'sslcert', 'sslkey'}
    fields = target.query.split('&') if '?' in jdbc else []
    if any(field.count('=') != 1 or field.split('=')[0] not in allowed for field in fields):
        raise ValueError('Only explicit PostgreSQL TLS query options are supported')
    query = parse_qs(target.query, strict_parsing=True, keep_blank_values=True)
    if (any(len(v) != 1 or not v[0].strip() or any(ord(c) < 32 or ord(c) == 127 for c in v[0])
            for v in query.values())):
        raise ValueError('Only explicit PostgreSQL TLS query options are supported')
    if target.hostname not in ('127.0.0.1', 'localhost', '::1') and query.get('sslmode') != ['verify-full']:
        raise ValueError('Remote database connections require sslmode=verify-full')
    return target, database, query


def database_check(settings, properties, schema):
    """2026-11-02: 지정한 기존 DB를 읽기 전용 검사한다. 2026-11-05: Java와 URL 검증 경계를 맞춘다."""
    target, database, query = database_target(properties['PAYSE_JDBC_URL'])
    environment = {key: value for key, value in os.environ.items() if not key.upper().startswith('PG')}
    environment.update(PGPASSWORD=properties['PAYSE_DB_PASSWORD'], PGCONNECT_TIMEOUT='5',
                       PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=1000')
    for key, value in query.items():
        environment['PG' + key.upper()] = value[0]
    result = subprocess.run([settings['server.psql'], '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1',
                             '-h', target.hostname, '-p', str(target.port or 5432),
                             '-U', properties['PAYSE_DB_USER'], '-d', database, '-c', schema_query(schema)],
                            env=environment, capture_output=True, text=True, timeout=12,
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    if result.returncode or result.stdout.strip() != 'READY':
        raise RuntimeError('Read-only database compatibility check failed; no migration was attempted')


def preflight(settings, properties, schema):
    """2026-11-02: Java·설정·DB·메모리 전제가 맞을 때만 설치·기동·교체를 허용한다."""
    port, heap, minimum = validate_settings(settings, properties, schema)
    if java_major(settings['server.java']) != 21:
        raise ValueError('Java 21 is required')
    available = runtime.memory()
    if min(available.values()) < minimum:
        raise RuntimeError('Insufficient physical or commit memory; server unchanged')
    checked_schema = dict(schema)
    if ai_setup.selected(properties):
        optional = schema.get('analysisPrerequisites')
        if not optional:
            raise ValueError('Release does not declare AI database prerequisites')
        checked_schema = {key: list(schema.get(key, [])) + list(optional.get(key, []))
                          for key in ('tables', 'columns', 'functions')}
        checked_schema['analysisPolicy'] = [properties[ai_setup.PREFIX + key] for key in ('project', 'pricing')]
    database_check(settings, properties, checked_schema)
    return {'port': port, 'maxHeapMiB': heap, 'memory': available, 'dbPrerequisites': 'PASS_READ_ONLY_CATALOG'}


def configure(directory):
    """2026-11-02: 환경 후보를 보여 주고 승인·숨긴 입력을 받아 Git 밖에 비공개 properties를 만든다."""
    detected = doctor()
    print(json.dumps(detected, indent=2))
    directory = runtime.outside_git(directory)
    if directory.exists():
        raise ValueError('Configuration directory must be new')
    if input('Create private configuration here? No firewall or DB changes. Type YES: ') != 'YES':
        raise RuntimeError('Configuration cancelled')
    java = input(f'Java 21 executable [{detected["java21"] or "required"}]: ').strip() or detected['java21']
    psql = input(f'psql executable [{detected["psql"] or "required"}]: ').strip() or detected['psql']
    if not java or not psql:
        raise ValueError('Install the missing tools with your system administrator, then configure again')
    settings = {
        'deployment.installRoot': str(runtime.outside_git(input('New dedicated server directory: ').strip())),
        'deployment.maxHeapMiB': input('Java maximum heap MiB [1024]: ').strip() or '1024',
        'deployment.minFreeGiB': input('Minimum free physical/commit GiB [4]: ').strip() or '4',
        'server.java': str(Path(java).resolve()), 'server.psql': str(Path(psql).resolve()),
        'github.repository': input('GitHub owner/repository: ').strip(),
        'github.branch': input('Release branch [develop]: ').strip() or 'develop',
        'github.token': getpass.getpass('Optional GitHub read token (blank uses gh login): '),
    }
    properties = {'spring.profiles.active': ','.join(PROFILES), 'PAYSE_BIND_ADDRESS': '127.0.0.1',
                  'PAYSE_PORT': input('API loopback port [8080]: ').strip() or '8080',
                  'PAYSE_JDBC_URL': input('Prepared database JDBC URL: ').strip(),
                  'PAYSE_DB_USER': input('Existing non-administrator DB login: ').strip(),
                  'PAYSE_AUTH_CODE_KEY_ID': input('Existing verifier key ID: ').strip(),
                  'PAYSE_DB_MAX_POOL_SIZE': input('DB pool connection budget: ').strip(),
                  'PAYSE_DB_CONNECTION_TIMEOUT_MS': input('DB connection timeout milliseconds: ').strip(),
                  'PAYSE_DB_VALIDATION_TIMEOUT_MS': input('DB validation timeout milliseconds: ').strip(),
                  'PAYSE_AUTH_PEER_MODE': 'direct'}
    for name in SECRET_KEYS:
        properties[name] = getpass.getpass(name + ' (existing value; not displayed): ')
    validate_settings(settings, properties, {'format': 'payse-schema-prerequisites-v1', 'supportedProfiles': PROFILES})
    runtime.private_directory(directory)
    if input('감마 전용 AI 성능 구성을 함께 준비할까요? 동의하면 YES: ').strip() == 'YES':
        ai_setup.configure(directory, properties)
    for name, values in (('deployment.properties', settings), ('server.properties', properties)):
        target = directory / name
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            javaproperties.dump(values, stream, timestamp=False)
    print('Private configuration created. Inspect the deployment plan before using --apply.')


def read_installation(home):
    """2026-11-02: 전용 설치 표식과 현재 JAR·설정 지문을 확인한다. 다른 서버 배치와 섞지 않는다."""
    home = runtime.outside_git(home).resolve(strict=True)
    state = json.loads((home / 'runtime.json').read_text(encoding='utf-8'))
    if state['format'] != FORMAT or state['home'] != str(home):
        raise ValueError('Not this portable installation; existing Windows launch.json uses its separate adapter')
    if (release.sha256(home / 'server.jar') != state['jarSha256']
            or release.sha256(home / 'server.properties') != state['configSha256']
            or release.sha256(home / 'release-schema.json') != state['schemaSha256']):
        raise ValueError('Installed JAR or server configuration changed outside deployment')
    settings = read_properties(home / 'deployment.properties')
    properties = read_properties(home / 'server.properties')
    schema = json.loads((home / 'release-schema.json').read_text(encoding='utf-8'))
    return home, state, settings, properties, schema


def health(port):
    """2026-11-02: 프록시 환경을 상속하지 않고 loopback 생존 응답을 확인한다. DB 기능 검증과 구분한다."""
    try:
        with build_opener(ProxyHandler({})).open(f'http://127.0.0.1:{port}/internal/health/live', timeout=2) as response:
            return response.status == 200 and json.load(response).get('status') == 'UP'
    except (OSError, ValueError):
        return False


def wait_healthy(state, port, timeout=60):
    """2026-11-02: 기록된 Java가 살아 있는 동안만 준비 응답을 기다린다. 사용: 시작·배포·복구."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if runtime.owned_process(state['process']) is None:
            raise RuntimeError('Owned Java exited before readiness')
        if runtime.owns_listener(state['process'], port) and health(port):
            return
        time.sleep(0.5)
    raise RuntimeError('API readiness timed out')


def start_locked(home, state, settings, properties):
    """2026-11-02: 기존 설정과 제한된 힙으로 Java를 시작하고 즉시 정체성을 기록한다. 호출자가 설치 잠금을 보유한다."""
    port = int(properties['PAYSE_PORT'])
    existing = runtime.owned_process(state.get('process'))
    if existing:
        wait_healthy(state, port)
        return
    if not runtime.port_free(port):
        raise RuntimeError('API port occupied by an unrelated process')
    ai_setup.probe(properties)
    heap = int(settings['deployment.maxHeapMiB'])
    argv = [settings['server.java'], '-Xms128m', f'-Xmx{heap}m', '-XX:MaxMetaspaceSize=384m',
            '-XX:ReservedCodeCacheSize=128m', '-XX:ActiveProcessorCount=2', '-jar', str(home / 'server.jar'),
            '--spring.config.additional-location=' + (home / 'server.properties').as_uri()]
    log = home / 'logs' / ('api-' + datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex + '.log')
    with log.open('xb') as output:
        state['process'] = runtime.launch(argv, home, output)
    runtime.write_json(home / 'runtime.json', state)
    try:
        wait_healthy(state, port)
    except Exception:
        runtime.stop(state['process'], home)
        state['process'] = None
        runtime.write_json(home / 'runtime.json', state)
        raise


def install(settings_path, package, commit, apply=False):
    """2026-11-02: 검증된 CI 묶음·현지 설정으로 새 디렉터리만 준비한다. 자동 기동·DB 생성·외부 공개는 하지 않는다."""
    settings_path, package = Path(settings_path).resolve(strict=True), Path(package).resolve(strict=True)
    runtime.outside_git(settings_path.parent)
    metadata = release.verify(package, commit, require_ci=apply)
    settings = read_properties(settings_path)
    properties_path = settings_path.parent / 'server.properties'
    properties = read_properties(properties_path)
    schema = json.loads((package / 'release-schema.json').read_text(encoding='utf-8'))
    home = runtime.outside_git(settings['deployment.installRoot'])
    if home.exists():
        raise ValueError('Install requires a new directory; use deploy for an existing portable server')
    checked = preflight(settings, properties, schema)
    if not runtime.port_free(checked['port']):
        raise RuntimeError('Chosen API port is occupied')
    if not apply:
        return dict(checked, status='COMPATIBLE', applied=False, destination=str(home))
    home = runtime.private_directory(home).resolve()
    for name in ('logs', 'releases', 'tools'):
        (home / name).mkdir(mode=0o700)
    for name in TOOLS:
        shutil.copyfile(package / name, home / 'tools' / name)
    for name in ('server.jar', 'release-schema.json'):
        shutil.copyfile(package / name, home / name)
    shutil.copyfile(settings_path, home / 'deployment.properties')
    shutil.copyfile(properties_path, home / 'server.properties')
    for name in ('deployment.properties', 'server.properties'):
        os.chmod(home / name, 0o600)
    state = {'format': FORMAT, 'home': str(home), 'sourceCommit': metadata['commit'],
             'jarSha256': release.sha256(home / 'server.jar'),
             'schemaSha256': release.sha256(home / 'release-schema.json'),
             'configSha256': release.sha256(home / 'server.properties'), 'process': None}
    runtime.write_json(home / 'runtime.json', state)
    return {'status': 'INSTALLED_STOPPED', 'home': str(home), 'applied': True}


def deploy_locked(home, state, settings, properties, package, metadata, starter=start_locked, stopper=runtime.stop):
    """2026-11-02: JAR·스키마 전제·메타를 백업하고 실패 시 이전 버전을 정상 재기동한다. 호출자가 잠금을 보유한다."""
    old = json.loads(json.dumps(state))
    backup = home / 'releases' / (datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex)
    backup.mkdir(mode=0o700)
    for name in ('server.jar', 'release-schema.json', 'runtime.json'):
        shutil.copyfile(home / name, backup / name)
    (backup / 'tools').mkdir(mode=0o700)
    for name in TOOLS:
        if (home / 'tools' / name).exists():
            shutil.copyfile(home / 'tools' / name, backup / 'tools' / name)
    stopped = False
    try:
        if (release.sha256(home / 'server.jar') != old['jarSha256']
                or release.sha256(package / 'server.jar') != metadata['sha256']['server.jar']
                or release.sha256(package / 'release-schema.json') != metadata['sha256']['release-schema.json']):
            raise ValueError('Installed or candidate files changed after preflight')
        stopper(state.get('process'), home)
        stopped = True
        if not runtime.port_free(properties['PAYSE_PORT']):
            raise RuntimeError('API port is not free after shutdown')
        pending = home / ('server.jar.' + uuid.uuid4().hex + '.next')
        shutil.copyfile(package / 'server.jar', pending)
        if release.sha256(pending) != metadata['sha256']['server.jar']:
            raise ValueError('Candidate changed after preflight')
        os.replace(pending, home / 'server.jar')
        pending_schema = home / ('schema.' + uuid.uuid4().hex + '.next')
        shutil.copyfile(package / 'release-schema.json', pending_schema)
        if release.sha256(pending_schema) != metadata['sha256']['release-schema.json']:
            raise ValueError('Candidate schema changed after preflight')
        os.replace(pending_schema, home / 'release-schema.json')
        for name in TOOLS:
            if release.sha256(package / name) != metadata['sha256'][name]:
                raise ValueError('Candidate control tool changed after preflight')
            shutil.copyfile(package / name, home / 'tools' / name)
        state.update(jarSha256=metadata['sha256']['server.jar'],
                     schemaSha256=metadata['sha256']['release-schema.json'],
                     sourceCommit=metadata['commit'], process=None)
        runtime.write_json(home / 'runtime.json', state)
        starter(home, state, settings, properties)
        return {'status': 'DEPLOYED', 'sourceCommit': state['sourceCommit'], 'backup': str(backup)}
    except Exception as failure:
        if not stopped:
            raise RuntimeError('Shutdown incomplete; installed files preserved') from failure
        try:
            current = json.loads((home / 'runtime.json').read_text(encoding='utf-8'))
            stopper(current.get('process'), home)
            if not runtime.port_free(properties['PAYSE_PORT']):
                raise RuntimeError('Recovery refused an occupied port')
            for name in ('server.jar', 'release-schema.json'):
                restore = home / (name + '.' + uuid.uuid4().hex + '.restore')
                shutil.copyfile(backup / name, restore)
                os.replace(restore, home / name)
            for name in TOOLS:
                saved = backup / 'tools' / name
                if saved.exists():
                    shutil.copyfile(saved, home / 'tools' / name)
                else:
                    (home / 'tools' / name).unlink(missing_ok=True)
            old['process'] = None
            runtime.write_json(home / 'runtime.json', old)
            starter(home, old, settings, properties)
        except Exception as recovery:
            raise RuntimeError('Deployment/recovery incomplete; preserve backups and inspect process identities') from recovery
        raise RuntimeError('Deployment failed; previous JAR restored and healthy') from failure


def operate(command, home, package=None, commit=None, apply=False):
    """2026-11-02: 모든 변경을 설치 잠금 안에서 수행하며 deploy 기본 동작은 호환성 점검이다. 사용: CLI."""
    home, state, settings, properties, schema = read_installation(home)
    with runtime.lock(home):
        home, state, settings, properties, schema = read_installation(home)
        if command == 'status':
            process = runtime.owned_process(state.get('process'))
            return {'status': 'RUNNING' if process else 'STOPPED', 'commit': state['sourceCommit'],
                    'health': bool(process and runtime.owns_listener(state['process'], properties['PAYSE_PORT'])
                                   and health(int(properties['PAYSE_PORT']))), 'memory': runtime.memory(),
                    'ai': ai_setup.status(properties, process.pid if process else None)}
        if command == 'stop':
            runtime.stop(state.get('process'), home)
            state['process'] = None
            runtime.write_json(home / 'runtime.json', state)
            return {'status': 'STOPPED', 'databaseChanged': False}
        if command == 'start':
            preflight(settings, properties, schema)
            start_locked(home, state, settings, properties)
            return {'status': 'RUNNING', 'commit': state['sourceCommit'],
                    'ai': ai_setup.status(properties, state['process']['pid'])}
        metadata = release.verify(package, commit, require_ci=apply)
        candidate_schema = json.loads((Path(package) / 'release-schema.json').read_text(encoding='utf-8'))
        checked = preflight(settings, properties, candidate_schema)
        if not apply:
            return dict(checked, status='COMPATIBLE', applied=False, commit=metadata['commit'])
        try:
            result = deploy_locked(home, state, settings, properties, Path(package), metadata)
        except Exception:
            runtime.write_json(home / 'deployment-result.json', {'status': 'FAILED', 'commit': metadata['commit']})
            raise
        runtime.write_json(home / 'deployment-result.json', result)
        return result


def main():
    """2026-11-02: 설치·배포는 --apply로 명시 승인하며 시스템 설치·방화벽 권한은 자동 요청/승격하지 않는다."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('doctor')
    config = commands.add_parser('configure')
    config.add_argument('--directory', required=True, type=Path)
    setup = commands.add_parser('install')
    setup.add_argument('--properties', required=True, type=Path)
    for name in ('start', 'stop', 'status', 'deploy'):
        sub = commands.add_parser(name)
        sub.add_argument('--home', required=True, type=Path)
        if name == 'deploy':
            deploy_parser = sub
    for sub in (setup, deploy_parser):
        sub.add_argument('--package', required=True, type=Path)
        sub.add_argument('--commit', required=True)
        sub.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'doctor':
            result = doctor()
        elif args.command == 'configure':
            configure(args.directory)
            return 0
        elif args.command == 'install':
            result = install(args.properties, args.package, args.commit, args.apply)
        else:
            result = operate(args.command, args.home, getattr(args, 'package', None),
                             getattr(args, 'commit', None), getattr(args, 'apply', False))
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError, psutil.Error) as error:
        print(f'Server operation failed ({type(error).__name__}). No forced kill, DB migration or network change was performed.', file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
