"""2026-10-26: 새 격리 PostgreSQL에서 세션 SQL의 권한·잠금·원자성을 검사한다.

사용: --pg-bin과 존재하지 않는 --work-dir을 지정한 직접 실행. 기존 DB 접속 옵션은 받지 않는다.
"""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import hashlib
import json
import secrets
import shutil
import tempfile
import unittest
import uuid

from auth_test_support import Cluster, SqlError, quote
from test_auth_access import AuthAccessTests, person


DIRECTORY = Path(__file__).resolve().parent
ENTRY = DIRECTORY / "004_auth_sessions.sql"


class SessionTests(unittest.TestCase):
    """2026-10-26: 공통 사용자·금융 구조를 유지하며 실제 세션 저장 경계를 검사한다.

    사용: main의 unittest 실행기. 코드 대조·HTTP 응답은 Java 서비스 검사에서 구분한다.
    """

    cluster = None
    database = "payse_auth_test_sessions"
    template = "payse_auth_test_sessions_base"

    @classmethod
    def setUpClass(cls):
        """2026-10-26: 기존 인증 기반·유효 관계를 만들고 004의 원본 보존을 기록한다.

        사용: unittest 클래스 준비.
        """
        if cls.cluster is None:
            raise unittest.SkipTest("Use the explicit isolated PostgreSQL runner")
        cls.cluster.sql(f"CREATE DATABASE {cls.template};")
        for name in ("001_initial.sql", "002_storage_guards.sql"):
            cls.cluster.load(DIRECTORY / name, cls.template)
        cls.bank = "bank" + uuid.uuid4().hex
        cls.cluster.sql(
            "INSERT INTO payse.institutions(code,kind,name) VALUES ("
            + quote(cls.bank) + ",'bank','가상은행');", cls.template,
        )
        cls.cluster.load(DIRECTORY / "003_auth_access.sql", cls.template)
        cls.cluster.sql(f"CREATE DATABASE {cls.database} TEMPLATE {cls.template};")
        cls.users = [person(), person()]
        for index, user in enumerate(cls.users):
            AuthAccessTests.seed_user.__func__(cls, user, index + 1)
        cls.before = cls.fingerprint()
        cls.cluster.load(ENTRY, cls.database)
        cls.after = cls.fingerprint()
        cls.cluster.sql("CREATE ROLE payse_session_public_probe NOLOGIN;", cls.database)
        cls.cluster.sql("GRANT USAGE ON SCHEMA payse TO payse_session_public_probe;", cls.database)

    @classmethod
    def fingerprint(cls, database=None):
        """2026-10-26: 현재 공통 행을 순서와 무관한 지문으로 읽는다.

        사용: 이행 전후 보존·rollback 검사. 이전 검증기의 전체 22개 공통 테이블 규칙을 재사용한다.
        """
        return AuthAccessTests.fingerprint.__func__(cls, database)

    def sql(self, statement):
        """2026-10-26: 검사 소유 클러스터의 현재 DB에만 관리자 SQL을 실행한다.

        사용: SessionTests의 준비·검증.
        """
        return self.cluster.sql(statement, self.database)

    def runtime(self, statement):
        """2026-10-26: runtime 역할의 명시 트랜잭션을 실행하고 정상 반환을 커밋한다.

        사용: 함수 권한·상태 검사.
        """
        return self.sql("BEGIN; SET LOCAL ROLE payse_runtime;\n" + statement + "\nCOMMIT;")

    def new_user(self):
        """2026-10-26: 동적 ID·관계를 검증한 새 사용자를 준비하고 세션만 명시 종료해 로그인 가능하게 한다.

        사용: 독립적인 세션 전이 테스트. 금융 행·ID·금액은 생성한 관계 그대로 유지한다.
        """
        user = person()
        AuthAccessTests.seed_user.__func__(type(self), user, 100)
        self.sql(
            "UPDATE payse.demo_sessions SET ended_at=clock_timestamp() WHERE id="
            + quote(user["session"]) + " AND user_id=" + quote(user["id"]) + ";"
        )
        self.assertEqual(self.sql(
            "SELECT count(*) FROM payse.demo_sessions WHERE user_id="
            + quote(user["id"]) + " AND ended_at IS NULL;"), ["0"])
        return user

    def open_sql(self, user, token=None):
        """2026-10-26: 준비된 소유자 ID와 호출별 토큰 검증값을 인용한 검사 SQL을 만든다.

        사용: 세션 생성·경합 검사. 제품 호출은 JDBC 바인딩을 사용한다.
        """
        token = token or user["token"]
        return (
            "SELECT row_to_json(session) FROM payse.auth_open_session("
            + quote(user["id"]) + "," + quote(token) + ") session;"
        )

    def reject(self, statement, state="42501"):
        """2026-10-26: runtime SQL이 기대 SQLSTATE로 실패하고 열린 트랜잭션을 남기지 않는지 확인한다.

        사용: 입력·직접 권한·격리 수준 검사.
        """
        with self.assertRaises(SqlError) as error:
            self.runtime(statement)
        self.assertEqual(error.exception.state, state)

    def test_migration_preserves_rows(self):
        """2026-10-26: 004 적용이 기존 사용자·금융·세션 22개 테이블의 행을 바꾸지 않는지 확인한다.

        사용: unittest.
        """
        self.assertEqual(len(self.before), 22)
        self.assertEqual(self.before, self.after)

    def test_permissions(self):
        """2026-10-26: runtime 직접 세션 접근·PUBLIC 실행·역할 상승을 거절하고 허용 열만 확인한다.

        사용: unittest.
        """
        user = self.users[0]
        for statement in (
            "SELECT token_digest FROM payse.demo_sessions;",
            "INSERT INTO payse.demo_sessions(id,user_id,token_digest,issued_at) VALUES ("
            + quote(str(uuid.uuid4())) + "," + quote(user["id"]) + ",'x',clock_timestamp());",
            "UPDATE payse.demo_sessions SET ended_at=clock_timestamp();",
            "DELETE FROM payse.demo_sessions;",
            "TRUNCATE payse.demo_sessions;",
        ):
            with self.subTest(statement=statement.split()[0]):
                self.reject(statement)
        with self.assertRaises(SqlError) as error:
            self.sql("SET ROLE payse_session_public_probe; SELECT payse.auth_end_session(NULL);")
        self.assertEqual(error.exception.state, "42501")
        with self.assertRaises(SqlError) as error:
            self.sql("SET SESSION AUTHORIZATION payse_runtime; SET ROLE payse_auth_owner;")
        self.assertEqual(error.exception.state, "42501")
        self.assertEqual(self.sql(
            "SELECT has_column_privilege('payse_auth_owner','payse.demo_sessions','ended_at','UPDATE') "
            "AND NOT has_column_privilege('payse_auth_owner','payse.demo_sessions','token_digest','UPDATE') "
            "AND NOT has_table_privilege('payse_auth_owner','payse.demo_sessions','DELETE');"), ["t"])
        self.assertEqual(self.sql(
            "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace "
            "WHERE n.nspname='payse' AND p.proname IN "
            "('auth_login_account','auth_open_session','auth_end_session') AND p.prosecdef "
            "AND p.proowner=(SELECT oid FROM pg_roles WHERE rolname='payse_auth_owner') "
            "AND p.proconfig=ARRAY['search_path=pg_catalog, payse, pg_temp'];"), ["3"])

    def test_login_candidate(self):
        """2026-10-26: 잠긴 후보에는 현재 코드만 담기며 비활성·DISABLED는 상태 거절과 구분한다.

        사용: unittest. 실제 코드 일치 판정은 AuthService 검사 책임이다.
        """
        user = self.new_user()
        statement = "SELECT row_to_json(account) FROM payse.auth_login_account(" + quote(user["name"])
        statement += "," + quote(user["phone"]) + ") account;"
        result = json.loads(self.runtime(statement)[0])
        self.assertEqual(result["user_id"], user["id"])
        self.assertEqual(result["name"], user["name"])
        self.assertEqual(result["code_verifier"], user["verifier"])
        self.sql("UPDATE payse.users SET deactivated_at=clock_timestamp(),"
                 "purge_after=clock_timestamp()+interval '1 year' WHERE id=" + quote(user["id"]) + ";")
        self.assertEqual(json.loads(self.runtime(statement)[0])["user_id"], user["id"])
        self.assertEqual(self.runtime(self.open_sql(user, "sha256:" + secrets.token_hex(32))), [])

    def test_open_end_and_relogin(self):
        """2026-10-26: 새 세션 한 건·기존 우선·명시 종료·재로그인과 금융 원천 불변을 확인한다.

        사용: unittest.
        """
        user = self.new_user()
        before = self.fingerprint()
        token = "sha256:" + secrets.token_hex(32)
        created = json.loads(self.runtime(self.open_sql(user, token))[0])
        self.assertEqual(set(created), {"user_id", "session_id", "name", "issued_at"})
        self.assertEqual(created["user_id"], user["id"])
        self.assertEqual(created["name"], user["name"])
        self.assertEqual(self.runtime(self.open_sql(user, "sha256:" + secrets.token_hex(32))), [])
        self.assertEqual(self.runtime("SELECT payse.auth_end_session(" + quote(token) + ");"), ["t"])
        self.assertEqual(self.runtime("SELECT payse.auth_end_session(" + quote(token) + ");"), ["f"])
        self.assertEqual(self.runtime("SELECT count(*) FROM payse.auth_authorize(" + quote(token) + ");"), ["0"])
        second = json.loads(self.runtime(self.open_sql(user, "sha256:" + secrets.token_hex(32)))[0])
        self.assertNotEqual(created["session_id"], second["session_id"])
        after = self.fingerprint()
        self.assertEqual({k: v for k, v in before.items() if k != "demo_sessions"},
                         {k: v for k, v in after.items() if k != "demo_sessions"})

    def test_invalid_inputs(self):
        """2026-10-26: 정규화 위반·누락·잘못된 digest·격리 수준을 거절하고 무효 토큰은 false로 반환한다.

        사용: unittest.
        """
        user = self.new_user()
        for name, phone in ((None, user["phone"]), (user["name"] + " ", user["phone"]),
                            (user["name"], "010-0000-0000")):
            self.reject("SELECT * FROM payse.auth_login_account(" + quote(name) + "," + quote(phone) + ");", "22023")
        for owner, token in ((None, user["token"]), (user["id"], None), (user["id"], "raw-token")):
            self.reject("SELECT * FROM payse.auth_open_session(" + quote(owner) + "," + quote(token) + ");", "22023")
        for token in (None, "bad-token", "sha256:" + secrets.token_hex(32)):
            self.assertEqual(self.runtime("SELECT payse.auth_end_session(" + quote(token) + ");"), ["f"])
        for options in ("ISOLATION LEVEL REPEATABLE READ", "READ ONLY"):
            with self.assertRaises(SqlError) as error:
                self.sql("BEGIN " + options + "; SET LOCAL ROLE payse_runtime;" + self.open_sql(user) + "COMMIT;")
            self.assertEqual(error.exception.state, "25000")

    def test_concurrent_open(self):
        """2026-10-26: 독립 연결의 동시 로그인 8건 중 세션을 정확히 한 건만 생성한다.

        사용: unittest. 사용자 행 잠금·부분 UNIQUE를 실제 DB에서 검사한다.
        """
        user = self.new_user()
        statements = [self.open_sql(user, "sha256:" + secrets.token_hex(32)) for _ in range(8)]
        with ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(self.runtime, statements))
        self.assertEqual(sum(len(rows) for rows in results), 1)
        self.assertEqual(self.sql("SELECT count(*) FROM payse.demo_sessions WHERE user_id="
                                 + quote(user["id"]) + " AND ended_at IS NULL;"), ["1"])

    def test_waiting_login_rechecks_verifier(self):
        """2026-10-26: 사용자 잠금 대기 중 바뀐 verifier를 대기 종료 뒤 다시 읽는다.

        사용: unittest.
        """
        user = self.new_user()
        replacement = "DISABLED:" + secrets.token_hex(12)
        with self.cluster.connect(self.database) as owner, self.cluster.connect(self.database) as waiting:
            owner.sql("BEGIN; SELECT id FROM payse.users WHERE id=" + quote(user["id"]) + " FOR UPDATE;")
            waiting.sql("BEGIN; SET LOCAL ROLE payse_runtime;")
            marker = waiting.submit("SELECT code_verifier FROM payse.auth_login_account("
                                    + quote(user["name"]) + "," + quote(user["phone"]) + ");")
            self.cluster.wait_for_lock(waiting.name)
            owner.sql("UPDATE payse.users SET code_verifier=" + quote(replacement)
                      + " WHERE id=" + quote(user["id"]) + "; COMMIT;")
            self.assertEqual(waiting.receive(marker), [replacement])
            waiting.sql("COMMIT;")

    def test_waiting_login_rechecks_identity(self):
        """2026-10-26: 잠금 대기 중 입력 조합이 변경되면 예전 이름으로 후보를 반환하지 않는다.

        사용: unittest.
        """
        user = self.new_user()
        with self.cluster.connect(self.database) as owner, self.cluster.connect(self.database) as waiting:
            owner.sql("BEGIN; SELECT id FROM payse.users WHERE id=" + quote(user["id"]) + " FOR UPDATE;")
            waiting.sql("BEGIN; SET LOCAL ROLE payse_runtime;")
            marker = waiting.submit("SELECT user_id FROM payse.auth_login_account("
                                    + quote(user["name"]) + "," + quote(user["phone"]) + ");")
            self.cluster.wait_for_lock(waiting.name)
            owner.sql("UPDATE payse.users SET name=" + quote("Changed" + user["name"][-8:])
                      + " WHERE id=" + quote(user["id"]) + "; COMMIT;")
            self.assertEqual(waiting.receive(marker), [])
            waiting.sql("COMMIT;")

    def test_logout_blocks_waiting_authorization(self):
        """2026-10-26: 종료가 먼저 커밋되면 기다리던 재확인·조회 인증을 거절한다.

        사용: unittest.
        """
        user = self.new_user()
        token = "sha256:" + secrets.token_hex(32)
        self.runtime(self.open_sql(user, token))
        with self.cluster.connect(self.database) as ending, self.cluster.connect(self.database) as waiting:
            self.assertEqual(ending.sql("BEGIN; SET LOCAL ROLE payse_runtime; SELECT payse.auth_end_session("
                                        + quote(token) + ");"), ["t"])
            waiting.sql("BEGIN; SET LOCAL ROLE payse_runtime;")
            marker = waiting.submit("SELECT count(*) FROM payse.auth_authorize(" + quote(token) + ");")
            self.cluster.wait_for_lock(waiting.name)
            ending.sql("COMMIT;")
            self.assertEqual(waiting.receive(marker), ["0"])
            self.assertEqual(waiting.sql("SELECT coalesce(current_setting('payse.user_id',true),'')=''; COMMIT;"), ["t"])

    def test_authorization_blocks_logout(self):
        """2026-10-26: 이미 잠근 조회·재확인이 끝난 뒤에만 종료가 진행되고 후속 인증은 거절된다.

        사용: unittest.
        """
        user = self.new_user()
        token = "sha256:" + secrets.token_hex(32)
        self.runtime(self.open_sql(user, token))
        with self.cluster.connect(self.database) as reading, self.cluster.connect(self.database) as ending:
            self.assertEqual(reading.sql("BEGIN; SET LOCAL ROLE payse_runtime; SELECT count(*) FROM payse.auth_authorize("
                                        + quote(token) + ");"), ["1"])
            ending.sql("BEGIN; SET LOCAL ROLE payse_runtime;")
            marker = ending.submit("SELECT payse.auth_end_session(" + quote(token) + ");")
            self.cluster.wait_for_lock(ending.name)
            reading.sql("COMMIT;")
            self.assertEqual(ending.receive(marker), ["t"])
            ending.sql("COMMIT;")
        self.assertEqual(self.runtime("SELECT count(*) FROM payse.auth_authorize(" + quote(token) + ");"), ["0"])

    def test_open_after_concurrent_logout(self):
        """2026-10-26: 종료를 기다리는 새 로그인은 커밋된 종료 후 한 개의 새 세션만 생성한다.

        사용: unittest.
        """
        user = self.new_user()
        token = "sha256:" + secrets.token_hex(32)
        self.runtime(self.open_sql(user, token))
        with self.cluster.connect(self.database) as ending, self.cluster.connect(self.database) as opening:
            ending.sql("BEGIN; SET LOCAL ROLE payse_runtime; SELECT payse.auth_end_session(" + quote(token) + ");")
            opening.sql("BEGIN; SET LOCAL ROLE payse_runtime;")
            marker = opening.submit(self.open_sql(user, "sha256:" + secrets.token_hex(32)))
            self.cluster.wait_for_lock(opening.name)
            ending.sql("COMMIT;")
            self.assertEqual(len(opening.receive(marker)), 1)
            opening.sql("COMMIT;")

    def test_rollback_and_context(self):
        """2026-10-26: 생성·종료 롤백과 종료 후 같은 연결의 사용자 문맥 제거를 확인한다.

        사용: unittest.
        """
        user = self.new_user()
        token = "sha256:" + secrets.token_hex(32)
        before = self.fingerprint()
        with self.cluster.connect(self.database) as connection:
            connection.sql("BEGIN; SET LOCAL ROLE payse_runtime;" + self.open_sql(user, token) + "ROLLBACK;")
            self.assertEqual(self.fingerprint(), before)
            connection.sql("BEGIN; SET LOCAL ROLE payse_runtime;" + self.open_sql(user, token) + "COMMIT;")
            before_end = self.fingerprint()
            connection.sql("BEGIN; SET LOCAL ROLE payse_runtime; SELECT payse.auth_end_session(" + quote(token) + "); ROLLBACK;")
            self.assertEqual(self.fingerprint(), before_end)
            self.assertEqual(connection.sql("BEGIN; SET LOCAL ROLE payse_runtime; SELECT count(*) FROM payse.auth_authorize("
                + quote(token) + "); SELECT payse.auth_end_session(" + quote(token) + ");"
                "SELECT coalesce(current_setting('payse.user_id',true),'')=''; COMMIT;"
                "SELECT coalesce(current_setting('payse.user_id',true),'')='';"), ["1", "t", "t", "t"])

    def test_duplicate_digest_rolls_back(self):
        """2026-10-26: 토큰 digest 충돌을 성공으로 숨기지 않으며 기존 행과 두 사용자 상태를 보존한다.

        사용: unittest.
        """
        user = self.new_user()
        before = self.fingerprint()
        self.reject(self.open_sql(user, self.users[0]["token"]), "23505")
        self.assertEqual(self.fingerprint(), before)

    def test_deactivation_wins_over_waiting_login(self):
        """2026-10-26: 먼저 커밋된 비활성 상태를 대기 중 세션 생성이 재검사한다.

        사용: unittest.
        """
        user = self.new_user()
        with self.cluster.connect(self.database) as deactivating, self.cluster.connect(self.database) as opening:
            deactivating.sql("BEGIN; SELECT id FROM payse.users WHERE id=" + quote(user["id"]) + " FOR UPDATE;")
            opening.sql("BEGIN; SET LOCAL ROLE payse_runtime;")
            marker = opening.submit(self.open_sql(user, "sha256:" + secrets.token_hex(32)))
            self.cluster.wait_for_lock(opening.name)
            deactivating.sql("UPDATE payse.users SET deactivated_at=clock_timestamp(),"
                "purge_after=clock_timestamp()+interval '1 year' WHERE id=" + quote(user["id"]) + "; COMMIT;")
            self.assertEqual(opening.receive(marker), [])
            opening.sql("COMMIT;")

    def test_reapply_is_rejected(self):
        """2026-10-26: 004 재실행은 기존 상태를 바꾸지 않고 명시적으로 거절한다.

        사용: unittest.
        """
        before = self.fingerprint()
        with self.assertRaises(SqlError) as error:
            self.cluster.load(ENTRY, self.database)
        self.assertEqual(error.exception.state, "55000")
        self.assertEqual(self.fingerprint(), before)

    def test_missing_auth_access_is_rejected(self):
        """2026-10-26: 003이 없는 기본 DB에 세션 전이만 부분 적용하지 않는다.

        사용: unittest.
        """
        database = "payse_auth_test_" + uuid.uuid4().hex
        self.cluster.sql(f"CREATE DATABASE {database};")
        try:
            self.cluster.load(DIRECTORY / "001_initial.sql", database)
            self.cluster.load(DIRECTORY / "002_storage_guards.sql", database)
            with self.assertRaises(SqlError) as error:
                self.cluster.load(ENTRY, database)
            self.assertEqual(error.exception.state, "55000")
            self.assertEqual(self.cluster.sql(
                "SELECT to_regprocedure('payse.auth_open_session(uuid,text)') IS NULL;", database), ["t"])
        finally:
            self.cluster.sql(f"DROP DATABASE {database};")

    def test_failed_install_rolls_back(self):
        """2026-10-26: 실제 004의 마지막 단계 SQL 오류·파일 누락은 앞선 함수와 권한까지 롤백한다.

        사용: unittest. 공백 포함 임시 경로에서 상대 include도 검증한다.
        """
        for mode in ("sql_error", "missing"):
            database = "payse_auth_test_" + uuid.uuid4().hex
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix="session sql ", dir=self.cluster.work) as folder:
                self.cluster.sql(f"CREATE DATABASE {database} TEMPLATE {self.template};")
                copied = Path(folder)
                shutil.copyfile(ENTRY, copied / ENTRY.name)
                shutil.copytree(DIRECTORY / "auth_sessions", copied / "auth_sessions")
                permissions = copied / "auth_sessions/permissions.sql"
                if mode == "sql_error":
                    with permissions.open("a", encoding="utf-8") as output:
                        output.write("\nSELECT 1 / 0;\n")
                else:
                    permissions.unlink()
                try:
                    with self.assertRaises(SqlError):
                        self.cluster.load(copied / ENTRY.name, database)
                    self.assertEqual(self.cluster.sql(
                        "SELECT to_regprocedure('payse.auth_login_account(text,text)') IS NULL "
                        "AND to_regprocedure('payse.auth_open_session(uuid,text)') IS NULL "
                        "AND to_regprocedure('payse.auth_end_session(text)') IS NULL "
                        "AND NOT has_column_privilege('payse_auth_owner','payse.demo_sessions','ended_at','UPDATE') "
                        "AND NOT EXISTS(SELECT 1 FROM pg_policy WHERE polrelid='payse.demo_sessions'::regclass "
                        "AND polname IN ('auth_owner_insert','auth_owner_end'));", database), ["t"])
                finally:
                    self.cluster.sql(f"DROP DATABASE {database};")

    def test_unsafe_install_is_rejected(self):
        """2026-10-26: RLS·직접 권한·역할·기본 ACL·함수 경로가 오염된 사전 조건을 거절한다.

        사용: unittest. 역할은 클러스터 범위이므로 매 사례 뒤 원래 속성을 복구한다.
        """
        cases = [
            ("rls", "ALTER TABLE payse.demo_sessions DISABLE ROW LEVEL SECURITY;", ""),
            ("public_column", "GRANT SELECT(token_digest) ON payse.demo_sessions TO PUBLIC;", ""),
            ("runtime_column", "GRANT UPDATE(ended_at) ON payse.demo_sessions TO payse_runtime;", ""),
            ("owner_write", "GRANT DELETE ON payse.demo_sessions TO payse_auth_owner;", ""),
            ("default_function", "ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO payse_runtime;", ""),
            ("schema_create", "GRANT CREATE ON SCHEMA payse TO payse_session_public_probe;", ""),
            ("function_path", "ALTER FUNCTION payse.auth_authorize(text) RESET search_path;", ""),
            ("unique", "DROP INDEX payse.active_session_per_user;", ""),
            ("role", "ALTER ROLE payse_runtime LOGIN;", "ALTER ROLE payse_runtime NOLOGIN;"),
            ("membership", "GRANT payse_auth_owner TO payse_runtime;", "REVOKE payse_auth_owner FROM payse_runtime;"),
        ]
        for label, prepare, restore in cases:
            database = "payse_auth_test_" + uuid.uuid4().hex
            with self.subTest(case=label):
                self.cluster.sql(f"CREATE DATABASE {database} TEMPLATE {self.template};")
                try:
                    self.cluster.sql(prepare, database)
                    with self.assertRaises(SqlError) as error:
                        self.cluster.load(ENTRY, database)
                    self.assertEqual(error.exception.state, "55000")
                    self.assertEqual(self.cluster.sql(
                        "SELECT to_regprocedure('payse.auth_open_session(uuid,text)') IS NULL;", database), ["t"])
                finally:
                    if restore:
                        self.cluster.sql(restore, database)
                    self.cluster.sql(f"DROP DATABASE {database};")


def main():
    """2026-10-26: 새 소유 클러스터만 사용해 SQL 검사를 실행하고 서버 종료·검증 범위를 기록한다.

    사용: 직접 실행 진입점. 기존 DB·HTTP·모바일 검증 결과로 확대하지 않는다.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    arguments = parser.parse_args()
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        SessionTests.cluster = cluster
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SessionTests)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        cluster.report.update({
            "passed": result.wasSuccessful(), "tests": result.testsRun,
            "failures": len(result.failures), "errors": len(result.errors), "skipped": len(result.skipped),
            "httpVerified": False, "existingDatabaseModified": False,
            "sourceRowsPreservedByMigration": SessionTests.before == SessionTests.after,
            "sqlSha256": {str(path.relative_to(DIRECTORY)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in [ENTRY, *sorted((DIRECTORY / "auth_sessions").glob("*.sql"))]},
        })
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
