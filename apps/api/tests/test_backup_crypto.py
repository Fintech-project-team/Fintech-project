"""2026-11-05: 실제 암호 라이브러리로 백업 무결성·실패 후 비공개·복구 키를 검사한다."""
import hashlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import backup_crypto as crypto


class BackupCryptoTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='payse-crypto-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.key = os.urandom(32)
        self.archive = self.root / 'backup.enc'

    def seal(self, content=b'synthetic-financial-private-marker'):
        crypto.encrypt_stream(io.BytesIO(content), self.archive, self.key)
        return content

    def test_empty_and_multiple_chunks_restore_exactly(self):
        for size in (0, 13, crypto.CHUNK * 2 + 77):
            with self.subTest(size=size):
                plain = os.urandom(size)
                self.seal(plain)
                restored = self.root / 'restored'
                expected = {'bytes': size, 'sha256': hashlib.sha256(plain).hexdigest()}
                self.assertEqual(crypto.decrypt_file(self.archive, self.key, restored), expected)
                self.assertEqual(restored.read_bytes(), plain)
                self.assertEqual(crypto.decrypt_file(self.archive, self.key), expected)
                self.archive.unlink()
                restored.unlink()

    def test_random_nonce_and_no_plain_marker(self):
        plain = self.seal()
        first = self.archive.read_bytes()
        self.assertNotIn(plain, first)
        self.archive.unlink()
        self.seal(plain)
        self.assertNotEqual(first, self.archive.read_bytes())

    def test_tamper_truncation_append_and_wrong_key_publish_nothing(self):
        self.seal()
        body = self.archive.read_bytes()
        damaged = []
        for index in (0, len(crypto.MAGIC) + 1, len(crypto.MAGIC) + 15, len(body) - 1):
            changed = bytearray(body)
            changed[index] ^= 1
            damaged.append(bytes(changed))
        damaged.extend((body[:5], body[:-1], body + b'x'))
        for variant, key in [(v, self.key) for v in damaged] + [(body, os.urandom(32))]:
            with self.subTest(length=len(variant)):
                self.archive.write_bytes(variant)
                destination = self.root / 'must-not-exist'
                with self.assertRaises(Exception):
                    crypto.decrypt_file(self.archive, key, destination)
                self.assertFalse(destination.exists())
                self.assertFalse(list(self.root.glob('.payse-restore-*')))

    def test_no_overwrite_and_git_boundary(self):
        plain = self.seal()
        original = self.archive.read_bytes()
        with self.assertRaises(ValueError):
            self.seal(b'replacement')
        with self.assertRaises(ValueError):
            crypto.decrypt_file(self.archive, self.key, self.archive)
        self.assertEqual(self.archive.read_bytes(), original)
        git = self.root / 'repository'
        git.mkdir()
        (git / '.git').mkdir()
        with self.assertRaises(ValueError):
            crypto.encrypt_stream(io.BytesIO(plain), git / 'secret', self.key)
        with self.assertRaises(ValueError):
            crypto.private_path(Path('relative.key'))

    def test_hardlink_key_rejected(self):
        key_file = self.root / 'key'
        crypto.write_key(key_file, self.key, 'file')
        os.link(key_file, self.root / 'copy')
        with self.assertRaises(ValueError):
            crypto.read_key(key_file)

    def test_stream_failure_and_limit_remove_partial_backup(self):
        class Broken(io.BytesIO):
            def read(self, size):
                if self.tell():
                    raise OSError('synthetic-read-failure')
                return super().read(size)

        with self.assertRaises(OSError):
            crypto.encrypt_stream(Broken(b'synthetic'), self.archive, self.key)
        self.assertFalse(self.archive.exists())
        with patch.object(crypto, 'MAX_SIZE', 3), self.assertRaises(ValueError):
            self.seal(b'oversized')
        self.assertFalse(self.archive.exists())

    def test_permission_failure_writes_no_private_bytes(self):
        with patch.object(crypto, 'restrict_file', side_effect=ValueError('ACL denied')), self.assertRaises(ValueError):
            self.seal()
        self.assertFalse(self.archive.exists())

    def test_small_document_authentication_and_memory_limit(self):
        plain = self.seal()
        self.assertEqual(crypto.read_encrypted(self.archive, self.key), plain)
        with self.assertRaises(ValueError):
            crypto.read_encrypted(self.archive, self.key, limit=3)
        with self.assertRaises(Exception):
            crypto.read_encrypted(self.archive, os.urandom(32))

    def test_key_formats_and_portable_recovery(self):
        key_file = self.root / 'key'
        crypto.write_key(key_file, self.key, 'file')
        self.assertEqual(crypto.read_key(key_file), self.key)
        phrase = 'synthetic-only-long-recovery-passphrase'
        envelope = crypto.export_key(self.key, phrase)
        self.assertNotIn(self.key, envelope)
        self.assertEqual(crypto.import_key(envelope, phrase), self.key)
        for body, password in ((envelope, phrase + 'wrong'), (envelope[:-1], phrase),
                               (envelope[:-1] + bytes([envelope[-1] ^ 1]), phrase)):
            with self.assertRaises(Exception):
                crypto.import_key(body, password)
        with self.assertRaises(ValueError):
            crypto.export_key(self.key, 'short')
        for invalid in (b'unknown', crypto.FILE_KEY + b'too-short', b'x' * 8193):
            key_file.write_bytes(invalid)
            with self.assertRaises(ValueError):
                crypto.read_key(key_file)

    @unittest.skipUnless(os.name == 'nt', 'Windows DPAPI only')
    def test_windows_dpapi_round_trip_and_tamper(self):
        key_file = self.root / 'key'
        crypto.write_key(key_file, self.key, 'dpapi')
        body = key_file.read_bytes()
        self.assertNotIn(self.key, body)
        self.assertEqual(crypto.read_key(key_file), self.key)
        key_file.write_bytes(body[:-1] + bytes([body[-1] ^ 1]))
        with self.assertRaises(ValueError):
            crypto.read_key(key_file)


if __name__ == '__main__':
    unittest.main()
