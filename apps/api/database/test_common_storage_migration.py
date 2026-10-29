"""Run only in a dedicated localhost payse_fixture_common_* PostgreSQL database."""
import argparse
import json
from pathlib import Path
import sys
import tempfile
import unittest
from uuid import uuid4
import migrate_common_storage as migration
from run_sql_tests import require_disposable_database

API=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(API));sys.path.insert(0,str(API/'fixtures'))
from reference_data.export_sql import export as reference_sql
from legacy_seed import export
from test_context import build_context
OPTIONS=None


class CommonStorageMigrationTests(unittest.TestCase):
    """Verify actual locks/rollback and exact retained data, including nonfixture users."""
    def sql(self,sql):
        """2026-10-29: 폐기용 DB에만 SQL을 실행한다. 사용: unittest."""
        return migration.run_psql(OPTIONS.psql,OPTIONS.database,sql,60)

    def setUp(self):
        """2026-10-29: 고정된 과거 스키마와 그 컬럼에 맞는 검증 데이터를 준비한다. 사용: unittest."""
        migration.require(OPTIONS.database.startswith('payse_fixture_common_'),'Dedicated common-storage test DB required')
        self.temp=tempfile.TemporaryDirectory(dir=OPTIONS.temp)
        self.addCleanup(self.temp.cleanup)
        self.backup=Path(self.temp.name)/'archive.json'
        self.sql('DROP SCHEMA IF EXISTS payse CASCADE;')
        for name in ('001_initial.sql','002_storage_guards.sql'):
            self.sql((API/'tests/legacy'/name).read_text(encoding='utf-8'))
        self.sql(reference_sql())
        seed=export(API/'fixtures/generated',['alpha-ready','beta-ready','gamma-month-end'])
        self.sql(seed.replace('payse.users','payse.demo_users').replace('user_attributes','user_settings').replace('phone','synthetic_phone'))
        context=build_context(API/'fixtures/generated')
        self.context=context
        self.owner=context['owner_id'];self.receipt=context['write_receipt_id']
        self.sql(f"INSERT INTO payse.demo_event_receipts VALUES ('{self.owner}','external-scenario','before','after','{self.receipt}');")
        self.sql(f"INSERT INTO payse.demo_sessions VALUES('{uuid4()}','{self.owner}','preserved-session',now(),NULL);")

    def state(self,legacy=True):
        """2026-10-29: 보존 대상의 전체 상태를 읽는다. 사용: unittest."""
        return json.loads(self.sql(migration.snapshot_query(legacy)))

    def plan(self):
        """2026-10-29: 현재 원천을 변경하지 않고 이행 계획을 만든다. 사용: unittest."""
        return migration.create_plan(OPTIONS.psql,OPTIONS.database,self.backup,60,3000)

    def apply(self,digest):
        """2026-10-29: 확인한 해시에 해당하는 이행만 실행한다. 사용: unittest."""
        return migration.apply_plan(OPTIONS.psql,OPTIONS.database,self.backup,digest,60,3000)

    def test_migration_preserves_rows_and_archive(self):
        """2026-10-29: 행·보관 자료·과거 175개 컬럼을 유지한다. 사용: unittest."""
        self.sql(f"INSERT INTO payse.demo_users VALUES('{uuid4()}','추가사용자','01099999999','disabled',1,now());")
        before=self.state();digest=self.plan();archive=self.backup.read_bytes()
        self.assertEqual(self.apply(digest),'APPLIED')
        after=self.state(False);migration.validate(after,False)
        self.assertEqual(before['data'],after['data'])
        self.assertEqual(len(json.loads(json.loads(archive)['sourceState'])['events']),1)
        self.assertEqual(self.backup.read_bytes(),archive)
        self.assertEqual(len(after['columns']),22)
        self.assertEqual(sum(map(len,after['columns'].values())),175)
        self.assertEqual(self.sql("SELECT count(*) FROM payse.demo_sessions WHERE ended_at IS NULL;"),'1')

    def test_changed_user_state_rejected(self):
        """2026-10-29: 검토 후 사용자 변경이 있으면 이행을 거절한다. 사용: unittest."""
        digest=self.plan()
        self.sql(f"UPDATE payse.demo_users SET data_version=data_version+1 WHERE id='{self.owner}';")
        before=self.state()
        with self.assertRaises(migration.MigrationError):self.apply(digest)
        self.assertEqual(self.state(),before)

    def test_migration_preserves_salary_evidence(self):
        """2026-10-23: The common rename must not require a future salary-format migration."""
        proof=[{'expectedPayDate':self.context['salary_evidence_date'],'confirmation':'confirmed',
                'transactionIds':[self.context['salary_transaction_id']]}]
        self.sql('UPDATE payse.source_contexts SET salary_evidence='+migration.sql_literal(json.dumps(proof))+
                 '::jsonb WHERE user_id='+migration.sql_literal(self.owner)+'::uuid;')
        before=self.state();digest=self.plan()
        self.assertEqual(self.apply(digest),'APPLIED')
        after=self.state(False);migration.validate(after,False)
        self.assertEqual(before['data'],after['data'])
        stored=json.loads(self.sql('SELECT salary_evidence FROM payse.source_contexts WHERE user_id='+migration.sql_literal(self.owner)+'::uuid;'))
        self.assertEqual(stored,proof)

    def test_changed_event_state_rejected(self):
        """2026-10-29: 검토 후 이벤트 변경이 있으면 이행을 거절한다. 사용: unittest."""
        digest=self.plan();self.sql("UPDATE payse.demo_event_receipts SET event_id='changed';")
        before=self.state()
        with self.assertRaises(migration.MigrationError):self.apply(digest)
        self.assertEqual(self.state(),before)

    def test_wrong_hash_rejected(self):
        """2026-10-29: 검토 해시가 다르면 상태를 변경하지 않는다. 사용: unittest."""
        self.plan();before=self.state()
        with self.assertRaises(migration.MigrationError):self.apply('0'*64)
        self.assertEqual(self.state(),before)

    def test_extra_column_requires_review(self):
        """2026-10-29: 알려지지 않은 컬럼은 자동 이행하지 않는다. 사용: unittest."""
        self.sql('ALTER TABLE payse.demo_users ADD COLUMN extra text;')
        with self.assertRaises(migration.MigrationError):self.plan()
        self.assertFalse(self.backup.exists())

    def test_custom_legacy_function_requires_review(self):
        """2026-10-29: 기존 이름을 참조하는 사용자 함수를 감지한다. 사용: unittest."""
        self.sql("CREATE FUNCTION payse.custom_reader() RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM payse.demo_users $$;")
        with self.assertRaises(migration.MigrationError):self.plan()

    def test_missing_owner_security_rejected(self):
        """2026-10-29: RLS가 없으면 이행을 거절한다. 사용: unittest."""
        self.sql('ALTER TABLE payse.financial_accounts DISABLE ROW LEVEL SECURITY;')
        with self.assertRaises(migration.MigrationError):self.plan()

    def test_dependency_rolls_back_all_renames(self):
        """2026-10-29: 추가 의존성이 있으면 전체 변경을 중단한다. 사용: unittest."""
        self.sql('CREATE VIEW payse.event_view AS SELECT * FROM payse.demo_event_receipts;')
        # The archive checker sees the extra view columns and rejects before any DDL.
        before=self.state()
        with self.assertRaises(migration.MigrationError):self.plan()
        self.assertEqual(self.state(),before)

    def test_old_plan_cannot_apply_twice(self):
        """2026-10-29: 완료된 계획을 재실행해도 현재 상태를 유지한다. 사용: unittest."""
        digest=self.plan();self.apply(digest);before=self.state(False)
        with self.assertRaises(migration.MigrationError):self.apply(digest)
        self.assertEqual(self.state(False),before)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database',required=True);parser.add_argument('--psql',required=True)
    parser.add_argument('--temp',type=Path,required=True)
    OPTIONS=parser.parse_args();require_disposable_database(OPTIONS.database)
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CommonStorageMigrationTests))
    raise SystemExit(not result.wasSuccessful())
