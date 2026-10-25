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
from testing.scenarios.export_state import export
from test_context import build_context
OPTIONS=None


class CommonStorageMigrationTests(unittest.TestCase):
    """Verify actual locks/rollback and exact retained data, including nonfixture users."""
    def sql(self,sql):
        return migration.run_psql(OPTIONS.psql,OPTIONS.database,sql,60)

    def setUp(self):
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
        return json.loads(self.sql(migration.snapshot_query(legacy)))

    def plan(self):
        return migration.create_plan(OPTIONS.psql,OPTIONS.database,self.backup,60,3000)

    def apply(self,digest):
        return migration.apply_plan(OPTIONS.psql,OPTIONS.database,self.backup,digest,60,3000)

    def test_preserve_rows_archive_events_and_allow_additional_users(self):
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
        digest=self.plan()
        self.sql(f"UPDATE payse.demo_users SET data_version=data_version+1 WHERE id='{self.owner}';")
        before=self.state()
        with self.assertRaises(migration.MigrationError):self.apply(digest)
        self.assertEqual(self.state(),before)

    def test_nonempty_v2_salary_proof_survives_common_transition(self):
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
        digest=self.plan();self.sql("UPDATE payse.demo_event_receipts SET event_id='changed';")
        before=self.state()
        with self.assertRaises(migration.MigrationError):self.apply(digest)
        self.assertEqual(self.state(),before)

    def test_wrong_hash_rejected(self):
        self.plan();before=self.state()
        with self.assertRaises(migration.MigrationError):self.apply('0'*64)
        self.assertEqual(self.state(),before)

    def test_extra_column_requires_review(self):
        self.sql('ALTER TABLE payse.demo_users ADD COLUMN extra text;')
        with self.assertRaises(migration.MigrationError):self.plan()
        self.assertFalse(self.backup.exists())

    def test_custom_legacy_function_requires_review(self):
        self.sql("CREATE FUNCTION payse.custom_reader() RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM payse.demo_users $$;")
        with self.assertRaises(migration.MigrationError):self.plan()

    def test_missing_owner_security_rejected(self):
        self.sql('ALTER TABLE payse.financial_accounts DISABLE ROW LEVEL SECURITY;')
        with self.assertRaises(migration.MigrationError):self.plan()

    def test_dependency_rolls_back_all_renames(self):
        self.sql('CREATE VIEW payse.event_view AS SELECT * FROM payse.demo_event_receipts;')
        # The archive checker sees the extra view columns and rejects before any DDL.
        before=self.state()
        with self.assertRaises(migration.MigrationError):self.plan()
        self.assertEqual(self.state(),before)

    def test_old_plan_cannot_apply_twice(self):
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
