"""2026-11-01: 원천 확인·결과 재사용의 사전 조건을 오프라인 증명한다. 사용: 평가 준비/테스트.

실제 HTTP·DB·권한 서비스에 연결되지 않는다. records는 서버 검증을 이미 마쳤다고
가정한 합성 입력이며 verified=True 자체는 권한 증명이 아니다. 이 지문은 평가용이며
공개 API·영구 DB 지문 규격이 아니다. 제안과 저장된 유효 분류의 합성도 아직 구현하지 않는다.
"""
import copy
from datetime import datetime
import hashlib
import json
from contract import validate_input, validate_output
from efficiency import select_items

VERSION_KEYS = {'policy', 'model', 'prompt', 'schema'}
TRUSTED_ROUTES = ('source_fact', 'user_confirmed', 'reused_result')


def instant(value):
    """2026-11-01: 오프셋 있는 저장·만료·현재 시각만 받는다. 사용: plan/check_record."""
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.utcoffset() is None:
        raise ValueError('Missing time offset')
    return parsed


def evidence_key(payload, item_key):
    """2026-11-01: 실제 ID·근거·관계·기존 분류를 보존한 평가 지문이다. 사용: plan/테스트."""
    selected = select_items(payload, [item_key])
    item = selected['items'][0]
    relevant = {'task': selected['semanticTaskKind'],
                'context': {key: selected['context'][key] for key in
                            ('schemaVersion', 'sourceVersion', 'ruleVersion', 'selectedAccountIds')},
                'target': {key: value for key, value in item.items() if key != 'itemKey'},
                'transactions': selected['transactions'], 'relations': selected['relations'],
                'unavailableReferences': selected['unavailableReferences'],
                'currentClassifications': selected['currentClassifications'],
                'candidates': selected['candidates']}

    def canonical(value):
        """2026-11-01: 순서 차이만 제거하고 원천 값·식별자는 유지한다. 사용: evidence_key."""
        if isinstance(value, dict):
            return {key: canonical(part) for key, part in sorted(value.items())}
        if isinstance(value, list):
            return sorted((canonical(part) for part in value), key=lambda part: json.dumps(part, sort_keys=True))
        return value

    encoded = json.dumps(canonical(relevant), ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(encoded.encode('utf-8')).hexdigest()


def check_record(payload, item, record, owner_scope, versions, now, fingerprint):
    """2026-11-01: 재사용 증거를 검사하고 탈락 사유만 돌려준다. 사용: plan."""
    if record.get('verified') is not True or record.get('route') not in TRUSTED_ROUTES:
        return 'unverified_proof'
    if record.get('ownerScope') != owner_scope:
        return 'owner_mismatch'
    prior_versions = record.get('versions')
    if not isinstance(prior_versions, dict) or set(prior_versions) != VERSION_KEYS:
        return 'version_mismatch'
    relevant_versions = VERSION_KEYS if record['route'] == 'reused_result' else {'policy', 'schema'}
    if any(prior_versions[key] != versions[key] for key in relevant_versions):
        return 'version_mismatch'
    required = {'active': True, 'deleted': False, 'expired': False, 'sourceValid': True, 'userCorrected': False}
    for key, expected in required.items():
        if record.get(key) is not expected:
            return 'invalid_' + key
    if record.get('evidenceFingerprint') != fingerprint:
        return 'evidence_changed'
    if any(not isinstance(record.get(flag), bool) for flag in ('isReference', 'important')):
        return 'invalid_retention_flags'
    if record['important'] and not record['isReference']:
        return 'invalid_retention_flags'
    try:
        stored_at, expires_at = instant(record['storedAt']), instant(record['normalExpiresAt'])
        if stored_at > now or expires_at <= stored_at:
            return 'invalid_lifetime'
        if record['accountPurgeAt'] is not None and now >= instant(record['accountPurgeAt']):
            return 'account_retention_ended'
        if now >= expires_at and not (record['isReference'] and record['important']):
            return 'expired_at_boundary'
        result = copy.deepcopy(record['result'])
        result['itemKey'] = item['itemKey']
        selected = select_items(payload, [item['itemKey']])
        validate_output(selected, {'meaningPolicyVersion': versions['policy'], 'items': [result]})
        fields = ('meaning', 'classification') if payload['semanticTaskKind'] == 'transactionMeaning' else ('meaning',)
        if record['route'] != 'reused_result' and any(
                result[field]['value'] is None or result[field]['status'] != 'candidate' for field in fields):
            return 'incomplete_result'
    except (ValueError, TypeError, KeyError, AttributeError):
        return 'invalid_record'
    return None


def plan(payload, owner_scope, versions, records, now):
    """2026-11-01: 완전한 검증 결과를 먼저 쓰고 미해결 항목은 그대로 남긴다. 사용: 오프라인 테스트.

운영의 소유권·원천 재검증·삭제·만료 조회는 호출자가 실제 구현해야 한다.
계약상 정상 unknown도 유효한 저장 결과이면 재사용한다. 자동 호출/재시도·TTL 변경은 하지 않는다.
"""
    validate_input(payload)
    if not isinstance(owner_scope, str) or not owner_scope:
        raise ValueError('Missing authenticated owner scope')
    if set(versions) != VERSION_KEYS or any(not isinstance(value, str) or not value for value in versions.values()):
        raise ValueError('Missing policy/model/prompt/schema versions')
    if versions['schema'] != payload['contractVersion']:
        raise ValueError('Analysis schema version mismatch')
    if not isinstance(records, list) or any(not isinstance(record, dict) for record in records):
        raise ValueError('Verified records must be a list of objects')
    current_time = instant(now)
    resolved, unresolved, rejected = {}, [], {}
    for item in payload['items']:
        key = item['itemKey']
        target = item['targetTransactionId'] or item['candidateKey']
        reasons, candidates = [], []
        try:
            fingerprint = evidence_key(payload, key)
        except ValueError:
            unresolved.append(key)
            rejected[key] = ['dependent_batch_kept']
            continue
        for record in records:
            if record.get('targetKey') != target:
                continue
            rejection = check_record(payload, item, record, owner_scope, versions, current_time, fingerprint)
            if rejection:
                reasons.append(rejection)
            else:
                candidates.append(record)
        if candidates:
            priority = min(TRUSTED_ROUTES.index(row['route']) for row in candidates)
            strongest = [row for row in candidates if TRUSTED_ROUTES.index(row['route']) == priority]
            if len(strongest) != len(candidates):
                reasons.append('lower_priority_result_not_used')
            candidates = strongest
        decisions = {json.dumps({field: row['result'].get(field) for field in ('meaning', 'classification', 'name')},
                                sort_keys=True) for row in candidates}
        if len(decisions) > 1:
            reasons.append('conflicting_verified_results')
            candidates = []
        if candidates:
            chosen = min(candidates, key=lambda row: (TRUSTED_ROUTES.index(row['route']), instant(row['storedAt'])))
            result = copy.deepcopy(chosen['result'])
            result['itemKey'] = key
            resolved[key] = {'route': chosen['route'], 'result': result,
                             'storedAt': chosen['storedAt'], 'normalExpiresAt': chosen['normalExpiresAt'],
                             'importantReference': chosen['isReference'] and chosen['important']}
        else:
            unresolved.append(key)
            if not reasons:
                reasons.append('no_verified_complete_result')
        if reasons:
            rejected[key] = sorted(set(reasons))
    if unresolved:
        try:
            select_items(payload, unresolved)
        except ValueError:
            # Keep the whole dependent batch instead of dropping evidence across a resolved item.
            resolved = {}
            unresolved = [item['itemKey'] for item in payload['items']]
            for key in unresolved:
                rejected[key] = sorted(set(rejected.get(key, []) + ['dependent_batch_kept']))
    return {'resolved': resolved, 'unresolvedItemKeys': unresolved, 'rejectedProofs': rejected,
            'totalItems': len(payload['items']), 'externalCalls': 0,
            'productionAuthorityVerified': False, 'effectivePersistedClassificationImplemented': False}
