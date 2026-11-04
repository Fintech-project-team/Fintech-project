"""2026-11-04: 새 폐기 DB와 실제 Spring API를 가진 무료 모의 공급자 서버. 사용: CLI.

기존 DB·서버·방화벽을 수정하지 않는다. 운영 설정/키는 읽지 않으며 loopback에만 바인딩한다.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
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

DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parents[1]
ROOT = API.parents[1]
sys.path.insert(0, str(API / 'database'))
sys.path.insert(0, str(API))
from auth_test_support import Cluster, PROCESS_FLAGS, quote
from test_analysis_service import create_database

DATABASE = 'payse_auth_test_protocol'
MARKER = 'payse-protocol-mock-1'


def java_path():
    """2026-11-04: 설정한 JDK 또는 PATH의 Java만 사용한다. 사용: prepare_classpath, serve."""
    executable = 'java.exe' if os.name == 'nt' else 'java'
    home = os.environ.get('JAVA_HOME')
    java = Path(home)/'bin'/executable if home else Path(shutil.which('java') or '')
    if not java.is_file(): raise ValueError('JDK 21 is required (JAVA_HOME or PATH)')
    return str(java)


def environment():
    """2026-11-04: 운영/유료 공급자 연결 설정을 자식에 전달하지 않는다. 사용: prepare_classpath, serve."""
    result = {key:value for key,value in os.environ.items()
              if not key.upper().startswith(('PAYSE_','SPRING_','PG','OPENAI_','SERVER_'))}
    result.update(PYTHONDONTWRITEBYTECODE='1', PYTHONIOENCODING='utf-8',
                  PAYSE_PROTOCOL_MOCK='isolated')
    return result


def prepare_classpath():
    """2026-11-04: 테스트 전용 실행 클래스를 현재 소스로 컴파일한다. 사용: serve."""
    java_path()
    launcher = ['cmd.exe','/d','/c','gradlew.bat'] if os.name=='nt' else [str(API/'gradlew')]
    completed = subprocess.run(launcher+['protocolClasspath','apiDocsCheck','--no-daemon',
        '--max-workers=1','--console=plain','-Dorg.gradle.jvmargs=-Xmx512m'], cwd=API,
        env=environment(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding='utf-8', errors='replace', timeout=240, creationflags=PROCESS_FLAGS)
    if completed.returncode:
        # 이 단계에는 실행 자격/원천/키가 아직 없고 컴파일 진단만 있다.
        sys.stderr.write(completed.stdout[-6000:])
        raise RuntimeError('Protocol test classpath compilation failed')
    return (API/'build/protocol-classpath.txt').read_text(encoding='utf-8').strip()


def prepare(cluster, port, scenario, delay):
    """2026-11-04: 동일 인증/RLS의 합성 원천·임시 로그인·최소권한을 새 DB에만 준비한다. 사용: serve."""
    from reference_data.export_sql import export as institutions
    from testing.scenarios.export_state import export as scenario_sql
    create_database(cluster, API/'database', DATABASE)
    cluster.sql(institutions(),DATABASE)
    sql = scenario_sql(API/'fixtures/generated-v4',['demo-life'])
    sql = sql.replace('SET CONSTRAINTS ALL IMMEDIATE;', 'ANALYZE;\nSET CONSTRAINTS ALL IMMEDIATE;')
    with cluster.connect(DATABASE,name='protocol_fixture') as connection:
        connection.sql("SET statement_timeout='120s';\n"+sql,timeout=130)
    source=json.loads((API/'fixtures/generated-v4/snapshots/demo-life.json').read_text(encoding='utf-8'))
    owner=source['userId']
    seeds=json.loads((API/'fixtures/generated-v4/server-seeds.json').read_text(encoding='utf-8'))
    user=next(row for row in seeds['users'] if row['userId']==owner)
    login='payse_protocol_'+uuid.uuid4().hex;password=secrets.token_urlsafe(48)
    code=f'{secrets.randbelow(1_000_000):06d}';code_key=secrets.token_bytes(32)
    verifier='hmac-sha256:protocol-test:'+hmac.new(code_key,
        ('payse-code-v1\n'+owner+'\n'+code).encode(),hashlib.sha256).hexdigest()
    cluster.sql(f'''
        CREATE ROLE {login} LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE
          PASSWORD {quote(password)};
        GRANT payse_runtime TO {login};
        GRANT CONNECT ON DATABASE {DATABASE} TO {login};
        UPDATE payse.users SET code_verifier={quote(verifier)} WHERE id={quote(owner)};
    ''',DATABASE)
    settings={
        'server.address':'127.0.0.1','server.port':str(port),'spring.main.banner-mode':'off',
        'PAYSE_AUTH_PEER_MODE':'direct','PAYSE_AUTH_CODE_KEY_ID':'protocol-test',
        'PAYSE_AUTH_CODE_KEY_BASE64':base64.b64encode(code_key).decode(),
        'PAYSE_AUTH_LIMIT_KEY_BASE64':base64.b64encode(secrets.token_bytes(32)).decode(),
        'PAYSE_FINANCE_CURSOR_KEY_BASE64':base64.b64encode(secrets.token_bytes(32)).decode(),
        'PAYSE_JDBC_URL':'jdbc:postgresql://127.0.0.1:'+cluster.env['PGPORT']+'/'+DATABASE,
        'PAYSE_DB_USER':login,'PAYSE_DB_PASSWORD':password,'PAYSE_DB_MAX_POOL_SIZE':'4',
        'PAYSE_DB_CONNECTION_TIMEOUT_MS':'5000','PAYSE_DB_VALIDATION_TIMEOUT_MS':'1000',
        'payse.protocol.scenario':scenario,'payse.protocol.delay-ms':str(delay),
    }
    config=cluster.work/'mock.private.properties'
    config.write_text(''.join(key+'='+value+'\n' for key,value in settings.items()),encoding='utf-8')
    details=dict(format=MARKER,baseUrl=f'http://127.0.0.1:{port}',scenario=scenario,
        login=dict(name=user['name'],phone=user['phone'],code=code))
    (cluster.work/'connection.private.json').write_text(
        json.dumps(details,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return config,details,source


def healthy(base_url):
    """2026-11-04: 별도 loopback 서버의 공개 생존 경로만 조회한다. 사용: serve."""
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(base_url+'/internal/health/live',timeout=1) as response:
            return response.status==200
    except (urllib.error.URLError,TimeoutError): return False


def serve(args):
    """2026-11-04: 자신이 만든 Java/DB만 소유하고 종료한다. 사용: main."""
    classpath=prepare_classpath()
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',args.port));port=listener.getsockname()[1]
    with Cluster(args.pg_bin,args.work_dir) as cluster:
        config,details,source=prepare(cluster,port,args.scenario,args.delay_ms)
        child=None
        try:
            with (cluster.work/'api.log').open('w',encoding='utf-8') as log:
                child=subprocess.Popen([java_path(),'-Xmx256m','-cp',classpath,
                    'com.payse.api.analysis.service.ProtocolMockServer',str(config)],
                    cwd=API,env=environment(),stdout=log,stderr=subprocess.STDOUT,
                    creationflags=PROCESS_FLAGS)
                deadline=time.monotonic()+60
                while not healthy(details['baseUrl']):
                    if child.poll() is not None: raise RuntimeError('Mock API startup failed; inspect private api.log')
                    if time.monotonic()>deadline: raise RuntimeError('Mock API startup timed out')
                    time.sleep(0.2)
                from mock_smoke import current_samples, run
                samples=current_samples(details,source)
                (cluster.work/'requests.json').write_text(json.dumps(samples,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
                (cluster.work/'ready.json').write_text(json.dumps(dict(format=MARKER,
                    baseUrl=details['baseUrl'],pid=child.pid,scenario=args.scenario)),encoding='utf-8')
                print('READY: '+details['baseUrl']+'; private connection: '+str(cluster.work/'connection.private.json'),flush=True)
                if args.smoke:
                    summary=run(details,samples,cluster)
                    (cluster.work/'smoke.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
                    print('PASS: authenticated protocol HTTP smoke; external provider calls=0',flush=True)
                else:
                    deadline=time.monotonic()+args.max_seconds
                    while not (cluster.work/'stop.request').exists() and time.monotonic()<deadline:
                        if child.poll() is not None: raise RuntimeError('Mock API exited unexpectedly')
                        time.sleep(0.25)
        finally:
            if child is not None and child.poll() is None:
                child.terminate()
                try: child.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    child.kill();child.wait(timeout=5)
            (cluster.work/'ready.json').unlink(missing_ok=True)
            (cluster.work/'stopped.json').write_text(json.dumps(dict(format=MARKER,stopped=True)),encoding='utf-8')
            cluster.report.update(mockOnly=True,externalProviderCalls=0,operatingServerChanged=False)


def main():
    """2026-11-04: 모의 실행과 소유 작업의 종료 요청만 제공한다. 사용: CLI."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir',required=True,type=Path)
    parser.add_argument('--pg-bin',type=Path)
    parser.add_argument('--port',type=int,default=43180)
    parser.add_argument('--scenario',choices=['success','unknown','invalid_once','timeout_once'],default='success')
    parser.add_argument('--delay-ms',type=int,default=250)
    parser.add_argument('--max-seconds',type=int,default=28800)
    parser.add_argument('--smoke',action='store_true')
    parser.add_argument('--stop',action='store_true')
    args=parser.parse_args()
    work=args.work_dir.resolve()
    if not work.is_relative_to((ROOT/'.harness').resolve()) or work==(ROOT/'.harness').resolve():
        parser.error('Use a new directory below repository .harness (private, Git ignored)')
    args.work_dir=work
    if args.stop:
        ready=json.loads((work/'ready.json').read_text(encoding='utf-8'))
        if ready.get('format')!=MARKER: raise ValueError('Not an owned protocol mock directory')
        (work/'stop.request').write_text('stop\n',encoding='ascii');return
    if args.pg_bin is None or not 0<=args.port<=65535 or not 0<=args.delay_ms<=10000 or not 1<=args.max_seconds<=28800:
        parser.error('Require --pg-bin, valid port/delay and max-seconds <= 28800')
    serve(args)


if __name__=='__main__':
    try: main()
    except KeyboardInterrupt: print('Stopped owned protocol mock',file=sys.stderr)
