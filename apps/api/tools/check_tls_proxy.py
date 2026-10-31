"""2026-10-30: 폐기용 인증서와 loopback에서 Caddy의 기기 인증·IP 재작성을 검사한다. 실제 폰 키를 만들지 않는다."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.request import HTTPSHandler, ProxyHandler, Request, build_opener


FLAGS = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0


def command(args, directory, environment=None):
    """2026-10-30: 테스트 도구 출력·키를 로그로 내보내지 않고 성공만 확인한다. 사용: 인증서·프록시 준비."""
    result = subprocess.run([str(value) for value in args], cwd=directory, env=environment,
        capture_output=True, timeout=30, creationflags=FLAGS)
    if result.returncode:
        raise RuntimeError(Path(args[0]).name + ' failed during local proxy verification')
    return result.stdout


def issue(openssl, root, name, *, server=False):
    """2026-10-30: 전용 임시 CA 아래 서버·클라이언트 시험 인증서를 발급한다. 사용: run_check."""
    command([openssl, 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', name + '.key',
        '-out', name + '.csr', '-subj', '/CN=' + name], root)
    usage = 'serverAuth' if server else 'clientAuth'
    extensions = 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=' + usage + '\n'
    if server:
        extensions += 'subjectAltName=DNS:localhost\n'
    (root / (name + '.ext')).write_text(extensions, encoding='ascii')
    command([openssl, 'x509', '-req', '-in', name + '.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key',
        '-CAcreateserial', '-days', '1', '-sha256', '-extfile', name + '.ext', '-out', name + '.pem'], root)


class Upstream(BaseHTTPRequestHandler):
    """2026-10-30: 프록시에서 실제 전달된 주소와 요청 수만 확인한다. 사용: 로컬 검증 서버."""
    requests = 0

    def do_GET(self):
        """2026-10-30: 민감 자료 없는 검증 응답을 반환한다. 사용: HTTPServer."""
        type(self).requests += 1
        payload = json.dumps({'peer': self.headers.get('X-Payse-Client-IP'),
                              'forwarded': self.headers.get('Forwarded')}).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        """2026-10-30: 요청·인증 정보가 테스트 로그에 남지 않게 한다. 사용: HTTPServer."""
        return


def fetch(port, root, identity=None):
    """2026-10-30: 서버 인증서 검증을 유지하며 지정한 시험 클라이언트만 제시한다. 사용: run_check."""
    context = ssl.create_default_context(cafile=str(root / 'ca.pem'))
    if identity:
        context.load_cert_chain(str(root / (identity + '.pem')), str(root / (identity + '.key')))
    opener = build_opener(ProxyHandler({}), HTTPSHandler(context=context))
    request = Request(f'https://localhost:{port}/check', headers={
        'X-Payse-Client-IP': '198.51.100.9', 'Forwarded': 'for=198.51.100.9',
        'X-Forwarded-For': '198.51.100.9'})
    try:
        with opener.open(request, timeout=3) as response:
            return response.status, json.load(response)
    except HTTPError as error:
        return error.code, None


def run_check(caddy, openssl):
    """2026-10-30: 실제 TLS에서 인증서 없음·미등록·허용 및 전달 헤더 위조를 검사한다. 사용: CLI."""
    template = Path(__file__).resolve().parents[1] / 'deploy/Caddyfile'
    with tempfile.TemporaryDirectory(prefix='payse-mtls-') as temporary:
        root = Path(temporary).resolve()
        if os.name == 'nt':
            import csv
            sid = next(csv.reader(command(['whoami', '/user', '/fo', 'csv', '/nh'], root).decode().splitlines()))[1]
            command(['icacls', root, '/inheritance:r', '/grant:r', f'*{sid}:(OI)(CI)F'], root)
        command([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key',
            '-out', 'ca.pem', '-days', '1', '-subj', '/CN=PAYSE Local Verification CA'], root)
        issue(openssl, root, 'server', server=True)
        issue(openssl, root, 'allowed')
        issue(openssl, root, 'unregistered')
        der = command([openssl, 'x509', '-in', 'allowed.pem', '-outform', 'DER'], root)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        upstream = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        Upstream.requests = 0
        thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        thread.start()
        environment = {key: value for key, value in os.environ.items() if not key.startswith('PAYSE_')}
        environment.update(PAYSE_PUBLIC_HOST='localhost', PAYSE_TLS_PORT=str(port),
            PAYSE_PROXY_BIND='127.0.0.1', PAYSE_TLS_CERT=str(root / 'server.pem'),
            PAYSE_TLS_KEY=str(root / 'server.key'), PAYSE_CLIENT_CA=str(root / 'ca.pem'),
            PAYSE_CLIENT_SHA256=hashlib.sha256(der).hexdigest(),
            PAYSE_API_UPSTREAM=f'127.0.0.1:{upstream.server_port}')
        process = None
        try:
            command([caddy, 'validate', '--config', template, '--adapter', 'caddyfile'], root, environment)
            with (root / 'proxy.log').open('wb') as log:
                process = subprocess.Popen([str(caddy), 'run', '--config', str(template), '--adapter', 'caddyfile'],
                    cwd=root, env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log, creationflags=FLAGS)
                deadline = time.monotonic() + 10
                while True:
                    try:
                        status, response = fetch(port, root, 'allowed')
                        break
                    except (URLError, OSError) as failure:
                        if process.poll() is not None or time.monotonic() >= deadline:
                            detail = (root / 'proxy.log').read_text(encoding='utf-8', errors='replace')[-1500:]
                            raise RuntimeError('Local TLS readiness failed: ' + str(failure) + '\n' + detail) from None
                        time.sleep(0.1)
                assert status == 200 and response == {'peer': '127.0.0.1', 'forwarded': None}, (status, response)
                before = Upstream.requests
                assert fetch(port, root, 'unregistered')[0] == 403
                try:
                    fetch(port, root)
                except (URLError, OSError):
                    pass
                else:
                    raise AssertionError('Missing client certificate was accepted')
                assert Upstream.requests == before
            return {'status': 'PASS', 'checks': ['valid_server_certificate', 'registered_client_allowed',
                'same_ca_unregistered_denied', 'missing_client_denied', 'spoofed_peer_replaced'],
                'externalExposure': False, 'androidDeviceTested': False}
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            upstream.shutdown()
            upstream.server_close()
            thread.join(timeout=5)
            if root != Path(temporary).resolve() or not root.name.startswith('payse-mtls-'):
                raise RuntimeError('Temporary cleanup boundary changed')


def main():
    """2026-10-30: 설치된 Caddy/OpenSSL 경로를 받아 비민감 결과만 반환한다. 사용: 직접 CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--caddy', type=Path, required=True)
    parser.add_argument('--openssl', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run_check(args.caddy.resolve(strict=True), args.openssl.resolve(strict=True)), indent=2))


if __name__ == '__main__':
    main()
