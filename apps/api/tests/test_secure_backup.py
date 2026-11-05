"""2026-11-05: DB 덤프 읽기 전용 인자·실패 처리와 CLI 비밀 비노출을 검사한다."""
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import backup_crypto as crypto
import secure_backup as backup


class SecureBackupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='payse-dump-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.key = os.urandom(32)
        self.destination = self.root / 'database.enc'
        self.properties = {'PAYSE_JDBC_URL': 'jdbc:postgresql://localhost/test_database',
                           'PAYSE_DB_USER': 'synthetic-backup-user',
                           'PAYSE_DB_PASSWORD': 'synthetic-secret-do-not-log'}
        self.body = b'PGDMP-synthetic-raw-financial-marker'

    def process(self, code):
        process = Mock(stdout=io.BytesIO(self.body))
        process.wait.return_value = code
        process.poll.return_value = code
        return process

    def test_dump_goes_directly_to_verified_ciphertext(self):
        with patch.object(backup, 'Popen', return_value=self.process(0)) as launch:
            actual = backup.dump_database(sys.executable, self.properties, self.destination, self.key)
        self.assertEqual(actual, {'bytes': len(self.body), 'sha256': hashlib.sha256(self.body).hexdigest()})
        self.assertEqual([self.destination], list(self.root.iterdir()))
        self.assertNotIn(self.body, self.destination.read_bytes())
        self.assertNotIn(self.properties['PAYSE_DB_PASSWORD'], str(launch.call_args.args))
        self.assertIn('default_transaction_read_only=on', launch.call_args.kwargs['env']['PGOPTIONS'])
        self.assertEqual(launch.call_args.kwargs['stderr'], backup.subprocess.DEVNULL)

    def test_failed_dump_removes_new_ciphertext(self):
        with patch.object(backup, 'Popen', return_value=self.process(1)), self.assertRaises(RuntimeError):
            backup.dump_database(sys.executable, self.properties, self.destination, self.key)
        self.assertFalse(self.destination.exists())

    def test_existing_backup_and_unverified_remote_never_launch(self):
        self.destination.write_bytes(b'preserved')
        with patch.object(backup, 'Popen') as launch, self.assertRaises(ValueError):
            backup.dump_database(sys.executable, self.properties, self.destination, self.key)
        launch.assert_not_called()
        self.assertEqual(self.destination.read_bytes(), b'preserved')
        self.destination.unlink()
        self.properties['PAYSE_JDBC_URL'] = 'jdbc:postgresql://db.example.test/payse'
        with patch.object(backup, 'Popen') as launch, self.assertRaises(ValueError):
            backup.dump_database(sys.executable, self.properties, self.destination, self.key)
        launch.assert_not_called()

    def test_timeout_kills_only_dump_and_cleans_partial(self):
        process = self.process(-1)
        class ImmediateTimer:
            daemon = False
            def __init__(self, timeout, callback):
                self.callback = callback
            def start(self):
                self.callback()
            def cancel(self):
                pass
            def join(self):
                pass
        with patch.object(backup, 'Popen', return_value=process), \
                patch.object(backup.threading, 'Timer', ImmediateTimer), self.assertRaises(RuntimeError):
            backup.dump_database(sys.executable, self.properties, self.destination, self.key)
        process.kill.assert_called_once()
        self.assertFalse(self.destination.exists())

    def test_cli_errors_do_not_echo_key_or_private_details(self):
        arguments = Mock(command='verify', key=self.root / 'synthetic-secret')
        with patch.object(backup, 'arguments', return_value=arguments), \
                patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(backup.main(), 1)
        self.assertEqual(json.loads(output.getvalue())['status'], 'REJECTED')
        self.assertNotIn('synthetic-secret', output.getvalue())

    def test_recovery_password_never_falls_back_to_echoed_input(self):
        with patch.object(backup, 'arguments', return_value=Mock(command='export-key')), \
                patch.object(backup.sys.stdin, 'isatty', return_value=False), \
                patch.object(backup.getpass, 'getpass') as prompt, \
                patch('sys.stdout', new_callable=io.StringIO):
            self.assertEqual(backup.main(), 1)
        prompt.assert_not_called()

    def test_identity_plan_encrypted_and_plaintext_requires_explicit_legacy_flag(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'database'))
        import migrate_identity as migration
        key_file = self.root / 'backup.key'
        crypto.write_key(key_file, self.key, 'file')
        raw = '{"synthetic-source":"private-marker"}'
        actions = {'rename': False, 'dropInstallation': False}
        with patch.object(migration, 'read_state', return_value=(raw, json.loads(raw), actions)):
            digest, returned = migration.create_plan('unused', 'unused', self.destination, 1, 1,
                                                      backup_key=key_file)
        self.assertEqual(returned, actions)
        self.assertNotIn(b'private-marker', self.destination.read_bytes())
        with patch.object(migration, 'validate_snapshot', return_value=actions):
            plan, _ = migration.load_plan(self.destination, digest, backup_key=key_file)
            self.assertEqual(plan['sourceState'], raw)
            with self.assertRaises(migration.MigrationError):
                migration.load_plan(self.destination, digest)
            legacy = self.root / 'legacy.json'
            legacy.write_text(json.dumps(plan), encoding='utf-8')
            checksum = hashlib.sha256(legacy.read_bytes()).hexdigest()
            with self.assertRaises(migration.MigrationError):
                migration.load_plan(legacy, checksum)
            self.assertEqual(migration.load_plan(legacy, checksum, allow_legacy_plaintext=True)[0], plan)
            with self.assertRaises(migration.MigrationError):
                migration.load_plan(legacy, checksum, backup_key=key_file, allow_legacy_plaintext=True)
        with patch.object(migration, 'read_state') as read, self.assertRaises(migration.MigrationError):
            migration.create_plan('unused', 'unused', self.root / 'missing-key', 1, 1)
        read.assert_not_called()


if __name__ == '__main__':
    unittest.main()
