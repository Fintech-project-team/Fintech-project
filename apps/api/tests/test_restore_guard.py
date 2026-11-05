"""2026-11-05: 삭제 결정의 보존·소유권·낡은 자료·실서버 쓰기 거절을 검사한다."""
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import backup_crypto as crypto
import restore_guard as guard


class RestoreGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='payse-restore-policy-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.key_path = self.root / 'key'
        self.key = os.urandom(32)
        crypto.write_key(self.key_path, self.key, 'file')
        self.archive = self.root / 'policy.enc'
        self.record = {'format': guard.FORMAT, 'sourceSystem': '123456789', 'sourceDatabase': 'payse',
                       'capturedAt': datetime.now(timezone.utc).isoformat(), 'revocations': [], 'suppressions': []}
        self.settings = {'PAYSE_JDBC_URL': 'jdbc:postgresql://localhost/payse_restore_test'}

    def seal(self, record=None, path=None):
        destination = path or self.archive
        crypto.encrypt_stream(io.BytesIO(json.dumps(record or self.record).encode()), destination, self.key)
        return hashlib.sha256(destination.read_bytes()).hexdigest()

    def test_capture_merges_deletion_and_never_exposes_plain_ids(self):
        owner, item = str(uuid4()), str(uuid4())
        self.record['revocations'] = [{'id': item, 'owner': owner,
                                      'deletedAt': self.record['capturedAt'], 'purgeAt': self.record['capturedAt']}]
        self.seal()
        now = dict(self.record, capturedAt=datetime.now(timezone.utc).isoformat(),
                   revocations=[dict(self.record['revocations'][0], deletedAt=None)])
        output = self.root / 'next.enc'
        with patch.object(guard, 'run_sql', return_value={k:v for k,v in now.items() if k!='format'}) as sql:
            guard.capture(sys.executable, {}, self.key_path, output, self.archive)
        recovered = json.loads(crypto.read_encrypted(output, self.key))
        self.assertEqual(recovered['revocations'][0]['deletedAt'], self.record['capturedAt'])
        self.assertNotIn(item.encode(), output.read_bytes())
        self.assertIn('READ ONLY', sql.call_args.args[2])

    def test_production_target_and_stale_policy_never_write(self):
        digest = self.seal()
        with patch.object(guard, 'run_sql') as sql, self.assertRaises(ValueError):
            guard.apply(sys.executable, {'PAYSE_JDBC_URL':'jdbc:postgresql://localhost/payse_dev'},
                        self.key_path, self.archive, digest, self.root)
        sql.assert_not_called()
        self.archive.unlink()
        self.record['capturedAt'] = (datetime.now(timezone.utc)-timedelta(minutes=6)).isoformat()
        digest = self.seal()
        with patch.object(guard, 'run_sql') as sql, self.assertRaises(ValueError):
            guard.apply(sys.executable, self.settings, self.key_path, self.archive, digest, self.root)
        sql.assert_not_called()

    def test_tamper_and_wrong_review_hash_never_write(self):
        self.seal()
        with patch.object(guard, 'run_sql') as sql, self.assertRaises(ValueError):
            guard.apply(sys.executable, self.settings, self.key_path, self.archive, '0'*64, self.root)
        sql.assert_not_called()
        self.archive.write_bytes(self.archive.read_bytes()[:-1])
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with patch.object(guard, 'run_sql') as sql, self.assertRaises(Exception):
            guard.apply(sys.executable, self.settings, self.key_path, self.archive, digest, self.root)
        sql.assert_not_called()

    def test_sql_checks_cluster_directory_owner_and_single_connection(self):
        digest = self.seal()
        with patch.object(guard, 'run_sql', return_value={'purgedItems':0}) as sql:
            guard.apply(sys.executable, self.settings, self.key_path, self.archive, digest, self.root)
        statement = sql.call_args.args[2]
        for required in ('pg_control_system()', 'data_directory', 'pg_stat_activity',
                         'i.user_id<>r.owner', 'ciphertext=NULL,crypto_meta=NULL',
                         'metadata_version=i.metadata_version+1', 'COMMIT;'):
            self.assertIn(required, statement)
        self.assertNotIn('DELETE FROM payse.users', statement)

    def test_invalid_owner_duplicate_and_future_decisions(self):
        item = {'id':str(uuid4()),'owner':str(uuid4()),'deletedAt':self.record['capturedAt'],'purgeAt':None}
        for rows in ([item,item], [dict(item,owner='invalid')],
                     [dict(item,deletedAt=(datetime.now(timezone.utc)+timedelta(days=1)).isoformat())]):
            with self.assertRaises(ValueError):
                guard.validate(dict(self.record,revocations=rows))

    def test_prior_journal_from_another_source_is_rejected(self):
        self.seal()
        source = dict(self.record, sourceSystem='987654321')
        with patch.object(guard, 'run_sql', return_value={k:v for k,v in source.items() if k!='format'}), \
                self.assertRaises(ValueError):
            guard.capture(sys.executable, {}, self.key_path, self.root/'next.enc', self.archive)
        self.assertFalse((self.root/'next.enc').exists())


if __name__ == '__main__':
    unittest.main()
