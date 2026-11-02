"""2026-11-01: 재사용과 저장된 공급자 응답을 오프라인 재현한다. 사용: CLI/평가.

공개 API가 아니다. 서버 검증을 가정한 합성 문맥만 받으며 외부 호출·DB 저장·
금융 분류 적용을 하지 않는다. 비공개 정답은 이 모듈에서 읽지 않는다.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path

from build_schemas import schemas
from contract import validate_output
from efficiency import pack, select_items, unpack
from evaluate import read_json
from routing import plan

CASE_FIELDS = {'payload', 'ownerScope', 'versions', 'records', 'now', 'requestId', 'attemptId'}
ENVELOPE_FIELDS = {'caseId', 'requestId', 'attemptId', 'requestFingerprint', 'status', 'output'}
STATUSES = {'completed', 'failed', 'incomplete', 'refused'}


def text_id(value):
    """2026-11-01: 공백 없는 비어 있지 않은 내부 실행 식별자만 받는다. 사용: prepare."""
    return isinstance(value, str) and bool(value) and not any(ch.isspace() for ch in value)


def fingerprint(value):
    """2026-11-01: 실행 문맥 전체를 결합하되 권한 증명으로 쓰지 않는다. 사용: prepare."""
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)
    return hashlib.sha256(encoded.encode('utf-8')).hexdigest()


def prepare(cases):
    """2026-11-01: 정답 없이 미해결 요청과 서버 전용 복원 문맥을 분리한다. 사용: CLI/replay.

반환의 requests만 요청 준비 산출물이다. 내부 prepared는 공급자에 보내지 않는다.
"""
    if not isinstance(cases, dict) or not cases:
        raise ValueError('Expected nonempty replay cases')
    prepared, requests, request_ids, attempt_ids = {}, [], set(), set()
    for case_id, case in cases.items():
        if not text_id(case_id) or not isinstance(case, dict) or set(case) != CASE_FIELDS:
            raise ValueError('Invalid replay case fields')
        for field, used in (('requestId', request_ids), ('attemptId', attempt_ids)):
            if not text_id(case[field]) or case[field] in used:
                raise ValueError('Missing or duplicate replay request/attempt')
            used.add(case[field])
        payload = case['payload']
        actual_policy = schemas()[payload['semanticTaskKind'] + '.output.schema.json'][
            'properties']['meaningPolicyVersion']['enum']
        if case['versions'].get('policy') not in actual_policy:
            raise ValueError('Unsupported meaning policy version')
        route_plan = plan(payload, case['ownerScope'], case['versions'], case['records'], case['now'])
        packed, request = None, None
        if route_plan['unresolvedItemKeys']:
            packed = pack(select_items(payload, route_plan['unresolvedItemKeys']))
            binding = fingerprint({'caseId': case_id, 'ownerScope': case['ownerScope'],
                                   'requestId': case['requestId'], 'attemptId': case['attemptId'],
                                   'now': case['now'], 'versions': case['versions'],
                                   'payload': payload, 'plan': route_plan,
                                   'input': packed.input, 'outputSchema': packed.output_schema,
                                   'ids': packed.ids})
            request = {'caseId': case_id, 'requestId': case['requestId'], 'attemptId': case['attemptId'],
                       'requestFingerprint': binding, 'versions': copy.deepcopy(case['versions']),
                       'input': packed.input, 'outputSchema': packed.output_schema}
            requests.append(request)
        prepared[case_id] = {'case': copy.deepcopy(case), 'plan': route_plan, 'packed': packed,
                             'request': request}
    return prepared, requests


def saved_output(request, packed, envelope):
    """2026-11-01: 요청 결합을 먼저 검사하고 공급자 배치를 전부 채택/실패 처리한다. 사용: replay."""
    if envelope is None:
        return None, 'missing_saved_response', False
    if not isinstance(envelope, dict) or set(envelope) != ENVELOPE_FIELDS:
        return None, 'invalid_envelope', False
    for field in ('caseId', 'requestId', 'attemptId', 'requestFingerprint'):
        if envelope[field] != request[field]:
            return None, 'request_binding_mismatch', False
    status = envelope['status']
    if not isinstance(status, str) or status not in STATUSES:
        return None, 'invalid_provider_status', False
    if status != 'completed':
        if envelope['output'] is not None:
            return None, 'invalid_envelope', True
        return None, 'provider_' + status, True
    try:
        return unpack(packed, envelope['output']), None, True
    except (ValueError, KeyError, TypeError, AttributeError):
        return None, 'invalid_provider_output', True


def replay(cases, envelopes):
    """2026-11-01: 성공 재사용과 공급자 실패를 항목별로 보존한다. 사용: CLI/score_replay.

정상 unknown은 결과이며 실패는 result=None과 별도 error다. 후보를 저장 분류로
승격하지 않는다. envelopes는 실제 전송 여부를 인증하지 못하는 오프라인 기록이다.
"""
    prepared, requests = prepare(cases)
    if not isinstance(envelopes, list):
        raise ValueError('Saved envelopes must be a list')
    indexed = {}
    for envelope in envelopes:
        if not isinstance(envelope, dict) or not text_id(envelope.get('caseId')):
            raise ValueError('Invalid saved response identity')
        case_id = envelope['caseId']
        if case_id not in prepared or case_id in indexed:
            raise ValueError('Unknown or duplicate saved case')
        if prepared[case_id]['request'] is None:
            raise ValueError('Unexpected provider response for fully reused case')
        indexed[case_id] = envelope
    outcomes, responses, routes, persisted = {}, {}, {}, {}
    for case_id, state in prepared.items():
        payload, route_plan = state['case']['payload'], state['plan']
        rows = {key: {'route': entry['route'], 'result': copy.deepcopy(entry['result']),
                      'error': None, 'providerAttemptRecorded': False}
                for key, entry in route_plan['resolved'].items()}
        if state['request'] is not None:
            output, error, recorded = saved_output(state['request'], state['packed'], indexed.get(case_id))
            received = {row['itemKey']: row for row in output['items']} if output is not None else {}
            for key in route_plan['unresolvedItemKeys']:
                rows[key] = {'route': 'processing_failure' if error else 'llm',
                             'result': received.get(key), 'error': error,
                             'providerAttemptRecorded': recorded}
        ordered = {item['itemKey']: rows[item['itemKey']] for item in payload['items']}
        outcomes[case_id] = ordered
        routes[case_id] = {key: row['route'] for key, row in ordered.items()}
        persisted[case_id] = copy.deepcopy(payload['currentClassifications'])
        if all(row['error'] is None for row in ordered.values()):
            response = {'meaningPolicyVersion': state['case']['versions']['policy'],
                        'items': [row['result'] for row in ordered.values()]}
            validate_output(payload, response)
            responses[case_id] = response
    return {'executionKind': 'offline_saved_response_replay', 'wholePipelineMeasured': False,
            'productionAuthorityVerified': False, 'externalCalls': 0,
            'actualTokens': None, 'actualCost': None,
            'preparedRequests': len(requests), 'items': outcomes, 'responses': responses,
            'routes': routes, 'persistedClassifications': persisted,
            'rejectedProofs': {key: row['plan']['rejectedProofs'] for key, row in prepared.items()}}


def write_new(path, value):
    """2026-11-01: 기존 평가 산출물을 덮지 않고 UTF-8 JSON을 만든다. 사용: CLI."""
    with path.open('x', encoding='utf-8') as output:
        json.dump(value, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write('\n')


def main():
    """2026-11-01: 요청 준비 또는 저장 응답 재현만 실행한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--export-requests', type=Path)
    mode.add_argument('--responses', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if bool(args.responses) != bool(args.output):
        parser.error('--responses requires --output; request export does not accept --output')
    cases = read_json(args.cases)
    if args.export_requests:
        _, requests = prepare(cases)
        write_new(args.export_requests, requests)
    else:
        responses = read_json(args.responses)
        report = replay(cases, responses)
        write_new(args.output, report)


if __name__ == '__main__':
    main()
