"""2026-11-02: 실제 작은 자식 프로세스와 OS 잠금으로 설치 간 간섭·오종료를 검증한다."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import server_runtime as runtime


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='payse-runtime-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def test_lock_rejects_competing_operation_and_releases(self):
        with runtime.lock(self.root):
            with self.assertRaises(RuntimeError):
                with runtime.lock(self.root):
                    self.fail('A competing operation acquired the lock')
        with runtime.lock(self.root):
            pass

    def test_git_home_and_root_refused(self):
        (self.root / '.git').write_text('gitdir: test', encoding='utf-8')
        for path in (self.root / 'private', Path.home(), Path(self.root.anchor)):
            with self.subTest(path=path), self.assertRaises(ValueError):
                runtime.outside_git(path)

    def test_port_collision(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            port = listener.getsockname()[1]
            self.assertFalse(runtime.port_free(port))
        self.assertTrue(runtime.port_free(port))

    def test_pid_identity_mismatch_refuses_without_signal(self):
        record = runtime.identity(os.getpid())
        self.assertIsNotNone(runtime.owned_process(record))
        for key, value in (('created', record['created'] - 1), ('exe', 'other.exe'), ('argv', ['different'])):
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                runtime.stop(dict(record, **{key: value}), self.root, timeout=1)
        self.assertIsNotNone(runtime.owned_process(record))

    def test_launch_records_settled_executable_identity(self):
        first = {'pid': 99999, 'created': 1, 'exe': 'launcher', 'argv': ['launcher']}
        final = dict(first, exe='runtime', argv=['runtime', 'server'])
        child = Mock(pid=99999)
        child.poll.return_value = None
        with patch.object(runtime.subprocess, 'Popen', return_value=child), \
                patch.object(runtime, 'identity', side_effect=[first, final, final, final, final, final]), \
                (self.root / 'mock.log').open('wb') as log:
            self.assertEqual(runtime.launch(['runtime', 'server'], self.root, log), final)
        runtime._children.pop(99999)

    def test_denied_detach_does_not_silently_change_launch_mode(self):
        with patch.object(runtime.subprocess, 'Popen', side_effect=PermissionError('denied')) as launch, \
                (self.root / 'mock.log').open('wb') as log:
            with self.assertRaises(PermissionError):
                runtime.launch(['runtime'], self.root, log)
        launch.assert_called_once()

    def test_detached_child_listener_and_graceful_stop(self):
        child = self.root / 'child.py'
        child.write_text(
            "import json,os,signal,socket,time\n"
            "from pathlib import Path\n"
            "listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen()\n"
            "Path('ready.json').write_text(json.dumps({'port':listener.getsockname()[1],"
            "'inherited':os.environ.get('PAYSE_RUNTIME_TEST')}))\n"
            "def finish(*args):\n"
            "    Path('stopped').write_text('graceful')\n"
            "    raise SystemExit(0)\n"
            "signal.signal(signal.SIGINT,finish)\n"
            "signal.signal(signal.SIGTERM,finish)\n"
            "while True: time.sleep(0.05)\n", encoding='utf-8')
        prior = os.environ.get('PAYSE_RUNTIME_TEST')
        os.environ['PAYSE_RUNTIME_TEST'] = 'must-not-inherit'
        try:
            with (self.root / 'child.log').open('wb') as log:
                argv = [sys._base_executable, '-u', str(child)]
                try:
                    record = runtime.launch(argv, self.root, log)
                except PermissionError as failure:
                    if os.name != 'nt' or not os.environ.get('GITHUB_ACTIONS') or failure.winerror != 5:
                        raise
                    create = subprocess.Popen
                    def runner_child(arguments, **options):
                        """2026-11-02: CI가 금지한 job 이탈만 시험 fixture에서 제거한다. 제품은 여전히 거절한다."""
                        self.assertTrue(options['creationflags'] & subprocess.CREATE_BREAKAWAY_FROM_JOB)
                        options['creationflags'] &= ~subprocess.CREATE_BREAKAWAY_FROM_JOB
                        return create(arguments, **options)
                    with patch.object(runtime.subprocess, 'Popen', side_effect=runner_child):
                        record = runtime.launch(argv, self.root, log)
                    print('Runner denies Windows job breakaway; console lifecycle tested within its job.')
        finally:
            if prior is None:
                os.environ.pop('PAYSE_RUNTIME_TEST', None)
            else:
                os.environ['PAYSE_RUNTIME_TEST'] = prior
        try:
            deadline = time.monotonic() + 10
            while not (self.root / 'ready.json').exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            ready = json.loads((self.root / 'ready.json').read_text())
            self.assertIsNone(ready['inherited'])
            self.assertTrue(runtime.owns_listener(record, ready['port']))
            runtime.stop(record, self.root, timeout=10)
            self.assertEqual((self.root / 'stopped').read_text(), 'graceful')
            self.assertIsNone(runtime.owned_process(record))
            self.assertTrue(runtime.port_free(ready['port']))
        finally:
            runtime.stop(record, self.root, timeout=10)


if __name__ == '__main__':
    unittest.main()
