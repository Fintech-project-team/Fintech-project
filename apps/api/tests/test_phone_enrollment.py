"""2026-11-02: 폐기용 CA·폰 키·CSR로 발급 경계를 검사한다. 실제 서버·DB·인증서는 사용하지 않는다."""

import base64
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('phone_issue', Path(__file__).parents[1] / 'tools/issue_phone.py')
PHONE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PHONE)
OPENSSL = os.environ.get('PAYSE_TEST_OPENSSL') or shutil.which('openssl')
if not OPENSSL and Path(r'C:\Program Files\Git\usr\bin\openssl.exe').is_file():
    OPENSSL = r'C:\Program Files\Git\usr\bin\openssl.exe'


@unittest.skipUnless(OPENSSL, 'OpenSSL is required for disposable certificate checks')
class PhoneEnrollmentTests(unittest.TestCase):
    """2026-11-02: 입력·발급·실패 보존을 실제 OpenSSL로 확인한다. 사용: unittest."""

    @classmethod
    def setUpClass(cls):
        """2026-11-02: 이 검사 전용 루트와 CA를 만든다. 사용: unittest 클래스 준비."""
        cls.temporary = tempfile.TemporaryDirectory(prefix='payse-phone-test-')
        cls.root = Path(cls.temporary.name).resolve()
        cls.openssl = Path(OPENSSL)
        cls.ca_cert = cls.root / 'ca.pem'
        cls.ca_key = cls.root / 'ca.key'
        cls.command('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3',
            '-keyout', cls.ca_key, '-out', cls.ca_cert, '-subj', '/CN=Disposable PAYSE Phone CA',
            '-addext', 'basicConstraints=critical,CA:TRUE',
            '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
        cls.ca_before = cls.ca_key.read_bytes()

    @classmethod
    def tearDownClass(cls):
        """2026-11-02: 검사에서 만든 폴더만 정리한다. 사용: unittest 클래스 종료."""
        if cls.root != Path(cls.temporary.name).resolve() or not cls.root.name.startswith('payse-phone-test-'):
            raise AssertionError('Temporary cleanup boundary changed')
        cls.temporary.cleanup()

    @classmethod
    def command(cls, *arguments):
        """2026-11-02: 폐기용 키가 stdout/stderr에 노출되지 않게 명령을 실행한다. 사용: 테스트 준비."""
        result = subprocess.run([str(cls.openssl), *(str(value) for value in arguments)],
            input=b'', capture_output=True, timeout=30, creationflags=PHONE.FLAGS)
        if result.returncode:
            raise AssertionError('Disposable OpenSSL fixture preparation failed')
        return result.stdout

    def setUp(self):
        """2026-11-02: 각 검사 입력·출력을 별도 하위 폴더에 둔다. 사용: unittest."""
        self.directory = self.root / self._testMethodName
        self.directory.mkdir()
        self.output = self.directory / 'issued'

    def tearDown(self):
        """2026-11-02: 모든 경로에서 CA 원본 키가 유지됐는지 확인한다. 사용: unittest."""
        self.assertEqual(self.ca_before, self.ca_key.read_bytes())

    def request(self, key='rsa:2048', *, extensions=()):
        """2026-11-02: 테스트에서만 비반출 폰 키를 대신할 폐기용 키를 만든다. 사용: 각 검사."""
        csr = self.directory / 'phone.csr'
        private = self.directory / 'phone.key'
        arguments = ['req', '-new', '-nodes', '-newkey', key, '-keyout', private,
            '-out', csr, '-subj', '/CN=Disposable Test Phone']
        if key.startswith('ec:'):
            curve = key.split(':', 1)[1]
            arguments = ['req', '-new', '-nodes', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:' + curve,
                '-keyout', private, '-out', csr, '-subj', '/CN=Disposable Test Phone']
        for extension in extensions:
            arguments += ['-addext', extension]
        self.command(*arguments)
        return csr

    def issue(self, csr, **overrides):
        """2026-11-02: 기본 안전 입력에 검사별 경계만 바꿔 발급한다. 사용: 각 검사."""
        options = dict(csr=csr, ca_cert=self.ca_cert, ca_key=self.ca_key,
            openssl=self.openssl, output=self.output, days=1)
        options.update(overrides)
        return PHONE.issue(**options)

    def assert_rejected(self, csr, **overrides):
        """2026-11-02: 실패 시 출력 폴더가 남지 않는지 확인한다. 사용: 입력 거절 검사."""
        with self.assertRaises(PHONE.EnrollmentError):
            self.issue(csr, **overrides)
        self.assertFalse(self.output.exists())

    def test_rsa_issued_without_private_key_or_registration(self):
        """2026-11-02: 실제 RSA CSR의 공개 인증서·지문만 출력한다. 사용: 정상 경로 검사."""
        csr = self.request()
        original_key = (self.directory / 'phone.key').read_bytes()
        metadata = self.issue(csr)
        self.assertEqual({file.name for file in self.output.iterdir()}, set(PHONE.PUBLIC_FILES))
        self.assertFalse(metadata['registered'])
        self.assertEqual(metadata['publicKey'], {'algorithm': 'RSA', 'bits': 2048})
        der = self.command('x509', '-in', self.output / 'client.pem', '-outform', 'DER')
        self.assertEqual(metadata['certificateSha256'], 'sha256:' + hashlib.sha256(der).hexdigest())
        self.assertEqual((self.output / 'chain.pem').read_bytes(), self.ca_cert.read_bytes())
        self.assertEqual(original_key, (self.directory / 'phone.key').read_bytes())
        for path in self.output.iterdir():
            self.assertNotIn(b'PRIVATE KEY', path.read_bytes())
        self.command('verify', '-CAfile', self.ca_cert, '-purpose', 'sslclient', self.output / 'client.pem')
        self.assertLessEqual(datetime.fromisoformat(metadata['notBefore']), datetime.now(timezone.utc))
        self.assertEqual(json.loads((self.output / 'enrollment.json').read_text()), metadata)

    def test_ec_p256_and_p384_supported(self):
        """2026-11-02: 두 허용 EC 곡선을 각각 실제 발급한다. 사용: Android 공개키 호환 검사."""
        for curve, bits in [('prime256v1', 256), ('secp384r1', 384)]:
            with self.subTest(curve=curve):
                csr = self.request('ec:' + curve)
                metadata = self.issue(csr, output=self.directory / curve)
                self.assertEqual(metadata['publicKey']['bits'], bits)

    def test_tampered_csr_signature_is_rejected(self):
        """2026-11-02: ASN.1 형식이 유지된 서명 변조를 거절한다. 사용: CSR 소유 검증."""
        csr = self.request()
        der = bytearray(self.command('req', '-in', csr, '-outform', 'DER'))
        der[-1] ^= 1
        encoded = base64.encodebytes(der)
        csr.write_bytes(b'-----BEGIN CERTIFICATE REQUEST-----\n' + encoded + b'-----END CERTIFICATE REQUEST-----\n')
        self.assert_rejected(csr)

    def test_single_bounded_pem_is_required(self):
        """2026-11-02: 여러 CSR·다른 PEM·과대 입력을 발급 전 거절한다. 사용: 입력 크기 검사."""
        csr = self.request()
        valid = csr.read_bytes()
        for malformed in [valid + valid, valid + b'garbage', self.ca_cert.read_bytes(), b' ' * 65537]:
            with self.subTest(length=len(malformed)):
                csr.write_bytes(malformed)
                self.assert_rejected(csr)

    def test_weak_rsa_and_unapproved_curve_rejected(self):
        """2026-11-02: 약한 RSA와 미지원 EC 곡선을 명시적으로 거절한다. 사용: 키 정책 검사."""
        for key in ['rsa:1024', 'ec:secp521r1']:
            with self.subTest(key=key):
                self.assert_rejected(self.request(key))

    def test_requested_ca_and_server_extensions_are_ignored(self):
        """2026-11-02: CSR의 CA·서버 인증 요구가 클라이언트 권한으로 승격되지 않는다. 사용: 확장 검사."""
        csr = self.request(extensions=('basicConstraints=critical,CA:TRUE',
            'keyUsage=critical,keyCertSign,cRLSign', 'extendedKeyUsage=serverAuth',
            'subjectAltName=DNS:unauthorized.invalid'))
        self.issue(csr)
        text = self.command('x509', '-in', self.output / 'client.pem', '-noout', '-text').decode()
        self.assertIn('CA:FALSE', text)
        self.assertIn('Digital Signature', text)
        self.assertIn('TLS Web Client Authentication', text)
        self.assertNotIn('CA:TRUE', text)
        self.assertNotIn('Certificate Sign', text)
        self.assertNotIn('TLS Web Server Authentication', text)
        self.assertNotIn('unauthorized.invalid', text)

    def test_ca_private_key_mismatch_rejected(self):
        """2026-11-02: 다른 키로 CA를 가장하지 못하게 한다. 사용: 발급자 키 검사."""
        csr = self.request()
        self.assert_rejected(csr, ca_key=self.directory / 'phone.key')

    def test_non_ca_issuer_rejected(self):
        """2026-11-02: 서명 키가 맞아도 CA 용도가 없으면 거절한다. 사용: 발급자 용도 검사."""
        csr = self.request()
        false_ca = self.directory / 'false-ca.pem'
        self.command('req', '-x509', '-new', '-key', self.ca_key, '-out', false_ca, '-days', '3',
            '-subj', '/CN=Disposable Non CA', '-addext', 'basicConstraints=critical,CA:FALSE',
            '-addext', 'keyUsage=critical,digitalSignature')
        self.assert_rejected(csr, ca_cert=false_ca)

    def test_validity_must_fit_ca_and_be_explicit_positive(self):
        """2026-11-02: CA 수명 초과·0·음수·불리언 기간을 거절한다. 사용: 기간 검사."""
        csr = self.request()
        for days in [0, -1, True, 4, 10 ** 20]:
            with self.subTest(days=days):
                self.assert_rejected(csr, days=days)

    def test_expired_ca_rejected(self):
        """2026-11-02: 종료된 CA의 서명 권한을 인정하지 않는다. 사용: 발급자 유효기간 검사."""
        csr = self.request()
        expired = self.directory / 'expired.pem'
        self.command('req', '-new', '-key', self.ca_key, '-out', self.directory / 'issuer.csr',
            '-subj', '/CN=Disposable Expired CA')
        extension = self.directory / 'ca.ext'
        extension.write_text('basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n')
        self.command('x509', '-req', '-in', self.directory / 'issuer.csr', '-signkey', self.ca_key,
            '-days', '-1', '-set_serial', '123', '-extfile', extension, '-out', expired)
        self.assert_rejected(csr, ca_cert=expired)

    def test_existing_output_is_preserved(self):
        """2026-11-02: 빈 폴더를 포함한 기존 출력은 덮어쓰지 않는다. 사용: 재실행 보존 검사."""
        csr = self.request()
        self.output.mkdir()
        sentinel = self.output / 'keep.txt'
        sentinel.write_bytes(b'existing public data')
        with self.assertRaises(PHONE.EnrollmentError):
            self.issue(csr)
        self.assertEqual(sentinel.read_bytes(), b'existing public data')
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_output_failure_rolls_back_owned_public_files(self):
        """2026-11-02: 마지막 파일 생성 실패 시 이 발급 출력만 제거한다. 사용: 출력 롤백 검사."""
        csr = self.request()
        original_open = Path.open

        def failing_open(path, *args, **kwargs):
            """2026-11-02: 발급 메타데이터 쓰기 한 지점만 실패시킨다. 사용: 롤백 검사 주입."""
            if path.name == 'enrollment.json' and path.parent.name.startswith('.payse-issue-'):
                raise OSError('Simulated output failure')
            return original_open(path, *args, **kwargs)

        with patch.object(Path, 'open', failing_open), self.assertRaises(OSError):
            self.issue(csr)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.directory.glob('.payse-issue-*')), [])

    def test_publication_is_complete_and_collision_safe(self):
        """2026-11-02: 완성 직전 대상 생성 경쟁에도 기존 파일을 보존한다. 사용: 원자 게시 검사."""
        csr = self.request()
        original_publish = PHONE.publish_directory

        def collide(prepared, output):
            """2026-11-02: 원자 게시 직전 다른 호출의 출력 생성을 재현한다. 사용: 경쟁 검사 주입."""
            self.assertFalse(output.exists())
            self.assertEqual({path.name for path in prepared.iterdir()}, set(PHONE.PUBLIC_FILES))
            output.mkdir()
            (output / 'keep.txt').write_bytes(b'another invocation')
            original_publish(prepared, output)

        with patch.object(PHONE, 'publish_directory', collide), self.assertRaises(OSError):
            self.issue(csr)
        self.assertEqual((self.output / 'keep.txt').read_bytes(), b'another invocation')
        self.assertEqual(len(list(self.output.iterdir())), 1)
        self.assertEqual(list(self.directory.glob('.payse-issue-*')), [])

    def test_random_positive_serials_and_no_ca_serial_file(self):
        """2026-11-02: 재발급은 무작위 양수 serial을 쓰고 CA 옆 파일을 만들지 않는다. 사용: 발급 충돌 검사."""
        csr = self.request()
        first = self.issue(csr)
        second = self.issue(csr, output=self.directory / 'second')
        self.assertNotEqual(first['serialHex'], second['serialHex'])
        self.assertTrue(0 < int(first['serialHex'], 16) < 2 ** 159)
        self.assertFalse(self.ca_cert.with_suffix('.srl').exists())

    def test_cli_failure_does_not_print_request_or_private_key(self):
        """2026-11-02: CLI 실패 출력에 원문·키·traceback이 없다. 사용: 로그 노출 검사."""
        csr = self.request('rsa:1024')
        result = subprocess.run([sys.executable, '-B', PHONE.__file__, '--csr', str(csr),
            '--ca-cert', str(self.ca_cert), '--ca-key', str(self.ca_key), '--openssl', str(self.openssl),
            '--output', str(self.output), '--days', '1'], capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b'issuance failed', result.stderr)
        self.assertIn(b'RSA keys must contain at least 2048 bits.', result.stderr)
        self.assertNotIn(str(self.directory).encode(), result.stderr)
        self.assertNotIn(b'Traceback', result.stderr)
        self.assertNotIn(b'PRIVATE KEY', result.stderr + result.stdout)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
