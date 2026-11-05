"""2026-11-04: 감마 성능 구성의 설치·연결 점검·상태. 학습·생성·전체 평가는 실행하지 않는다."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
from urllib.error import HTTPError, URLError
from urllib.request import HTTPSHandler, HTTPRedirectHandler, ProxyHandler, Request, build_opener

import javaproperties
import release_server as release
import server_runtime as runtime


PREFIX = 'payse.gamma-local.'
FIELDS = ('enabled', 'llm-file', 'key-file', 'state-directory', 'project', 'pricing', 'source-version')


class NoRedirect(HTTPRedirectHandler):
    """2026-11-04: 자격 헤더가 다른 주소로 따라가지 않게 한다. 사용: probe."""
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def selected(properties):
    """2026-11-04: 명시 프로필만 감마 로컬 기능으로 취급한다. 사용: 설치/시작/상태."""
    return 'gamma-local' in [part.strip() for part in properties.get('spring.profiles.active', '').split(',')]


def regular(path, outside=True):
    """2026-11-04: Git 밖의 일반 파일만 자격 경로로 허용한다."""
    path = runtime.outside_git(Path(path)) if outside else Path(path)
    if not path.is_absolute():
        raise ValueError("AI file path must be absolute")
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 16384:
        raise ValueError('AI private file unavailable')
    return path


def credential(values):
    """2026-11-04: 명시적으로 선택한 자격만 메모리에서 읽는다. 반환값을 출력하지 않는다."""
    key = values.get('apiKey', '')
    if values.get('apiKeyEnvFile'):
        if key:
            raise ValueError('Choose one AI credential source')
        entries = re.findall(r'^\s*(?:export\s+)?OPENAI_API_KEY\s*=\s*(.*?)\s*$',
                             regular(values['apiKeyEnvFile'], outside=False).read_text(encoding='utf-8'), re.M)
        if len(entries) != 1:
            raise ValueError('AI credential unavailable')
        key = entries[0].strip('"\'')
    if not re.fullmatch(r'[A-Za-z0-9_.-]{8,512}', key):
        raise ValueError('AI credential unavailable')
    return key


def validate(properties):
    """2026-11-04: 키 생성·API 호출·DB 변경 없이 명시된 로컬 구성을 확인한다."""
    if not selected(properties):
        return {'enabled': False}
    if any(not properties.get(PREFIX + field) for field in FIELDS):
        raise ValueError('Gamma AI configuration incomplete')
    if properties[PREFIX + 'enabled'] != 'true' or properties.get('PAYSE_ANALYSIS_SETTINGS_FILE'):
        raise ValueError('Gamma and Google KMS configurations cannot be combined')
    for field in ('project', 'pricing'):
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,120}', properties[PREFIX + field]):
            raise ValueError('Invalid AI cost policy identifier')
    source = properties[PREFIX + 'source-version']
    if not re.fullmatch(r'fixture:gamma-(?:(?:year|challenge):1:[0-9-]+:[0-9]+|fresh:(?:development|holdout):[0-9]+)', source):
        raise ValueError('An explicit synthetic gamma source version is required')
    key = regular(properties[PREFIX + 'key-file'])
    if key.stat().st_size != 32:
        raise ValueError('Existing local master key must have 32 bytes; it will not be replaced')
    state = runtime.outside_git(properties[PREFIX + 'state-directory'])
    if not state.is_dir():
        raise ValueError('Prepare the private AI state directory first')
    llm = release.properties(regular(properties[PREFIX + 'llm-file']))
    required = {'enabled', 'provider', 'model', 'apiKey', 'reasoningEffort'}
    if (set(llm) - {'apiKeyEnvFile'} != required
            or llm.get('enabled') != 'true' or llm.get('provider') != 'openai'
            or llm.get('model') != 'gpt-6-luna' or llm.get('reasoningEffort') != 'none'):
        raise ValueError('AI settings differ from the validated gamma profile')
    credential(llm)
    return {'enabled': True, 'state': state, 'llm': llm}


def probe(properties, force=False, opener=None):
    """2026-11-04: 자격/모델 변경 때 한 번 모델 접근을 점검한다. 생성 가능/정확도 검증과 구분한다."""
    config = validate(properties)
    if not config['enabled']:
        return {'status': 'DISABLED'}
    llm = config['llm']
    key = credential(llm)
    fingerprint = hashlib.sha256((llm['model'] + '\n' + key).encode()).hexdigest()
    target = config['state'] / 'ai-connection.json'
    with runtime.lock(config['state']):
        previous = read(target)
        if (not force and previous.get('credentialFingerprint') == fingerprint
                and previous.get('status') == 'MODEL_ACCESSIBLE' and previous.get('checkedAt')):
            return dict(previous, reused=True)
        opener = opener or build_opener(ProxyHandler({}), NoRedirect(), HTTPSHandler())
        status = 'UNAVAILABLE'
        try:
            request = Request('https://api.openai.com/v1/models/' + llm['model'],
                              headers={'Authorization': 'Bearer ' + key})
            with opener.open(request, timeout=8) as response:
                body = json.loads(response.read(32769))
                if response.status == 200 and body.get('id') == llm['model']:
                    status = 'MODEL_ACCESSIBLE'
        except HTTPError as error:
            status = 'AUTHORIZATION_FAILED' if error.code in (401, 403) else 'UNAVAILABLE'
        except (OSError, URLError, ValueError):
            pass
        result = {'status': status, 'checkedAt': datetime.now(timezone.utc).isoformat(),
                  'credentialFingerprint': fingerprint, 'generationPerformed': False,
                  'responsesPermissionVerified': False}
        runtime.write_json(target, result)
        return dict(result, reused=False)


def read(path):
    """2026-11-04: 누락·손상된 상태를 완료로 읽지 않는다."""
    try:
        if path.is_symlink() or path.stat().st_size > 16384:
            return {}
        value = json.loads(path.read_text(encoding='utf-8'))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def status(properties, process_id=None):
    """2026-11-04: 현재 서버 준비와 과거 접근/실제 분석 관측을 구별한다. 자격과 경로는 반환하지 않는다."""
    if not selected(properties):
        return {'enabled': False, 'preparation': 'DISABLED'}
    try:
        config = validate(properties)
    except (OSError, ValueError):
        return {'enabled': True, 'preparation': 'INVALID_CONFIGURATION', 'runtimeReady': False}
    saved = read(config['state'] / 'ai-status.json')
    installed = read(config['state'] / 'ai-profile.json')
    connection = read(config['state'] / 'ai-connection.json')
    llm = config['llm']
    llm_fingerprint = hashlib.sha256((llm['model'] + '\n' + llm['reasoningEffort'] + '\ndefault\n'
                                      + credential(llm)).encode()).hexdigest()
    key_fingerprint = 'gamma-local-v1:' + hashlib.sha256(regular(properties[PREFIX + 'key-file']).read_bytes()).hexdigest()
    configuration = llm_fingerprint + key_fingerprint + properties[PREFIX + 'project'] + ':' + properties[PREFIX + 'pricing'] + properties[PREFIX + 'source-version']
    expected = hashlib.sha256((json.dumps(installed, separators=(',', ':'), ensure_ascii=False) + configuration).encode()).hexdigest()
    intact = bool(installed and installed == saved.get('profile') and saved.get('preparedAt')
                  and saved.get('fingerprint') == expected)
    fingerprint = hashlib.sha256((config['llm']['model'] + '\n' + credential(config['llm'])).encode()).hexdigest()
    current = connection.get('credentialFingerprint') == fingerprint
    return {'enabled': True, 'preparation': saved.get('preparation', 'PENDING') if intact else 'PENDING',
            'runtimeReady': bool(intact and process_id and process_id == saved.get('processId')),
            'preparationReused': saved.get('preparationReused', False) if intact else False,
            'preparedAt': saved.get('preparedAt') if intact else None,
            'preparationCount': saved.get('preparationCount', 0),
            'agent': saved.get('agent', 'NOT_PREPARED') if intact else 'NOT_PREPARED',
            'modelAccess': connection.get('status', 'NOT_CHECKED') if current else 'NOT_CHECKED',
            'modelAccessCheckedAt': connection.get('checkedAt') if current else None,
            'providerSuccessAt': saved.get('providerSuccessAt') if intact else None,
            'analysisValidatedAt': saved.get('analysisValidatedAt') if intact else None,
            'providerFailureAt': saved.get('providerFailureAt') if intact else None,
            'analysisFailureAt': saved.get('analysisFailureAt') if intact else None,
            'lastEvent': saved.get('lastEvent') if intact else None, 'profile': installed if intact else None}


def configure(directory, properties):
    """2026-11-04: 명시 동의를 받은 새 설치에만 별도 키/프로필 설정을 만들며 기존 키를 교체하지 않는다."""
    env_file = input('사용할 API 키 파일의 절대 경로 (.env, 키 값은 입력하지 마세요): ').strip()
    llm = {'enabled': 'true', 'provider': 'openai', 'model': 'gpt-6-luna',
           'reasoningEffort': 'none', 'apiKey': '', 'apiKeyEnvFile': str(regular(env_file, outside=False))}
    credential(llm)
    values = {'enabled': 'true', 'llm-file': str(directory / 'llm.properties'),
              'key-file': str(directory / 'gamma-master.key'),
              'state-directory': str(directory / 'ai-state'),
              'project': input('DB에 준비된 분석 비용 프로젝트 ID: ').strip(),
              'pricing': input('DB에 준비된 가격 정책 버전: ').strip(),
              'source-version': input('현재 감마 합성 데이터 sourceVersion: ').strip()}
    runtime.private_directory(directory / 'ai-state')
    for name, content in (('gamma-master.key', os.urandom(32)),
                          ('llm.properties', javaproperties.dumps(llm, timestamp=False).encode())):
        descriptor = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(content)
    properties['spring.profiles.active'] += ',analysis,gamma-local'
    properties.update({PREFIX + key: value for key, value in values.items()})
    validate(properties)


def main():
    """2026-11-04: 기존 비공개 서버 properties를 사용해 AI 연결 또는 상태를 확인한다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'status'))
    parser.add_argument('--properties', required=True)
    arguments = parser.parse_args()
    properties = release.properties(regular(arguments.properties))
    if arguments.action == 'check':
        result = probe(properties, force=True)
        result.pop('credentialFingerprint', None)
    else:
        result = status(properties)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('AI setup failed; check the private configuration. No generation was performed.')
