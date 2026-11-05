"""2026-11-02: 신규 설치 점검·DB 접근 조건·복구 경계를 임시 폴더에서 검증한다."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, Mock, patch

import javaproperties

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import ai_setup
import portable_server as server
import release_server as release
from test_release_server import COMMIT, bundle, receipt


class PortableTests(unittest.TestCase):
    def test_ambiguous_database_urls_are_rejected_before_process_launch(self):
        suffixes = ('//localhost,db.example.test/payse', '//localhost:0/payse',
                    '//localhost:65536/payse', '//localhost:private-marker/payse',
                    '//localhost/payse?', '//localhost/payse#', '//localhost/a%2Fb',
                    '//localhost/payse?sslmode=', '//localhost/payse?sslmode=disable&',
                    '//db.example.test/payse?sslmode=verify-full&sslmode=disable',
                    '//db.example.test/payse?sslmode=verify-full&%73slmode=disable',
                    '//db.example.test/payse?sslmode=verify-full&sslfactory=Ignore',
                    '//localhost/payse?sslrootcert=a%0Ab', '//local\nhost/payse',
                    '//localhost@db.example.test/payse?sslmode=verify-full')
        for suffix in suffixes:
            with self.subTest(suffix=suffix), self.assertRaises(ValueError) as failure:
                server.database_target('jdbc:postgresql:' + suffix)
            self.assertNotIn('private-marker', str(failure.exception))
        for suffix in ('//localhost/payse', '//127.0.0.1:5432/payse', '//[::1]/payse',
                       '//db.example.test/payse?sslmode=verify-full&sslrootcert=C%3A%2Fca.pem'):
            self.assertTrue(server.database_target('jdbc:postgresql:' + suffix))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='payse-portable-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.package, self.metadata = bundle(self.root)
        self.schema = json.loads((self.package / 'release-schema.json').read_text())
        self.home = self.root / 'server'
        self.settings = {'deployment.installRoot': str(self.home), 'deployment.maxHeapMiB': '1024',
                         'deployment.minFreeGiB': '4', 'server.java': sys.executable, 'server.psql': 'psql'}
        self.properties = {'spring.profiles.active': ','.join(server.PROFILES),
                           'PAYSE_BIND_ADDRESS': '127.0.0.1', 'PAYSE_PORT': '18080',
                           'PAYSE_JDBC_URL': 'jdbc:postgresql://127.0.0.1:5432/test_database',
                           'PAYSE_DB_USER': 'test_runtime', 'PAYSE_DB_PASSWORD': 'synthetic-password',
                           'PAYSE_AUTH_CODE_KEY_ID': 'test-key', 'PAYSE_DB_MAX_POOL_SIZE': '4',
                           'PAYSE_DB_CONNECTION_TIMEOUT_MS': '5000', 'PAYSE_DB_VALIDATION_TIMEOUT_MS': '1000',
                           'PAYSE_AUTH_PEER_MODE': 'direct'}
        for key in server.SECRET_KEYS[1:]:
            self.properties[key] = base64.b64encode(os.urandom(32)).decode()
        self.config = self.root / 'configuration'
        self.config.mkdir()
        self.write_config()

    def write_config(self):
        for name, values in (('deployment.properties', self.settings), ('server.properties', self.properties)):
            with (self.config / name).open('w', encoding='utf-8') as stream:
                javaproperties.dump(values, stream, timestamp=False)

    def test_configuration_rejects_unsafe_or_unsupported_values(self):
        self.assertEqual(server.validate_settings(self.settings, self.properties, self.schema), (18080, 1024, 4))
        changes = ({'spring.profiles.active': ','.join(server.PROFILES) + ',analysis'},
                   {'PAYSE_BIND_ADDRESS': '0.0.0.0'}, {'PAYSE_PORT': '443'},
                   {'PAYSE_AUTH_CODE_KEY_BASE64': 'not-a-key'},
                   {'PAYSE_AUTH_CODE_KEY_BASE64': self.properties['PAYSE_AUTH_LIMIT_KEY_BASE64']},
                   {'spring.config.import': 'file:external.properties'}, {'PAYSE_DB_MAX_POOL_SIZE': '0'})
        for change in changes:
            with self.subTest(change=list(change)), self.assertRaises(ValueError):
                server.validate_settings(self.settings, dict(self.properties, **change), self.schema)
        for heap in ('-1', '8192', '4096'):
            with self.subTest(heap=heap), self.assertRaises(ValueError):
                server.validate_settings(dict(self.settings, **{'deployment.maxHeapMiB': heap}),
                                         self.properties, self.schema)

    def test_analysis_policy_preflight_is_read_only_and_validated(self):
        schema = dict(self.schema, analysisPolicy=['gamma-test', 'version-1'])
        query = server.schema_query(schema)
        self.assertIn("BEGIN READ ONLY", query)
        self.assertIn("analysis_cost_policy('gamma-test', 'version-1')", query)
        self.assertIn("'inputLimit')='12000'", query)
        self.assertNotIn('INSERT', query)
        with self.assertRaises(ValueError):
            server.schema_query(dict(self.schema, analysisPolicy=["bad'identity", 'version-1']))

    def test_remote_db_requires_verified_tls_and_secrets_stay_off_argv(self):
        remote = dict(self.properties, PAYSE_JDBC_URL='jdbc:postgresql://db.example.invalid/test_database')
        with patch.object(server.subprocess, 'run') as run, self.assertRaises(ValueError):
            server.database_check(self.settings, remote, self.schema)
        run.assert_not_called()
        remote['PAYSE_JDBC_URL'] += '?sslmode=verify-full'
        with patch.object(server.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'READY\n', '')) as run:
            server.database_check(self.settings, remote, self.schema)
        call = run.call_args
        self.assertNotIn('synthetic-password', str(call.args))
        self.assertEqual(call.kwargs['env']['PGPASSWORD'], 'synthetic-password')
        self.assertEqual(call.kwargs['env']['PGSSLMODE'], 'verify-full')
        self.assertIn('default_transaction_read_only=on', call.kwargs['env']['PGOPTIONS'])
        sql = call.args[0][-1]
        self.assertNotIn('UPDATE ', sql)
        self.assertNotIn('SELECT *', sql)
        self.assertIn('BEGIN READ ONLY; SET LOCAL ROLE payse_runtime;', sql)
        self.assertIn('WHERE rolname=session_user', sql)

    def test_failed_db_check_does_not_expose_psql_error(self):
        with patch.object(server.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'synthetic-password')):
            with self.assertRaises(RuntimeError) as caught:
                server.database_check(self.settings, self.properties, self.schema)
        self.assertNotIn('synthetic-password', str(caught.exception))

    def test_low_commit_memory_blocks_before_database(self):
        with patch.object(server, 'java_major', return_value=21), patch.object(server.runtime, 'memory',
                return_value={'physicalFreeGiB': 20, 'commitFreeGiB': 2}), patch.object(server, 'database_check') as database:
            with self.assertRaises(RuntimeError):
                server.preflight(self.settings, self.properties, self.schema)
        database.assert_not_called()

    def test_install_default_is_check_only_and_apply_requires_ci(self):
        with patch.object(server, 'preflight', return_value={'port': 18080}), patch.object(server.runtime, 'port_free', return_value=True):
            result = server.install(self.config / 'deployment.properties', self.package, COMMIT)
        self.assertFalse(result['applied'])
        self.assertFalse(self.home.exists())
        with self.assertRaises(FileNotFoundError):
            server.install(self.config / 'deployment.properties', self.package, COMMIT, apply=True)
        self.assertFalse(self.home.exists())

    def installed(self):
        receipt(self.package, self.metadata)
        with patch.object(server, 'preflight', return_value={'port': 18080}), patch.object(server.runtime, 'port_free', return_value=True):
            result = server.install(self.config / 'deployment.properties', self.package, COMMIT, apply=True)
        self.assertEqual(result['status'], 'INSTALLED_STOPPED')
        return server.read_installation(self.home)[1]

    def test_install_protects_private_files_and_refuses_overwrite(self):
        state = self.installed()
        self.assertIsNone(state['process'])
        self.assertEqual((self.home / 'server.properties').read_bytes(), (self.config / 'server.properties').read_bytes())
        if os.name != 'nt':
            self.assertEqual(self.home.stat().st_mode & 0o777, 0o700)
            self.assertEqual((self.home / 'server.properties').stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError):
            server.install(self.config / 'deployment.properties', self.package, COMMIT, apply=True)

    def test_schema_tampering_blocks_management(self):
        self.installed()
        (self.home / 'release-schema.json').write_text('{}', encoding='utf-8')
        with self.assertRaises(ValueError):
            server.read_installation(self.home)

    def transaction(self, starter, stopper):
        state = self.installed()
        candidate, metadata = bundle(self.root, 'candidate', 'b' * 40)
        with (candidate / 'server.jar').open('ab') as stream:
            stream.write(b'new-version')
        metadata['sha256']['server.jar'] = release.sha256(candidate / 'server.jar')
        protected = {name: (self.home / name).read_bytes() for name in ('deployment.properties', 'server.properties')}
        with patch.object(server.runtime, 'port_free', return_value=True):
            result = server.deploy_locked(self.home, state, self.settings, self.properties,
                                          candidate, metadata, starter=starter, stopper=stopper)
        for name, content in protected.items():
            self.assertEqual((self.home / name).read_bytes(), content)
        return result, metadata

    def test_successful_replacement_preserves_settings_and_backup(self):
        starter, stopper = Mock(), Mock()
        result, metadata = self.transaction(starter, stopper)
        self.assertEqual(result['status'], 'DEPLOYED')
        self.assertEqual(release.sha256(self.home / 'server.jar'), metadata['sha256']['server.jar'])
        self.assertTrue((Path(result['backup']) / 'server.jar').is_file())
        self.assertEqual(server.read_installation(self.home)[1]['sourceCommit'], 'b' * 40)
        starter.assert_called_once()
        stopper.assert_called_once()

    def test_failed_start_restores_old_jar_and_reports_failure(self):
        starter = Mock(side_effect=[RuntimeError('new startup failed'), None])
        with self.assertRaisesRegex(RuntimeError, 'previous JAR restored and healthy'):
            self.transaction(starter, Mock())
        self.assertEqual(server.read_installation(self.home)[1]['sourceCommit'], COMMIT)
        self.assertEqual((self.home / 'server.jar').read_bytes(), (self.package / 'server.jar').read_bytes())
        self.assertEqual(starter.call_count, 2)

    def test_stop_timeout_does_not_overwrite_live_files(self):
        starter = Mock()
        with self.assertRaisesRegex(RuntimeError, 'Shutdown incomplete'):
            self.transaction(starter, Mock(side_effect=RuntimeError('timeout')))
        starter.assert_not_called()
        self.assertEqual((self.home / 'server.jar').read_bytes(), (self.package / 'server.jar').read_bytes())

    def test_recovery_failure_retains_backup_and_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'Deployment/recovery incomplete'):
            self.transaction(Mock(side_effect=RuntimeError('cannot start')), Mock())
        backups = list((self.home / 'releases').glob('*/server.jar'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), (self.package / 'server.jar').read_bytes())

    def test_failed_standalone_start_stops_only_its_new_process(self):
        state = self.installed()
        identity = {'pid': 123, 'created': 1, 'exe': 'test', 'argv': []}
        with patch.object(server.runtime, 'owned_process', return_value=None), patch.object(server.runtime, 'port_free', return_value=True), \
                patch.object(server.runtime, 'launch', return_value=identity), patch.object(server, 'wait_healthy', side_effect=RuntimeError('timeout')), \
                patch.object(server.runtime, 'stop') as stop:
            with self.assertRaises(RuntimeError):
                server.start_locked(self.home, state, self.settings, self.properties)
        stop.assert_called_once_with(identity, self.home)
        self.assertIsNone(server.read_installation(self.home)[1]['process'])


class AiSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='payse-ai-setup-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.key = self.root / 'master.key'
        self.key.write_bytes(bytes(range(32)))
        self.llm = self.root / 'llm.properties'
        self.values = dict(enabled='true', provider='openai', model='gpt-6-luna',
                           reasoningEffort='none', apiKey='synthetic-key-12345')
        self.llm.write_text(javaproperties.dumps(self.values, timestamp=False))
        self.properties = {'spring.profiles.active': 'database,auth,finance,analysis,gamma-local'}
        self.properties.update({ai_setup.PREFIX + key: value for key, value in {
            'enabled': 'true', 'llm-file': str(self.llm), 'key-file': str(self.key),
            'state-directory': str(self.root), 'project': 'test', 'pricing': 'v1',
            'source-version': 'fixture:gamma-fresh:holdout:100'}.items()})
        self.opener = MagicMock()
        response = self.opener.open.return_value.__enter__.return_value
        response.status = 200
        response.read.return_value = b'{"id":"gpt-6-luna"}'

    def test_cached_access_is_not_generation_or_runtime_readiness(self):
        first = ai_setup.probe(self.properties, opener=self.opener)
        again = ai_setup.probe(self.properties, opener=self.opener)
        self.assertFalse(first['generationPerformed'])
        self.assertFalse(first['responsesPermissionVerified'])
        self.assertTrue(again['reused'])
        self.assertEqual(self.opener.open.call_count, 1)
        status = ai_setup.status(self.properties)
        self.assertEqual(status['modelAccess'], 'MODEL_ACCESSIBLE')
        self.assertEqual(status['preparation'], 'PENDING')
        self.assertFalse(status['runtimeReady'])
        self.assertNotIn('synthetic-key', json.dumps(status))

    def test_rotation_and_forced_check_do_not_reuse_old_success(self):
        ai_setup.probe(self.properties, opener=self.opener)
        self.values['apiKey'] = 'synthetic-replacement-key'
        self.llm.write_text(javaproperties.dumps(self.values, timestamp=False))
        self.assertEqual(ai_setup.status(self.properties)['modelAccess'], 'NOT_CHECKED')
        self.assertFalse(ai_setup.probe(self.properties, opener=self.opener)['reused'])
        ai_setup.probe(self.properties, force=True, opener=self.opener)
        self.assertEqual(self.opener.open.call_count, 3)

    def test_java_standard_service_preparation_is_current_only_for_its_process(self):
        profile = {'format': 'payse-ai-performance-v1', 'model': 'gpt-6-luna'}
        # LlmSettings.configurationFingerprint includes the explicit standard service tier.
        llm_hash = hashlib.sha256(b'gpt-6-luna\nnone\ndefault\nsynthetic-key-12345').hexdigest()
        key_hash = 'gamma-local-v1:' + hashlib.sha256(bytes(range(32))).hexdigest()
        material = json.dumps(profile, separators=(',', ':')) + llm_hash + key_hash
        material += 'test:v1fixture:gamma-fresh:holdout:100'
        saved = {'fingerprint': hashlib.sha256(material.encode()).hexdigest(),
                 'profile': profile, 'preparedAt': '2026-11-05T00:00:00Z',
                 'preparation': 'READY', 'preparationCount': 1, 'processId': 71}
        (self.root / 'ai-profile.json').write_text(json.dumps(profile))
        (self.root / 'ai-status.json').write_text(json.dumps(saved))
        self.assertTrue(ai_setup.status(self.properties, process_id=71)['runtimeReady'])
        self.assertFalse(ai_setup.status(self.properties, process_id=72)['runtimeReady'])
        self.values['apiKey'] = 'synthetic-replacement-key'
        self.llm.write_text(javaproperties.dumps(self.values, timestamp=False))
        status = ai_setup.status(self.properties, process_id=71)
        self.assertEqual(status['preparation'], 'PENDING')
        self.assertFalse(status['runtimeReady'])

    def test_missing_required_empty_key_is_rejected_before_access_probe(self):
        self.values.pop('apiKey')
        self.llm.write_text(javaproperties.dumps(self.values, timestamp=False))
        with self.assertRaises(ValueError):
            ai_setup.probe(self.properties, opener=self.opener)
        self.opener.open.assert_not_called()

    def test_failed_probe_is_not_cached_as_connected(self):
        self.opener.open.side_effect = TimeoutError()
        self.assertEqual(ai_setup.probe(self.properties, opener=self.opener)['status'], 'UNAVAILABLE')
        ai_setup.probe(self.properties, opener=self.opener)
        self.assertEqual(self.opener.open.call_count, 2)

    def test_disabled_and_invalid_scope_never_contact_provider(self):
        self.assertEqual(ai_setup.probe({})['status'], 'DISABLED')
        self.properties[ai_setup.PREFIX + 'source-version'] = 'real-data'
        with self.assertRaises(ValueError):
            ai_setup.probe(self.properties, opener=self.opener)
        self.opener.open.assert_not_called()


if __name__ == '__main__':
    unittest.main()
