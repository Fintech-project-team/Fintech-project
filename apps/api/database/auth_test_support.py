"""2026-10-25: Standard-library helpers for a fresh, private PostgreSQL test cluster."""

from contextlib import AbstractContextManager
from pathlib import Path
import csv
import json
import os
import queue
import secrets
import socket
import subprocess
import threading
import time
import uuid


PROCESS_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


class SqlError(RuntimeError):
    """2026-10-25: SQL·행 값을 제외하고 PostgreSQL 오류 코드만 전달한다.

    사용: Connection.receive, Cluster.sql.
    """

    def __init__(self, state):
        """2026-10-25: 받은 SQLSTATE를 보관하고 원문을 포함하지 않는 오류 메시지를 만든다.

        사용: Connection.receive, Cluster.sql.
        """
        self.state = state
        super().__init__(f"PostgreSQL rejected the statement (SQLSTATE {state})")


class Connection(AbstractContextManager):
    """2026-10-25: psql 연결 하나를 유지해 트랜잭션과 실제 잠금 대기를 검사한다.

    사용: Cluster.connect.
    """

    def __init__(self, cluster, database, name):
        """2026-10-25: 지정한 격리 DB의 psql을 시작하고 출력·오류 수집 스레드를 연다.

        사용: Cluster.connect.
        """
        self.name = name
        self.lines = queue.Queue()
        self.errors = []
        self.process = subprocess.Popen(
            cluster.psql_command(database), stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            encoding="utf-8", errors="replace", bufsize=1,
            env=cluster.environment(name), cwd=cluster.work,
            creationflags=PROCESS_FLAGS,
        )
        self.reader = threading.Thread(target=self.read_output, daemon=True)
        self.error_reader = threading.Thread(target=self.read_errors, daemon=True)
        self.reader.start()
        self.error_reader.start()

    def read_output(self):
        """2026-10-25: 출력 행을 큐에 넣고 프로세스 출력 종료를 None 표식으로 알린다.

        사용: Connection.__init__의 출력 수집 스레드.
        """
        for line in self.process.stdout:
            self.lines.put(line.rstrip("\r\n"))
        self.lines.put(None)

    def read_errors(self):
        """2026-10-25: SQLSTATE만 출력하도록 설정된 psql의 오류 행을 수집한다.

        사용: Connection.__init__의 오류 수집 스레드.
        """
        for line in self.process.stderr:
            # VERBOSITY=sqlstate avoids values, input text and error context.
            self.errors.append(line.strip())

    def submit(self, sql):
        """2026-10-25: 기존 연결에 SQL과 완료 표식을 보내고 기다리지 않고 표식을 반환한다.

        사용: Connection.sql, AuthAccessTests의 경합 검사.
        """
        marker = "done_" + uuid.uuid4().hex
        try:
            self.process.stdin.write(sql + "\n\\echo " + marker + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            # ON_ERROR_STOP can close the input while a long migration is still being sent.
            # receive() reports its SQLSTATE after the reader observes EOF.
            pass
        return marker

    def receive(self, marker, timeout=15):
        """2026-10-25: 완료 표식까지 결과 행을 읽고 시간 초과나 SQL 거절이면 예외를 낸다.

        사용: Connection.sql, AuthAccessTests의 경합 검사.
        """
        rows = []
        deadline = time.monotonic() + timeout
        while True:
            try:
                line = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                raise RuntimeError("Timed out waiting for the isolated test connection") from None
            if line is None:
                self.error_reader.join(timeout=1)
                states = [line.split()[-1] for line in self.errors if "ERROR:" in line]
                raise SqlError(states[-1] if states else "unknown")
            if line == marker:
                return rows
            if line:
                rows.append(line)
            if time.monotonic() >= deadline:
                raise RuntimeError("Timed out waiting for the isolated test connection")

    def sql(self, sql, timeout=15):
        """2026-10-25: 같은 연결에 SQL을 제출하고 제한 시간 안에 결과 행 목록을 반환한다.

        사용: AuthAccessTests의 트랜잭션·잠금 검사.
        """
        return self.receive(self.submit(sql), timeout)

    def __exit__(self, *exception):
        """2026-10-25: 미완료 트랜잭션을 롤백하고 프로세스·수집 스레드·스트림을 정리한다.

        사용: 연결을 사용하는 with 문; 원래 예외는 전파.
        """
        if self.process.poll() is None:
            try:
                self.process.stdin.write("ROLLBACK;\n\\q\n")
                self.process.stdin.flush()
                self.process.wait(timeout=3)
            except (BrokenPipeError, OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=3)
        self.reader.join(timeout=1)
        self.error_reader.join(timeout=1)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            try:
                stream.close()
            except OSError:
                # Windows can reject flushing already broken stdin after ON_ERROR_STOP.
                if self.process.poll() is None:
                    raise
        return False


class Cluster(AbstractContextManager):
    """2026-10-25: 새 디렉터리에 만든 PostgreSQL만 소유하며 기존 서버는 재사용하지 않는다.

    사용: test_auth_access.main.
    """

    def __init__(self, binaries, work):
        """2026-10-25: 새 작업 경로와 실행 파일을 검증하고 외부 PostgreSQL 접속 환경을 제거한다.

        사용: test_auth_access.main.
        """
        self.binaries = Path(binaries).resolve(strict=True)
        self.work = Path(work).absolute()
        if self.work.exists() or self.work.is_symlink():
            raise ValueError("--work-dir must be a new directory; existing paths are never reused")
        self.work.parent.resolve(strict=True)
        self.data = self.work / "cluster"
        self.role = "payse_test_admin"
        self.marker = uuid.uuid4().hex
        self.env = {key: value for key, value in os.environ.items() if not key.upper().startswith("PG")}
        self.env.update({"PGCLIENTENCODING": "UTF8", "PGCONNECT_TIMEOUT": "5"})
        self.report = {"existingClusterConnections": 0, "serviceChanges": 0, "stopped": False}
        for program in ("initdb", "pg_ctl", "psql"):
            if not self.binary(program).is_file():
                raise ValueError(f"Missing PostgreSQL binary: {program}")

    def binary(self, name):
        """2026-10-25: 도구 이름에 OS별 실행 확장자를 붙여 검증 디렉터리 안의 경로를 반환한다.

        사용: Cluster.__init__, __enter__, psql_command, stop.
        """
        return self.binaries / (name + (".exe" if os.name == "nt" else ""))

    def private_directory(self):
        """2026-10-25: 자격 파일을 쓰기 전에 새 검사 디렉터리의 접근 권한을 현재 OS 사용자로 제한한다.

        사용: Cluster.__enter__.
        """
        self.work.mkdir(mode=0o700)
        if os.name == "nt":
            identity = subprocess.run(
                ["whoami", "/user", "/fo", "csv", "/nh"], capture_output=True,
                text=True, timeout=10, creationflags=PROCESS_FLAGS, check=True,
            )
            account_sid = next(csv.reader(identity.stdout.strip().splitlines()))[1]
            result = subprocess.run(
                ["icacls", str(self.work), "/inheritance:r", "/grant:r", f"*{account_sid}:(OI)(CI)F"],
                capture_output=True, timeout=10, creationflags=PROCESS_FLAGS,
            )
            if result.returncode:
                raise RuntimeError("Could not restrict the isolated cluster directory permissions")

    def command(self, phase, args, timeout=45):
        """2026-10-25: 단계별 로그 파일로 프로세스를 실행하고 시간 초과·실패 종료를 거절한다.

        사용: Cluster.__enter__, Cluster.stop.
        """
        with (self.work / f"{phase}.log").open("w", encoding="utf-8") as output:
            try:
                result = subprocess.run(
                    [str(arg) for arg in args], stdout=output, stderr=output,
                    cwd=self.work, env=self.env, timeout=timeout,
                    creationflags=PROCESS_FLAGS,
                )
            except subprocess.TimeoutExpired:
                raise RuntimeError(f"Isolated PostgreSQL {phase} timed out") from None
        if result.returncode:
            raise RuntimeError(f"Isolated PostgreSQL {phase} failed (exit {result.returncode})")

    def __enter__(self):
        """2026-10-25: 새 서버를 초기화·시작하고 로컬 주소·데이터 경로·접속 사용자를 대조한다.

        사용: test_auth_access.main의 with 문; 성공 시 self 반환.
        """
        self.private_directory()
        (self.work / "owner.json").write_text(json.dumps({"marker": self.marker, "directory": str(self.data)}), encoding="utf-8")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        password = secrets.token_urlsafe(48)
        password_file = self.work / "init-password.tmp"
        password_file.write_text(password + "\n", encoding="ascii")
        password_file.chmod(0o600)
        pass_file = self.work / "test.pgpass"
        pass_file.write_text(f"127.0.0.1:{port}:*:{self.role}:{password}\n", encoding="ascii")
        pass_file.chmod(0o600)
        self.env.update({"PGHOST": "127.0.0.1", "PGPORT": str(port), "PGUSER": self.role,
                         "PGDATABASE": "postgres", "PGPASSFILE": str(pass_file)})
        try:
            self.command("initialize", [self.binary("initdb"), "-D", self.data,
                         f"--username={self.role}", "--encoding=UTF8", "--locale=C",
                         "--auth=scram-sha-256", "--pwfile", password_file])
            password_file.unlink()
            with (self.data / "postgresql.conf").open("a", encoding="utf-8") as config:
                config.write("\nlisten_addresses='127.0.0.1'\n")
                config.write(f"port={port}\n")
                config.write("log_statement='none'\nlog_min_error_statement='panic'\n")
                config.write("log_error_verbosity='terse'\nlog_parameter_max_length_on_error=0\n")
                config.write("statement_timeout='12s'\nlock_timeout='10s'\n")
            self.command("start", [self.binary("pg_ctl"), "-D", self.data, "-l",
                         self.work / "server.log", "-w", "-t", "30", "start"], timeout=40)
            identity = json.loads(self.sql("SELECT json_build_object('directory',current_setting('data_directory'),"
                "'host',current_setting('listen_addresses'),'port',current_setting('port'),'user',current_user);")[0])
            if (Path(identity["directory"]).resolve() != self.data.resolve() or identity["host"] != "127.0.0.1"
                    or identity["port"] != str(port) or identity["user"] != self.role):
                raise RuntimeError("The new PostgreSQL endpoint did not match its isolated directory")
            self.report["serverVersion"] = self.sql("SHOW server_version;")[0]
            return self
        except BaseException:
            self.stop()
            raise
        finally:
            password_file.unlink(missing_ok=True)

    def environment(self, name):
        """2026-10-25: 격리 접속 환경에 잠금 추적용 application_name을 추가한 사본을 반환한다.

        사용: Connection.__init__, Cluster.sql.
        """
        return {**self.env, "PGAPPNAME": name}

    def psql_command(self, database):
        """2026-10-25: 허용된 테스트 DB 이름만 받아 오류 즉시 중단·SQLSTATE 출력 명령을 만든다.

        사용: Connection.__init__, Cluster.sql.
        """
        if not database.startswith(("payse_auth_test_", "payse_fixture_auth_")) and database != "postgres":
            raise ValueError("Unexpected database outside the isolated test naming convention")
        return [str(self.binary("psql")), "-X", "-A", "-t", "-q", "-w",
                "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=sqlstate", "-d", database]

    def connect(self, database="postgres", name=None):
        """2026-10-25: 트랜잭션을 유지할 지속 연결을 만들고 잠금 추적용 이름을 부여한다.

        사용: AuthAccessTests의 동일 연결·경합 검사.
        """
        return Connection(self, database, name or "auth_test_" + uuid.uuid4().hex)

    def sql(self, sql, database="postgres"):
        """2026-10-25: SQL 전송부터 결과 수집까지 제한 시간을 적용한 단발 연결을 실행한다.

        2026-10-26: 파일 실행과 공통 오류/시간 제한 처리를 공유한다.
        사용: wait_for_lock, AuthAccessTests; 결과 행 목록 반환.
        """
        return self.execute(database, sql=sql)

    def execute(self, database, *, sql=None, path=None):
        """2026-10-26: SQL 문자열 또는 psql 파일 하나를 실행하고 민감 원문 없이 오류를 전달한다.

        사용: Cluster.sql, Cluster.load. 파일은 -f로 전달해 상대 include 기준을 보존한다.
        """
        if (sql is None) == (path is None):
            raise ValueError("Exactly one SQL input is required")
        command = self.psql_command(database)
        if path is not None:
            command += ["-f", str(path)]
        input_option = {"input": sql} if sql is not None else {"stdin": subprocess.DEVNULL}
        try:
            result = subprocess.run(
                command, **input_option, capture_output=True, text=True,
                encoding="utf-8", errors="replace", env=self.environment("auth_test_" + uuid.uuid4().hex),
                cwd=self.work, timeout=30, creationflags=PROCESS_FLAGS,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("Timed out executing isolated PostgreSQL test SQL") from None
        if result.returncode:
            states = [line.split()[-1] for line in result.stderr.splitlines() if "ERROR:" in line]
            raise SqlError(states[-1] if states else "unknown")
        return [line for line in result.stdout.splitlines() if line]

    def load(self, path, database):
        """2026-10-25: UTF-8 SQL 파일을 읽어 지정한 격리 DB에 적용하고 결과 행을 반환한다.

        2026-10-26: psql -f 실행으로 분리 SQL의 상대 경로와 오류 즉시 중단을 유지한다.
        사용: AuthAccessTests, test_auth_jdbc.prepare_database의 스키마 준비·이행 검사.
        """
        return self.execute(database, path=Path(path).resolve(strict=True))

    def wait_for_lock(self, name, timeout=5):
        """2026-10-25: 지정한 연결이 PostgreSQL에서 실제 Lock 대기 상태인지 제한 시간 안에 확인한다.

        사용: AuthAccessTests의 경합 검사; 대기 미관측 시 실패.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            rows = self.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name="
                            + quote(name) + " AND wait_event_type='Lock';")
            if rows == ["1"]:
                return
            time.sleep(0.025)
        raise AssertionError("Expected backend did not enter a PostgreSQL lock wait")

    def stop(self):
        """2026-10-25: 소유 표식을 확인한 서버만 종료하고 자격 파일을 지운 뒤 결과를 기록한다.

        사용: Cluster.__enter__의 실패 처리, Cluster.__exit__.
        """
        owner = self.work / "owner.json"
        if not owner.exists() or json.loads(owner.read_text(encoding="utf-8")).get("marker") != self.marker:
            raise RuntimeError("Refusing cluster shutdown without this run's ownership marker")
        try:
            if (self.data / "postmaster.pid").exists():
                try:
                    self.command("stop", [self.binary("pg_ctl"), "-D", self.data, "-m", "fast",
                                 "-w", "-t", "15", "stop"], timeout=20)
                except RuntimeError:
                    self.command("stop-immediate", [self.binary("pg_ctl"), "-D", self.data,
                                 "-m", "immediate", "-w", "-t", "15", "stop"], timeout=20)
            self.report["stopped"] = not (self.data / "postmaster.pid").exists()
        finally:
            (self.work / "test.pgpass").unlink(missing_ok=True)
            (self.work / "result.json").write_text(json.dumps(self.report, indent=2) + "\n", encoding="utf-8")

    def __exit__(self, *exception):
        """2026-10-25: 소유 서버를 정리하고 with 본문에서 발생한 예외를 그대로 전파한다.

        사용: test_auth_access.main의 with 문.
        """
        self.stop()
        return False


def quote(value):
    """2026-10-25: 테스트 값을 SQL 리터럴로 인용하며 None은 NULL로 표현한다.

    사용: test_auth_access의 검사 SQL 준비, Cluster.wait_for_lock; 런타임 바인딩 대체 아님.
    """
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"
