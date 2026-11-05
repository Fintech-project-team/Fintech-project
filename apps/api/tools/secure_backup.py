"""2026-11-05: Git 밖의 암호화 백업·복구 도구. 서버 시작·중지·DB 복원은 수행하지 않는다."""
import argparse
import getpass
import json
import os
from pathlib import Path
import subprocess
from subprocess import Popen
import sys
import threading

import backup_crypto as crypto
import server_runtime as runtime


def dump_database(executable, properties, destination, key, timeout=300):
    """2026-11-05: 읽기 전용 pg_dump stdout을 직접 암호화하고 실패한 새 암호문만 제거한다."""
    from portable_server import database_target
    target, database, query = database_target(properties['PAYSE_JDBC_URL'])
    executable = Path(executable)
    if not executable.is_absolute() or not executable.is_file():
        raise ValueError('An explicit pg_dump executable is required')
    destination = crypto.private_path(destination)
    environment = {k: v for k, v in os.environ.items() if not k.upper().startswith('PG')}
    environment.update(PGPASSWORD=properties['PAYSE_DB_PASSWORD'], PGCONNECT_TIMEOUT='5',
                       PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=120000')
    for name, values in query.items():
        environment['PG' + name.upper()] = values[0]
    arguments = [str(executable), '--format=custom', '--no-password', '--lock-wait-timeout=5s',
                 '-h', target.hostname, '-p', str(target.port or 5432),
                 '-U', properties['PAYSE_DB_USER'], '-d', database]
    process = Popen(arguments, env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    expired = threading.Event()

    def expire():
        expired.set()
        try:
            process.kill()
        except OSError:
            pass

    deadline = threading.Timer(timeout, expire)
    deadline.daemon = True
    deadline.start()
    encrypted = False
    try:
        with process.stdout:
            expected = crypto.encrypt_stream(process.stdout, destination, key)
        encrypted = True
        code = process.wait(timeout=10)
        if expired.is_set() or code != 0:
            raise RuntimeError('Database backup failed or timed out; database unchanged')
        verified = crypto.decrypt_file(destination, key)
        if verified != expected:
            raise RuntimeError('Backup verification failed')
        return verified
    except BaseException:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=10)
        if encrypted:
            destination.unlink(missing_ok=True)
        raise
    finally:
        deadline.cancel()
        deadline.join()


def write_new(path, body):
    """2026-11-05: 기존 복구 파일을 덮어쓰지 않고 제한된 새 파일만 쓴다."""
    path = crypto.private_path(path)
    descriptor = crypto.create_private_file(path)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(body)
        output.flush()
        os.fsync(output.fileno())


def arguments():
    """2026-11-05: 비밀값 인자는 제공하지 않고 경로·명시 동작만 받는다."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    initialize = commands.add_parser('init-directory')
    initialize.add_argument('--directory', type=Path, required=True)
    for name in ('init-key', 'export-key', 'import-key', 'seal', 'verify', 'restore', 'dump'):
        command = commands.add_parser(name)
        command.add_argument('--key', type=Path, required=True)
        if name in ('init-key', 'import-key'):
            command.add_argument('--protection', choices=('dpapi', 'file'),
                                 default='dpapi' if os.name == 'nt' else None)
        if name in ('import-key', 'seal', 'verify', 'restore'):
            command.add_argument('--input', type=Path, required=True)
        if name in ('export-key', 'seal', 'restore', 'dump'):
            command.add_argument('--output', type=Path, required=True)
        if name == 'dump':
            command.add_argument('--pg-dump', type=Path, required=True)
            command.add_argument('--properties', type=Path, required=True)
    return parser.parse_args()


def main():
    """2026-11-05: 키·암호·DB 원문을 출력하지 않고 인증 완료 여부만 보고한다."""
    args = arguments()
    try:
        if args.command in ('export-key', 'import-key') and not sys.stdin.isatty():
            raise ValueError('Recovery passphrases require an interactive private terminal')
        if args.command == 'init-directory':
            runtime.private_directory(args.directory)
        elif args.command == 'init-key':
            crypto.write_key(args.key, os.urandom(32), args.protection)
        elif args.command == 'import-key':
            path = crypto.private_path(args.input, existing=True)
            if path.stat().st_size > 1024:
                raise ValueError('Invalid recovery envelope')
            password = getpass.getpass('복구 암호 (화면에 표시하지 않음): ')
            key = crypto.import_key(path.read_bytes(), password)
            crypto.write_key(args.key, key, args.protection)
        elif args.command == 'export-key':
            password = getpass.getpass('새 복구 암호 (12자 이상, 별도 보관): ')
            if password != getpass.getpass('복구 암호 다시 입력: '):
                raise ValueError('Recovery passphrases differ')
            key = crypto.read_key(args.key)
            envelope = crypto.export_key(key, password)
            if crypto.import_key(envelope, password) != key:
                raise ValueError('Recovery verification failed')
            write_new(args.output, envelope)
        else:
            key = crypto.read_key(args.key)
            if args.command == 'seal':
                with crypto.private_path(args.input, existing=True).open('rb') as source:
                    expected = crypto.encrypt_stream(source, args.output, key)
                if crypto.decrypt_file(args.output, key) != expected:
                    raise ValueError('Backup verification failed')
            elif args.command in ('verify', 'restore'):
                crypto.decrypt_file(args.input, key, args.output if args.command == 'restore' else None)
            elif args.command == 'dump':
                from release_server import properties
                values = properties(crypto.private_path(args.properties, existing=True))
                dump_database(args.pg_dump, values, args.output, key)
        print(json.dumps({'status': 'VERIFIED', 'operation': args.command}))
        return 0
    except Exception:
        print(json.dumps({'status': 'REJECTED', 'operation': args.command,
                          'reason': 'Check permissions, key, input integrity and required options; originals preserved'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
