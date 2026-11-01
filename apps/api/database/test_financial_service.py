"""2026-10-29: 새 격리 PostgreSQL에서 실제 금융 HTTP·저장과 기존 인증 회귀를 검사한다.

기존 DB 주소는 받지 않는다. 시나리오는 테스트 준비에만 사용하며 런타임 API가
fixture를 읽는 경로를 만들지 않는다. 앱 자격은 하위 검사 환경에만 전달한다.
"""
from pathlib import Path
import argparse
import os
import secrets
import subprocess
import sys
import uuid

from auth_test_support import Cluster, PROCESS_FLAGS, quote
from test_session_service import prepare_database as prepare_auth, fingerprint as session_fingerprint
from test_auth_jdbc import java_results, fingerprint as jdbc_fingerprint


DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
DATABASE = "payse_auth_test_financial"


def prepare_database(cluster):
    """2026-10-29: 금융 전용 DB·기관 기준·복원 SQL과 최소 권한 실행 자격을 준비한다.

    사용: main. 인증 회귀 DB와 금융 쓰기 DB를 분리한다.
    """
    environment = prepare_auth(cluster)
    cluster.sql("CREATE DATABASE " + DATABASE + ";")
    for filename in ("001_initial.sql", "002_storage_guards.sql", "003_auth_access.sql",
                     "004_auth_sessions.sql", "007_financial_access.sql"):
        cluster.load(DIRECTORY / filename, DATABASE)
    sys.path.insert(0, str(API))
    from reference_data.export_sql import export as institution_sql
    from testing.scenarios.export_state import export as scenario_sql
    cluster.sql(institution_sql(), DATABASE)
    seed = cluster.work / "financial-seed.sql"
    seed.write_text(scenario_sql(API / "fixtures/generated",
        ["alpha-ready", "beta-ready", "gamma-month-end"]), encoding="utf-8")
    responses = cluster.work / "public-responses"
    responses.mkdir()
    suffix = uuid.uuid4().hex
    login = "payse_financial_" + suffix
    admin = "payse_financial_setup_" + suffix
    password = secrets.token_urlsafe(48)
    admin_password = secrets.token_urlsafe(48)
    cluster.sql(f"""
    CREATE ROLE {login}
      LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE
      PASSWORD {quote(password)};
    GRANT payse_runtime TO {login};
    GRANT CONNECT ON DATABASE {DATABASE} TO {login};
    CREATE ROLE {admin}
      LOGIN NOINHERIT SUPERUSER
      PASSWORD {quote(admin_password)};
    """, DATABASE)
    if cluster.sql("SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolinherit "
                   "FROM pg_roles WHERE rolname=" + quote(login) + ";", DATABASE) != ["t"]:
        raise AssertionError("Financial runtime test role exceeded its boundary")
    environment.update({
        "PAYSE_FINANCIAL_TEST_JDBC_URL": "jdbc:postgresql://127.0.0.1:" + cluster.env["PGPORT"] + "/" + DATABASE,
        "PAYSE_FINANCIAL_TEST_DB_USER": login,
        "PAYSE_FINANCIAL_TEST_DB_PASSWORD": password,
        "PAYSE_FINANCIAL_TEST_ADMIN_USER": admin,
        "PAYSE_FINANCIAL_TEST_ADMIN_PASSWORD": admin_password,
        "PAYSE_FINANCIAL_TEST_SEED_FILE": str(seed),
        "PAYSE_FINANCIAL_TEST_RESPONSE_DIR": str(responses),
    })
    return environment


def main():
    """2026-10-29: 소유한 임시 클러스터에서 전체 Java 검사와 필수 금융 suite 실행을 확인한다.

    사용: 직접 CLI. 실제 운영 DB 적용·외부 배포·모바일 실행 검사는 포함하지 않는다.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    arguments = parser.parse_args()
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        credentials = prepare_database(cluster)
        jdbc_before = jdbc_fingerprint(cluster)
        session_before = session_fingerprint(cluster)
        environment = {key: value for key, value in os.environ.items()
                       if not key.upper().startswith(("PAYSE_", "SPRING_", "PG"))}
        environment.update(credentials)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        launcher = ["cmd.exe", "/d", "/c", "gradlew.bat"] if os.name == "nt" else [str(API / "gradlew")]
        with (cluster.work / "java-tests.log").open("w", encoding="utf-8") as output:
            completed = subprocess.run(launcher + ["test", "apiDocsCheck", "--rerun-tasks", "--no-daemon", "--console=plain"],
                cwd=API, env=environment, stdout=output, stderr=subprocess.STDOUT,
                timeout=1200, creationflags=PROCESS_FLAGS)
        suites = java_results()
        required = (".AuthHttpTest", ".SessionJdbcTest", ".FinancialHttpTest")
        for suffix in required:
            if not any(suite["name"].endswith(suffix) for suite in suites):
                raise RuntimeError("Required HTTP/JDBC suite did not produce a JUnit result")
        passed = completed.returncode == 0 and all(int(suite[key]) == 0
            for suite in suites for key in ("failures", "errors", "skipped"))
        preserved = jdbc_before == jdbc_fingerprint(cluster) and session_before == session_fingerprint(cluster)
        passed = passed and preserved
        cluster.report.update({"passed": passed, "javaExitCode": completed.returncode,
            "javaSuites": suites, "financialHttpVerified": passed, "authBaselineRowsUnchanged": preserved,
            "runtimeCredentialsPersisted": False})
        if not passed:
            return 1
        print("PASS: isolated financial HTTP, persistence, authorization and authentication regression checks")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        print("Isolated financial checks did not complete: " + type(error).__name__, file=sys.stderr)
        sys.exit(2)
