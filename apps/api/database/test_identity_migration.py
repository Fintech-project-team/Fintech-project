"""Native PostgreSQL migration regression suite; destroys only the named test schema.

The caller must supply a dedicated database named payse_fixture_identity_*.
No existing user database or application server is used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from uuid import uuid4

import migrate_identity as migration
from test_context import build_context
from run_sql_tests import require_disposable_database

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fixtures'))
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from testing.scenarios.export_state import export
from reference_data.export_sql import export as export_reference

def legacy_sql(sql):
    return sql.replace("payse.users", "payse.demo_users").replace("user_attributes", "user_settings").replace("phone", "synthetic_phone")

OPTIONS = None
DATABASE = Path(__file__).parent
FIXTURES = DATABASE.parent / 'fixtures' / 'generated'


class IdentityMigrationTests(unittest.TestCase):
    """Exercise actual transactions and constraints in an isolated PostgreSQL DB."""

    @classmethod
    def setUpClass(cls):
        """2026-10-22: Resolve fixture roles once without copying approved migration IDs."""
        cls.context = build_context(FIXTURES)

    def sql(self, text):
        """Execute only test-owned SQL using the same bounded psql invocation."""
        return migration.run_psql(OPTIONS.psql, OPTIONS.database, text, OPTIONS.timeout_seconds)

    def setUp(self):
        """Rebuild the dedicated test schema and add active/ended synthetic sessions."""
        self.temp = tempfile.TemporaryDirectory(prefix='payse-identity-', dir=OPTIONS.temp)
        self.addCleanup(self.temp.cleanup)
        self.backup = Path(self.temp.name) / 'identity-plan.json'
        migration.require(OPTIONS.database.startswith('payse_fixture_identity_'), 'Identity test database required')
        self.sql("DO $$ BEGIN IF current_database() NOT LIKE 'payse_fixture_identity_%' THEN RAISE EXCEPTION 'Test database required'; END IF; END $$; DROP SCHEMA IF EXISTS payse CASCADE;")
        self.sql((DATABASE.parent/'tests/legacy/001_initial.sql').read_text(encoding='utf-8'))
        self.sql((DATABASE.parent/'tests/legacy/002_storage_guards.sql').read_text(encoding='utf-8'))
        self.sql(export_reference())
        self.sql(legacy_sql(export(FIXTURES,['alpha-ready','beta-ready','gamma-month-end'])))
        # Current context resolves IDs; the historical schema is verified by migration assertions.
        self.owner_id = self.context['owner_id']
        self.other_owner_id = self.context['other_owner_id']
        owner = self.owner_id
        self.sql("INSERT INTO payse.demo_sessions(id,user_id,token_digest,issued_at,ended_at) VALUES "
                 f"('{uuid4()}','{owner}','test-only-active','2026-10-20T00:00:00+09',NULL),"
                 f"('{uuid4()}','{owner}','test-only-ended','2026-10-19T00:00:00+09','2026-10-20T00:00:00+09');")

    def legacy(self, installation=True):
        """Build a documented historical schema fixture; never alter the real initial SQL."""
        commands = [
            'ALTER TABLE payse.demo_users ADD COLUMN synthetic_name text, ADD COLUMN display_name text;',
            'ALTER TABLE payse.demo_users DROP CONSTRAINT identity_phone_format;',
        ]
        for row in migration.IDENTITY_USERS:
            commands.append('UPDATE payse.demo_users SET synthetic_name=' + migration.sql_literal(row['legacy_synthetic_name']) + ',display_name=' + migration.sql_literal(row['legacy_display_name']) + ' WHERE id=' + migration.sql_literal(row['user_id']) + ';')
        commands += [
            'ALTER TABLE payse.demo_users ALTER COLUMN synthetic_name SET NOT NULL, ALTER COLUMN display_name SET NOT NULL;',
            'ALTER TABLE payse.demo_users ADD UNIQUE(synthetic_name,synthetic_phone);',
            'ALTER TABLE payse.demo_users ADD CHECK(synthetic_name IS NULL OR length(btrim(synthetic_name))>0), ADD CHECK(display_name IS NULL OR length(btrim(display_name))>0), ADD CHECK(synthetic_phone IS NULL OR length(btrim(synthetic_phone))>0);',
            'ALTER TABLE payse.demo_users DROP COLUMN name RESTRICT;',
        ]
        if installation:
            commands.append("ALTER TABLE payse.demo_sessions ADD COLUMN installation_id text; UPDATE payse.demo_sessions SET installation_id='synthetic-old-device';")
        self.sql('BEGIN;' + '\n'.join(commands) + 'COMMIT;')

    def state(self):
        """Read raw metadata without concealing malformed-contract test states."""
        return json.loads(self.sql(migration.snapshot_query()))

    def plan(self):
        """Create and verify a real external source backup for this test."""
        return migration.create_plan(OPTIONS.psql, OPTIONS.database, self.backup, OPTIONS.timeout_seconds, OPTIONS.lock_timeout_ms)[0]

    def apply(self, digest, lock_timeout_ms=None):
        """Apply only the exact file chosen by the test with its original hash."""
        return migration.apply_plan(OPTIONS.psql, OPTIONS.database, self.backup, digest, OPTIONS.timeout_seconds, lock_timeout_ms or OPTIONS.lock_timeout_ms)

    def test_legacy_migration_preserves_finance_sessions_verifier_and_archive(self):
        self.legacy()
        before = self.state()
        digest = self.plan()
        archived = migration.load_plan(self.backup, digest)[1]
        archived_bytes = self.backup.read_bytes()
        self.assertEqual(archived, before)
        self.assertEqual(len(archived['legacyInstallations']), 2)
        self.assertEqual(self.apply(digest), 'APPLIED')
        after = self.state()
        self.assertEqual(before['data'], after['data'])
        self.assertEqual(migration.validate_snapshot(after), {'rename': False, 'dropInstallation': False})
        self.assertEqual(self.backup.read_bytes(), archived_bytes)

    def test_legacy_without_installation_column(self):
        self.legacy(False)
        self.assertEqual(self.apply(self.plan()), 'APPLIED')

    def test_target_noop_validates_schema_and_data(self):
        before = self.state()
        self.assertEqual(self.apply(self.plan()), 'NOOP')
        self.assertEqual(self.state(), before)

    def test_target_with_installation_only(self):
        self.sql("ALTER TABLE payse.demo_sessions ADD COLUMN installation_id text; UPDATE payse.demo_sessions SET installation_id='synthetic-only';")
        before = self.state()['data']
        self.assertEqual(self.apply(self.plan()), 'APPLIED')
        self.assertEqual(self.state()['data'], before)

    def test_old_plan_replay_rejected_then_new_plan_noop(self):
        self.legacy()
        digest = self.plan()
        self.assertEqual(self.apply(digest), 'APPLIED')
        with self.assertRaises(migration.MigrationError): self.apply(digest)
        self.backup = Path(self.temp.name) / 'reviewed-target.json'
        self.assertEqual(self.apply(self.plan()), 'NOOP')

    def test_wrong_mapping_rejected_without_backup(self):
        self.legacy()
        self.sql(f"UPDATE payse.demo_users SET synthetic_name='Unexpected name' WHERE id='{self.owner_id}';")
        with self.assertRaises(migration.MigrationError): self.plan()
        self.assertFalse(self.backup.exists())

    def test_unknown_uuid_rejected(self):
        self.sql(f"INSERT INTO payse.demo_users VALUES('{uuid4()}','추가사용자','01099999999','DISABLED:auth-design-pending',1,now());")
        with self.assertRaises(migration.MigrationError): self.plan()

    def test_phone_mismatch_rejected(self):
        self.sql(f"UPDATE payse.demo_users SET synthetic_phone='01099999999' WHERE id='{self.owner_id}';")
        with self.assertRaises(migration.MigrationError): self.plan()

    def test_partial_schema_rejected(self):
        self.sql('ALTER TABLE payse.demo_users ADD COLUMN display_name text;')
        with self.assertRaises(migration.MigrationError): self.plan()

    def test_forged_target_check_rejected(self):
        self.sql('ALTER TABLE payse.demo_users DROP CONSTRAINT identity_name_format; ALTER TABLE payse.demo_users ADD CONSTRAINT identity_name_format CHECK(true);')
        with self.assertRaises(migration.MigrationError): self.plan()

    def test_active_session_index_false_predicate_rejected(self):
        self.sql('DROP INDEX payse.active_session_per_user; CREATE UNIQUE INDEX active_session_per_user ON payse.demo_sessions(user_id) WHERE ended_at IS NULL AND false;')
        with self.assertRaises(migration.MigrationError): self.plan()

    def test_missing_identity_row_policy_rejected(self):
        self.sql('DROP POLICY own_rows ON payse.demo_users;')
        with self.assertRaises(migration.MigrationError): self.plan()

    def test_tautological_identity_row_policy_rejected(self):
        self.sql('ALTER POLICY own_rows ON payse.demo_sessions USING(true) WITH CHECK(true);')
        with self.assertRaises(migration.MigrationError): self.plan()

    def test_extra_permissive_identity_row_policy_rejected(self):
        self.sql('CREATE POLICY bypass_identity ON payse.demo_users USING(true) WITH CHECK(true);')
        with self.assertRaises(migration.MigrationError): self.plan()

    def test_custom_legacy_check_preserved_by_refusal(self):
        self.legacy()
        self.sql('ALTER TABLE payse.demo_users ADD CONSTRAINT custom_legacy_check CHECK(length(synthetic_name)<100);')
        before = self.state()
        with self.assertRaises(migration.MigrationError): self.plan()
        self.assertEqual(self.state(), before)

    def test_custom_legacy_index_preserved_by_refusal(self):
        self.legacy()
        self.sql('CREATE INDEX custom_legacy_index ON payse.demo_sessions(installation_id);')
        before = self.state()
        with self.assertRaises(migration.MigrationError): self.plan()
        self.assertEqual(self.state(), before)

    def test_dependent_view_rejected(self):
        self.legacy()
        self.sql('CREATE VIEW payse_legacy_identity_probe AS SELECT synthetic_name FROM payse.demo_users;')
        try:
            with self.assertRaises(migration.MigrationError): self.plan()
        finally:
            self.sql('DROP VIEW payse_legacy_identity_probe;')

    def test_backup_tamper_rejected_before_database_write(self):
        self.legacy()
        before = self.state()
        digest = self.plan()
        self.backup.write_bytes(self.backup.read_bytes() + b' ')
        with self.assertRaises(migration.MigrationError): self.apply(digest)
        self.assertEqual(self.state(), before)

    def test_backup_overwrite_refused(self):
        self.backup.write_text('existing', encoding='utf-8')
        with self.assertRaises(migration.MigrationError): self.plan()
        self.assertEqual(self.backup.read_text(encoding='utf-8'), 'existing')

    def test_malformed_rehashed_plan_returns_value_free_rejection(self):
        self.plan()
        before = self.state()
        original = json.loads(self.backup.read_text(encoding='utf-8'))
        cases = [None, [], {**original, 'sourceState': None}, {**original, 'sourceState': 7},
                 {**original, 'stateDigest': 7}, {**original, 'actions': 7},
                 {**original, 'actions': {'rename': 1, 'dropInstallation': False}},
                 {**original, 'sourceState': '[]', 'stateDigest': hashlib.sha256(b'[]').hexdigest()}]
        for value in cases:
            with self.subTest(kind=type(value).__name__):
                body = json.dumps(value).encode('utf-8')
                self.backup.write_bytes(body)
                command = [sys.executable, '-B', str(DATABASE / 'migrate_identity.py'), '--apply',
                           '--psql', str(OPTIONS.psql), '--database', OPTIONS.database,
                           '--backup', str(self.backup), '--expected-sha256', hashlib.sha256(body).hexdigest(),
                           '--timeout-seconds', str(OPTIONS.timeout_seconds), '--lock-timeout-ms', str(OPTIONS.lock_timeout_ms)]
                result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', timeout=OPTIONS.timeout_seconds)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout)['status'], 'REJECTED')
                self.assertEqual(result.stderr, '')
        self.assertEqual(self.state(), before)

    def test_changed_database_state_rejected(self):
        self.legacy()
        digest = self.plan()
        account_id = self.context['owner_account_id']
        self.sql(f"UPDATE payse.financial_accounts SET nickname='변경' WHERE id='{account_id}' AND user_id='{self.owner_id}';")
        before = self.state()
        with self.assertRaises(migration.MigrationError): self.apply(digest)
        self.assertEqual(self.state(), before)

    def test_wrong_database_fingerprint_rejected(self):
        digest = self.plan()
        plan = json.loads(self.backup.read_text(encoding='utf-8'))
        source = json.loads(plan['sourceState'])
        source['database']['systemIdentifier'] = 'different-cluster'
        plan['sourceState'] = json.dumps(source)
        plan['stateDigest'] = hashlib.sha256(plan['sourceState'].encode()).hexdigest()
        body = json.dumps(plan).encode()
        self.backup.write_bytes(body)
        with self.assertRaises(migration.MigrationError): self.apply(hashlib.sha256(body).hexdigest())

    def test_mid_update_failure_rolls_back_all_changes(self):
        self.legacy()
        self.sql(f"CREATE FUNCTION payse.identity_test_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id='{self.other_owner_id}' THEN RAISE EXCEPTION 'test failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER identity_test_fail BEFORE UPDATE ON payse.demo_users FOR EACH ROW EXECUTE FUNCTION payse.identity_test_fail();")
        before = self.state()
        digest = self.plan()
        with self.assertRaises(migration.MigrationError): self.apply(digest)
        self.assertEqual(self.state(), before)

    def test_restricted_rls_role_does_not_plan_partial_rows(self):
        role = 'payse_identity_probe_' + uuid4().hex[:8]
        self.sql(f'CREATE ROLE {role}; GRANT USAGE ON SCHEMA payse TO {role}; GRANT SELECT ON ALL TABLES IN SCHEMA payse TO {role};')
        try:
            with self.assertRaises(migration.MigrationError):
                self.sql(f"BEGIN; SET ROLE {role}; SET LOCAL row_security=off; SELECT * FROM payse.demo_users; ROLLBACK;")
        finally:
            self.sql(f'DROP OWNED BY {role}; DROP ROLE {role};')

    def test_lock_timeout_refuses_migration(self):
        self.legacy()
        digest = self.plan()
        command = [str(OPTIONS.psql), '-X', '--no-password', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', OPTIONS.database]
        holder = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8')
        try:
            holder.stdin.write("BEGIN; LOCK TABLE payse.demo_users IN ACCESS EXCLUSIVE MODE; SELECT 'LOCKED'; SELECT pg_sleep(3); ROLLBACK;\n")
            holder.stdin.flush()
            self.assertEqual(holder.stdout.readline().strip(), 'LOCKED')
            with self.assertRaises(migration.MigrationError): self.apply(digest, 100)
        finally:
            holder.communicate(timeout=OPTIONS.timeout_seconds)


def main():
    """Require an explicitly named disposable database and explicit tool limits."""
    global OPTIONS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--psql', type=Path, required=True)
    parser.add_argument('--database', required=True)
    parser.add_argument('--timeout-seconds', type=int, required=True)
    parser.add_argument('--lock-timeout-ms', type=int, required=True)
    parser.add_argument('--temp', type=Path, required=True)
    OPTIONS = parser.parse_args()
    require_disposable_database(OPTIONS.database)
    migration.require(OPTIONS.database.startswith('payse_fixture_identity_'), 'Identity test database required')
    OPTIONS.temp.mkdir(parents=True, exist_ok=True)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(IdentityMigrationTests))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
