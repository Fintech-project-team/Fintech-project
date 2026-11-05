"""2026-11-02: 검증된 커밋의 배포 묶음을 만들고 성공한 GitHub CI 산출물만 가져온다. 사용: CI·수동 CD."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from zipfile import ZipFile

import javaproperties

from package_server import API, check_jar, package


WORKFLOW = '.github/workflows/release.yml'
FORMAT = 'payse-release-v1'


def sha256(path):
    """2026-11-02: 큰 JAR를 한꺼번에 메모리에 올리지 않고 지문을 계산한다. 사용: build·verify."""
    with Path(path).open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()


def properties(path):
    """2026-11-02: Java escape 규칙으로 읽으며 중복 설정을 거절한다. 사용: fetch."""
    values = {}
    with Path(path).open(encoding='utf-8-sig') as source:
        for item in javaproperties.parse(source):
            if isinstance(item, javaproperties.KeyValue):
                if item.key in values:
                    raise ValueError('Duplicate deployment property')
                values[item.key] = item.value
    return values


def build(jar, output, commit, repository, branch, run_id):
    """2026-11-02: 기존 패키저를 재사용하고 소스·CI 식별자와 허용 파일 지문을 묶는다. 사용: CI·검사."""
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('A full commit SHA is required')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('A GitHub repository is required')
    if branch not in ('develop', 'sunghyun-dev') or int(run_id) < 0:
        raise ValueError('Unsupported release branch or run ID')
    output = package(jar, output)
    schema = API / 'deploy/release-schema.json'
    (output / schema.name).write_bytes(schema.read_bytes())
    for name in ('portable_server.py', 'server_runtime.py', 'release_server.py', 'package_server.py', 'ai_setup.py'):
        (output / name).write_bytes((API / 'tools' / name).read_bytes())
    for name in ('requirements.txt', 'deployment.properties.example', 'portable.properties.example',
                 'continuous-delivery.md', 'Deploy-Payse.ps1', 'Release-Control.psm1', 'ai.properties.example'):
        (output / name).write_bytes((API / 'deploy' / name).read_bytes())
    release = {
        'format': FORMAT, 'commit': commit, 'repository': repository,
        'branch': branch, 'runId': int(run_id), 'workflow': WORKFLOW, 'javaMajor': 21,
        'sha256': {p.name: sha256(p) for p in output.iterdir() if p.is_file()},
    }
    (output / 'release.json').write_text(json.dumps(release, indent=2) + '\n', encoding='utf-8')
    return release


def verify(output, expected_commit=None, require_ci=False):
    """2026-11-02: 배포 묶음의 필수 파일·허용 경로·모든 지문을 대조한다. 사용: fetch·검사."""
    output = Path(output)
    release = json.loads((output / 'release.json').read_text(encoding='utf-8'))
    if release['format'] != FORMAT or release['javaMajor'] != 21:
        raise ValueError('Unsupported release format')
    if (not re.fullmatch(r'[0-9a-f]{40}', release['commit'])
            or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', release['repository'])
            or type(release['runId']) is not int or release['runId'] < 0
            or release['workflow'] != WORKFLOW
            or release['branch'] not in ('develop', 'sunghyun-dev')
            or expected_commit is not None and release['commit'] != expected_commit):
        raise ValueError('Unexpected release identity')
    if not {'server.jar', 'release-schema.json', 'manifest.json'} <= release['sha256'].keys():
        raise ValueError('Required release file missing')
    permitted = set(release['sha256']) | {'release.json', 'ci-receipt.json'}
    if any(p.name not in permitted or not p.is_file() or p.is_symlink() for p in output.iterdir()):
        raise ValueError('Unexpected release contents')
    for name, digest in release['sha256'].items():
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', name) or name in ('.', '..'):
            raise ValueError('Invalid release path')
        source = output / name
        if (not re.fullmatch(r'[0-9a-f]{64}', digest)
                or source.is_symlink() or not source.is_file() or sha256(source) != digest):
            raise ValueError('Release file integrity check failed')
    check_jar(output / 'server.jar')
    if require_ci:
        receipt = json.loads((output / 'ci-receipt.json').read_text(encoding='utf-8'))
        if (receipt['format'] != 'payse-ci-receipt-v1' or release['runId'] <= 0
                or any(receipt[key] != release[key] for key in ('commit', 'repository', 'branch', 'runId', 'workflow'))
                or receipt['releaseSha256'] != sha256(output / 'release.json')):
            raise ValueError('Successful CI download receipt missing or mismatched')
    return release


def validate_run(run, repository, branch, head):
    """2026-11-02: 같은 저장소·허용 브랜치 최신 커밋의 완료된 성공 실행만 허용한다. 사용: fetch·검사."""
    valid = (
        run.get('status') == 'completed' and run.get('conclusion') == 'success'
        and run.get('event') in ('push', 'workflow_dispatch')
        and run.get('path') == WORKFLOW and run.get('head_branch') == branch
        and run.get('head_repository', {}).get('full_name') == repository
        and run.get('head_sha') == head and re.fullmatch(r'[0-9a-f]{40}', head)
    )
    if not valid:
        raise ValueError('Only successful release CI for the current approved branch head is allowed')


def extract(archive_bytes, output):
    """2026-11-02: 경로 이탈·링크·중복·과도한 크기를 거절하고 새 폴더에만 푼다. 사용: fetch·검사."""
    output = Path(output)
    if output.exists() or output.is_symlink():
        raise ValueError('Download output must be a new directory')
    with ZipFile(io.BytesIO(archive_bytes)) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len({name.casefold() for name in names}) or len(names) > 30:
            raise ValueError('Duplicate or excessive artifact entries')
        for entry in entries:
            if (not re.fullmatch(r'[A-Za-z0-9_.-]+', entry.filename)
                    or entry.filename in ('.', '..')
                    or (entry.external_attr >> 16) & 0o170000 == 0o120000):
                raise ValueError('Unsafe artifact entry')
        if sum(entry.file_size for entry in entries) > 512 * 1024 * 1024:
            raise ValueError('Artifact is too large')
        output.mkdir(parents=True, exist_ok=False)
        for entry in entries:
            with archive.open(entry) as source, (output / entry.filename).open('xb') as target:
                shutil.copyfileobj(source, target, 1024 * 1024)


def fetch(settings_path, run_id, output):
    """2026-11-02: gh 인증을 이용해 CI 출처와 ZIP 지문을 검증한다. 서버에는 접속하지 않는다. 사용: CLI."""
    settings = properties(settings_path)
    repository, branch = settings.get('github.repository', ''), settings.get('github.branch', '')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Configure github.repository')
    if branch not in ('develop', 'sunghyun-dev') or run_id <= 0:
        raise ValueError('Configure an approved branch and a positive run ID')
    if Path(output).exists():
        raise ValueError('Output already exists')
    environment = dict(os.environ, GH_HOST='github.com', GH_PROMPT_DISABLED='1')
    if settings.get('github.token'):
        environment['GH_TOKEN'] = settings['github.token']

    def api(endpoint, binary=False):
        """2026-11-02: 고정 GitHub 호스트에 CLI로 요청하고 원문 오류·자격은 출력하지 않는다. 사용: fetch."""
        response = subprocess.run(['gh', 'api', '--hostname', 'github.com', endpoint],
                                  env=environment, capture_output=True, timeout=180,
                                  creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        if response.returncode:
            raise RuntimeError('GitHub request failed; check local gh authentication and Actions read access')
        return response.stdout if binary else json.loads(response.stdout)

    run = api(f'repos/{repository}/actions/runs/{run_id}')
    head = api(f'repos/{repository}/git/ref/heads/{branch}')['object']['sha']
    validate_run(run, repository, branch, head)
    artifacts = api(f'repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100')['artifacts']
    matches = [item for item in artifacts if item['name'] == f'payse-api-{head}' and not item['expired']]
    if len(matches) != 1:
        raise ValueError('Exactly one unexpired release artifact is required')
    artifact = matches[0]
    archive = api(f'repos/{repository}/actions/artifacts/{int(artifact["id"])}/zip', binary=True)
    archive_digest = 'sha256:' + hashlib.sha256(archive).hexdigest()
    if artifact.get('digest') != archive_digest:
        raise ValueError('GitHub artifact digest does not match')
    extract(archive, output)
    release = verify(output)
    if (release['commit'], release['repository'], release['branch'], release['runId']) != (
            head, repository, branch, run_id):
        raise ValueError('Artifact provenance differs from the successful CI run')
    receipt = {'format': 'payse-ci-receipt-v1', 'commit': head, 'runId': run_id,
               'repository': repository, 'branch': branch, 'workflow': WORKFLOW,
               'artifactDigest': archive_digest, 'releaseSha256': sha256(Path(output) / 'release.json')}
    (Path(output) / 'ci-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')


def main():
    """2026-11-02: 패키지 생성과 다운로드를 분리하며 실제 배포는 PowerShell의 명시 Apply로 한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    make = commands.add_parser('build')
    make.add_argument('--jar', required=True, type=Path)
    make.add_argument('--output', required=True, type=Path)
    make.add_argument('--commit', required=True)
    make.add_argument('--repository', required=True)
    make.add_argument('--branch', required=True)
    make.add_argument('--run-id', required=True, type=int)
    download = commands.add_parser('fetch')
    download.add_argument('--properties', required=True, type=Path)
    download.add_argument('--run-id', required=True, type=int)
    download.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'build':
            build(args.jar, args.output, args.commit, args.repository, args.branch, args.run_id)
        else:
            fetch(args.properties, args.run_id, args.output)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'Release preparation failed ({type(error).__name__}); server unchanged.', file=sys.stderr)
        return 1
    print('Release prepared. Run the portable installer or Windows adapter for checks before manual Apply.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
