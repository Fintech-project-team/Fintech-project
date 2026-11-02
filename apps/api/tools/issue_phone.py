"""2026-11-02: 폰이 만든 CSR을 검증해 공개 인증서 묶음만 발급한다. 사용: 운영자 CLI.

서버 설정·등록 지문·DB는 변경하지 않는다. 개인키는 폰에서 생성하며 이 도구는
CA 개인키를 OpenSSL에 읽기 전용 입력으로 전달한다. 암호화된 CA 키의 암호 입력은
지원하지 않으며 실패 시 키 내용을 출력하지 않는다. --days는 운영자가 명시한다.
CSR 64 KiB, RSA 2048비트 이상, EC P-256/P-384는 이 발급 도구의 입력 보호 기준이다.
"""

from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile


MAX_PEM_BYTES = 64 * 1024
PUBLIC_FILES = ('client.pem', 'chain.pem', 'enrollment.json')
FLAGS = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0


class EnrollmentError(ValueError):
    """2026-11-02: 비밀이나 원문을 포함하지 않는 발급 오류다. 사용: 발급 검증·CLI."""


def run(openssl: Path, args: list[str | Path], *, content: bytes | None = None) -> bytes:
    """2026-11-02: 쉘·대화형 암호 입력·원문 로그 없이 OpenSSL을 실행한다. 사용: 검증·서명."""
    environment = dict(os.environ)
    for name in ('OPENSSL_CONF', 'OPENSSL_MODULES', 'OPENSSL_ENGINES'):
        environment.pop(name, None)
    try:
        result = subprocess.run([str(openssl), *(str(value) for value in args)],
            input=content if content is not None else b'', capture_output=True,
            timeout=30, creationflags=FLAGS, env=environment)
    except (OSError, subprocess.TimeoutExpired):
        raise EnrollmentError('OpenSSL execution failed or timed out.') from None
    if result.returncode:
        raise EnrollmentError('OpenSSL rejected the certificate, key, or request.')
    return result.stdout


def read_pem(path: Path, label: str) -> bytes:
    """2026-11-02: 크기가 제한된 단일 공개 PEM만 읽는다. 사용: CSR·CA 인증서 입력."""
    try:
        with path.open('rb') as source:
            body = source.read(MAX_PEM_BYTES + 1)
    except OSError:
        raise EnrollmentError('A required public input could not be read.') from None
    marker = label.encode('ascii')
    pattern = rb'\s*-----BEGIN ' + marker + rb'-----\r?\n([A-Za-z0-9+/=\r\n]+)-----END ' + marker + rb'-----\s*'
    if len(body) > MAX_PEM_BYTES or re.fullmatch(pattern, body) is None:
        raise EnrollmentError('Exactly one bounded PEM object is required.')
    return body


def public_key(openssl: Path, pem: bytes) -> tuple[bytes, dict]:
    """2026-11-02: 공개키 강도와 허용 곡선을 확인하고 SPKI DER을 얻는다. 사용: CSR·CA 확인."""
    description = run(openssl, ['pkey', '-pubin', '-text', '-noout'], content=pem).decode('ascii')
    size = re.search(r'Public-Key:\s*\((\d+) bit\)', description)
    if size is None:
        raise EnrollmentError('The public key type is unsupported.')
    bits = int(size.group(1))
    if re.search(r'^Modulus:', description, re.MULTILINE):
        if bits < 2048:
            raise EnrollmentError('RSA keys must contain at least 2048 bits.')
        kind = {'algorithm': 'RSA', 'bits': bits}
    else:
        curve = re.search(r'^ASN1 OID:\s*(\S+)\s*$', description, re.MULTILINE)
        curves = {'prime256v1': (256, 'P-256'), 'secp384r1': (384, 'P-384')}
        if curve is None or curve.group(1) not in curves or bits != curves[curve.group(1)][0]:
            raise EnrollmentError('Only RSA or EC P-256/P-384 keys are supported.')
        kind = {'algorithm': 'EC', 'curve': curves[curve.group(1)][1], 'bits': bits}
    der = run(openssl, ['pkey', '-pubin', '-outform', 'DER'], content=pem)
    return der, kind


def cert_dates(openssl: Path, certificate: Path) -> tuple[datetime, datetime]:
    """2026-11-02: 인증서의 UTC 유효기간만 파싱한다. 사용: CA와 발급 결과 검증."""
    text = run(openssl, ['x509', '-in', certificate, '-noout', '-dates', '-dateopt', 'iso_8601']).decode('ascii')
    values = dict(line.split('=', 1) for line in text.splitlines() if '=' in line)
    try:
        start = datetime.strptime(values['notBefore'], '%Y-%m-%d %H:%M:%SZ').replace(tzinfo=timezone.utc)
        end = datetime.strptime(values['notAfter'], '%Y-%m-%d %H:%M:%SZ').replace(tzinfo=timezone.utc)
        return start, end
    except (KeyError, ValueError):
        raise EnrollmentError('Certificate validity dates could not be verified.') from None


def check_ca(openssl: Path, certificate: Path, key: Path, days: int) -> datetime:
    """2026-11-02: CA 용도·유효기간·개인키 일치를 확인한다. 사용: issue의 서명 전 점검."""
    extensions = run(openssl, ['x509', '-in', certificate, '-noout',
        '-ext', 'basicConstraints,keyUsage']).decode('ascii')
    if not re.search(r'\bCA:TRUE\b', extensions) or 'Certificate Sign' not in extensions:
        raise EnrollmentError('The issuer must be a certificate-signing CA.')
    start, end = cert_dates(openssl, certificate)
    now = datetime.now(timezone.utc)
    try:
        requested_end = now + timedelta(days=days)
    except OverflowError:
        raise EnrollmentError('The requested validity exceeds the CA lifetime.') from None
    if not start <= now < end or requested_end > end:
        raise EnrollmentError('The requested validity exceeds the active CA lifetime.')
    cert_public = run(openssl, ['x509', '-in', certificate, '-pubkey', '-noout'])
    expected, _ = public_key(openssl, cert_public)
    actual = run(openssl, ['pkey', '-in', key, '-passin', 'pass:', '-pubout', '-outform', 'DER'])
    if actual != expected:
        raise EnrollmentError('The CA certificate and private key do not match.')
    run(openssl, ['verify', '-CAfile', certificate, '-no-CApath', '-no-CAstore',
        '-partial_chain', '-check_ss_sig', certificate])
    return end


def fingerprint(body: bytes) -> str:
    """2026-11-02: 공개 자료 지문을 표준 SHA-256 형식으로 만든다. 사용: 발급 메타데이터."""
    return 'sha256:' + hashlib.sha256(body).hexdigest()


def publish_directory(prepared: Path, output: Path) -> None:
    """2026-11-02: 완성 폴더를 기존 대상 대체 없이 원자 게시한다. 사용: publish."""
    if os.name == 'nt':
        # Windows rename rejects an existing destination atomically, including an empty directory.
        os.rename(prepared, output)
        return
    if sys.platform.startswith('linux'):
        native = ctypes.CDLL(None, use_errno=True)
        rename = getattr(native, 'renameat2', None)
        if rename is None:
            raise EnrollmentError('Atomic no-replace directory publication is unavailable.')
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(-100, os.fsencode(prepared), -100, os.fsencode(output), 1) != 0:
            raise OSError(ctypes.get_errno(), 'Atomic certificate publication failed')
        return
    raise EnrollmentError('This platform requires a verified atomic no-replace publication adapter.')


def publish(output: Path, files: dict[str, bytes]) -> None:
    """2026-11-02: 동일 볼륨에서 완성한 공개 묶음만 게시하고 실패 시 준비 파일을 롤백한다. 사용: issue."""
    try:
        prepared = Path(tempfile.mkdtemp(prefix='.payse-issue-', dir=output.parent)).resolve()
    except OSError:
        raise EnrollmentError('The output parent must exist and be writable.') from None
    created = []
    try:
        for name, body in files.items():
            target = prepared / name
            with target.open('xb') as stream:
                created.append(target)
                stream.write(body)
                stream.flush()
                os.fsync(stream.fileno())
        publish_directory(prepared, output)
    finally:
        if prepared.exists():
            if prepared.parent != output.parent.resolve() or not prepared.name.startswith('.payse-issue-'):
                raise EnrollmentError('Temporary public output cleanup boundary changed.')
            # Remove only this invocation's files; an existing output or unrelated child is never removed.
            for target in reversed(created):
                target.unlink(missing_ok=True)
            prepared.rmdir()


def issue(*, csr: Path, ca_cert: Path, ca_key: Path, openssl: Path,
          output: Path, days: int) -> dict:
    """2026-11-02: CSR 검증·서명·결과 검증 후 공개 파일만 출력한다. 사용: CLI·격리 테스트."""
    if isinstance(days, bool) or not isinstance(days, int) or days <= 0:
        raise EnrollmentError('A positive explicit validity in days is required.')
    try:
        openssl = openssl.resolve(strict=True)
        ca_key = ca_key.resolve(strict=True)
        output = output.absolute()
    except OSError:
        raise EnrollmentError('OpenSSL or the issuer key path is unavailable.') from None
    if not openssl.is_file() or not ca_key.is_file() or output.exists() or output.is_symlink():
        raise EnrollmentError('Executable/key must be files and the output must be new.')
    csr_pem = read_pem(csr, 'CERTIFICATE REQUEST')
    ca_pem = read_pem(ca_cert, 'CERTIFICATE')
    with tempfile.TemporaryDirectory(prefix='payse-phone-public-') as temporary:
        work = Path(temporary)
        request = work / 'request.pem'
        issuer = work / 'ca.pem'
        certificate = work / 'client.pem'
        request.write_bytes(csr_pem)
        issuer.write_bytes(ca_pem)
        run(openssl, ['req', '-in', request, '-verify', '-noout'])
        key_pem = run(openssl, ['req', '-in', request, '-pubkey', '-noout'])
        spki, key_info = public_key(openssl, key_pem)
        ca_end = check_ca(openssl, issuer, ca_key, days)
        extensions = work / 'client.ext'
        extensions.write_text('basicConstraints=critical,CA:FALSE\n'
            'keyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n', encoding='ascii')
        serial = secrets.randbits(159) or 1
        run(openssl, ['x509', '-req', '-in', request, '-CA', issuer, '-CAkey', ca_key,
            '-passin', 'pass:', '-set_serial', hex(serial), '-days', str(days), '-sha256',
            '-copy_extensions', 'none', '-extfile', extensions, '-out', certificate])
        run(openssl, ['verify', '-CAfile', issuer, '-no-CApath', '-no-CAstore',
            '-partial_chain', '-purpose', 'sslclient', certificate])
        actual_spki, _ = public_key(openssl,
            run(openssl, ['x509', '-in', certificate, '-pubkey', '-noout']))
        start, end = cert_dates(openssl, certificate)
        if actual_spki != spki or end > ca_end or end <= start:
            raise EnrollmentError('The issued certificate failed public-key or validity verification.')
        cert_der = run(openssl, ['x509', '-in', certificate, '-outform', 'DER'])
        csr_der = run(openssl, ['req', '-in', request, '-outform', 'DER'])
        ca_der = run(openssl, ['x509', '-in', issuer, '-outform', 'DER'])
        metadata = {'formatVersion': 1, 'registered': False,
            'certificateSha256': fingerprint(cert_der), 'csrSha256': fingerprint(csr_der),
            'spkiSha256': fingerprint(spki), 'issuerSha256': fingerprint(ca_der),
            'serialHex': format(serial, 'x'), 'notBefore': start.isoformat(),
            'notAfter': end.isoformat(), 'requestedDays': days, 'publicKey': key_info,
            'files': {'certificate': 'client.pem', 'issuerChain': 'chain.pem'}}
        publish(output, {'client.pem': certificate.read_bytes(), 'chain.pem': ca_pem,
            'enrollment.json': (json.dumps(metadata, ensure_ascii=False, indent=2) + '\n').encode('utf-8')})
        return metadata


def main() -> int:
    """2026-11-02: 필수 경로·기간을 받아 민감 원문 없는 결과만 표시한다. 사용: CLI 진입점."""
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('csr', 'ca-cert', 'ca-key', 'openssl', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--days', type=int, required=True)
    options = parser.parse_args()
    try:
        metadata = issue(**vars(options))
    except EnrollmentError as failure:
        # Only EnrollmentError contains reviewed fixed messages, never OpenSSL or filesystem output.
        print('Phone certificate issuance failed: ' + str(failure), file=sys.stderr)
        print('Existing keys and server settings were not changed.', file=sys.stderr)
        return 1
    except (OSError, ValueError):
        print('Phone certificate issuance failed. Existing keys and server settings were not changed.', file=sys.stderr)
        return 1
    print(json.dumps({'status': 'ISSUED_NOT_REGISTERED',
        'certificateSha256': metadata['certificateSha256'], 'notAfter': metadata['notAfter']}, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
