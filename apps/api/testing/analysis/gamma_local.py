"""2026-11-03: 감마 합성 원천의 명시적 실제 LLM·로컬 키 검증. 사용: CLI.

기존 DB 주소를 받지 않는다. 실제 호출은 --live를 요구하며 자동 재시도하지 않는다.
비밀·모델 원문 대신 검증 상태·토큰·보수 비용 집계만 남긴다.
"""
from pathlib import Path
import argparse
import copy
import getpass
import json
import os
import secrets
import subprocess
import sys
import uuid

API = Path(__file__).resolve().parents[2]
ROOT = API.parents[1]
sys.path.insert(0, str(API))
sys.path.insert(0, str(API / 'database'))
sys.path.insert(0, str(API / 'fixtures'))
from auth_test_support import Cluster, PROCESS_FLAGS, quote
from test_analysis_service import create_database
from testing.scenarios.gamma_year import build
from testing.scenarios.export_state import state_rows
from export_sql import financial_rows, load_sources, render
from reference_data.export_sql import export as institution_sql

DATABASE = 'payse_auth_test_gamma_local'
PROJECT = 'gamma-local-test'
VERSION = 'gamma-local-upper-20261103'
RUN_RESERVE = 1_000_000_000  # 1,000 KRW; unresolved runs retain this reservation.
LIMIT = 45_000_000_000
FIELDS = ('transactionId', 'recordKind', 'direction', 'status', 'reflectionReason',
          'merchantName', 'description', 'originalTransactionId')


def inputs(source):
    """2026-11-03: 정답을 읽지 않고 ID·소유자·원천 사실을 대조한 세 검증 입력을 만든다."""
    base = {'contractVersion': 'PAYSE-ANALYSIS-1', 'semanticTaskKind': 'transactionMeaning',
            'context': {key: source[key] for key in
                        ('schemaVersion', 'dataVersion', 'sourceVersion', 'ruleVersion', 'asOf')},
            'items': [], 'transactions': [], 'relations': [], 'unavailableReferences': [],
            'currentClassifications': [], 'candidates': []}
    base['context'].update(inputRevision=1, localSessionEpoch=1, selectedAccountIds=[])
    base['context']['schemaVersion'] = 'PAYSE-API-0.6-4'
    by_ref = {row['sourceRef']: row for row in source['transactions']}
    cases = []
    selections = (
        ('salary', [f'2026-{month:02}-15/3' for month in (8, 9, 10)]),
        ('transfer-insufficient', ['2026-10-20/3', '2026-10-20/4']),
        ('recurring', [f'2026-{month:02}-03/2' for month in (8, 9, 10)]),
    )
    for name, refs in selections:
        rows = [by_ref['fixture/gamma-year/1/' + ref] for ref in refs]
        if any(row['userId'] != source['userId'] for row in rows):
            raise ValueError('Gamma evidence ownership changed')
        request = copy.deepcopy(base)
        ids = [row['transactionId'] for row in rows]
        target = ids[-1] if name == 'salary' else ids[0]
        item_key = str(uuid.uuid5(uuid.NAMESPACE_URL, 'gamma-local/' + name))
        request['transactions'] = [{key: row[key] for key in FIELDS} for row in rows]
        request['items'] = [{'itemKey': item_key, 'targetTransactionId': target,
                             'candidateKey': None, 'evidenceTransactionIds': ids}]
        if name == 'recurring':
            if any(row['amountKRW'] != 55000 or row['direction'] != 'out' for row in rows):
                raise ValueError('Reviewed recurring evidence changed')
            request['semanticTaskKind'] = 'recurringMeaning'
            request['items'][0].update(targetTransactionId=None, candidateKey=item_key)
            request['candidates'] = [{'candidateKey': item_key,
                'sourceVersion': source['sourceVersion'], 'ruleVersion': source['ruleVersion'],
                'evidenceTransactionIds': ids, 'normalizedName': rows[0]['merchantName'],
                'suggestedAmountKRW': 55000, 'suggestedDay': 3,
                'features': {'occurrenceCount': 3, 'observedMonths': ['2026-08', '2026-09', '2026-10'],
                    'dayWithinRule': True, 'amountWithinRule': True, 'hasUnresolvedReversal': False}}]
        cases.append({'name': name, 'input': request})
    return cases


def private_directory(path):
    """2026-11-03: 키·실행 장부는 현재 사용자에게만 허용하는 Git 제외 폴더에 둔다."""
    path.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError('Private directory cannot be a link')
    if os.name == 'nt':
        result = subprocess.run(['icacls', str(path), '/inheritance:r', '/grant:r',
            getpass.getuser() + ':(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'],
            capture_output=True, creationflags=PROCESS_FLAGS)
        if result.returncode:
            raise RuntimeError('Private directory permissions unavailable')
    else:
        path.chmod(0o700)


def reserve_run(directory, run_id, reservation=RUN_RESERVE):
    """2026-11-03: 새 DB로 과거 호출 예산이 초기화되지 않도록 영속 예약을 먼저 기록한다."""
    if not isinstance(reservation, int) or not 0 < reservation <= 25_000_000_000:
        raise ValueError('Invalid explicitly bounded run reservation')
    ledger_path = directory / 'ledger.json'
    if ledger_path.exists():
        ledger = json.loads(ledger_path.read_text(encoding='utf-8'))
    else:
        # 사용자 확인: 온보딩 외 사용 없음. 온보딩 정확한 청구는 미확인으로 100 KRW 보류.
        ledger = {'onboardingReserveMicros': 100_000_000, 'runs': []}
    occupied = ledger['onboardingReserveMicros'] + sum(row['budgetMicros'] for row in ledger['runs'])
    if occupied + reservation >= LIMIT:
        raise RuntimeError('Gamma cumulative budget exhausted')
    ledger['runs'].append({'id': run_id, 'budgetMicros': reservation, 'state': 'reserved'})
    temporary = ledger_path.with_suffix('.pending')
    temporary.write_text(json.dumps(ledger, indent=2), encoding='utf-8')
    os.replace(temporary, ledger_path)
    return occupied


def run_reservation(evaluation, requested_krw=None):
    """2026-11-04: 표본 평가 예약은 기존 25000원 상한 안에서만 줄일 수 있다. 사용: CLI."""
    if requested_krw is None:
        return 25_000_000_000 if evaluation else RUN_RESERVE
    if not evaluation or type(requested_krw) is not int or not 1 <= requested_krw <= 25000:
        raise ValueError('Sample reserve must be 1..25000 KRW in evaluation mode')
    return requested_krw * 1_000_000


def prepare(cluster, source, opening, evaluation=False, reservation=None):
    """2026-11-03: 새 DB에 세 계정의 일반 금융 자료와 감마 전용 비용 정책만 준비한다."""
    create_database(cluster, API / 'database', DATABASE)
    cluster.sql(institution_sql(), DATABASE)
    snapshots, seeds = load_sources(API / 'fixtures/generated-v4',
                                    ['demo-life', 'beta-ready', 'gamma-life'])
    rows = []
    for snapshot in snapshots:
        current = source if snapshot['userId'] == source['userId'] else snapshot
        rows.extend(row for row in financial_rows(current, seeds[current['userId']], connected=True)
                    if row[0] != 'user_attributes')
        rows.extend(state_rows(current))
    seed = cluster.work / 'gamma-seed.sql'
    seed.write_text(render(rows), encoding='utf-8')
    with cluster.connect(DATABASE, name='gamma_preparation') as connection:
        connection.sql("SET statement_timeout='120s';\n" + seed.read_text(encoding='utf-8'), timeout=130)
    suffix = uuid.uuid4().hex
    login, admin = 'payse_gamma_' + suffix, 'payse_gamma_setup_' + suffix
    password, admin_password = secrets.token_urlsafe(48), secrets.token_urlsafe(48)
    cluster.sql(f"CREATE ROLE {login} LOGIN NOINHERIT PASSWORD {quote(password)};\n"
                f"GRANT payse_runtime TO {login};\n"
                f"GRANT CONNECT ON DATABASE {DATABASE} TO {login};\n"
                f"CREATE ROLE {admin} LOGIN SUPERUSER PASSWORD {quote(admin_password)};", DATABASE)
    # 실제 청구·환율이 아닌 3,000 KRW/USD의 보수적 예산 상한이다.
    # 입력 전체를 $0.25/M로 평가해 12시간 캐시 쓰기 단가까지 포함한다.
    pricing = {'model': 'gpt-6-luna', 'inputMicrosPerMillion': 750_000_000,
        'cachedMicrosPerMillion': 750_000_000, 'outputMicrosPerMillion': 1_500_000_000,
        'countingMicros': 100_000_000, 'kmsMicros': 0, 'inputLimit': 6000, 'outputLimit': 1200}
    reservation = run_reservation(evaluation) if reservation is None else reservation
    if type(reservation) is not int or not 0 < reservation <= run_reservation(evaluation):
        raise ValueError('Invalid run budget')
    if evaluation:
        pricing.update(inputLimit=12000, outputLimit=4000)
    cluster.sql('INSERT INTO payse.analysis_cost_projects VALUES (' +
        ','.join((quote(PROJECT), quote(VERSION), quote(json.dumps(pricing)) + '::jsonb',
                  str(opening), str(opening + reservation), 'now()', 'true')) + ');', DATABASE)
    return {'PAYSE_GAMMA_JDBC_URL': f"jdbc:postgresql://127.0.0.1:{cluster.env['PGPORT']}/{DATABASE}",
        'PAYSE_GAMMA_DB_USER': login, 'PAYSE_GAMMA_DB_PASSWORD': password,
        'PAYSE_GAMMA_ADMIN_USER': admin, 'PAYSE_GAMMA_ADMIN_PASSWORD': admin_password}


def main():
    """2026-11-03: 승인된 실제 호출을 순차 실행하고 자체 소유 PostgreSQL만 종료한다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true')
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--env-file', required=True, type=Path)
    parser.add_argument('--evaluation-dir', type=Path)
    parser.add_argument('--reserve-krw', type=int)
    args = parser.parse_args()
    if not args.live:
        raise ValueError('Explicit --live approval is required')
    env_file = args.env_file.resolve(strict=True)
    if env_file != ROOT / '.env.local' or args.env_file.is_symlink():
        raise ValueError('Only the previously approved env file is supported')
    ignored = subprocess.run(['git', 'check-ignore', '--quiet', str(env_file)], cwd=ROOT)
    if ignored.returncode:
        raise ValueError('The credential file must be Git ignored')
    dataset = args.evaluation_dir.resolve(strict=True) if args.evaluation_dir else None
    if dataset:
        from testing.analysis.gamma_evaluation import verify_bundle, score_run
        manifest = verify_bundle(dataset)
        if manifest['batches'] > 200 or not dataset.is_relative_to(ROOT / '.harness'):
            raise ValueError('Evaluation must be a bounded ignored synthetic dataset')
    reservation = run_reservation(bool(dataset), args.reserve_krw)
    private = ROOT / '.harness/gamma-local-private'
    private_directory(private)
    lock = private / 'run.lock'
    lock.touch(exist_ok=False)
    try:
        master = private / 'master.key'
        if not master.exists():
            with master.open('xb') as stream:
                stream.write(secrets.token_bytes(32))
            if os.name != 'nt':
                master.chmod(0o600)
        if master.is_symlink() or master.stat().st_size != 32:
            raise ValueError('Invalid local master key')
        llm = private / 'llm.properties'
        llm.write_text('enabled=true\nprovider=openai\nmodel=gpt-6-luna\napiKey=\n'
            + 'apiKeyEnvFile=' + env_file.as_posix() + '\nreasoningEffort=none\n', encoding='utf-8')
        run_id = str(uuid.uuid4())
        opening = reserve_run(private, run_id, reservation)
        source = json.loads((dataset / 'source.json').read_text(encoding='utf-8')) if dataset else build()[0]
        with Cluster(args.pg_bin, args.work_dir) as cluster:
            environment = {key: value for key, value in os.environ.items()
                           if not key.upper().startswith(('PAYSE_', 'SPRING_', 'PG'))}
            environment.update(prepare(cluster, source, opening, evaluation=bool(dataset),
                                       reservation=reservation))
            requests = cluster.work / 'synthetic-inputs.json'
            cases = json.loads((dataset / 'inputs.json').read_text(encoding='utf-8')) if dataset else inputs(source)
            requests.write_text(json.dumps(cases, ensure_ascii=False), encoding='utf-8')
            report = cluster.work / 'live-summary.json'
            environment.update(PAYSE_GAMMA_LIVE='approved', PAYSE_GAMMA_LLM_FILE=str(llm),
                PAYSE_GAMMA_KEY_FILE=str(master), PAYSE_GAMMA_PROJECT=PROJECT,
                PAYSE_GAMMA_PRICING=VERSION, PAYSE_GAMMA_SOURCE_VERSION=source['sourceVersion'],
                PAYSE_GAMMA_INPUTS=str(requests), PAYSE_GAMMA_REPORT=str(report),
                PYTHONIOENCODING='utf-8', PYTHONDONTWRITEBYTECODE='1')
            if dataset:
                environment['PAYSE_GAMMA_EVALUATION'] = 'approved'
                (cluster.work / 'dataset-manifest.json').write_text(
                    json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
            launcher = ['cmd.exe', '/d', '/c', 'gradlew.bat'] if os.name == 'nt' else ['./gradlew']
            with (cluster.work / 'java-tests.log').open('w', encoding='utf-8') as output:
                completed = subprocess.run(launcher + ['gammaLiveTest', '--no-daemon',
                    '--max-workers=1', '--console=plain'], cwd=API, env=environment,
                    stdout=output, stderr=subprocess.STDOUT, timeout=5400 if dataset else 600,
                    creationflags=PROCESS_FLAGS)
            ledger = json.loads((private / 'ledger.json').read_text(encoding='utf-8'))
            entry = next(row for row in ledger['runs'] if row['id'] == run_id)
            costs = cluster.sql("SELECT coalesce(sum(CASE WHEN state='reserved' THEN maximum_micros "
                "ELSE actual_micros END),0),count(*) FILTER(WHERE dispatched_at IS NOT NULL) "
                "FROM payse.analysis_cost_calls;", DATABASE)[0].split('|')
            entry.update(budgetMicros=int(costs[0]), dispatchedCalls=int(costs[1]),
                         state='verified' if completed.returncode == 0 else 'failed')
            (private / 'ledger.json').write_text(json.dumps(ledger, indent=2), encoding='utf-8')
            cluster.report.update(passed=completed.returncode == 0, provider='openai',
                googleKmsCalled=False, sourceTransactions=len(source['transactions']),
                budgetUpperMicros=int(costs[0]), dispatchedCalls=int(costs[1]), runId=run_id)
            if report.exists():
                cluster.report['executionCompleted'] = completed.returncode == 0
                cluster.report['passed'] = completed.returncode == 0 and json.loads(
                    report.read_text(encoding='utf-8')).get('passed', False)
            cluster.report['modelCalls'] = int(cluster.sql(
                "SELECT count(*) FROM payse.analysis_cost_calls WHERE category='model' "
                "AND dispatched_at IS NOT NULL;", DATABASE)[0])
            cluster.report['usage'] = [json.loads(row) for row in cluster.sql(
                "SELECT jsonb_build_object('known',detail->'usageKnown','reason',detail->'reason',"
                "'inputTokens',detail->'inputTokens','outputTokens',detail->'outputTokens',"
                "'cachedTokens',detail->'cachedTokens')::text FROM payse.analysis_attempts;", DATABASE)]
            cluster.report['encryptedItems'] = int(cluster.sql(
                "SELECT count(*) FROM payse.analysis_items WHERE ciphertext IS NOT NULL "
                "AND crypto_meta::text LIKE '%gamma-local-v1:%';", DATABASE)[0])
            cluster.report['callDurations'] = [json.loads(row) for row in cluster.sql(
                "SELECT jsonb_build_object('category',category,'seconds',"
                "extract(epoch FROM finished_at-dispatched_at))::text "
                "FROM payse.analysis_cost_calls ORDER BY dispatched_at;", DATABASE)]
            if dataset and report.exists():
                summary = json.loads(report.read_text(encoding='utf-8'))
                quality = score_run(dataset, summary)
                quality['runId'] = run_id
                quality['usage'] = cluster.report['usage']
                quality['budgetUpperMicros'] = int(costs[0])
                (cluster.work / 'evaluation.json').write_text(
                    json.dumps(quality, ensure_ascii=False, indent=2), encoding='utf-8')
                cluster.report['evaluationItems'] = quality['overall']['items']
                cluster.report['evaluationFailures'] = quality['overall']['failures']
        safe_report = {key: value for key, value in cluster.report.items() if key not in ('usage', 'callDurations')}
        print(json.dumps(safe_report, ensure_ascii=False))
        return completed.returncode
    finally:
        lock.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as failure:
        print('Gamma verification stopped: ' + type(failure).__name__, file=sys.stderr)
        sys.exit(1)
