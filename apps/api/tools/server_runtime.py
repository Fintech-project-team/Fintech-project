"""2026-11-02: 설치별 잠금·프로세스 정체성·메모리·정상 종료를 OS에 맞게 제공한다. 사용: portable_server."""
from contextlib import contextmanager
import ctypes
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid

import psutil


_children = {}


def outside_git(path):
    """2026-11-02: 실제 설정·키가 저장소나 링크를 통해 다른 위치에 저장되지 않게 한다. 사용: 설치·설정."""
    path = Path(os.path.abspath(path))
    for parent in (path, *path.parents):
        linked = parent.is_symlink()
        if os.name == 'nt' and parent.exists():
            linked = linked or bool(parent.lstat().st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT)
        if linked or (parent / '.git').exists():
            raise ValueError('Private installation/configuration must be outside Git and symbolic links')
    if path == Path(path.anchor) or path == Path.home():
        raise ValueError('Use a dedicated installation directory')
    return path


def private_directory(path):
    """2026-11-02: 새 전용 폴더를 현재 사용자만 읽도록 보호한 후 비밀 파일을 쓰게 한다. 사용: 설치·configure."""
    path = outside_git(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=False)
    if os.name == 'nt':
        import csv
        identity = subprocess.run(['whoami', '/user', '/fo', 'csv', '/nh'],
                                  capture_output=True, text=True, check=True, timeout=10,
                                  creationflags=subprocess.CREATE_NO_WINDOW)
        sid = next(csv.reader(identity.stdout.strip().splitlines()))[1]
        secured = subprocess.run(['icacls', str(path), '/inheritance:r', '/grant:r', f'*{sid}:(OI)(CI)F'],
                                 capture_output=True, timeout=10, creationflags=subprocess.CREATE_NO_WINDOW)
        if secured.returncode:
            raise RuntimeError('Cannot restrict installation permissions; no credentials were written')
    return path


def write_json(path, value):
    """2026-11-02: 같은 디렉터리의 임시 파일로 기록 후 원자 교체한다. 사용: 런타임·배포 상태."""
    path = Path(path)
    pending = path.with_name(path.name + '.' + uuid.uuid4().hex + '.next')
    descriptor = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(pending, path)


@contextmanager
def lock(home):
    """2026-11-02: 설치별 단일 작업만 허용하며 프로세스 종료 시 OS가 잠금을 회수한다. 사용: start·stop·deploy."""
    with (Path(home) / '.control.lock').open('a+b') as stream:
        stream.seek(0, os.SEEK_END)
        if stream.tell() == 0:
            stream.write(b'0')
            stream.flush()
        stream.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise RuntimeError('Another server operation holds the installation lock') from error
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == 'nt':
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def memory():
    """2026-11-02: 물리 여유와 Windows commit 여유를 GiB로 반환한다. 사용: doctor·시작 전 점검."""
    available = psutil.virtual_memory().available / 1024**3
    commit = available
    if os.name == 'nt':
        class MemoryStatus(ctypes.Structure):
            """2026-11-02: Windows 메모리 상태 구조체. 사용: memory."""
            _fields_ = [('length', ctypes.c_ulong), ('load', ctypes.c_ulong)] + [
                (name, ctypes.c_ulonglong) for name in ('total', 'available', 'pageTotal', 'pageAvailable',
                                                       'virtualTotal', 'virtualAvailable', 'extended')]
        status = MemoryStatus()
        status.length = ctypes.sizeof(status)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
            raise RuntimeError('Cannot inspect Windows commit headroom')
        commit = status.pageAvailable / 1024**3
    return {'physicalFreeGiB': round(available, 2), 'commitFreeGiB': round(commit, 2)}


def addresses():
    """2026-11-02: 로컬 인터페이스 주소 후보만 반환하며 외부 IP 서비스나 방화벽을 건드리지 않는다. 사용: doctor."""
    return sorted({entry.address for entries in psutil.net_if_addrs().values() for entry in entries
                   if entry.family == socket.AF_INET and not entry.address.startswith(('127.', '169.254.'))})


def identity(pid):
    """2026-11-02: PID 재사용을 구분할 생성 시각·실행 파일·인자를 함께 기록한다. 사용: start."""
    process = psutil.Process(pid)
    return {'pid': pid, 'created': process.create_time(), 'exe': process.exe(), 'argv': process.cmdline()}


def owned_process(record):
    """2026-11-02: 사라진 프로세스와 다른 프로세스로 바뀐 PID를 구분한다. 사용: status·종료·준비 검사."""
    if not record:
        return None
    try:
        process = psutil.Process(int(record['pid']))
        if not process.is_running() or process.status() == psutil.STATUS_ZOMBIE:
            return None
        same = (abs(process.create_time() - record['created']) < 0.001
                and os.path.normcase(process.exe()) == os.path.normcase(record['exe'])
                and process.cmdline() == record['argv'])
        if not same:
            raise RuntimeError('Recorded PID belongs to a different process; nothing was signalled')
        return process
    except psutil.NoSuchProcess:
        return None


def port_free(port):
    """2026-11-02: loopback 포트를 점유하지 않고 사용 가능 여부를 검사한다. 사용: 기동 전 점검."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        if os.name == 'nt':
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        try:
            listener.bind(('127.0.0.1', int(port)))
        except OSError:
            return False
    return True


def owns_listener(record, port):
    """2026-11-02: 다른 프로세스의 정상 응답을 새 API 기동 성공으로 오인하지 않는다. 사용: 준비 확인."""
    process = owned_process(record)
    return bool(process and any(connection.status == psutil.CONN_LISTEN
                                and connection.laddr.ip == '127.0.0.1'
                                and connection.laddr.port == int(port)
                                for connection in process.net_connections(kind='tcp')))


def launch(argv, home, log):
    """2026-11-02: 숨긴 독립 프로세스로 Java를 시작하며 inherited 설정 덮어쓰기를 제거한다. 사용: start."""
    environment = {key: value for key, value in os.environ.items()
                   if not key.upper().startswith(('PAYSE_', 'SPRING_'))
                   and key.upper() not in ('JAVA_TOOL_OPTIONS', 'JDK_JAVA_OPTIONS', '_JAVA_OPTIONS', 'LC_ALL')}
    options = {'cwd': home, 'env': environment, 'stdin': subprocess.DEVNULL,
               'stdout': log, 'stderr': subprocess.STDOUT, 'close_fds': True}
    if os.name == 'nt':
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        options.update(startupinfo=startup,
                       creationflags=subprocess.CREATE_NEW_CONSOLE | subprocess.CREATE_BREAKAWAY_FROM_JOB)
    else:
        options['start_new_session'] = True
    child = subprocess.Popen(argv, **options)
    _children[child.pid] = child
    record = identity(child.pid)
    stable_since = time.monotonic()
    deadline = stable_since + 5
    while time.monotonic() < deadline:
        time.sleep(0.05)
        current = identity(child.pid)
        if current['created'] != record['created'] or child.poll() is not None:
            raise RuntimeError('Launched process exited or its PID changed before identity recording')
        if current != record:
            record, stable_since = current, time.monotonic()
        elif time.monotonic() - stable_since >= 0.15:
            return record
    raise RuntimeError('Launched process identity did not settle')


def signal_windows(record):
    """2026-11-02: 별도 helper에서 대상 혼자 사용하는 콘솔인지 재확인한 후 Ctrl+C를 보낸다. 사용: stop."""
    process = owned_process(record)
    if process is None:
        return
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.FreeConsole()
    if not kernel.AttachConsole(int(record['pid'])):
        raise RuntimeError('Cannot attach to the owned Java console; no force-kill attempted')
    try:
        members = (ctypes.c_ulong * 64)()
        count = kernel.GetConsoleProcessList(members, 64)
        if count == 0 or count > 64 or set(members[:count]) != {os.getpid(), int(record['pid'])}:
            raise RuntimeError('Shared console refused; no signal sent')
        if owned_process(record) is None:
            return
        if not kernel.SetConsoleCtrlHandler(None, True) or not kernel.GenerateConsoleCtrlEvent(0, 0):
            raise RuntimeError('Normal Java stop signal failed')
        time.sleep(0.1)
    finally:
        kernel.FreeConsole()


def stop(record, home, timeout=60):
    """2026-11-02: Windows는 전용 콘솔 Ctrl+C, POSIX는 SIGTERM으로 정상 종료한다. 강제 종료하지 않는다. 사용: CLI·CD."""
    process = owned_process(record)
    if process is None:
        return
    if os.name == 'nt':
        request = Path(home) / ('.stop-' + uuid.uuid4().hex + '.json')
        write_json(request, record)
        try:
            result = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--signal', str(request)],
                                    capture_output=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
            if result.returncode:
                raise RuntimeError('Normal shutdown helper refused; no force-kill attempted')
        finally:
            request.unlink(missing_ok=True)
    else:
        process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=timeout)
        child = _children.pop(process.pid, None)
        if child is not None:
            child.wait(timeout=1)
    except psutil.TimeoutExpired as error:
        raise RuntimeError('Normal shutdown timed out; process and data preserved') from error


if __name__ == '__main__':
    try:
        if os.name != 'nt' or len(sys.argv) != 3 or sys.argv[1] != '--signal':
            raise ValueError('Internal Windows shutdown helper only')
        signal_windows(json.loads(Path(sys.argv[2]).read_text(encoding='utf-8')))
    except Exception:
        sys.exit(1)
