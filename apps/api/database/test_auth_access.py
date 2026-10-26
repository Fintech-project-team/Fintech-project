"""2026-10-25: Real PostgreSQL checks for auth permissions, counters and lock ordering.

Run explicitly with --pg-bin and a nonexistent --work-dir. No server address, existing
cluster, HTTP endpoint or application credentials are accepted by this test runner.
"""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import hashlib
import secrets
import string
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

from auth_test_support import Cluster, SqlError, quote


DIRECTORY = Path(__file__).resolve().parent


def digest():
    """2026-10-25: 테스트 키로 쓸 32바이트 난수를 64자리 소문자 16진수로 반환한다. 실제 입력의 해시/HMAC 연산은 아니다.

    사용: person과 키를 만드는 인증 검사.
    """
    return secrets.token_hex(32)


def person():
    """2026-10-25: 새 UUID 관계·합성 이름/전화번호·검사용 토큰 digest와 DISABLED verifier를 준비한다.

    사용: AuthAccessTests.setUpClass, test_credentials_are_internal_candidates.
    """
    return {"id": str(uuid.uuid4()), "session": str(uuid.uuid4()), "account": str(uuid.uuid4()),
            "name": "Test" + "".join(secrets.choice(string.ascii_letters) for _ in range(12)),
            "phone": "010" + "".join(secrets.choice(string.digits) for _ in range(8)),
            "token": "sha256:" + digest(), "verifier": "DISABLED:isolated-auth-check"}


class AuthAccessTests(unittest.TestCase):
    """2026-10-25: 실제 DB 역할·요청 제한·잠금·롤백을 검사하며 HTTP 세션 발급은 검사하지 않는다.

    사용: main의 unittest 로더.
    """

    cluster = None
    database = "payse_auth_test_main"

    @classmethod
    def setUpClass(cls):
        """2026-10-25: 기본 스키마와 사용자 관계를 준비하고 인증 SQL 적용 전후 지문을 기록한다.

        사용: unittest 클래스 준비 단계.
        """
        if cls.cluster is None:
            raise unittest.SkipTest("Run this suite explicitly with --pg-bin and a new --work-dir")
        cls.cluster.sql(f"CREATE DATABASE {cls.database};")
        cls.cluster.load(DIRECTORY / "001_initial.sql", cls.database)
        cls.cluster.load(DIRECTORY / "002_storage_guards.sql", cls.database)
        cls.cluster.report["baselinePolicyExpressions"] = cls.cluster.sql(
            "SELECT c.relname,pg_get_expr(p.polqual,p.polrelid) FROM pg_policy p JOIN pg_class c "
            "ON c.oid=p.polrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='payse' "
            "AND c.relname IN ('users','financial_accounts') ORDER BY c.relname;", cls.database)
        cls.users = [person(), person()]
        cls.bank = "test" + uuid.uuid4().hex
        cls.cluster.sql("INSERT INTO payse.institutions(code,kind,name) VALUES ("
                        + quote(cls.bank) + ",'bank','가상은행');", cls.database)
        for index, user in enumerate(cls.users):
            cls.seed_user(user, index + 1)
        cls.before = cls.fingerprint()
        cls.cluster.load(DIRECTORY / "003_auth_access.sql", cls.database)
        cls.after = cls.fingerprint()
        cls.cluster.sql("CREATE ROLE payse_auth_public_probe NOLOGIN; "
                        "GRANT USAGE ON SCHEMA payse TO payse_auth_public_probe;", cls.database)

    @classmethod
    def seed_user(cls, user, balance):
        """2026-10-25: 전달받은 사용자·세션·계좌 ID로 행을 적재하고 단일 존재·소유권·사전 상태를 확인한다.

        사용: AuthAccessTests.setUpClass.
        """
        statement = f"""
        BEGIN;
        INSERT INTO payse.users(id,name,phone,code_verifier,data_version,created_at)
          VALUES ({quote(user['id'])},{quote(user['name'])},{quote(user['phone'])},
                  {quote(user['verifier'])},1,'2026-10-25T00:00:00Z');
        INSERT INTO payse.demo_sessions(id,user_id,token_digest,issued_at)
          VALUES ({quote(user['session'])},{quote(user['id'])},{quote(user['token'])},'2026-10-25T00:00:00Z');
        INSERT INTO payse.source_contexts(user_id,source_version,schema_version,rule_version,as_of,
                                          coverage,salary_evidence,occurrence_links)
          VALUES ({quote(user['id'])},'test-source','v3','test-rules','2026-10-25T00:00:00Z','[]','[]','[]');
        INSERT INTO payse.financial_accounts(id,user_id,institution_code,source_ref,source_version,
            product_type,product_name,masked_number,balance_krw,as_of,included)
          VALUES ({quote(user['account'])},{quote(user['id'])},{quote(cls.bank)},{quote(user['account'])},
            'test-source','demand','일상 통장','****1234',{balance},'2026-10-25T00:00:00Z',false);
        COMMIT;
        SELECT (SELECT count(*) FROM payse.users WHERE id={quote(user['id'])})=1
          AND (SELECT count(*) FROM payse.demo_sessions WHERE id={quote(user['session'])}
               AND user_id={quote(user['id'])} AND ended_at IS NULL)=1
          AND (SELECT count(*) FROM payse.financial_accounts WHERE id={quote(user['account'])}
               AND user_id={quote(user['id'])})=1;
        """
        if cls.cluster.sql(statement, cls.database) != ["t"]:
            raise AssertionError("Generated fixture ownership or prerequisite count was incorrect")

    @classmethod
    def fingerprint(cls, database=None):
        """2026-10-25: 기존 테이블의 행 수·내용 지문을 반환하며 신규 인증 컬럼은 기존 값 대조에서 제외한다.

        사용: 이행·회귀 검사.
        """
        database = database or cls.database
        tables = cls.cluster.sql("SELECT tablename FROM pg_tables WHERE schemaname='payse' "
                                 "AND tablename<>'auth_rate_limits' ORDER BY tablename;", database)
        result = {}
        for table in tables:
            projection = "to_jsonb(record)"
            if table == "users":
                projection += "-'deactivated_at'-'purge_after'"
            result[table] = cls.cluster.sql(
                f"SELECT count(*)::text||':'||md5(coalesce(string_agg(value,E'\\n' ORDER BY value),'')) "
                f"FROM (SELECT ({projection})::text AS value FROM payse.{table} record) rows;", database)[0]
        return result

    def sql(self, statement):
        """2026-10-25: 현재 테스트 DB에 관리자 SQL을 실행하고 결과 행 목록을 반환한다.

        사용: AuthAccessTests의 준비·검사·복구.
        """
        return self.cluster.sql(statement, self.database)

    def runtime(self, statement):
        """2026-10-25: runtime 역할의 단일 트랜잭션을 실행하고 성공 시 커밋한다.

        사용: AuthAccessTests의 권한·제한 검사.
        """
        return self.sql("BEGIN; SET LOCAL ROLE payse_runtime; " + statement + "; COMMIT;")

    def reject(self, statement, state="42501", prefix="SET ROLE payse_runtime;"):
        """2026-10-25: 지정한 역할·접두 SQL로 실행한 문장이 기대 SQLSTATE로 거절되는지 확인한다.

        사용: AuthAccessTests의 거절 사례.
        """
        with self.assertRaises(SqlError) as error:
            self.sql(prefix + statement)
        self.assertEqual(error.exception.state, state)

    def test_relative_files_keep_one_transaction(self):
        """2026-10-26: 상대 파일 적용 성공과 파일 누락·SQL 오류의 전체 롤백을 실제 DB에서 검사한다.

        사용: unittest. 공백 포함 경로를 현재 작업 디렉터리와 다르게 준비한다.
        """
        for mode in ("success", "sql_error", "missing"):
            table = "layout_probe_" + uuid.uuid4().hex
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(
                prefix="sql include ", dir=self.cluster.work
            ) as directory:
                folder = Path(directory)
                entry = folder / "entry.sql"
                entry.write_text(
                    "\\set ON_ERROR_STOP on\nBEGIN;\n"
                    f"CREATE TABLE public.{table} (value integer NOT NULL);\n"
                    "\\ir part.sql\nCOMMIT;\n",
                    encoding="utf-8",
                )
                if mode != "missing":
                    statement = f"INSERT INTO public.{table} (value) VALUES (7);\n"
                    if mode == "sql_error":
                        statement += "SELECT 1 / 0;\n"
                    (folder / "part.sql").write_text(statement, encoding="utf-8")
                try:
                    if mode == "success":
                        self.cluster.load(entry, self.database)
                        self.assertEqual(self.sql(f"SELECT value FROM public.{table};"), ["7"])
                    else:
                        with self.assertRaises(SqlError) as error:
                            self.cluster.load(entry, self.database)
                        if mode == "sql_error":
                            self.assertEqual(error.exception.state, "22012")
                        self.assertEqual(self.sql(f"SELECT to_regclass('public.{table}') IS NULL;"), ["t"])
                finally:
                    self.sql(f"DROP TABLE IF EXISTS public.{table};")

    def test_migration_preserves_rows(self):
        """2026-10-25: 인증 SQL 적용 전후 기존 22개 테이블의 행 수와 내용 지문이 같은지 확인한다.

        사용: unittest 테스트 실행기.
        """
        self.assertEqual(len(self.before), 22)
        self.assertEqual(self.before, self.after)

    def test_fixture_preservation_and_regressions(self):
        """2026-10-25: 검증된 v3 자료에 인증 SQL을 적용하고 기존 저장 검사·행·JSON 보존을 확인한다.

        사용: unittest 테스트 실행기.
        """
        sys.path.insert(0, str(DIRECTORY.parent))
        from reference_data.export_sql import export as reference_export
        from testing.scenarios.export_state import export as scenario_export
        from test_context import build_context
        import run_sql_tests

        fixtures = DIRECTORY.parent / "fixtures" / "generated"
        files = sorted(fixtures.rglob("*.json"))
        before_files = {str(path.relative_to(fixtures)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
        context = build_context(fixtures)
        database = "payse_fixture_auth_" + uuid.uuid4().hex
        self.cluster.sql(f"CREATE DATABASE {database};")
        try:
            self.cluster.load(DIRECTORY / "001_initial.sql", database)
            self.cluster.load(DIRECTORY / "002_storage_guards.sql", database)
            self.cluster.sql(reference_export(), database)
            self.cluster.sql(scenario_export(fixtures, ["alpha-ready", "beta-ready", "gamma-month-end"]), database)
            before_rows = self.fingerprint(database)
            self.cluster.load(DIRECTORY / "003_auth_access.sql", database)
            self.assertEqual(len(before_rows), 22)
            self.assertEqual(before_rows, self.fingerprint(database))

            def run_isolated(psql, selected_database, sql, timeout_seconds):
                """2026-10-25: 기존 SQL 검사기를 이 실행의 검증된 격리 접속으로 연결하고 결과 문자열을 반환한다.

                사용: run_sql_tests.run_suites가 호출하는 run_sql의 임시 대체 함수.
                """
                self.assertEqual(selected_database, database)
                return "\n".join(self.cluster.sql(sql, selected_database))

            with patch.object(run_sql_tests, "run_sql", run_isolated):
                run_sql_tests.run_suites(str(self.cluster.binary("psql")), database, context, 15)
            self.assertEqual(before_rows, self.fingerprint(database))
            self.assertEqual(before_files, {str(path.relative_to(fixtures)): hashlib.sha256(path.read_bytes()).hexdigest()
                                           for path in files})
            self.cluster.report["fixtureRegressionSuites"] = len(run_sql_tests.SUITES)
            self.cluster.report["preservedBaselineTables"] = len(before_rows)
        finally:
            self.cluster.sql(f"DROP DATABASE {database};")

    def test_reapply_is_atomic(self):
        """2026-10-25: 중복 적용을 55000으로 거절하고 기존 행을 변경하지 않는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        before = self.fingerprint()
        with self.assertRaises(SqlError) as error:
            self.cluster.load(DIRECTORY / "003_auth_access.sql", self.database)
        self.assertEqual(error.exception.state, "55000")
        self.assertEqual(before, self.fingerprint())

    def test_roles_and_search_paths(self):
        """2026-10-25: 인증 역할의 제한 속성과 모든 auth 함수의 고정 검색 경로를 확인한다.

        사용: unittest 테스트 실행기.
        """
        self.assertEqual(self.sql("SELECT count(*) FROM pg_roles WHERE rolname IN "
            "('payse_runtime','payse_auth_owner') AND NOT(rolsuper OR rolcanlogin OR rolcreatedb "
            "OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls);"), ["2"])
        self.assertEqual(self.sql("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace "
            "WHERE n.nspname='payse' AND p.proname LIKE 'auth_%' "
            "AND NOT ('search_path=pg_catalog, payse, pg_temp'=ANY(p.proconfig));"), ["0"])

    def test_runtime_secret_access_denied(self):
        """2026-10-25: runtime의 비밀·내부 함수 접근과 허용하지 않은 데이터·스키마 쓰기를 거절하는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        statements = ["SELECT name FROM payse.users;", "SELECT phone FROM payse.users;",
            "SELECT code_verifier FROM payse.users;", "SELECT * FROM payse.demo_sessions;",
            "SELECT * FROM payse.auth_rate_limits;", "UPDATE payse.demo_sessions SET ended_at=clock_timestamp();",
            "DELETE FROM payse.auth_rate_limits;", "TRUNCATE payse.auth_rate_limits;",
            "CREATE TABLE payse.forbidden(value text);",
            "SELECT payse.auth_require_transaction();",
            "SELECT payse.auth_lock_limit('ip'," + quote(digest()) + ");",
            "SELECT payse.auth_combo_state(" + quote(digest()) + ");",
            "SELECT payse.auth_events_valid(ARRAY[]::timestamptz[],5);",
            "UPDATE payse.financial_accounts SET balance_krw=9;"]
        for statement in statements:
            with self.subTest(operation=statement.split()[0], number=statements.index(statement)):
                self.reject(statement)

    def test_session_user_cannot_escalate(self):
        """2026-10-25: runtime 세션 사용자가 관리자·인증 소유자 역할로 승격하거나 비밀에 접근하지 못하는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        prefix = "SET SESSION AUTHORIZATION payse_runtime;"
        self.assertEqual(self.sql(prefix + "SELECT current_user=session_user AND current_user='payse_runtime';"), ["t"])
        self.reject("SET ROLE payse_auth_owner;", prefix=prefix)
        self.reject("SET ROLE payse_test_admin;", prefix=prefix)
        self.reject("SELECT code_verifier FROM payse.users;", prefix=prefix)
        self.reject("CREATE TABLE payse.forbidden(value text);", prefix=prefix)

    def test_public_cannot_execute(self):
        """2026-10-25: PUBLIC 권한만 가진 역할이 인증 함수와 내부 보조 함수를 실행하지 못하는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        calls = ["auth_ip_request(" + quote(digest()) + ")", "auth_limit(" + quote(digest()) + ")",
                 "auth_failure(" + quote(digest()) + ")", "auth_credentials('Ab','01012345678')",
                 "auth_authorize(NULL)", "auth_require_transaction()",
                 "auth_events_valid(ARRAY[]::timestamptz[],5)",
                 "auth_lock_limit('ip'," + quote(digest()) + ")", "auth_combo_state(" + quote(digest()) + ")"]
        for call in calls:
            with self.subTest(function=call.split("(")[0]):
                self.reject("SELECT payse." + call + ";", prefix="SET SESSION AUTHORIZATION payse_auth_public_probe;")

    def test_credentials_are_internal_candidates(self):
        """2026-10-25: 후보 조회가 사용자 ID·검증값을 반환해도 금융 소유자 문맥을 열지는 않는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        user = self.users[0]
        self.assertEqual(self.runtime(f"SELECT user_id={quote(user['id'])}::uuid AND "
            f"code_verifier={quote(user['verifier'])} FROM payse.auth_credentials({quote(user['name'])},{quote(user['phone'])}); "
            "SELECT count(*) FROM payse.financial_accounts"), ["t", "0"])
        unknown = person()
        self.assertEqual(self.runtime("SELECT count(*) FROM payse.auth_credentials("
                         + quote(unknown["name"]) + "," + quote(unknown["phone"]) + ")"), ["0"])

    def test_owner_rows_and_context_cleanup(self):
        """2026-10-25: 소유자 행만 조회되고 커밋·롤백·같은 트랜잭션의 실패 재인증 뒤 문맥이 지워지는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        first, second = self.users
        with self.cluster.connect(self.database) as connection:
            for user, end in ((first, "COMMIT"), (second, "ROLLBACK")):
                rows = connection.sql(f"BEGIN; SET LOCAL ROLE payse_runtime; "
                    f"SELECT user_id={quote(user['id'])}::uuid AND session_id={quote(user['session'])}::uuid "
                    f"FROM payse.auth_authorize({quote(user['token'])}); "
                    f"SELECT count(*)=1 AND bool_and(id={quote(user['account'])}::uuid) FROM payse.financial_accounts; "
                    f"SELECT count(*)=1 AND bool_and(id={quote(user['id'])}::uuid) FROM payse.users; {end}; "
                    "BEGIN; SET LOCAL ROLE payse_runtime; SELECT count(*) FROM payse.financial_accounts; COMMIT;")
                self.assertEqual(rows, ["t", "t", "t", "0"])
            rows = connection.sql(f"BEGIN; SET LOCAL ROLE payse_runtime; "
                f"SELECT count(*) FROM payse.auth_authorize({quote(first['token'])}); "
                "SELECT count(*) FROM payse.auth_authorize(NULL); SELECT count(*) FROM payse.financial_accounts; COMMIT;")
            self.assertEqual(rows, ["1", "0", "0"])

    def test_invalid_tokens_clear_context(self):
        """2026-10-25: 누락·미등록·형식 오류 토큰에서 인증 행과 소유 금융 행이 반환되지 않는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        for token in (None, "", "sha256:" + digest(), "SHA256:" + digest(), "bad-token"):
            with self.subTest(format="null" if token is None else token.split(":")[0]):
                self.assertEqual(self.runtime("SELECT count(*) FROM payse.auth_authorize(" + quote(token)
                    + "); SELECT count(*) FROM payse.financial_accounts"), ["0", "0"])

    def test_runtime_version_write_and_full_rollback(self):
        """2026-10-25: 버전 갱신·저장 검사 오류 시 제한 기록이 롤백되고 후속 연결에서 소유 금융 행이 보이지 않는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        user = self.users[0]
        self.assertEqual(self.sql("BEGIN; SET LOCAL ROLE payse_runtime; SELECT count(*) FROM payse.auth_authorize("
            + quote(user["token"]) + "); UPDATE payse.users SET data_version=data_version+1 WHERE id="
            + quote(user["id"]) + " RETURNING data_version; SELECT payse.assert_user_storage(" + quote(user["id"])
            + "); ROLLBACK; SELECT data_version FROM payse.users WHERE id=" + quote(user["id"]) + ";"), ["1", "2", "1"])
        key = digest()
        self.reject("SELECT payse.auth_failure(" + quote(key) + "); SELECT count(*) FROM payse.auth_authorize("
            + quote(user["token"]) + "); SELECT 1/0;", "22012",
            "BEGIN; SET LOCAL ROLE payse_runtime;")
        self.assertEqual(self.sql("SELECT count(*) FROM payse.auth_rate_limits WHERE kind='combo' AND key_digest="
                                 + quote(key) + ";"), ["0"])
        self.assertEqual(self.runtime("SELECT count(*) FROM payse.financial_accounts"), ["0"])

    def test_inactive_sessions_and_users(self):
        """2026-10-25: 종료 세션·비활성 사용자의 접근을 거절하고 검사에 사용한 상태 변경을 복구한다.

        사용: unittest 테스트 실행기.
        """
        user = self.users[0]
        for change, restore in (
            (f"UPDATE payse.demo_sessions SET ended_at=clock_timestamp() WHERE id={quote(user['session'])}",
             f"UPDATE payse.demo_sessions SET ended_at=NULL WHERE id={quote(user['session'])}"),
            (f"UPDATE payse.users SET deactivated_at=clock_timestamp(),purge_after=clock_timestamp()+interval '1 year' "
             f"WHERE id={quote(user['id'])}",
             f"UPDATE payse.users SET deactivated_at=NULL,purge_after=NULL WHERE id={quote(user['id'])}"),
        ):
            try:
                self.sql(change + ";")
                self.assertEqual(self.runtime("SELECT count(*) FROM payse.auth_authorize(" + quote(user["token"])
                    + "); SELECT count(*) FROM payse.financial_accounts"), ["0", "0"])
            finally:
                self.sql(restore + ";")

    def test_owner_lock_rescans_committed_state(self):
        """2026-10-25: 실제 사용자 잠금 대기 뒤 먼저 커밋된 로그아웃·비활성화를 재조회하여 접근을 거절하는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        user = self.users[0]
        for kind in ("logout", "deactivate"):
            with self.subTest(change=kind):
                try:
                    with self.cluster.connect(self.database) as owner, self.cluster.connect(self.database) as caller:
                        owner.sql(f"BEGIN; SELECT id IS NOT NULL FROM payse.users WHERE id={quote(user['id'])} FOR UPDATE;")
                        marker = caller.submit("BEGIN; SET LOCAL ROLE payse_runtime; SELECT count(*) FROM payse.auth_authorize("
                            + quote(user["token"]) + "); SELECT count(*) FROM payse.financial_accounts; COMMIT;")
                        self.cluster.wait_for_lock(caller.name)
                        if kind == "logout":
                            owner.sql(f"UPDATE payse.demo_sessions SET ended_at=clock_timestamp() WHERE id={quote(user['session'])}; COMMIT;")
                        else:
                            owner.sql("UPDATE payse.users SET deactivated_at=clock_timestamp(),"
                                f"purge_after=clock_timestamp()+interval '1 year' WHERE id={quote(user['id'])}; COMMIT;")
                        self.assertEqual(caller.receive(marker), ["0", "0"])
                finally:
                    self.sql(f"UPDATE payse.demo_sessions SET ended_at=NULL WHERE id={quote(user['session'])}; "
                             f"UPDATE payse.users SET deactivated_at=NULL,purge_after=NULL WHERE id={quote(user['id'])};")

    def test_transaction_requirements(self):
        """2026-10-25: 반복 읽기·직렬화·읽기 전용 트랜잭션에서 인증 함수를 25000으로 거절하는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        calls = ["payse.auth_authorize(NULL)", "payse.auth_credentials('Ab','01012345678')",
                 "payse.auth_limit(" + quote(digest()) + ")", "payse.auth_failure(" + quote(digest()) + ")",
                 "payse.auth_ip_request(" + quote(digest()) + ")"]
        for mode in ("ISOLATION LEVEL REPEATABLE READ", "ISOLATION LEVEL SERIALIZABLE", "READ ONLY"):
            for call in calls:
                with self.subTest(mode=mode, function=call.split("(")[0]):
                    self.reject("SELECT " + call + ";", "25000", f"BEGIN {mode}; SET LOCAL ROLE payse_runtime;")

    def test_generic_input_errors(self):
        """2026-10-25: 잘못된 제한 키와 정규화되지 않은 자격 입력을 22023으로 거절하는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        for value in (None, "", "A" * 64, "a" * 63, "a" * 65, "bad secret value"):
            for function in ("auth_limit", "auth_failure", "auth_ip_request"):
                with self.subTest(function=function, length=0 if value is None else len(value)):
                    self.reject("SELECT payse." + function + "(" + quote(value) + ");", "22023")
        for name, phone in ((None, "01012345678"), ("A B", "01012345678"), ("Ab", None),
                            ("Ab", "010-1234-5678"), ("A", "01012345678"), ("Ab", "01112345678")):
            self.reject("SELECT * FROM payse.auth_credentials(" + quote(name) + "," + quote(phone) + ");", "22023")

    def test_counter_commit_and_rollback(self):
        """2026-10-25: 요청/실패 기록은 커밋에만 남고 롤백하면 취소되는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        key = digest()
        self.assertEqual(self.runtime("SELECT payse.auth_failure(" + quote(key) + ") IS NULL"), ["t"])
        self.sql("BEGIN; SET LOCAL ROLE payse_runtime; SELECT payse.auth_failure(" + quote(key) + "); ROLLBACK;")
        self.assertEqual(self.sql("SELECT cardinality(event_times) FROM payse.auth_rate_limits WHERE kind='combo' AND key_digest="
                                 + quote(key) + ";"), ["1"])
        ip_key = digest()
        self.sql("BEGIN; SET LOCAL ROLE payse_runtime; SELECT allowed FROM payse.auth_ip_request(" + quote(ip_key) + "); ROLLBACK;")
        self.assertEqual(self.sql("SELECT count(*) FROM payse.auth_rate_limits WHERE kind='ip' AND key_digest=" + quote(ip_key) + ";"), ["0"])
        self.assertEqual(self.runtime("SELECT allowed FROM payse.auth_ip_request(" + quote(ip_key) + ")"), ["t"])

    def test_combination_threshold_and_no_extension(self):
        """2026-10-25: 다섯 번째 실패부터 차단하고 실패 기록 없는 제한 조회·차단 중 재시도가 이력이나 기한을 바꾸지 않는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        key = digest()
        for _ in range(4):
            self.assertEqual(self.runtime("SELECT payse.auth_failure(" + quote(key) + ") IS NULL"), ["t"])
        # A successful comparison is represented only by the read/check call, without a failure write.
        self.assertEqual(self.runtime("SELECT payse.auth_limit(" + quote(key) + ") IS NULL"), ["t"])
        self.assertEqual(self.sql("SELECT cardinality(event_times) FROM payse.auth_rate_limits WHERE kind='combo' AND key_digest="
                                 + quote(key) + ";"), ["4"])
        self.assertEqual(self.runtime("SELECT payse.auth_failure(" + quote(key) + ") IS NOT NULL"), ["t"])
        before = self.sql("SELECT md5(event_times::text||blocked_until::text),blocked_until=event_times[5]+interval '5 minutes' "
                          "FROM payse.auth_rate_limits WHERE kind='combo' AND key_digest=" + quote(key) + ";")
        for _ in range(3):
            self.assertEqual(self.runtime("SELECT payse.auth_failure(" + quote(key) + ") IS NOT NULL"), ["t"])
        self.assertEqual(self.sql("SELECT md5(event_times::text||blocked_until::text),blocked_until=event_times[5]+interval '5 minutes' "
                                 "FROM payse.auth_rate_limits WHERE kind='combo' AND key_digest=" + quote(key) + ";"), before)
        self.assertTrue(before[0].endswith("|t"))

    def test_combination_expiry(self):
        """2026-10-25: 실제 시계에서 차단 만료 전·기한 도달 이후 동작을 확인한다. 시각을 마이크로초 단위로 고정하는 검사는 아니다.

        사용: unittest 테스트 실행기.
        """
        key = digest()
        self.sql("WITH deadline AS MATERIALIZED (SELECT clock_timestamp()+interval '2 seconds' AS at) "
                 "INSERT INTO payse.auth_rate_limits SELECT 'combo'," + quote(key) + ","
                 "array_fill(at-interval '5 minutes',ARRAY[5]),at FROM deadline;")
        self.assertEqual(self.runtime("SELECT payse.auth_limit(" + quote(key) + ") IS NOT NULL"), ["t"])
        self.sql("SELECT pg_sleep_until(blocked_until) FROM payse.auth_rate_limits WHERE kind='combo' AND key_digest=" + quote(key) + ";")
        self.assertEqual(self.runtime("SELECT payse.auth_limit(" + quote(key) + ") IS NULL"), ["t"])
        self.assertEqual(self.sql("SELECT cardinality(event_times),blocked_until IS NULL FROM payse.auth_rate_limits "
                                 "WHERE kind='combo' AND key_digest=" + quote(key) + ";"), ["0|t"])

    def test_old_events_expire(self):
        """2026-10-25: 5분·60초 창보다 오래된 사건을 제외한 뒤 새 사건만 남는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        for kind, function, window in (("combo", "auth_failure", "5 minutes"), ("ip", "auth_ip_request", "60 seconds")):
            key = digest()
            self.sql("INSERT INTO payse.auth_rate_limits(kind,key_digest,event_times) VALUES ("
                     + quote(kind) + "," + quote(key) + ",ARRAY[clock_timestamp()-interval " + quote(window) + "]);")
            self.runtime("SELECT payse." + function + "(" + quote(key) + ")")
            self.assertEqual(self.sql("SELECT cardinality(event_times) FROM payse.auth_rate_limits WHERE kind="
                                     + quote(kind) + " AND key_digest=" + quote(key) + ";"), ["1"])

    def test_ip_threshold_and_rejected_record(self):
        """2026-10-25: IP 60회 허용 후 거절하며 거절 요청도 최근 60개 사건에 기록하는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        key = digest()
        with self.cluster.connect(self.database) as connection:
            for index in range(61):
                rows = connection.sql("BEGIN; SET LOCAL ROLE payse_runtime; SELECT allowed,retry_at IS NULL FROM "
                    "payse.auth_ip_request(" + quote(key) + "); COMMIT;")
                self.assertEqual(rows, ["t|t" if index < 60 else "f|f"])
        before = self.sql("SELECT event_times[60]::text FROM payse.auth_rate_limits WHERE kind='ip' AND key_digest=" + quote(key) + ";")[0]
        self.assertEqual(self.runtime("SELECT allowed FROM payse.auth_ip_request(" + quote(key) + ")"), ["f"])
        self.assertEqual(self.sql("SELECT cardinality(event_times)=60 AND event_times[60]>" + quote(before)
                                 + "::timestamptz FROM payse.auth_rate_limits WHERE kind='ip' AND key_digest=" + quote(key) + ";"), ["t"])

    def test_ip_expiry(self):
        """2026-10-25: 실제 시계에서 이전 IP 요청의 제한 창이 지나면 새 요청을 허용하는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        key = digest()
        self.sql("INSERT INTO payse.auth_rate_limits(kind,key_digest,event_times) VALUES ('ip'," + quote(key)
                 + ",array_fill(clock_timestamp()-interval '58 seconds',ARRAY[60]));")
        self.assertEqual(self.runtime("SELECT allowed FROM payse.auth_ip_request(" + quote(key) + ")"), ["f"])
        self.sql("SELECT pg_sleep_until(event_times[1]+interval '60 seconds') FROM payse.auth_rate_limits "
                 "WHERE kind='ip' AND key_digest=" + quote(key) + ";")
        self.assertEqual(self.runtime("SELECT allowed FROM payse.auth_ip_request(" + quote(key) + ")"), ["t"])

    def test_first_insert_waits(self):
        """2026-10-25: 같은 신규 키의 두 번째 요청이 실제 잠금을 기다리고 두 사건이 모두 저장되는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        for kind, function in (("combo", "auth_failure"), ("ip", "auth_ip_request")):
            key = digest()
            with self.subTest(kind=kind), self.cluster.connect(self.database) as first, self.cluster.connect(self.database) as second:
                first.sql("BEGIN; SET LOCAL ROLE payse_runtime; SELECT payse." + function + "(" + quote(key) + ");")
                marker = second.submit("BEGIN; SET LOCAL ROLE payse_runtime; SELECT payse." + function + "(" + quote(key) + "); COMMIT;")
                self.cluster.wait_for_lock(second.name)
                first.sql("COMMIT;")
                second.receive(marker)
            self.assertEqual(self.sql("SELECT cardinality(event_times) FROM payse.auth_rate_limits WHERE kind="
                                     + quote(kind) + " AND key_digest=" + quote(key) + ";"), ["2"])

    def test_parallel_limits_do_not_overrun(self):
        """2026-10-25: 동시 요청에서도 조합·IP의 허용 수와 저장 사건 수 상한을 넘지 않는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        for kind, function, attempts, accepted in (("combo", "auth_failure", 12, 4), ("ip", "auth_ip_request", 72, 60)):
            key = digest()
            expression = "payse.auth_failure(" + quote(key) + ") IS NULL" if kind == "combo" else "allowed FROM payse.auth_ip_request(" + quote(key) + ")"
            with self.subTest(kind=kind), ThreadPoolExecutor(max_workers=12) as workers:
                requests = [workers.submit(self.runtime, "SELECT " + expression) for _ in range(attempts)]
                results = [request.result(timeout=20)[0] for request in requests]
            self.assertEqual(results.count("t"), accepted)
            self.assertEqual(results.count("f"), attempts - accepted)
            self.assertEqual(self.sql("SELECT cardinality(event_times) FROM payse.auth_rate_limits WHERE kind="
                                     + quote(kind) + " AND key_digest=" + quote(key) + ";"), ["5" if kind == "combo" else "60"])

    def test_array_and_deadline_constraints(self):
        """2026-10-25: 사건 배열의 null·유한성·정렬·차원·상한과 차단 기한의 정합성 제약을 확인한다.

        사용: unittest 테스트 실행기.
        """
        invalid = ["NULL", "ARRAY[NULL]::timestamptz[]", "ARRAY['infinity'::timestamptz]",
            "ARRAY['-infinity'::timestamptz]", "ARRAY[clock_timestamp(),clock_timestamp()-interval '1 second']",
            "ARRAY[[clock_timestamp(),clock_timestamp()]]", "array_fill(clock_timestamp(),ARRAY[1],ARRAY[0])",
            "array_fill(clock_timestamp(),ARRAY[6])"]
        for events in invalid:
            with self.subTest(case=invalid.index(events)):
                self.reject("INSERT INTO payse.auth_rate_limits(kind,key_digest,event_times) VALUES ('combo',"
                    + quote(digest()) + "," + events + ");", "23502" if events == "NULL" else "23514", prefix="")
        for kind, events, deadline in (("ip", "array_fill(now(),ARRAY[61])", "NULL"),
            ("ip", "ARRAY[now()]", "now()"), ("combo", "ARRAY[now()]", "now()+interval '5 minutes'"),
            ("combo", "array_fill(now(),ARRAY[5])", "NULL"),
            ("combo", "array_fill(now(),ARRAY[5])", "'infinity'"),
            ("combo", "array_fill(now(),ARRAY[5])", "now()+interval '6 minutes'")):
            self.reject("INSERT INTO payse.auth_rate_limits VALUES (" + quote(kind) + "," + quote(digest())
                        + "," + events + "," + deadline + ");", "23514", prefix="")

    def test_clock_reversal_rejected(self):
        """2026-10-25: 저장된 마지막 사건이 현재 시각보다 미래이면 55000으로 거절하는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        key = digest()
        self.sql("INSERT INTO payse.auth_rate_limits(kind,key_digest,event_times) VALUES ('ip'," + quote(key)
                 + ",ARRAY[clock_timestamp()+interval '1 minute']);")
        self.reject("SELECT payse.auth_ip_request(" + quote(key) + ");", "55000")

    def test_deactivation_constraints(self):
        """2026-10-25: 비활성·파쇄 시각의 null 쌍·유한성·선후관계 위반을 23514로 거절하는지 확인한다.

        사용: unittest 테스트 실행기.
        """
        user = self.users[0]
        for dates in ("deactivated_at=now()", "purge_after=now()",
            "deactivated_at=now(),purge_after=now()", "deactivated_at='-infinity',purge_after=now()",
            "deactivated_at=now(),purge_after='infinity'"):
            self.reject("UPDATE payse.users SET " + dates + " WHERE id=" + quote(user["id"]) + ";", "23514", prefix="")

    def test_unsafe_migration_inputs_are_atomic(self):
        """2026-10-25: 권한·역할·RLS가 오염된 기준 DB를 원자적으로 거절하고 검사한 역할 변경을 복구한다.

        사용: unittest 테스트 실행기.
        """
        cases = [
            ("role_attribute", "ALTER ROLE payse_runtime LOGIN;", "ALTER ROLE payse_runtime NOLOGIN;"),
            ("role_membership", "GRANT payse_auth_owner TO payse_runtime;", "REVOKE payse_auth_owner FROM payse_runtime;"),
            ("public_table", "GRANT SELECT ON payse.users TO PUBLIC;", ""),
            ("public_column", "GRANT SELECT(code_verifier) ON payse.users TO PUBLIC;", ""),
            ("runtime_column", "GRANT SELECT(code_verifier) ON payse.users TO payse_runtime;", ""),
            ("default_table", "ALTER DEFAULT PRIVILEGES GRANT TRUNCATE ON TABLES TO payse_runtime;", ""),
            ("default_function", "ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO payse_runtime;", ""),
            ("owned_function", "CREATE FUNCTION payse.old_function() RETURNS integer LANGUAGE sql SECURITY DEFINER AS 'SELECT 1'; "
             "ALTER FUNCTION payse.old_function() OWNER TO payse_auth_owner;", ""),
            ("schema_create", "GRANT CREATE ON SCHEMA payse TO payse_auth_public_probe;", ""),
            ("rls_disabled", "ALTER TABLE payse.financial_accounts DISABLE ROW LEVEL SECURITY;", ""),
            ("rls_not_forced", "ALTER TABLE payse.users NO FORCE ROW LEVEL SECURITY;", ""),
            ("rls_extra_policy", "CREATE POLICY unexpected_access ON payse.financial_accounts USING (true);", ""),
            ("rls_altered_policy", "ALTER POLICY own_rows ON payse.users USING (true);", ""),
        ]
        for label, prepare, restore in cases:
            database = "payse_auth_test_" + uuid.uuid4().hex
            with self.subTest(case=label):
                self.cluster.sql(f"CREATE DATABASE {database};")
                try:
                    self.cluster.load(DIRECTORY / "001_initial.sql", database)
                    self.cluster.load(DIRECTORY / "002_storage_guards.sql", database)
                    self.cluster.sql(prepare, database)
                    with self.assertRaises(SqlError) as error:
                        self.cluster.load(DIRECTORY / "003_auth_access.sql", database)
                    self.assertEqual(error.exception.state, "55000")
                    self.assertEqual(self.cluster.sql("SELECT to_regclass('payse.auth_rate_limits') IS NULL AND "
                        "NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='payse' "
                        "AND table_name='users' AND column_name IN ('deactivated_at','purge_after'));", database), ["t"])
                finally:
                    if restore:
                        self.cluster.sql(restore, database)
                    self.cluster.sql(f"DROP DATABASE {database};")


def main():
    """2026-10-25: 명시된 새 격리 서버에서 전체 검사를 실행하고 HTTP 미검증을 포함한 결과를 기록한 뒤 종료 코드를 반환한다.

    사용: 파일 직접 실행 진입점.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", required=True, type=Path, help="PostgreSQL directory containing initdb, pg_ctl and psql")
    parser.add_argument("--work-dir", required=True, type=Path, help="New private directory; never an existing database/cluster")
    arguments = parser.parse_args()
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        AuthAccessTests.cluster = cluster
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(AuthAccessTests)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        cluster.report.update({"testsRun": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
            "passed": result.wasSuccessful(), "httpSessionsVerified": False,
            "expiryCheck": "real clock before and at-or-after deadline; no frozen microsecond equality"})
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(f"Isolated auth tests could not complete: {type(error).__name__}", file=sys.stderr)
        sys.exit(2)
