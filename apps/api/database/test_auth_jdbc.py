"""2026-10-25: 새 PostgreSQL에서 Java 인증 DB 연결과 기존 Java 검사를 실행한다.

--pg-bin과 존재하지 않는 --work-dir을 명시한다. 기존 서버 주소·운영 자격은
받지 않으며 생성한 테스트 계정·관계 입력은 하위 Gradle 환경으로만 전달한다.
"""

from pathlib import Path
import argparse
import os
import secrets
import string
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET

from auth_test_support import Cluster, PROCESS_FLAGS, quote
from prepare_links import prepare_links


DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
DATABASE = "payse_auth_test_jdbc"


def user_fixture():
    """2026-10-25: 단일 사용자·활성 세션·계좌 관계를 새 UUID와 합성 자격으로 준비한다.

    사용: prepare_database; 표시명으로 기존 행을 선택하지 않는다.
    """
    return {"user": str(uuid.uuid4()), "session": str(uuid.uuid4()), "account": str(uuid.uuid4()),
        "name": "이용자" + "".join(secrets.choice(string.ascii_letters) for _ in range(12)),
        "phone": "010" + "".join(secrets.choice(string.digits) for _ in range(8)),
        "token": "sha256:" + secrets.token_hex(32), "verifier": "DISABLED:isolated-jdbc-check"}


def fingerprint(cluster):
    """2026-10-25: 인증 제한 행을 제외한 공통 테이블의 행 수·내용 지문을 반환한다.

    사용: main의 검사 전후 금융/사용자 보존 확인.
    """
    # DB 자체 목록에서 공통 테이블을 읽고 허용된 식별자 형식만 SQL 식별자로 사용한다.
    tables = cluster.sql("SELECT tablename FROM pg_tables WHERE schemaname='payse' "
        "AND tablename<>'auth_rate_limits' ORDER BY tablename;", DATABASE)
    result = {}
    for table in tables:
        if not table.replace("_", "").isalnum() or not table.isascii():
            raise RuntimeError("Unexpected test table identifier")
        result[table] = cluster.sql("SELECT count(*)::text||':'||md5(coalesce(string_agg(value,E'\\n' ORDER BY value),'')) "
            "FROM (SELECT to_jsonb(record)::text AS value FROM payse." + table + " record) rows;", DATABASE)[0]
    return result


def prepare_database(cluster):
    """2026-10-25: 격리 DB에 기존 스키마·두 사용자 관계·최소 권한 접속 역할을 준비한다.

    사용: main; 생성한 자격은 반환 환경에만 담고 디스크/출력에 기록하지 않는다.
    수정 2026-10-29: 원거래 JOIN을 위한 연결·거래 관계 준비를 추가한다.
    """
    # 새 클러스터 안에만 테스트 DB를 만들고 현재 001/002를 적용한다.
    cluster.sql("CREATE DATABASE " + DATABASE + ";")
    for filename in ("001_initial.sql", "002_storage_guards.sql"):
        cluster.load(DIRECTORY / filename, DATABASE)
    users = [user_fixture(), user_fixture()]
    bank = "jdbc" + uuid.uuid4().hex
    # 기관·사용자·원천 컨텍스트·계좌는 제품과 같은 테이블과 소유자 관계를 사용한다.
    cluster.sql("INSERT INTO payse.institutions(code,kind,name) VALUES (" + quote(bank)
        + ",'bank','가상은행');", DATABASE)
    for index, user in enumerate(users):
        statement = f"""
        BEGIN;
        -- 준비된 UUID를 사용해 사용자와 그 사용자 소유 활성 세션을 연결한다.
        INSERT INTO payse.users(id,name,phone,code_verifier,data_version,created_at)
          VALUES ({quote(user['user'])},{quote(user['name'])},{quote(user['phone'])},
            {quote(user['verifier'])},1,'2026-10-25T00:00:00Z');
        INSERT INTO payse.demo_sessions(id,user_id,token_digest,issued_at)
          VALUES ({quote(user['session'])},{quote(user['user'])},{quote(user['token'])},'2026-10-25T00:00:00Z');
        -- 원천 컨텍스트와 계좌는 동일 사용자 ID를 가지며 서로 다른 잔액으로 격리를 확인한다.
        INSERT INTO payse.source_contexts(user_id,source_version,schema_version,rule_version,as_of,
          coverage,salary_evidence,occurrence_links)
          VALUES ({quote(user['user'])},'jdbc-source','v3','jdbc-rules','2026-10-25T00:00:00Z','[]','[]','[]');
        INSERT INTO payse.financial_accounts(id,user_id,institution_code,source_ref,source_version,
          product_type,product_name,masked_number,balance_krw,as_of,included)
          VALUES ({quote(user['account'])},{quote(user['user'])},{quote(bank)},{quote(user['account'])},
            'jdbc-source','demand','생활 통장','****1234',{index + 1},'2026-10-25T00:00:00Z',false);
        COMMIT;
        -- 단일 존재·소유권·활성 세션·원천 잔액을 본 검사 전에 확인한다.
        SELECT (SELECT count(*) FROM payse.users WHERE id={quote(user['user'])})=1
          AND (SELECT count(*) FROM payse.demo_sessions WHERE id={quote(user['session'])}
            AND user_id={quote(user['user'])} AND ended_at IS NULL)=1
          AND (SELECT count(*) FROM payse.financial_accounts WHERE id={quote(user['account'])}
            AND user_id={quote(user['user'])} AND balance_krw={index + 1})=1;
        """
        if cluster.sql(statement, DATABASE) != ["t"]:
            raise AssertionError("Generated JDBC fixture relationship was not unique and complete")
        user.update(prepare_links(cluster, DATABASE, user))
    # 검토한 인증 SQL을 그대로 적용한 뒤 runtime 역할로 전환 가능한 테스트 로그인만 추가한다.
    cluster.load(DIRECTORY / "003_auth_access.sql", DATABASE)
    login = "payse_jdbc_" + uuid.uuid4().hex
    password = secrets.token_urlsafe(48)
    cluster.sql("CREATE ROLE " + login + " LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE "
        "PASSWORD " + quote(password) + "; GRANT payse_runtime TO " + login
        + "; GRANT CONNECT,TEMPORARY ON DATABASE " + DATABASE + " TO " + login + ";", DATABASE)
    if cluster.sql("SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolinherit FROM pg_roles WHERE rolname="
        + quote(login) + ";", DATABASE) != ["t"]:
        raise AssertionError("JDBC test login exceeded the reviewed role boundary")
    url = "jdbc:postgresql://127.0.0.1:" + cluster.env["PGPORT"] + "/" + DATABASE
    environment = {"PAYSE_AUTH_TEST_JDBC_URL": url, "PAYSE_AUTH_TEST_DB_USER": login,
        "PAYSE_AUTH_TEST_DB_PASSWORD": password,
        "PAYSE_TEST_JDBC_URL": url, "PAYSE_TEST_DB_USER": login, "PAYSE_TEST_DB_PASSWORD": password}
    for index, user in enumerate(users):
        for name, value in user.items():
            environment["PAYSE_AUTH_TEST_" + name.upper() + "_" + str(index)] = value
    return environment


def java_results():
    """2026-10-25: Gradle의 JUnit XML에서 테스트 수·실패·건너뜀만 읽어 결과를 요약한다.

    사용: main; 테스트 출력이나 환경 자격은 결과 JSON에 복사하지 않는다.
    """
    suites = []
    for path in sorted((API / "build/test-results/test").glob("TEST-*.xml")):
        suite = ET.parse(path).getroot()
        suites.append({name: suite.attrib[name] for name in ("name", "tests", "failures", "errors", "skipped")})
    if not any(suite["name"].endswith(".AuthJdbcTest") for suite in suites):
        raise RuntimeError("AuthJdbcTest did not produce a JUnit result")
    return suites


def main():
    """2026-10-25: 새 PostgreSQL의 자격을 Gradle 환경에만 주입하고 검증 결과를 기록한다.

    사용: 파일 직접 실행 진입점; 종료 전에 클러스터·임시 자격 파일을 정리한다.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", required=True, type=Path, help="PostgreSQL initdb/pg_ctl/psql directory")
    parser.add_argument("--work-dir", required=True, type=Path, help="New private directory, never an existing cluster")
    arguments = parser.parse_args()
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        credentials = prepare_database(cluster)
        before = fingerprint(cluster)
        # 운영/기존 검사 자격은 계승하지 않고 방금 생성한 격리 연결만 제공한다.
        environment = {key: value for key, value in os.environ.items()
            if not key.upper().startswith(("PAYSE_", "SPRING_", "PG"))}
        environment.update(credentials)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        launcher = ["cmd.exe", "/d", "/c", "gradlew.bat"] if os.name == "nt" else [str(API / "gradlew")]
        # --rerun-tasks는 새 서버와 자격에서 이전 XML/UP-TO-DATE를 통과 근거로 사용하지 않게 한다.
        with (cluster.work / "java-tests.log").open("w", encoding="utf-8") as output:
            completed = subprocess.run(launcher + ["test", "apiDocsCheck", "--rerun-tasks", "--no-daemon", "--console=plain"],
                cwd=API, env=environment, stdout=output, stderr=subprocess.STDOUT,
                timeout=840, creationflags=PROCESS_FLAGS)
        suites = java_results()
        passed = completed.returncode == 0 and all(int(suite[key]) == 0
            for suite in suites for key in ("failures", "errors", "skipped"))
        after = fingerprint(cluster)
        preserved = before == after
        cluster.report.update({"javaSuites": suites, "javaExitCode": completed.returncode,
            "passed": passed and preserved, "preservedBaselineTables": len(before),
            "baselineRowsUnchanged": preserved, "httpAuthenticationVerified": False,
            "runtimeCredentialsPersisted": False})
        if not preserved:
            raise AssertionError("Java authentication checks changed baseline financial/user rows")
        if not passed:
            return 1
        print("PASS: Java authentication JDBC checks and common rows preserved")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        print("Isolated JDBC checks did not complete: " + type(error).__name__, file=sys.stderr)
        sys.exit(2)
