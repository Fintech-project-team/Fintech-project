"""2026-10-26: 새 PostgreSQL에서 세션 서비스와 기존 JDBC 회귀 검사를 실행한다.

기존 서버 주소를 받지 않는다. 임시 준비 관리자와 최소 권한 앱 자격은 하위
검사 프로세스 환경으로만 전달하고 결과 파일에 남기지 않는다.
"""
from pathlib import Path
import argparse
import os
import secrets
import subprocess
import sys
import uuid

from auth_test_support import Cluster, PROCESS_FLAGS, quote
from test_auth_jdbc import prepare_database as prepare_jdbc, fingerprint as jdbc_fingerprint, java_results


DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
DATABASE = "payse_auth_test_sessions"


def prepare_database(cluster):
    """2026-10-26: 기존 JDBC DB와 별도 세션 DB·일회 검사 자격을 준비한다.

    사용: main, 통합 검증 실행기. 반환 환경은 디스크에 저장하지 않는다.
    """
    environment = prepare_jdbc(cluster)
    cluster.sql("CREATE DATABASE " + DATABASE + ";")
    for filename in ("001_initial.sql", "002_storage_guards.sql", "003_auth_access.sql", "004_auth_sessions.sql"):
        cluster.load(DIRECTORY / filename, DATABASE)
    suffix = uuid.uuid4().hex
    login = "payse_session_" + suffix
    admin = "payse_session_setup_" + suffix
    password = secrets.token_urlsafe(48)
    admin_password = secrets.token_urlsafe(48)
    # 테스트 준비 자격과 제품 호출 자격을 분리한다. 실제 서비스는 runtime 역할만 사용한다.
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
        raise AssertionError("Session test runtime role is not restricted")
    environment.update({
        "PAYSE_SESSION_TEST_JDBC_URL": "jdbc:postgresql://127.0.0.1:" + cluster.env["PGPORT"] + "/" + DATABASE,
        "PAYSE_SESSION_TEST_DB_USER": login,
        "PAYSE_SESSION_TEST_DB_PASSWORD": password,
        "PAYSE_SESSION_TEST_ADMIN_USER": admin,
        "PAYSE_SESSION_TEST_ADMIN_PASSWORD": admin_password,
    })
    return environment


def fingerprint(cluster):
    """2026-10-26: 서비스가 바꾸지 않아야 할 금융·설정 테이블 내용을 기록한다.

    사용: main의 전후 보존 검사. users·sessions·제한은 업무 전이 검사의 대상이다.
    """
    tables = cluster.sql("""
    SELECT tablename
    FROM pg_tables
    WHERE schemaname='payse'
      AND tablename NOT IN ('users', 'demo_sessions', 'auth_rate_limits')
    ORDER BY tablename;
    """, DATABASE)
    result = {}
    for table in tables:
        if not table.isascii() or not table.replace("_", "").isalnum():
            raise RuntimeError("Unexpected session test table identifier")
        result[table] = cluster.sql("""
        SELECT count(*)::text || ':' || md5(coalesce(string_agg(value, E'\\n' ORDER BY value), ''))
        FROM (
          SELECT to_jsonb(record)::text AS value
          FROM payse.""" + table + " record\n) rows;", DATABASE)[0]
    return result


def main():
    """2026-10-26: 새 클러스터에서 전체 Java 검사와 두 DB 보존 여부를 확인한다.

    사용: 파일 직접 실행. 실제 HTTP·운영 DB 검증으로 보고하지 않는다.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    arguments = parser.parse_args()
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        credentials = prepare_database(cluster)
        before_jdbc = jdbc_fingerprint(cluster)
        before_finance = fingerprint(cluster)
        environment = {key: value for key, value in os.environ.items()
                       if not key.upper().startswith(("PAYSE_", "SPRING_", "PG"))}
        environment.update(credentials)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        launcher = ["cmd.exe", "/d", "/c", "gradlew.bat"] if os.name == "nt" else [str(API / "gradlew")]
        with (cluster.work / "java-tests.log").open("w", encoding="utf-8") as output:
            completed = subprocess.run(launcher + ["test", "apiDocsCheck", "--rerun-tasks", "--no-daemon", "--console=plain"],
                cwd=API, env=environment, stdout=output, stderr=subprocess.STDOUT,
                timeout=840, creationflags=PROCESS_FLAGS)
        suites = java_results()
        if not any(suite["name"].endswith(".SessionJdbcTest") for suite in suites):
            raise RuntimeError("SessionJdbcTest did not produce a JUnit result")
        preserved = before_jdbc == jdbc_fingerprint(cluster) and before_finance == fingerprint(cluster)
        passed = completed.returncode == 0 and preserved and all(int(suite[key]) == 0
            for suite in suites for key in ("failures", "errors", "skipped"))
        cluster.report.update({"passed": passed, "javaExitCode": completed.returncode,
            "javaSuites": suites, "baselineRowsUnchanged": preserved,
            "preservedFinancialTables": len(before_finance), "httpAuthenticationVerified": False,
            "runtimeCredentialsPersisted": False})
        if not preserved:
            raise AssertionError("Session service checks changed baseline financial rows")
        if not passed:
            return 1
        print("PASS: session service, existing JDBC checks and financial rows preserved")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        print("Isolated session checks did not complete: " + type(error).__name__, file=sys.stderr)
        sys.exit(2)
