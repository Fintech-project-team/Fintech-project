"""2026-11-01: 새 격리 PostgreSQL에서 기억 목록용 메타·권한·기간·이행 원자성을 검사한다.

기존 DB 주소·운영 키를 받지 않는다. 사용: CLI; --base-sql-root는 현재 검토 저장소 경로다.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import shutil
import sys
import unittest
import uuid


DIRECTORY = Path(__file__).resolve().parent


def load_module(path):
    """2026-11-01: 검토 저장소의 기존 SQL 검사 준비 도구를 읽어 재사용한다. 사용: main."""
    spec = importlib.util.spec_from_file_location('payse_analysis_storage_tests', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_tests(base):
    """2026-11-01: 기존 사용자·세션 준비와 거절 검사에 새 이행 검사를 추가한다. 사용: main."""
    class MemoryRefsTests(base.AnalysisStorageTests):
        """2026-11-01: 메타 형식·불변·RLS·기간 경계와 기존 분석 회귀를 함께 검사한다. 사용: unittest."""

        def insert_memory(self, refs, source_hash, index=0, stored=None):
            """2026-11-01: JSON 배열을 typed uuid[]로 넣는 JPA 저장 형식을 재현한다. 사용: 신규 검사."""
            item_id = str(uuid.uuid4())
            result_id = self.result(index)
            row = {
                'id': item_id, 'user_id': self.owners[index], 'result_id': result_id,
                'item_key': item_id, 'semantic_kind': 'transactionMeaning',
                'memory_key': base.digest('memory-' + item_id), 'evidence_hash': base.digest(item_id),
                'stored_at': stored or '2026-01-31T15:00:00+09:00',
                'normal_expires_at': '2027-01-31T15:00:00+09:00',
                'ciphertext': '\\x' + 'ab' * 16, 'crypto_meta': {},
                'active': True, 'is_reference': False, 'important': False,
                'reference_policy': 'optional', 'metadata_version': 1,
                'policy_version': 'test-policy-1', 'policy_actor': 'server',
                'source_refs': refs, 'source_hash': source_hash,
            }
            sql = '''
              INSERT INTO payse.analysis_items
              SELECT *
              FROM jsonb_populate_record(NULL::payse.analysis_items, ''' + base.quote(json.dumps(row)) + '''::jsonb);
            '''
            self.runtime(sql, index)
            return item_id

        def test_source_metadata_shape_and_legacy(self):
            """2026-11-01: 원천 메타를 추정하지 않고 NULL 쌍과 UUID 배열 저장을 검증한다. 사용: unittest."""
            legacy = self.item()
            self.assertEqual(['t'], self.runtime('''
              SELECT source_refs IS NULL AND source_hash IS NULL
              FROM payse.analysis_items
              WHERE id=''' + base.quote(legacy) + ';'))
            refs = [str(uuid.uuid4()), str(uuid.uuid4())]
            current = self.insert_memory(refs, base.digest('refs-' + refs[0]))
            self.assertEqual(['2|t'], self.runtime('''
              SELECT cardinality(source_refs), source_refs[1]=''' + base.quote(refs[0]) + '''::uuid
              FROM payse.analysis_items
              WHERE id=''' + base.quote(current) + ';'))
            for ids, checksum in ((None, base.digest('hash')), (refs, None),
                                  ([], base.digest('empty')), ([None], base.digest('null')),
                                  ([[refs[0]]], base.digest('nested')),
                                  (refs, 'sha256:' + 'A' * 64), (refs, 'incorrect')):
                with self.assertRaises(base.SqlError) as failure:
                    self.insert_memory(ids, checksum)
                self.assertEqual('23514', failure.exception.state)

        def test_source_metadata_permissions_and_immutable(self):
            """2026-11-01: 원천 메타 수정·타 사용자 조회·직접 트리거 호출을 허용하지 않는다. 사용: unittest."""
            current = self.insert_memory([str(uuid.uuid4())], base.digest('immutable'))
            self.assertEqual(['0'], self.runtime('''
              SELECT count(*)
              FROM payse.analysis_items
              WHERE id=''' + base.quote(current) + ';', 1))
            self.rejected('42501', '''
              UPDATE payse.analysis_items
              SET source_hash=''' + base.quote(base.digest('replacement')) + ''', metadata_version=metadata_version+1
              WHERE id=''' + base.quote(current) + ';')
            with self.assertRaises(base.SqlError) as failure:
                self.cluster.sql('''
                  UPDATE payse.analysis_items
                  SET source_hash=''' + base.quote(base.digest('admin-replacement')) + ''', metadata_version=metadata_version+1
                  WHERE id=''' + base.quote(current) + ';', self.database)
            self.assertEqual('23514', failure.exception.state)
            self.assertEqual(['t|f|f|f|t'], self.cluster.sql('''
              SELECT
                has_column_privilege('payse_runtime','payse.analysis_items','source_refs','INSERT'),
                has_column_privilege('payse_runtime','payse.analysis_items','source_refs','UPDATE'),
                has_column_privilege('payse_runtime','payse.analysis_items','source_hash','UPDATE'),
                has_function_privilege('payse_runtime','payse.analysis_source_guard()','EXECUTE'),
                (SELECT relforcerowsecurity FROM pg_class WHERE oid='payse.analysis_items'::regclass);
            ''', self.database))

        def test_stored_period_and_keyset(self):
            """2026-11-01: 한국 날짜 양끝 경계와 UUID 키셋의 중복 없는 후속 행을 검사한다. 사용: unittest."""
            dates = ['2026-01-31T23:59:59.999999+09:00', '2026-02-01T00:00:00+09:00',
                     '2026-02-28T23:59:59.999999+09:00', '2026-03-01T00:00:00+09:00']
            ids = [self.insert_memory([str(uuid.uuid4())], base.digest(day), stored=day) for day in dates]
            where = '''
              WHERE user_id=''' + base.quote(self.owners[0]) + '''
                AND stored_at >= '2026-01-31T15:00:00Z'::timestamptz
                AND stored_at < '2026-02-28T15:00:00Z'::timestamptz
            '''
            expected = sorted(ids[1:3])
            self.assertEqual(expected, self.runtime('SELECT id FROM payse.analysis_items ' + where + ' ORDER BY id;'))
            self.assertEqual(expected[1:], self.runtime('SELECT id FROM payse.analysis_items ' + where
                + ' AND id>' + base.quote(expected[0]) + ' ORDER BY id LIMIT 2;'))

        def memory_context(self, now):
            """2026-11-01: 저장소의 실제 메타 집계 SQL을 읽어 격리 DB에서 실행한다. 사용: 문맥 검사."""
            path = DIRECTORY.parent / 'src/main/java/com/payse/api/analysis/mapper/AnalysisRepository.java'
            method = path.read_text(encoding='utf-8').split('public String memoryContext(', 1)[1]
            sql = method.split('String sql = """', 1)[1].split('""" + memoryPeriod', 1)[0]
            sql = sql.replace('\\\\n', '\\n').replace('?1', base.quote(self.owners[0])).replace('?2', base.quote(now))
            sql += '''
              AND stored_at >= '2026-01-31T15:00:00Z'::timestamptz
              AND stored_at < '2026-02-28T15:00:00Z'::timestamptz;
            '''
            return self.runtime(sql)[0]

        def test_context_tracks_only_scope_changes(self):
            """2026-11-01: 메타 집계는 사용자·기간을 분리하고 시간 자체 대신 만료 전환·삭제를 감지한다. 사용: unittest."""
            item = self.insert_memory([str(uuid.uuid4())], base.digest('in-period'), stored='2026-02-15T12:00:00+09:00')
            before = self.memory_context('2026-10-01T00:00:00Z')
            self.assertEqual(64, len(before))
            self.assertEqual(before, self.memory_context('2026-10-02T00:00:00Z'))
            self.insert_memory([str(uuid.uuid4())], base.digest('other-owner'), index=1, stored='2026-02-15T12:00:00+09:00')
            self.insert_memory([str(uuid.uuid4())], base.digest('other-period'), stored='2026-04-01T12:00:00+09:00')
            self.assertEqual(before, self.memory_context('2026-10-02T00:00:00Z'))
            self.assertNotEqual(before, self.memory_context('2027-01-31T06:00:00Z'))
            self.runtime('''
              UPDATE payse.analysis_items
              SET active=false, metadata_version=metadata_version+1
              WHERE id=''' + base.quote(item) + ';')
            inactive = self.memory_context('2026-10-02T00:00:00Z')
            self.assertNotEqual(before, inactive)
            self.runtime('''
              UPDATE payse.analysis_items
              SET deleted_at=now(), purge_requested_at=now(),
                ciphertext=NULL, crypto_meta=NULL, metadata_version=metadata_version+1
              WHERE id=''' + base.quote(item) + ';')
            self.assertNotEqual(inactive, self.memory_context('2026-10-02T00:00:00Z'))

        def test_refs_migration_atomicity(self):
            """2026-11-01: 재적용과 마지막 SQL 실패는 메타 열·권한·인덱스를 부분 적용하지 않는다. 사용: unittest."""
            with self.assertRaises(base.SqlError) as failure:
                self.cluster.load(DIRECTORY / '011_analysis_memory_refs.sql', self.database)
            self.assertEqual('55000', failure.exception.state)
            database = 'payse_auth_test_memory_refs_migration'
            self.cluster.sql('CREATE DATABASE ' + database + ';')
            for filename in ('001_initial.sql', '002_storage_guards.sql', '003_auth_access.sql',
                             '004_auth_sessions.sql', '007_financial_access.sql', '008_analysis_storage.sql'):
                self.cluster.load(self.base_sql_root / filename, database)
            destination = self.cluster.work / 'failing-memory-refs-migration'
            (destination / 'analysis').mkdir(parents=True)
            shutil.copyfile(DIRECTORY / '011_analysis_memory_refs.sql', destination / '011_analysis_memory_refs.sql')
            shutil.copyfile(DIRECTORY / 'analysis' / 'memory_refs.sql', destination / 'analysis' / 'memory_refs.sql')
            with (destination / 'analysis' / 'memory_refs.sql').open('a', encoding='utf-8') as output:
                output.write('\n-- 검사 전용 실패 주입; 제품 SQL에는 포함하지 않음.\nSELECT 1/0;\n')
            with self.assertRaises(base.SqlError) as failure:
                self.cluster.load(destination / '011_analysis_memory_refs.sql', database)
            self.assertEqual('22012', failure.exception.state)
            self.assertEqual(['0|t|t'], self.cluster.sql('''
              SELECT
                (SELECT count(*) FROM pg_attribute
                 WHERE attrelid='payse.analysis_items'::regclass AND attname IN ('source_refs','source_hash') AND NOT attisdropped),
                to_regclass('payse.analysis_items_period') IS NULL,
                to_regprocedure('payse.analysis_source_guard()') IS NULL;
            ''', database))
            self.cluster.load(DIRECTORY / '011_analysis_memory_refs.sql', database)

    return MemoryRefsTests


def main():
    """2026-11-01: 신규 클러스터만 만들고 기존 분석 회귀와 추가 메타를 검사한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--base-sql-root', required=True, type=Path)
    arguments = parser.parse_args()
    base_root = arguments.base_sql_root.resolve(strict=True)
    sys.path.insert(0, str(base_root))
    from auth_test_support import Cluster, SqlError, quote
    base = load_module(base_root / 'test_analysis_storage.py')
    base.SqlError = SqlError
    base.quote = quote
    database = 'payse_auth_test_memory_refs'
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        cluster.sql('CREATE DATABASE ' + database + ';')
        for filename in ('001_initial.sql', '002_storage_guards.sql', '003_auth_access.sql',
                         '004_auth_sessions.sql', '007_financial_access.sql', '008_analysis_storage.sql'):
            cluster.load(base_root / filename, database)
        # 실제 기존 행을 먼저 넣어 이행이 원문·시각·키 바이트를 바꾸지 않는지 비교한다.
        base.AnalysisStorageTests.cluster = cluster
        base.AnalysisStorageTests.database = database
        base.AnalysisStorageTests.base_sql_root = base_root
        probe = base.AnalysisStorageTests()
        probe.setUp()
        existing_id = probe.item()
        before = cluster.sql('SELECT to_jsonb(item)::text FROM payse.analysis_items item WHERE id='
                             + quote(existing_id) + ';', database)
        cluster.load(DIRECTORY / '011_analysis_memory_refs.sql', database)
        after = cluster.sql("SELECT (to_jsonb(item)-'source_refs'-'source_hash')::text FROM payse.analysis_items item WHERE id="
                            + quote(existing_id) + ';', database)
        if before != after:
            raise AssertionError('Existing analysis item changed during metadata migration')
        probe.tearDown()
        tests = build_tests(base)
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(tests))
        cluster.report.update({'memoryRefsSqlChecks': result.testsRun, 'memoryRefsSqlPassed': result.wasSuccessful(),
                              'existingMemoryPreserved': before == after, 'httpVerified': False,
                              'paidProviderCalled': False})
        if not result.wasSuccessful():
            return 1
        print('PASS: isolated memory metadata, permissions, original data and atomic migration')
    return 0


if __name__ == '__main__':
    sys.exit(main())
