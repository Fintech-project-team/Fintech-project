"""2026-11-05: EFS 실제 복구 자료를 암호화하고 로컬 복구 암호를 준비한다. 서비스 변경 없음."""
import argparse
import getpass
import io
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys

import backup_crypto as crypto
from secure_backup import write_new


def efs(action, packet):
    """2026-11-05: 비밀 PFX/암호를 인자·환경·임시 파일 대신 자식 표준 파이프로만 전달한다."""
    if os.name != 'nt':
        raise ValueError('EFS recovery requires Windows')
    executable = shutil.which('pwsh') or str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe')
    result = subprocess.run([str(executable), '-NoProfile', '-NonInteractive', '-File',
                             str(Path(__file__).with_name('efs_recovery.ps1')), '-Action', action],
                            input=json.dumps(packet).encode('utf-8'), capture_output=True,
                            timeout=60, creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode:
        raise ValueError('EFS recovery failed; inspect permissions without sharing secrets')
    return json.loads(result.stdout)


def prepare(key_path, output):
    """2026-11-05: 기존 분석 키는 유지하고 EFS PFX·내부 암호를 함께 암호화한 복구 묶음을 만든다."""
    crypto.private_path(output)
    key = crypto.read_key(key_path)
    password = secrets.token_urlsafe(48)
    result = efs('export', {'password': password})
    packet = {'format': 'PAYSE-EFS-RECOVERY-1', 'password': password, 'certificates': result['certificates']}
    if result['verifiedCount'] != len(packet['certificates']):
        raise ValueError('EFS recovery verification incomplete')
    body = json.dumps(packet).encode('utf-8')
    crypto.encrypt_stream(io.BytesIO(body), output, key)
    return verify(key_path, output)


def verify(key_path, archive, *, install=False):
    """2026-11-05: 원래 인증서 저장소를 사용하지 않는 메모리 가져오기로 복구 개인키를 검증한다."""
    packet = json.loads(crypto.read_encrypted(archive, crypto.read_key(key_path), limit=1024**2))
    if packet.get('format') != 'PAYSE-EFS-RECOVERY-1':
        raise ValueError('Unsupported EFS recovery bundle')
    result = efs('import' if install else 'verify', packet)
    if result['verifiedCount'] != len(packet['certificates']):
        raise ValueError('EFS recovery verification incomplete')
    return {'verifiedCertificates': result['verifiedCount'], 'installed': install,
            'offlineCopyVerified': False, 'serverFilesChanged': False}


def portable_key(key_path, archive, output):
    """2026-11-05: 사용자 로컬 입력으로 실제 백업 키를 내보내고 그 키로 EFS 복구 묶음까지 확인한다."""
    if not sys.stdin.isatty():
        raise ValueError('Use a private interactive terminal')
    crypto.private_path(output)
    password = getpass.getpass('새 복구 암호 (12자 이상, 암호 관리자에 별도 보관): ')
    if password != getpass.getpass('복구 암호 다시 입력: '):
        raise ValueError('Passphrases differ')
    key = crypto.read_key(key_path)
    envelope = crypto.export_key(key, password)
    recovered = crypto.import_key(envelope, password)
    packet = json.loads(crypto.read_encrypted(archive, recovered, limit=1024**2))
    if packet.get('format') != 'PAYSE-EFS-RECOVERY-1':
        raise ValueError('Unsupported EFS recovery bundle')
    result = efs('verify', packet)
    if result['verifiedCount'] != len(packet['certificates']):
        raise ValueError('EFS recovery verification incomplete')
    write_new(output, envelope)
    return {'portableKeyVerified': True, 'verifiedCertificates': result['verifiedCount'],
            'offlineCopyVerified': False}


def main():
    """2026-11-05: 사람은 로컬에서 암호만 입력하며 응답은 건수·상태만 표시한다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare-efs', 'verify-efs', 'import-efs', 'export-key'))
    parser.add_argument('--key', required=True, type=Path)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'prepare-efs':
            result = prepare(args.key, args.archive)
        elif args.action == 'export-key':
            if args.output is None:
                raise ValueError('A new recovery key envelope is required')
            result = portable_key(args.key, args.archive, args.output)
        else:
            result = verify(args.key, args.archive, install=args.action == 'import-efs')
        print(json.dumps({'status': 'VERIFIED', **result}))
        return 0
    except Exception:
        print(json.dumps({'status': 'REJECTED', 'reason': 'Recovery setup failed; existing server files preserved'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
