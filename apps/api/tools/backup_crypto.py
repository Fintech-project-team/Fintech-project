"""2026-11-05: 파일 백업의 인증 암호화와 별도 복구 키. DB/서비스를 변경하지 않는다."""
import ctypes
import csv
from functools import cache
import hashlib
import os
from pathlib import Path
import tempfile
import subprocess

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

import server_runtime as runtime


MAGIC = b'PAYSE-BACKUP\x01'
DPAPI_KEY = b'PAYSE-DPAPI-KEY\x01'
FILE_KEY = b'PAYSE-FILE-KEY\x01'
RECOVERY = b'PAYSE-RECOVERY\x01'
CHUNK = 1024 * 1024
MAX_SIZE = 32 * 1024**3


@cache
def current_sid():
    """2026-11-05: 새 파일 ACL에 사용할 현재 Windows 사용자 SID만 조회한다."""
    result = subprocess.run(['whoami', '/user', '/fo', 'csv', '/nh'], capture_output=True,
                            text=True, check=True, timeout=10, creationflags=subprocess.CREATE_NO_WINDOW)
    return next(csv.reader(result.stdout.strip().splitlines()))[1]


def restrict_file(path):
    """2026-11-05: Windows는 상속 권한을 제거하고 현재 사용자만 허용한 후 내용을 쓴다."""
    if os.name == 'nt':
        result = subprocess.run(['icacls', str(path), '/inheritance:r', '/grant:r', '*' + current_sid() + ':F'],
                                capture_output=True, timeout=10, creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode:
            raise ValueError('Cannot restrict private file permissions')


def create_private_file(path):
    """2026-11-05: 배타적 빈 파일을 만들고 접근 제한 성공 후에만 쓰기 핸들을 반환한다."""
    path = private_path(path)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        restrict_file(path)
        return descriptor
    except BaseException:
        os.close(descriptor)
        path.unlink(missing_ok=True)
        raise


def private_path(path, *, existing=False):
    """2026-11-05: Git·링크 경계를 먼저 확인하고 명시한 일반 파일만 읽는다."""
    path = Path(path)
    if not path.is_absolute():
        raise ValueError('An absolute private path is required')
    path = runtime.outside_git(path)
    if existing and (not path.is_file() or path.stat().st_nlink != 1):
        raise ValueError('A private regular file is required')
    if not existing and (path.exists() or not path.parent.is_dir()):
        raise ValueError('A new file in an existing private directory is required')
    return path


def dpapi(data, *, decrypt=False):
    """2026-11-05: Windows 현재 사용자·컴퓨터에서만 열리는 키를 UI/명령줄 없이 보호한다."""
    if os.name != 'nt':
        raise ValueError('DPAPI requires the original Windows account')
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]

    library = ctypes.WinDLL('crypt32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    operation = library.CryptUnprotectData if decrypt else library.CryptProtectData
    operation.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.POINTER(Blob),
                          ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    operation.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    buffer = ctypes.create_string_buffer(data)
    entropy_buffer = ctypes.create_string_buffer(DPAPI_KEY)
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    entropy = Blob(len(DPAPI_KEY), ctypes.cast(entropy_buffer, ctypes.POINTER(ctypes.c_ubyte)))
    result = Blob()
    try:
        if not operation(ctypes.byref(source), None, ctypes.byref(entropy), None, None, 1,
                         ctypes.byref(result)):
            raise ValueError('Windows key protection failed')
        return ctypes.string_at(result.data, result.size)
    finally:
        ctypes.memset(buffer, 0, len(buffer))
        if result.data:
            ctypes.memset(result.data, 0, result.size)
            kernel.LocalFree(result.data)


def check_key(key):
    """2026-11-05: AES-256 이외의 길이를 묵시적으로 보정하지 않는다."""
    if not isinstance(key, bytes) or len(key) != 32:
        raise ValueError('A 32-byte backup key is required')


def write_key(path, key, protection):
    """2026-11-05: 새 키 파일만 쓴다. Windows의 기본 DPAPI와 명시한 파일 보호를 구별한다."""
    check_key(key)
    path = private_path(path)
    if protection == 'dpapi':
        body = DPAPI_KEY + dpapi(key)
    elif protection == 'file':
        body = FILE_KEY + key
    else:
        raise ValueError('Choose dpapi or an explicitly protected file location')
    descriptor = create_private_file(path)
    with os.fdopen(descriptor, 'wb') as target:
        target.write(body)
        target.flush()
        os.fsync(target.fileno())
    if read_key(path) != key:
        raise ValueError('Key protection round trip failed; preserve existing material')


def read_key(path):
    """2026-11-05: 키를 자동 생성하지 않고 버전·길이·현재 사용자 보호를 확인한다."""
    path = private_path(path, existing=True)
    with path.open('rb') as source:
        body = source.read(8193)
    if len(body) > 8192:
        raise ValueError('Backup key file is too large')
    if body.startswith(DPAPI_KEY):
        key = dpapi(body[len(DPAPI_KEY):], decrypt=True)
    elif body.startswith(FILE_KEY):
        key = body[len(FILE_KEY):]
    else:
        raise ValueError('Unsupported backup key format')
    check_key(key)
    return key


def recovery_key(password, salt):
    """2026-11-05: 복구 암호를 고정 비용 scrypt로 파생하며 파일의 임의 비용값을 받지 않는다."""
    if not isinstance(password, str) or len(password) < 12:
        raise ValueError('Use a recovery passphrase of at least 12 characters')
    return Scrypt(salt=salt, length=32, n=2**15, r=8, p=1).derive(password.encode('utf-8'))


def export_key(key, password):
    """2026-11-05: 다른 PC 복구용으로 같은 키를 인증 암호화하며 원래 키를 회전하지 않는다."""
    check_key(key)
    salt, nonce = os.urandom(16), os.urandom(12)
    header = RECOVERY + salt + nonce
    return header + AESGCM(recovery_key(password, salt)).encrypt(nonce, key, header)


def import_key(body, password):
    """2026-11-05: 복구 암호·인증 태그를 확인한 뒤에만 동일한 백업 키를 반환한다."""
    if len(body) != len(RECOVERY) + 16 + 12 + 48 or not body.startswith(RECOVERY):
        raise ValueError('Invalid recovery envelope')
    salt = body[len(RECOVERY):len(RECOVERY) + 16]
    nonce = body[len(RECOVERY) + 16:len(RECOVERY) + 28]
    header = body[:-48]
    key = AESGCM(recovery_key(password, salt)).decrypt(nonce, body[-48:], header)
    check_key(key)
    return key


def read_encrypted(path, key, limit=32 * 1024**2):
    """2026-11-05: 작은 이행 문서를 디스크 평문 없이 인증 후 메모리에서만 읽는다."""
    check_key(key)
    path = private_path(path, existing=True)
    with path.open('rb') as source:
        body = source.read(limit + len(MAGIC) + 12 + 16 + 1)
    header_length = len(MAGIC) + 12
    if (not body.startswith(MAGIC) or len(body) < header_length + 16
            or len(body) > limit + header_length + 16):
        raise ValueError('Invalid or excessive encrypted document')
    header = body[:header_length]
    return AESGCM(key).decrypt(header[-12:], body[header_length:], header)


def encrypt_stream(source, destination, key):
    """2026-11-05: 입력을 1MiB씩 읽어 평문 임시 파일 없이 AES-GCM 백업을 쓴다."""
    check_key(key)
    destination = private_path(destination)
    nonce = os.urandom(12)
    header = MAGIC + nonce
    encryptor = Cipher(algorithms.AES(key), modes.GCM(nonce)).encryptor()
    encryptor.authenticate_additional_data(header)
    digest, size = hashlib.sha256(), 0
    descriptor = create_private_file(destination)
    try:
        with os.fdopen(descriptor, 'wb') as target:
            target.write(header)
            while block := source.read(CHUNK):
                size += len(block)
                if size > MAX_SIZE:
                    raise ValueError('Backup size limit exceeded')
                digest.update(block)
                target.write(encryptor.update(block))
            target.write(encryptor.finalize())
            target.write(encryptor.tag)
            target.flush()
            os.fsync(target.fileno())
        return {'bytes': size, 'sha256': digest.hexdigest()}
    except BaseException:
        destination.unlink(missing_ok=True)
        raise


def decrypt_file(source, key, destination=None):
    """2026-11-05: 기본은 메모리 검증. 명시 복원도 최종 태그 통과 전에는 목적지를 공개하지 않는다."""
    check_key(key)
    source = private_path(source, existing=True)
    if destination is not None:
        destination = private_path(destination)
    pending, output = None, None
    digest, size = hashlib.sha256(), 0
    try:
        with source.open('rb') as archive:
            length = os.fstat(archive.fileno()).st_size
            payload = length - len(MAGIC) - 12 - 16
            header = archive.read(len(MAGIC) + 12)
            if payload < 0 or payload > MAX_SIZE or not header.startswith(MAGIC):
                raise ValueError('Invalid backup envelope')
            archive.seek(-16, os.SEEK_END)
            tag = archive.read(16)
            archive.seek(len(header))
            decryptor = Cipher(algorithms.AES(key), modes.GCM(header[-12:], tag)).decryptor()
            decryptor.authenticate_additional_data(header)
            if destination is not None:
                descriptor, name = tempfile.mkstemp(prefix='.payse-restore-', dir=destination.parent)
                pending = Path(name)
                output = os.fdopen(descriptor, 'wb')
                restrict_file(pending)
            while payload:
                block = archive.read(min(CHUNK, payload))
                if not block:
                    raise ValueError('Truncated backup')
                payload -= len(block)
                plain = decryptor.update(block)
                digest.update(plain)
                size += len(plain)
                if output is not None:
                    output.write(plain)
            final = decryptor.finalize()
            digest.update(final)
            size += len(final)
            if output is not None:
                output.write(final)
                output.flush()
                os.fsync(output.fileno())
                output.close()
                output = None
                # Link creation is atomic and refuses an existing destination on every supported OS.
                os.link(pending, destination)
        return {'bytes': size, 'sha256': digest.hexdigest()}
    finally:
        if output is not None:
            output.close()
        if pending is not None:
            pending.unlink(missing_ok=True)
