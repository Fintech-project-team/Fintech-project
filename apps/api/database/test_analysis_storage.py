"""2026-11-01: 새 PostgreSQL에서 분석 저장의 소유권·최소 권한·경합·롤백을 검사한다.

기존 DB 주소를 받지 않는다. 이 실행기는 SQL 저장 검사이며 HTTP·LLM 연결 성공을 뜻하지 않는다.
사용: 독립 CLI; --base-sql-root는 검토용 staging에서만 기존 이행 파일 위치를 지정한다.
"""
from pathlib import Path
import argparse
import hashlib
import shutil
import sys
import time
import unittest
import uuid


DIRECTORY = Path(__file__).resolve().parent


def digest(value):
    """2026-11-01: 합성 테스트 식별을 정규 SHA-256 값으로 만든다. 사용: SQL 입력 준비."""
    return 'sha256:' + hashlib.sha256(value.encode('utf-8')).hexdigest()


class AnalysisStorageTests(unittest.TestCase):
    """2026-11-01: 준비한 사용자 관계를 변수로 전달해 분석 SQL의 경계를 확인한다. 사용: main."""

    def setUp(self):
        """2026-11-01: 이번 검사에서만 쓸 사용자·세션을 생성하고 소유권을 대조한다. 사용: unittest."""
        self.owners = [str(uuid.uuid4()), str(uuid.uuid4())]
        self.sessions = [str(uuid.uuid4()), str(uuid.uuid4())]
        self.digests = [digest(str(uuid.uuid4())), digest(str(uuid.uuid4()))]
        for index, owner in enumerate(self.owners):
            self.cluster.sql(f'''
              INSERT INTO payse.users (id, name, phone, code_verifier, data_version, created_at)
              VALUES ({quote(owner)}, {quote('검사가' if index == 0 else '검사나')},
                {quote('010' + str(uuid.uuid4().int % 100000000).zfill(8))}, 'DISABLED', 1, now());
              INSERT INTO payse.demo_sessions (id, user_id, token_digest, issued_at)
              VALUES ({quote(self.sessions[index])}, {quote(owner)}, {quote(self.digests[index])}, now());
            ''', self.database)
            self.assertEqual(['1'], self.cluster.sql(
                'SELECT count(*) FROM payse.demo_sessions WHERE user_id=' + quote(owner)
                + ' AND id=' + quote(self.sessions[index]) + ';', self.database))

    def tearDown(self):
        """2026-11-01: 종료 전 합성 활성 작업을 만료시켜 다음 검사 용량과 분리한다. 사용: unittest."""
        self.cluster.sql('''
          UPDATE payse.analysis_jobs
          SET execution_expires_at = accepted_at + interval '1 microsecond'
          WHERE user_id IN (''' + ','.join(map(quote, self.owners)) + ');', self.database)

    def begin(self, index=0):
        """2026-11-01: 실제 인증 함수로 같은 트랜잭션의 사용자 문맥을 확정한다. 사용: runtime, 동시성 검사."""
        return f'''
          SET SESSION AUTHORIZATION payse_runtime;
          BEGIN;
          SET LOCAL ROLE payse_runtime;
          DO $$
          BEGIN
            IF (SELECT user_id FROM payse.auth_authorize({quote(self.digests[index])}))
              IS DISTINCT FROM {quote(self.owners[index])}::uuid
            THEN
              RAISE EXCEPTION 'Prepared authentication relation did not match';
            END IF;
          END $$;
        '''

    def runtime(self, sql, index=0):
        """2026-11-01: 인증·업무·커밋을 같은 임시 DB 연결에서 실행한다. 사용: 각 SQL 검사."""
        return self.cluster.sql(self.begin(index) + sql + 'COMMIT;', self.database)

    def job_sql(self, job, index=0, state='queued', descriptor=None, input_hash=None):
        """2026-11-01: 고정 UUID나 표시명 검색 없이 명시 준비한 작업을 생성한다. 사용: job, 동시성 검사."""
        source = quote(input_hash) if input_hash is not None else 'NULL'
        return f'''
          INSERT INTO payse.analysis_jobs (
            id, user_id, semantic_kind, trigger_kind, descriptor_hash, input_hash,
            accepted_at, guard_expires_at, execution_expires_at, state, execution_session_id
          ) VALUES (
            {quote(job)}, {quote(self.owners[index])}, 'transactionMeaning', 'A',
            {quote(descriptor or digest(job))}, {source},
            now(), now() + interval '3 months', now() + interval '180 seconds',
            {quote(state)}, {quote(self.sessions[index])}
          );
        '''

    def job(self, index=0, state='queued', descriptor=None, input_hash=None):
        """2026-11-01: 작업 ID를 생성하고 실제 저장한 뒤 반환한다. 사용: 테스트 준비."""
        job = str(uuid.uuid4())
        self.runtime(self.job_sql(job, index, state, descriptor, input_hash), index)
        return job

    def result(self, index=0):
        """2026-11-01: 본문 없는 결과 헤더 하나를 같은 사용자로 생성한다. 사용: 참조·기억 검사."""
        result = str(uuid.uuid4())
        self.runtime(f'''
          INSERT INTO payse.analysis_results (
            id, user_id, semantic_kind, input_hash, provenance, accepted_manifest, committed_at
          ) VALUES (
            {quote(result)}, {quote(self.owners[index])}, 'transactionMeaning',
            {quote(digest(result))}, '{{}}'::jsonb, '[]'::jsonb, now()
          );
        ''', index)
        return result

    def item(self, index=0, result=None):
        """2026-11-01: 암호문 형식의 합성 바이트와 독립 기억을 준비한다. 사용: 보존 메타 검사."""
        result = result or self.result(index)
        item = str(uuid.uuid4())
        self.runtime(f'''
          INSERT INTO payse.analysis_items (
            id, user_id, result_id, item_key, semantic_kind, memory_key, evidence_hash,
            stored_at, normal_expires_at, ciphertext, crypto_meta,
            active, is_reference, important, reference_policy, metadata_version, policy_version, policy_actor
          ) VALUES (
            {quote(item)}, {quote(self.owners[index])}, {quote(result)}, {quote(item)},
            'transactionMeaning', {quote('transaction:' + item)}, {quote(digest(item))},
            now(), now() + interval '3 months', decode(repeat('ab', 16), 'hex'), '{{}}'::jsonb,
            true, false, false, 'optional', 1, 'test-policy-1', 'server'
          );
        ''', index)
        return item

    def rejected(self, state, sql, index=0):
        """2026-11-01: 기대 SQLSTATE를 독립 상수로 비교하고 원문은 출력하지 않는다. 사용: 거절 검사."""
        with self.assertRaises(SqlError) as failure:
            self.runtime(sql, index)
        self.assertEqual(state, failure.exception.state)

    def test_owner_and_reference_isolation(self):
        """2026-11-01: 다른 사용자 행 조회·소유권 변경·결과/세션 결합을 거절한다. 사용: unittest."""
        job = self.job()
        result = self.result(1)
        self.assertEqual(['0'], self.runtime(
            'SELECT count(*) FROM payse.analysis_jobs WHERE id=' + quote(job) + ';', 1))
        self.rejected('42501', 'UPDATE payse.analysis_jobs SET user_id=' + quote(self.owners[1])
                      + ' WHERE id=' + quote(job) + ';')
        self.rejected('23503', 'UPDATE payse.analysis_jobs SET selected_result_id=' + quote(result)
                      + ' WHERE id=' + quote(job) + ';')
        self.rejected('23503', 'UPDATE payse.analysis_jobs SET execution_session_id=' + quote(self.sessions[1])
                      + ' WHERE id=' + quote(job) + ';')

    def test_immutable_and_active_identity(self):
        """2026-11-01: 활성 지문 중복과 최초 시각·검증 입력 교체를 막는다. 사용: unittest."""
        same = digest(str(uuid.uuid4()))
        job = self.job(descriptor=same)
        self.rejected('23505', self.job_sql(str(uuid.uuid4()), descriptor=same))
        self.job(index=1, descriptor=same)
        self.rejected('42501', 'UPDATE payse.analysis_jobs SET accepted_at=now() WHERE id=' + quote(job) + ';')
        first = digest('first-' + job)
        self.runtime('UPDATE payse.analysis_jobs SET input_hash=' + quote(first) + ' WHERE id=' + quote(job) + ';')
        self.rejected('23514', 'UPDATE payse.analysis_jobs SET input_hash=' + quote(digest('later-' + job))
                      + ' WHERE id=' + quote(job) + ';')
        self.rejected('23505', self.job_sql(str(uuid.uuid4()), input_hash=first))
        self.runtime('UPDATE payse.analysis_jobs SET state=\'failed\' WHERE id=' + quote(job) + ';')
        self.job(input_hash=first)

    def test_first_result_and_canonical_cycle(self):
        """2026-11-01: 늦은 결과 덮어쓰기·자기 참조·대표 작업 순환을 거절한다. 사용: unittest."""
        job = self.job()
        results = [self.result(), self.result()]
        self.runtime('UPDATE payse.analysis_jobs SET selected_result_id=' + quote(results[0])
                     + ' WHERE id=' + quote(job) + ';')
        self.rejected('23514', 'UPDATE payse.analysis_jobs SET selected_result_id=' + quote(results[1])
                      + ' WHERE id=' + quote(job) + ';')
        self.rejected('23514', 'UPDATE payse.analysis_jobs SET canonical_job_id=' + quote(job)
                      + ' WHERE id=' + quote(job) + ';')
        other = self.job()
        self.runtime('UPDATE payse.analysis_jobs SET canonical_job_id=' + quote(other)
                     + ' WHERE id=' + quote(job) + ';')
        self.rejected('23514', 'UPDATE payse.analysis_jobs SET canonical_job_id=' + quote(job)
                      + ' WHERE id=' + quote(other) + ';')

    def test_memory_delete_and_permissions(self):
        """2026-11-01: 기억 삭제 버전·복원 금지·중요보존 제약과 불변 암호문을 검사한다. 사용: unittest."""
        item = self.item()
        where = ' WHERE id=' + quote(item) + ';'
        self.rejected('23514', 'UPDATE payse.analysis_items SET important=true, metadata_version=2' + where)
        self.rejected('23514', 'UPDATE payse.analysis_items SET active=false' + where)
        self.rejected('23514', 'UPDATE payse.analysis_items SET ciphertext=decode(\'ab\',\'hex\'), metadata_version=2' + where)
        self.rejected('42501', 'DELETE FROM payse.analysis_items' + where)
        self.runtime('''
          UPDATE payse.analysis_items
          SET active=false, deleted_at=now(), purge_requested_at=now(), metadata_version=2
        ''' + where)
        self.rejected('23514', 'UPDATE payse.analysis_items SET active=true, deleted_at=NULL, metadata_version=3' + where)
        self.assertEqual(['2|f'], self.runtime('SELECT metadata_version, active FROM payse.analysis_items' + where))

    def test_ciphertext_removal_guards(self):
        """2026-11-01: 정상 본문 필수·쌍 제거·삭제/폐기 조건·교체/복원 금지를 검사한다. 사용: unittest."""
        item = self.item()
        where = ' WHERE id=' + quote(item) + ';'
        self.rejected('23514', '''
          UPDATE payse.analysis_items
          SET ciphertext=NULL, crypto_meta=NULL, metadata_version=2
        ''' + where)
        self.rejected('23514', '''
          UPDATE payse.analysis_items
          SET ciphertext=NULL, active=false, purge_requested_at=now(), metadata_version=2
        ''' + where)
        self.rejected('23514', '''
          UPDATE payse.analysis_items
          SET ciphertext=decode(repeat('cd',16),'hex'), metadata_version=2
        ''' + where)
        self.rejected('23514', '''
          UPDATE payse.analysis_items
          SET crypto_meta='{"changed":true}'::jsonb, metadata_version=2
        ''' + where)
        # 처음 저장할 때도 NULL 쌍·짧은 암호문·잘못된 메타 구조는 통과할 수 없다.
        for replacement in (
            "'ciphertext',NULL,'crypto_meta',NULL",
            "'ciphertext',decode('ab','hex')",
            "'crypto_meta','[]'::jsonb",
        ):
            identity = str(uuid.uuid4())
            self.rejected('23514', f'''
              INSERT INTO payse.analysis_items
              SELECT (jsonb_populate_record(NULL::payse.analysis_items,
                to_jsonb(item) || jsonb_build_object(
                  'id',{quote(identity)},'item_key',{quote(identity)},{replacement}
                ))).*
              FROM payse.analysis_items item
              WHERE item.id={quote(item)};
            ''')
        self.runtime('''
          UPDATE payse.analysis_items
          SET ciphertext=NULL, crypto_meta=NULL, active=false,
            deleted_at=now(), purge_requested_at=now(), metadata_version=2
        ''' + where)
        self.assertEqual(['t|t|2'], self.runtime(
            'SELECT ciphertext IS NULL, crypto_meta IS NULL, metadata_version FROM payse.analysis_items' + where))
        self.rejected('23514', '''
          UPDATE payse.analysis_items
          SET ciphertext=decode(repeat('ab',16),'hex'), crypto_meta='{}'::jsonb, metadata_version=3
        ''' + where)
        purge = self.item()
        self.runtime('''
          UPDATE payse.analysis_items
          SET ciphertext=NULL, crypto_meta=NULL, active=false,
            purge_requested_at=now(), metadata_version=2
          WHERE id=''' + quote(purge) + ';')
        self.assertEqual(['t|t|t'], self.runtime('''
          SELECT ciphertext IS NULL, crypto_meta IS NULL, deleted_at IS NULL
          FROM payse.analysis_items
          WHERE id=''' + quote(purge) + ';'))

    def test_commands_match_job_and_are_immutable(self):
        """2026-11-01: 명령별 대상과 같은 작업의 시도 관계·키 불변을 검증한다. 사용: unittest."""
        jobs = [self.job(), self.job()]
        attempt = str(uuid.uuid4())
        self.runtime(f'''
          INSERT INTO payse.analysis_attempts (id,user_id,job_id,attempt_no,dispatch_state,created_at)
          VALUES ({quote(attempt)},{quote(self.owners[0])},{quote(jobs[0])},1,'notSent',now());
        ''')
        key = str(uuid.uuid4())
        sql = f'''
          INSERT INTO payse.analysis_commands (
            user_id,request_key,operation,request_hash,job_id,attempt_id,created_at,expires_at
          ) VALUES (
            {quote(self.owners[0])},{quote(key)},'input',{quote(digest(key))},
            {quote(jobs[1])},{quote(attempt)},now(),now()+interval '3 months'
          );
        '''
        self.rejected('23503', sql)
        self.runtime(sql.replace(quote(jobs[1]), quote(jobs[0])))
        self.rejected('23505', sql.replace(quote(jobs[1]), quote(jobs[0])))
        self.rejected('42501', 'UPDATE payse.analysis_commands SET expires_at=now()+interval \'1 year\';')

    def test_capacity_counts_and_role(self):
        """2026-11-01: RLS를 유지하면서 함수가 전 사용자 합계만 읽고 만료·별칭은 제외한다. 사용: unittest."""
        jobs = [self.job(), self.job(1, state='running')]
        alias = self.job()
        self.runtime('UPDATE payse.analysis_jobs SET canonical_job_id=' + quote(jobs[0])
                     + ' WHERE id=' + quote(alias) + ';')
        self.assertEqual(['1|1|0|1'], self.runtime('SELECT * FROM payse.analysis_capacity();'))
        self.assertEqual(['0|1|1|1'], self.runtime('SELECT * FROM payse.analysis_capacity();', 1))
        self.cluster.sql('UPDATE payse.analysis_jobs SET execution_expires_at=accepted_at+interval \'1 microsecond\' '
                         'WHERE id=' + quote(jobs[1]) + ';', self.database)
        self.assertEqual(['1|1|0|0'], self.runtime('SELECT * FROM payse.analysis_capacity();'))
        with self.assertRaises(SqlError) as failure:
            self.cluster.sql('BEGIN; SET LOCAL ROLE payse_runtime; SELECT * FROM payse.analysis_capacity();', self.database)
        self.assertEqual('42501', failure.exception.state)
        self.rejected('42501', 'SET LOCAL ROLE payse_analysis_guard;')

    def test_capacity_serializes_and_rollback(self):
        """2026-11-01: 다른 사용자 접수도 전역 잠금 뒤 커밋 상태를 보고 실패 삽입은 남지 않는다. 사용: unittest."""
        first = str(uuid.uuid4())
        with self.cluster.connect(self.database, 'analysis-first') as one, self.cluster.connect(self.database, 'analysis-second') as two:
            one.sql(self.begin() + 'SELECT * FROM payse.analysis_capacity();' + self.job_sql(first))
            marker = two.submit(self.begin(1) + 'SELECT * FROM payse.analysis_capacity();')
            self.cluster.wait_for_lock('analysis-second')
            one.sql('COMMIT;')
            self.assertEqual(['0|1|0|0'], two.receive(marker))
            two.sql('ROLLBACK;')
        rejected = str(uuid.uuid4())
        self.rejected('22012', self.job_sql(rejected) + 'SELECT 1/0;')
        self.assertEqual(['0'], self.cluster.sql('SELECT count(*) FROM payse.analysis_jobs WHERE id='
                         + quote(rejected) + ';', self.database))

    def test_cancel_rolls_back(self):
        """2026-11-01: 진행 SQL을 실제 취소한 뒤 미커밋 작업·권한 문맥이 남지 않는지 확인한다. 사용: unittest."""
        job = str(uuid.uuid4())
        with self.cluster.connect(self.database, 'analysis-cancel') as connection:
            connection.sql(self.begin() + self.job_sql(job))
            marker = connection.submit('SELECT pg_sleep(20);')
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                waiting = self.cluster.sql("SELECT count(*) FROM pg_stat_activity WHERE "
                                           "application_name='analysis-cancel' AND wait_event='PgSleep';")
                if waiting == ['1']:
                    break
                time.sleep(0.025)
            else:
                self.fail('Owned cancellation query did not start')
            self.assertEqual(['t'], self.cluster.sql('''
              SELECT pg_cancel_backend(pid)
              FROM pg_stat_activity
              WHERE application_name='analysis-cancel';
            '''))
            with self.assertRaises(SqlError) as failure:
                connection.receive(marker)
            self.assertEqual('57014', failure.exception.state)
        self.assertEqual(['0'], self.cluster.sql('SELECT count(*) FROM payse.analysis_jobs WHERE id='
                         + quote(job) + ';', self.database))

    def test_schema_permissions(self):
        """2026-11-01: 여섯 테이블 강제 RLS·삭제 금지·제한 집계 열 권한을 확인한다. 사용: unittest."""
        self.assertEqual(['6'], self.cluster.sql('''
          SELECT count(*)
          FROM pg_class relation
          JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
          WHERE namespace.nspname='payse'
            AND relation.relname IN (
              'analysis_jobs','analysis_attempts','analysis_commands',
              'analysis_results','analysis_items','analysis_suppressions'
            )
            AND relation.relrowsecurity
            AND relation.relforcerowsecurity;
        ''', self.database))
        self.assertEqual(['f|f|f|t|f|f'], self.cluster.sql('''
          SELECT
            has_table_privilege('payse_runtime','payse.analysis_jobs','DELETE'),
            has_table_privilege('payse_runtime','payse.analysis_items','TRUNCATE'),
            has_column_privilege('payse_runtime','payse.analysis_jobs','guard_expires_at','UPDATE'),
            has_column_privilege('payse_analysis_guard','payse.analysis_jobs','state','SELECT'),
            has_column_privilege('payse_analysis_guard','payse.analysis_jobs','detail','SELECT'),
            has_table_privilege('payse_analysis_guard','payse.analysis_items','SELECT');
        ''', self.database))
        self.assertEqual(['t'], self.cluster.sql('''
          SELECT NOT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls
            AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolinherit
          FROM pg_roles
          WHERE rolname='payse_analysis_guard';
        ''', self.database))

    def test_logout_cancels_only_its_waiting_jobs(self):
        """2026-11-01: 실제 로그아웃 커밋 즉시 해당 세션 대기만 취소하고 진행·타세션·타사용자는 보존한다. 사용: unittest."""
        queued = self.job()
        awaiting = self.job(state='awaitingInput')
        running = self.job(state='running')
        other_owner = self.job(1)
        old_session_job = self.job()
        old_session = str(uuid.uuid4())
        self.cluster.sql(f'''
          INSERT INTO payse.demo_sessions (id,user_id,token_digest,issued_at,ended_at)
          VALUES ({quote(old_session)},{quote(self.owners[0])},{quote(digest(old_session))},
            now()-interval '1 day',now()-interval '1 hour');
          UPDATE payse.analysis_jobs
          SET execution_session_id={quote(old_session)}
          WHERE id={quote(old_session_job)};
        ''', self.database)
        self.runtime('''
          UPDATE payse.analysis_jobs
          SET permit_hash=''' + quote(digest(awaiting)) + ''',
            permit_expires_at=now()+interval '60 seconds'
          WHERE id=''' + quote(awaiting) + ';')
        self.assertEqual(['t'], self.runtime(
            'SELECT payse.auth_end_session(' + quote(self.digests[0]) + ');'))
        self.assertEqual(['2'], self.cluster.sql('''
          SELECT count(*)
          FROM payse.analysis_jobs
          WHERE id IN (''' + quote(queued) + ',' + quote(awaiting) + ''')
            AND state='cancelled'
            AND finished_at IS NOT NULL
            AND permit_hash IS NULL
            AND permit_expires_at IS NULL;
        ''', self.database))
        for job, state in ((running, 'running'), (other_owner, 'queued'), (old_session_job, 'queued')):
            self.assertEqual([state], self.cluster.sql(
                'SELECT state FROM payse.analysis_jobs WHERE id=' + quote(job) + ';', self.database))
        self.assertEqual(['f'], self.cluster.sql('''
          SET SESSION AUTHORIZATION payse_runtime;
          BEGIN;
          SET LOCAL ROLE payse_runtime;
          SELECT payse.auth_end_session(''' + quote(self.digests[0]) + ''');
          COMMIT;
        ''', self.database))

    def test_logout_rollback_and_minimal_permissions(self):
        """2026-11-01: 종료 후 SQL 실패는 세션·대기 취소를 함께 롤백하며 인증 역할의 새 권한을 제한한다. 사용: unittest."""
        job = self.job()
        self.rejected('22012', 'SELECT payse.auth_end_session(' + quote(self.digests[0]) + '); SELECT 1/0;')
        self.assertEqual(['queued'], self.runtime('SELECT state FROM payse.analysis_jobs WHERE id=' + quote(job) + ';'))
        self.assertEqual(['t'], self.cluster.sql('''
          SELECT ended_at IS NULL
          FROM payse.demo_sessions
          WHERE id=''' + quote(self.sessions[0]) + ';', self.database))
        self.assertEqual(['t|f|f|f|f|f'], self.cluster.sql('''
          SELECT
            has_column_privilege('payse_auth_owner','payse.analysis_jobs','state','UPDATE'),
            has_column_privilege('payse_auth_owner','payse.analysis_jobs','input_hash','UPDATE'),
            has_column_privilege('payse_auth_owner','payse.analysis_jobs','detail','SELECT'),
            has_function_privilege('payse_auth_owner','payse.analysis_cancel_waiting()','EXECUTE'),
            has_function_privilege('payse_runtime','payse.analysis_cancel_waiting()','EXECUTE'),
            (SELECT prosecdef FROM pg_proc WHERE oid='payse.analysis_cancel_waiting()'::regprocedure);
        ''', self.database))

    def test_migration_atomicity(self):
        """2026-11-01: 재적용을 막고 마지막 SQL 실패를 전부 롤백하며 009 선행도 허용한다. 사용: unittest."""
        with self.assertRaises(SqlError) as failure:
            self.cluster.load(DIRECTORY / '008_analysis_storage.sql', self.database)
        self.assertEqual('55000', failure.exception.state)
        database = 'payse_auth_test_analysis_migration'
        self.cluster.sql('CREATE DATABASE ' + database + ';')
        for filename in ('001_initial.sql', '002_storage_guards.sql', '003_auth_access.sql',
                         '004_auth_sessions.sql', '007_financial_access.sql', '009_salary_notices.sql'):
            self.cluster.load(self.base_sql_root / filename, database)
        destination = self.cluster.work / 'failing-analysis-migration'
        destination.mkdir()
        shutil.copyfile(DIRECTORY / '008_analysis_storage.sql', destination / '008_analysis_storage.sql')
        shutil.copytree(DIRECTORY / 'analysis', destination / 'analysis')
        with (destination / 'analysis' / 'permissions.sql').open('a', encoding='utf-8') as output:
            output.write('\n-- 테스트 전용 실패 주입; 제품 SQL에는 포함하지 않음.\nSELECT 1/0;\n')
        with self.assertRaises(SqlError) as failure:
            self.cluster.load(destination / '008_analysis_storage.sql', database)
        self.assertEqual('22012', failure.exception.state)
        self.assertEqual(['t|t|t'], self.cluster.sql('''
          SELECT to_regclass('payse.analysis_jobs') IS NULL,
            to_regprocedure('payse.analysis_capacity()') IS NULL,
            to_regclass('payse.salary_notice_dismissals') IS NOT NULL;
        ''', database))
        self.cluster.load(DIRECTORY / '008_analysis_storage.sql', database)
        self.assertEqual(['t'], self.cluster.sql(
            "SELECT to_regclass('payse.analysis_jobs') IS NOT NULL;", database))


def run_checks(cluster, database, base_sql_root):
    """2026-11-01: 준비된 전용 SQL DB에서 검사만 실행한다. 사용: main, test_analysis_service."""
    global SqlError, quote
    from auth_test_support import SqlError, quote
    AnalysisStorageTests.cluster = cluster
    AnalysisStorageTests.database = database
    AnalysisStorageTests.base_sql_root = base_sql_root
    return unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(AnalysisStorageTests))


def main():
    """2026-11-01: 소유한 새 클러스터만 만들고 SQL 결과·기존 원천 불변을 기록한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--base-sql-root', type=Path, default=DIRECTORY)
    arguments = parser.parse_args()
    sys.path.insert(0, str(arguments.base_sql_root.resolve(strict=True)))
    from auth_test_support import Cluster
    database = 'payse_auth_test_analysis'
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        cluster.sql('CREATE DATABASE ' + database + ';')
        for filename in ('001_initial.sql', '002_storage_guards.sql', '003_auth_access.sql',
                         '004_auth_sessions.sql', '007_financial_access.sql'):
            cluster.load(arguments.base_sql_root / filename, database)
        cluster.load(DIRECTORY / '008_analysis_storage.sql', database)
        # 급여 안내 이행은 분석 이후에도 독립 적용 가능해야 한다.
        cluster.load(arguments.base_sql_root / '009_salary_notices.sql', database)
        result = run_checks(cluster, database, arguments.base_sql_root)
        cluster.report.update({'analysisSqlChecks': result.testsRun,
                              'analysisSqlPassed': result.wasSuccessful(),
                              'httpVerified': False, 'paidProviderCalled': False})
        if not result.wasSuccessful():
            return 1
        print('PASS: isolated analysis SQL storage, owner isolation, capacity locks and rollback')
    return 0


if __name__ == '__main__':
    sys.exit(main())
