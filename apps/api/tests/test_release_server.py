"""2026-11-02: 출처·파일 경계·변조를 실제 묶음과 모의 GitHub 응답으로 검증한다."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
from zipfile import ZipFile, ZipInfo

import javaproperties

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import release_server as release


COMMIT = 'a' * 40
REPOSITORY = 'example/payse'
RUN_ID = 123


def bundle(root, name='bundle', commit=COMMIT):
    """2026-11-02: 실행하지 않는 최소 JAR로 패키지 경계만 검사한다. 사용: 배포 도구 테스트."""
    jar = root / (name + '.jar')
    with ZipFile(jar, 'w') as archive:
        archive.writestr('META-INF/MANIFEST.MF',
                         'Start-Class: com.payse.api.PayseApiApplication\n'
                         'Main-Class: org.springframework.boot.loader.launch.JarLauncher\n'
                         'Build-Jdk-Spec: 21\n')
        archive.writestr('BOOT-INF/classes/com/payse/api/PayseApiApplication.class', b'test-only')
    output = root / name
    metadata = release.build(jar, output, commit, REPOSITORY, 'develop', RUN_ID)
    return output, metadata


def receipt(directory, metadata):
    """2026-11-02: 오프라인 테스트 전용 영수증을 구성한다. 실제 CI 통과 증거로 사용하지 않는다."""
    value = {key: metadata[key] for key in ('commit', 'repository', 'branch', 'runId', 'workflow')}
    value.update(format='payse-ci-receipt-v1', releaseSha256=release.sha256(directory / 'release.json'))
    (directory / 'ci-receipt.json').write_text(json.dumps(value), encoding='utf-8')


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='payse-release-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output, self.metadata = bundle(self.root)

    def test_valid_bundle_contains_no_private_configuration(self):
        self.assertEqual(release.verify(self.output, COMMIT), self.metadata)
        forbidden = {'server.properties', 'deployment.properties', 'client.pem', 'chain.pem', 'runtime.json'}
        self.assertFalse(forbidden & {item.name for item in self.output.iterdir()})
        for name in ('deployment.properties.example', 'portable.properties.example'):
            self.assertTrue(all(value == '' for value in release.properties(self.output / name).values()))

    def test_apply_requires_matching_receipt(self):
        with self.assertRaises(FileNotFoundError):
            release.verify(self.output, COMMIT, require_ci=True)
        receipt(self.output, self.metadata)
        release.verify(self.output, COMMIT, require_ci=True)
        self.metadata['commit'] = 'b' * 40
        (self.output / 'release.json').write_text(json.dumps(self.metadata), encoding='utf-8')
        with self.assertRaises(ValueError):
            release.verify(self.output, require_ci=True)

    def test_dashboard_files_are_packaged_and_integrity_checked(self):
        for name in ('Dashboard.psm1', 'Watch-Payse.ps1'):
            with self.subTest(name=name):
                path = self.output / name
                self.assertEqual(path.read_bytes(), (release.API / 'deploy' / name).read_bytes())
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises(ValueError):
                    release.verify(self.output, COMMIT)
                path.write_bytes(original + b'\n# modified')
                with self.assertRaises(ValueError):
                    release.verify(self.output, COMMIT)
                path.write_bytes(original)

    def test_tampered_jar_rejected(self):
        with (self.output / 'server.jar').open('ab') as stream:
            stream.write(b'changed')
        with self.assertRaises(ValueError):
            release.verify(self.output)

    def test_unexpected_private_file_rejected(self):
        (self.output / 'server.properties').write_text('private=test', encoding='utf-8')
        with self.assertRaises(ValueError):
            release.verify(self.output)

    def test_expected_commit_and_profile_branch_fail_closed(self):
        with self.assertRaises(ValueError):
            release.verify(self.output, 'b' * 40)
        self.metadata['branch'] = 'main'
        (self.output / 'release.json').write_text(json.dumps(self.metadata), encoding='utf-8')
        with self.assertRaises(ValueError):
            release.verify(self.output)

    def test_properties_unicode_escaping_and_duplicates(self):
        target = self.root / 'settings.properties'
        expected = {'deployment.installRoot': 'C:\\서버 폴더\\PAYSE', 'github.token': 'test:with=escape'}
        with target.open('w', encoding='utf-8') as stream:
            javaproperties.dump(expected, stream, timestamp=False)
        self.assertEqual(release.properties(target), expected)
        target.write_text('same=one\nsame=two\n', encoding='utf-8')
        with self.assertRaises(ValueError):
            release.properties(target)

    def test_zip_boundary_rejects_paths_links_duplicates(self):
        for name in ('../escape', 'C:/escape', '/escape', 'nested/file', '..'):
            with self.subTest(name=name):
                data = io.BytesIO()
                with ZipFile(data, 'w') as archive:
                    archive.writestr(name, b'value')
                with self.assertRaises(ValueError):
                    release.extract(data.getvalue(), self.root / 'unsafe')
                self.assertFalse((self.root / 'unsafe').exists())
        for names in (('same', 'same'), ('same', 'SAME')):
            data = io.BytesIO()
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', UserWarning)
                with ZipFile(data, 'w') as archive:
                    for name in names:
                        archive.writestr(name, b'value')
            with self.assertRaises(ValueError):
                release.extract(data.getvalue(), self.root / 'duplicate')
        data = io.BytesIO()
        with ZipFile(data, 'w') as archive:
            link = ZipInfo('link')
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            archive.writestr(link, b'elsewhere')
        with self.assertRaises(ValueError):
            release.extract(data.getvalue(), self.root / 'link')

    def test_failed_foreign_stale_or_pr_run_rejected(self):
        good = {'status': 'completed', 'conclusion': 'success', 'event': 'push',
                'path': release.WORKFLOW, 'head_branch': 'develop',
                'head_repository': {'full_name': REPOSITORY}, 'head_sha': COMMIT}
        release.validate_run(good, REPOSITORY, 'develop', COMMIT)
        changes = ({'conclusion': 'failure'}, {'status': 'in_progress'}, {'event': 'pull_request'},
                   {'path': '.github/workflows/other.yml'}, {'head_branch': 'main'},
                   {'head_repository': {'full_name': 'foreign/repository'}}, {'head_sha': 'b' * 40})
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                release.validate_run(dict(good, **change), REPOSITORY, 'develop', COMMIT)

    def fetch_responses(self):
        data = io.BytesIO()
        with ZipFile(data, 'w') as archive:
            for path in self.output.iterdir():
                archive.writestr(path.name, path.read_bytes())
        archive_bytes = data.getvalue()
        run = {'status': 'completed', 'conclusion': 'success', 'event': 'push',
               'path': release.WORKFLOW, 'head_branch': 'develop',
               'head_repository': {'full_name': REPOSITORY}, 'head_sha': COMMIT}
        artifact = {'name': 'payse-api-' + COMMIT, 'id': 456, 'expired': False,
                    'digest': 'sha256:' + hashlib.sha256(archive_bytes).hexdigest()}
        values = [run, {'object': {'sha': COMMIT}}, {'artifacts': [artifact]}]
        return [subprocess.CompletedProcess([], 0, json.dumps(value).encode(), b'') for value in values] + [
            subprocess.CompletedProcess([], 0, archive_bytes, b'')]

    def test_fetch_verifies_github_digest_and_writes_receipt(self):
        settings = self.root / 'private.properties'
        settings.write_text(f'github.repository={REPOSITORY}\ngithub.branch=develop\ngithub.token=synthetic-token\n',
                            encoding='utf-8')
        with patch.object(release.subprocess, 'run', side_effect=self.fetch_responses()) as run:
            release.fetch(settings, RUN_ID, self.root / 'download')
        release.verify(self.root / 'download', COMMIT, require_ci=True)
        for call in run.call_args_list:
            self.assertNotIn('synthetic-token', str(call.args))
            self.assertEqual(call.kwargs['env']['GH_TOKEN'], 'synthetic-token')
            self.assertEqual(call.args[0][2:4], ['--hostname', 'github.com'])

    def test_fetch_digest_mismatch_does_not_extract(self):
        settings = self.root / 'private.properties'
        settings.write_text(f'github.repository={REPOSITORY}\ngithub.branch=develop\n', encoding='utf-8')
        responses = self.fetch_responses()
        responses[-1].stdout += b'tampered'
        with patch.object(release.subprocess, 'run', side_effect=responses), self.assertRaises(ValueError):
            release.fetch(settings, RUN_ID, self.root / 'download')
        self.assertFalse((self.root / 'download').exists())


if __name__ == '__main__':
    unittest.main()
