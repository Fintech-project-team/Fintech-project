"""2026-11-01: 새 PostgreSQL에서 분석 HTTP·암호화 저장·사용자 격리와 기존 API 회귀를 검사한다.

기존 DB 주소·인증 키를 입력받지 않는다. fixture는 준비에만 사용하며 제품 런타임 의존이 아니다.
검사 자격은 하위 Java 프로세스 환경에만 전달하고 보고서·명령줄에 기록하지 않는다.
사용: 독립 CLI. 실제 LLM/KMS 접속·유료 호출·모바일 검증을 수행하지 않는다.
"""
from pathlib import Path
import argparse
import os
import secrets
import subprocess
import sys
import uuid


DIRECTORY = Path(__file__).resolve().parent
DATABASE = 'payse_auth_test_analysis'
SQL_DATABASE = 'payse_auth_test_analysis_sql'
BASE_MIGRATIONS = (
    '001_initial.sql',
    '002_storage_guards.sql',
    '003_auth_access.sql',
    '004_auth_sessions.sql',
    '007_financial_access.sql',
)


def create_database(cluster, base_sql_root, database):
    """2026-11-01: 신규 DB에 현재 공통 구조·분석·급여 안내만 적용한다. 사용: prepare_database, main."""
    cluster.sql('CREATE DATABASE ' + database + ';')
    for filename in BASE_MIGRATIONS:
        cluster.load(base_sql_root / filename, database)
    cluster.load(DIRECTORY / '008_analysis_storage.sql', database)
    cluster.load(base_sql_root / '009_salary_notices.sql', database)
    # 005/006/010은 구 DB용이다. 신규 001에 포함된 현재 구조 위에 중복 적용하지 않는다.
    checks = cluster.sql('''
      SELECT
        to_regclass('payse.statement_items') IS NOT NULL,
        EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema='payse'
            AND table_name='financial_transactions'
            AND column_name='cancellation_date'
        ),
        EXISTS (
          SELECT 1
          FROM pg_constraint
          WHERE conrelid='payse.financial_transactions'::regclass
            AND conname='account_entry_status_valid'
        );
    ''', database)
    if checks != ['t|t|t']:
        raise RuntimeError('Current financial storage prerequisites are missing')


def prepare_database(cluster, base_sql_root):
    """2026-11-01: 기존 회귀와 별도 분석 DB·세 시연 계정·최소 권한 접속을 준비한다. 사용: main."""
    from auth_test_support import quote
    from test_salary_notice_service import prepare_database as prepare_salary
    environment = prepare_salary(cluster)
    create_database(cluster, base_sql_root, DATABASE)
    api = base_sql_root.parent
    sys.path.insert(0, str(api))
    from reference_data.export_sql import export as institution_sql
    from testing.scenarios.export_state import export as scenario_sql
    cluster.sql(institution_sql(), DATABASE)
    seed = cluster.work / 'analysis-seed.sql'
    seed.write_text(scenario_sql(api / 'fixtures/generated-v4',
        ['demo-life', 'beta-ready', 'gamma-month-end']), encoding='utf-8')
    # 연간 3계정 fixture 준비만 120초로 분리하고 제품·실패 검사는 기존 제한을 유지한다.
    with cluster.connect(DATABASE, name='analysis_fixture_preparation') as connection:
        connection.sql("SET statement_timeout = '120s';\n" + seed.read_text(encoding='utf-8'), timeout=130)
    suffix = uuid.uuid4().hex
    login = 'payse_analysis_' + suffix
    admin = 'payse_analysis_setup_' + suffix
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
          AND NOT rolcreatedb AND NOT rolcreaterole
        FROM pg_roles
        WHERE rolname=''' + quote(login) + ';', DATABASE) != ['t']:
        raise RuntimeError('Analysis runtime exceeded its role boundary')
    environment.update({
        'PAYSE_ANALYSIS_TEST_JDBC_URL': 'jdbc:postgresql://127.0.0.1:' + cluster.env['PGPORT'] + '/' + DATABASE,
        'PAYSE_ANALYSIS_TEST_DB_USER': login,
        'PAYSE_ANALYSIS_TEST_DB_PASSWORD': password,
        'PAYSE_ANALYSIS_TEST_ADMIN_USER': admin,
        'PAYSE_ANALYSIS_TEST_ADMIN_PASSWORD': admin_password,
        'PAYSE_ANALYSIS_TEST_SEED_FILE': str(seed),
    })
    return environment


def financial_fingerprint(cluster):
    """2026-11-01: 분석 DB의 금융 원천·설정·버전·기존 영수증 보존을 대조한다. 사용: main."""
    tables = cluster.sql('''
      SELECT tablename
      FROM pg_tables
      WHERE schemaname='payse'
        AND tablename NOT LIKE 'analysis\\_%' ESCAPE '\\'
        AND tablename NOT IN ('users','demo_sessions','auth_rate_limits')
      ORDER BY tablename;
    ''', DATABASE)
    result = {}
    for table in tables:
        if not table.isascii() or not table.replace('_', '').isalnum():
            raise RuntimeError('Unexpected financial table identifier')
        result[table] = cluster.sql('''
          SELECT count(*)::text || ':' || md5(coalesce(string_agg(value, E'\\n' ORDER BY value), ''))
          FROM (
            SELECT to_jsonb(record)::text AS value
            FROM payse.''' + table + ' record\n) rows;', DATABASE)[0]
    # 테스트가 발급한 코드 verifier·세션은 제외하되 사용자 소유권과 금융 버전은 보존한다.
    result['users.identity_version'] = cluster.sql('''
      SELECT count(*)::text || ':' || md5(coalesce(string_agg(value, E'\\n' ORDER BY value), ''))
      FROM (
        SELECT jsonb_build_object('id',id,'dataVersion',data_version)::text AS value
        FROM payse.users
      ) rows;
    ''', DATABASE)[0]
    return result


def main():
    """2026-11-01: SQL·실제 HTTP 필수 suite·기존 회귀를 실행하고 사용자별 결과 보존을 기록한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--base-sql-root', type=Path, default=DIRECTORY)
    arguments = parser.parse_args()
    base_sql_root = arguments.base_sql_root.resolve(strict=True)
    api = base_sql_root.parent
    sys.path.insert(0, str(base_sql_root))
    from auth_test_support import Cluster, PROCESS_FLAGS
    from test_auth_jdbc import java_results, fingerprint as jdbc_fingerprint
    from test_session_service import fingerprint as session_fingerprint
    from test_salary_notice_service import fingerprint as salary_fingerprint
    sys.path.insert(0, str(DIRECTORY))
    from test_analysis_storage import run_checks
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        credentials = prepare_database(cluster, base_sql_root)
        jdbc_before = jdbc_fingerprint(cluster)
        session_before = session_fingerprint(cluster)
        salary_before = salary_fingerprint(cluster)
        finance_before = financial_fingerprint(cluster)
        create_database(cluster, base_sql_root, SQL_DATABASE)
        sql_result = run_checks(cluster, SQL_DATABASE, base_sql_root)
        cluster.report.update({'analysisSqlChecks': sql_result.testsRun,
                              'analysisSqlPassed': sql_result.wasSuccessful()})
        if not sql_result.wasSuccessful():
            return 1
        environment = {key: value for key, value in os.environ.items()
                       if not key.upper().startswith(('PAYSE_', 'SPRING_', 'PG'))}
        environment.update(credentials)
        environment['PYTHONDONTWRITEBYTECODE'] = '1'
        environment['PYTHONIOENCODING'] = 'utf-8'
        launcher = ['cmd.exe', '/d', '/c', 'gradlew.bat'] if os.name == 'nt' else [str(api / 'gradlew')]
        with (cluster.work / 'java-tests.log').open('w', encoding='utf-8') as output:
            completed = subprocess.run(launcher + [
                'cleanTest', 'test', 'apiDocsCheck', '--rerun-tasks', '--no-daemon', '--console=plain'
            ], cwd=api, env=environment, stdout=output, stderr=subprocess.STDOUT,
                timeout=1200, creationflags=PROCESS_FLAGS)
        suites = java_results()
        required = ('.AuthHttpTest', '.SessionJdbcTest', '.FinancialHttpTest',
                    '.SalaryNoticeHttpTest', '.AnalysisHttpTest')
        for suffix in required:
            if not any(suite['name'].endswith(suffix) and int(suite['tests']) > 0 for suite in suites):
                raise RuntimeError('Required analysis HTTP/JPA suite did not produce a JUnit result')
        passed = completed.returncode == 0 and all(int(suite[key]) == 0
            for suite in suites for key in ('failures', 'errors', 'skipped'))
        finance_preserved = finance_before == financial_fingerprint(cluster)
        existing_preserved = (jdbc_before == jdbc_fingerprint(cluster)
                              and session_before == session_fingerprint(cluster)
                              and salary_before == salary_fingerprint(cluster))
        passed = passed and finance_preserved and existing_preserved
        cluster.report.update({
            'passed': passed,
            'javaExitCode': completed.returncode,
            'javaSuites': suites,
            'analysisHttpVerified': passed,
            'financialSourcesUnchanged': finance_preserved,
            'authAndSalaryBaselineRowsUnchanged': existing_preserved,
            'runtimeCredentialsPersisted': False,
            'paidProviderCalled': False,
        })
        if not passed:
            return 1
        print('PASS: isolated analysis HTTP/JPA, storage, user isolation and existing API regression')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        print('Analysis service checks did not complete: ' + type(error).__name__, file=sys.stderr)
        sys.exit(2)
