"""2026-11-05: 복구 파일 비밀 보호·재가져오기·로컬 입력 경계를 운영 인증서 없이 검사한다."""
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import backup_crypto as crypto
import recovery_setup as recovery


class RecoverySetupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='payse-recovery-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.key_file = self.root / 'backup.key'
        self.key = os.urandom(32)
        crypto.write_key(self.key_file, self.key, 'file')
        self.archive = self.root / 'efs.enc'
        self.packet = {'format': 'PAYSE-EFS-RECOVERY-1', 'password': 'synthetic-private-password',
                       'certificates': [{'thumbprint': 'synthetic-thumbprint', 'pfx': 'synthetic-private-pfx'}]}

    def archive_packet(self):
        crypto.encrypt_stream(io.BytesIO(json.dumps(self.packet).encode()), self.archive, self.key)

    def test_prepare_seals_and_verifies_efs_without_installing(self):
        outputs = [{'certificates': self.packet['certificates'], 'verifiedCount': 1}, {'verifiedCount': 1}]
        with patch.object(recovery, 'efs', side_effect=outputs) as invoke:
            result = recovery.prepare(self.key_file, self.archive)
        self.assertEqual([call.args[0] for call in invoke.call_args_list], ['export', 'verify'])
        self.assertNotIn(b'synthetic-private-pfx', self.archive.read_bytes())
        self.assertEqual(result['verifiedCertificates'], 1)
        self.assertFalse(result['installed'])
        self.assertFalse(result['offlineCopyVerified'])

    def test_tampered_archive_never_reaches_certificate_store(self):
        self.archive_packet()
        self.archive.write_bytes(self.archive.read_bytes()[:-1])
        with patch.object(recovery, 'efs') as invoke, self.assertRaises(Exception):
            recovery.verify(self.key_file, self.archive, install=True)
        invoke.assert_not_called()

    def test_existing_recovery_file_is_preserved(self):
        self.archive_packet()
        before = self.archive.read_bytes()
        with patch.object(recovery, 'efs') as invoke, self.assertRaises(ValueError):
            recovery.prepare(self.key_file, self.archive)
        invoke.assert_not_called()
        self.assertEqual(self.archive.read_bytes(), before)

    def test_password_export_checks_actual_envelope_and_efs(self):
        self.archive_packet()
        target = self.root / 'recovery.key'
        phrase = 'synthetic-long-password'
        with patch.object(recovery.sys.stdin, 'isatty', return_value=True), \
                patch.object(recovery.getpass, 'getpass', side_effect=[phrase, phrase]), \
                patch.object(recovery, 'efs', return_value={'verifiedCount': 1}):
            result = recovery.portable_key(self.key_file, self.archive, target)
        self.assertEqual(crypto.import_key(target.read_bytes(), phrase), self.key)
        self.assertTrue(result['portableKeyVerified'])
        self.assertFalse(result['offlineCopyVerified'])

    def test_input_requires_terminal_and_matching_passwords(self):
        self.archive_packet()
        target = self.root / 'recovery.key'
        with patch.object(recovery.sys.stdin, 'isatty', return_value=False), self.assertRaises(ValueError):
            recovery.portable_key(self.key_file, self.archive, target)
        with patch.object(recovery.sys.stdin, 'isatty', return_value=True), \
                patch.object(recovery.getpass, 'getpass', side_effect=['synthetic-long-one', 'synthetic-long-two']), \
                self.assertRaises(ValueError):
            recovery.portable_key(self.key_file, self.archive, target)
        self.assertFalse(target.exists())

    def test_incomplete_verification_never_claims_success(self):
        self.archive_packet()
        with patch.object(recovery, 'efs', return_value={'verifiedCount': 0}), self.assertRaises(ValueError):
            recovery.verify(self.key_file, self.archive)


if __name__ == '__main__':
    unittest.main()
