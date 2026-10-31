"""2026-10-29: 배포 묶음의 소스 독립성·기존 자료 보존을 검사한다. 사용: unittest."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile


SPEC = importlib.util.spec_from_file_location('payse_package', Path(__file__).parents[1] / 'tools/package_server.py')
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class ServerPackageTests(unittest.TestCase):
    """2026-10-29: DB·네트워크 없이 배포 파일 경계를 검증한다. 사용: unittest."""

    def setUp(self):
        """2026-10-29: 공백이 있는 임시 경로와 실행 JAR 표본을 준비한다. 사용: unittest."""
        self.directory = tempfile.TemporaryDirectory(prefix='payse-package-')
        self.root = Path(self.directory.name).resolve()
        self.jar = self.root / 'input server.jar'
        with ZipFile(self.jar, 'w') as archive:
            archive.writestr('META-INF/MANIFEST.MF',
                'Main-Class: org.springframework.boot.loader.launch.JarLauncher\n'
                'Start-Class: com.payse.api.PayseApiApplication\nBuild-Jdk-Spec: 21\n')
            archive.writestr('BOOT-INF/classes/com/payse/api/PayseApiApplication.class', b'fixture')

    def tearDown(self):
        """2026-10-29: 이 검사에서 생성한 디렉터리만 제거한다. 사용: unittest."""
        if Path(self.directory.name).resolve() != self.root or not self.root.name.startswith('payse-package-'):
            raise AssertionError('Temporary cleanup boundary differs')
        self.directory.cleanup()

    def test_only_reviewed_files_are_packaged(self):
        """2026-10-29: 비밀·DB·로그가 아닌 실행 자료와 정확한 JAR만 복사한다. 사용: unittest.

        2026-10-30: Docker·Caddy 설정·빌드 제외 규칙·HTTPS 안내를 배포 묶음에서 검증한다.
        """
        output = PACKAGE.package(self.jar, self.root / 'moved install')
        self.assertEqual({p.name for p in output.iterdir()},
                         {'server.jar', 'server.properties.example', 'README.md', 'manifest.json',
                          'Dockerfile', '.dockerignore', 'Caddyfile', 'android-https.md'})
        self.assertEqual((output / 'server.jar').read_bytes(), self.jar.read_bytes())
        manifest = json.loads((output / 'manifest.json').read_text())
        self.assertEqual(manifest['javaMajor'], 21)
        self.assertEqual(set(manifest['sha256']), {'server.jar', *PACKAGE.FILES})
        self.assertNotIn(str(self.root), (output / 'manifest.json').read_text())

    def test_existing_directory_is_never_modified(self):
        """2026-10-29: 설치 폴더가 이미 있으면 비밀·현지 설정을 건드리지 않는다. 사용: unittest."""
        output = self.root / 'existing'
        output.mkdir()
        settings = output / 'server.properties'
        settings.write_text('preserve existing config')
        with self.assertRaises(ValueError):
            PACKAGE.package(self.jar, output)
        self.assertEqual(settings.read_text(), 'preserve existing config')
        self.assertEqual(len(list(output.iterdir())), 1)

    def test_non_executable_jar_is_rejected_before_output(self):
        """2026-10-29: 일반 ZIP을 실행 서버로 배포하지 않는다. 사용: unittest."""
        with ZipFile(self.jar, 'w') as archive:
            archive.writestr('META-INF/MANIFEST.MF', 'Main-Class: Other\n')
        output = self.root / 'invalid'
        with self.assertRaises(ValueError):
            PACKAGE.package(self.jar, output)
        self.assertFalse(output.exists())

    def test_missing_template_does_not_create_output(self):
        """2026-10-29: 누락된 설치 자료는 패키지를 만들기 전에 거절한다. 사용: unittest."""
        output = self.root / 'missing'
        with patch.object(PACKAGE, 'API', self.root), self.assertRaises(ValueError):
            PACKAGE.package(self.jar, output)
        self.assertFalse(output.exists())

    def test_damaged_jar_reports_failure_without_traceback(self):
        """2026-10-29: 손상된 파일은 부분 설치나 원문 예외 출력 없이 거절한다. 사용: unittest."""
        self.jar.write_bytes(b'not a jar')
        output = self.root / 'damaged'
        result = subprocess.run([sys.executable, '-B', PACKAGE.__file__, '--jar', str(self.jar),
                                 '--output', str(output)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Package creation failed', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertFalse(output.exists())

    def test_template_requires_secrets_and_uses_external_values(self):
        """2026-10-29: 암호·PC 경로 없이 기존 설정 키로 실행하게 한다. 사용: unittest."""
        template = (PACKAGE.API / 'deploy/server.properties.example').read_text()
        active = [line for line in template.splitlines() if line and not line.startswith('#')]
        self.assertIn('spring.config.import=configtree:./secrets/', active)
        self.assertIn('spring.profiles.active=database,auth,finance,salary-notices', active)
        self.assertFalse(any(line.startswith('PAYSE_DB_PASSWORD=') for line in active))
        self.assertFalse(any('_KEY_BASE64=' in line for line in active))
        self.assertNotIn('C:\\', template)


if __name__ == '__main__':
    unittest.main()
