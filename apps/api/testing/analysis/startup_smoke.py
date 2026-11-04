"""2026-11-04: 실제 배포 JAR의 최초/반복/손상 복구 기동. 폐기용 DB, 합성 키, 유료 호출 0."""
import argparse
import base64
import json
from pathlib import Path
import secrets
import socket
import sys
import tempfile

from testing.analysis.gamma_local import API, ROOT, Cluster, prepare, DATABASE

sys.path.insert(0, str(API / 'tools'))
import ai_setup
import portable_server
import server_runtime
import javaproperties


def main():
    """2026-11-04: 자신이 만든 PostgreSQL과 Java만 시작/정지하고 기존 서비스는 건드리지 않는다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--jar', type=Path, required=True)
    parser.add_argument('--java', type=Path, required=True)
    args = parser.parse_args()
    args.jar = args.jar.resolve(strict=True)
    args.java = args.java.resolve(strict=True)
    source = json.loads(args.source.read_text(encoding='utf-8'))
    if min(server_runtime.memory().values()) < 4:
        raise RuntimeError('Insufficient memory for isolated startup verification')
    with Cluster(args.pg_bin, args.work_dir) as cluster, tempfile.TemporaryDirectory(prefix='payse-ai-startup-') as folder:
        home = server_runtime.private_directory(Path(folder) / 'server')
        identity = None
        try:
            database = prepare(cluster, source, 0, evaluation=True)
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            (home / 'master.key').write_bytes(secrets.token_bytes(32))
            (home / 'llm.properties').write_text(javaproperties.dumps({
                'enabled': 'true', 'provider': 'openai', 'model': 'gpt-6-luna',
                'reasoningEffort': 'none', 'apiKey': 'synthetic-startup-key-no-external-calls'},
                timestamp=False), encoding='utf-8')
            properties = {'spring.profiles.active': 'database,auth,finance,analysis,gamma-local',
                          'PAYSE_BIND_ADDRESS': '127.0.0.1', 'PAYSE_PORT': str(port),
                          'PAYSE_JDBC_URL': database['PAYSE_GAMMA_JDBC_URL'],
                          'PAYSE_DB_USER': database['PAYSE_GAMMA_DB_USER'],
                          'PAYSE_DB_PASSWORD': database['PAYSE_GAMMA_DB_PASSWORD'],
                          'PAYSE_DB_MAX_POOL_SIZE': '5', 'PAYSE_DB_CONNECTION_TIMEOUT_MS': '5000',
                          'PAYSE_DB_VALIDATION_TIMEOUT_MS': '1000', 'PAYSE_AUTH_CODE_KEY_ID': 'startup-test',
                          'PAYSE_AUTH_PEER_MODE': 'direct',
                          'payse.gamma-local.enabled': 'true', 'payse.gamma-local.llm-file': str(home / 'llm.properties'),
                          'payse.gamma-local.key-file': str(home / 'master.key'),
                          'payse.gamma-local.state-directory': str(home),
                          'payse.gamma-local.project': 'gamma-local-test',
                          'payse.gamma-local.pricing': 'gamma-local-upper-20261103',
                          'payse.gamma-local.source-version': source['sourceVersion']}
            for key in portable_server.SECRET_KEYS[1:]:
                properties[key] = base64.b64encode(secrets.token_bytes(32)).decode()
            (home / 'server.properties').write_text(javaproperties.dumps(properties, timestamp=False), encoding='utf-8')
            observations = []
            for run in range(3):
                if run == 2:
                    (home / 'ai-profile.json').write_text('{}', encoding='utf-8')
                argv = [str(args.java.resolve()), '-Xms128m', '-Xmx512m', '-XX:MaxMetaspaceSize=256m',
                        '-XX:ActiveProcessorCount=2', '-jar', str(args.jar.resolve()),
                        '--spring.config.additional-location=' + (home / 'server.properties').as_uri()]
                with (cluster.work / f'boot-{run}.log').open('xb') as log:
                    identity = server_runtime.launch(argv, home, log)
                portable_server.wait_healthy({'process': identity}, port)
                result = ai_setup.status(properties, identity['pid'])
                if not result['runtimeReady'] or result['preparation'] != 'READY':
                    raise AssertionError('Packaged AI did not become ready')
                observations.append(result)
                server_runtime.stop(identity, home)
                identity = None
            if (observations[0]['preparedAt'] != observations[1]['preparedAt']
                    or not observations[1]['preparationReused']
                    or [row['preparationCount'] for row in observations] != [1, 1, 2]):
                raise AssertionError('Preparation did not reuse or repair correctly')
            calls = int(cluster.sql('SELECT count(*) FROM payse.analysis_cost_calls;', DATABASE)[0])
            if calls or any(row['analysisValidatedAt'] for row in observations):
                raise AssertionError('Startup unexpectedly performed an analysis')
            result = {'passed': True, 'starts': 3, 'reusedOnSecondStart': True,
                      'corruptProfileRepaired': True, 'providerCalls': calls,
                      'syntheticCredentialOnly': True, 'runtimeStatusVerified': True,
                      'preparationCounts': [1, 1, 2], 'memory': server_runtime.memory()}
            (cluster.work / 'startup-summary.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
            print(json.dumps(result))
        finally:
            if identity:
                server_runtime.stop(identity, home)


if __name__ == '__main__':
    main()
