"""2026-11-04: 공개 입력 지문의 독립 참조 구현. 모델·DB·인증 자료를 읽지 않는다.

사용: 공통 벡터 생성/검사, 모의 서버 연동 도구. 제품 서버는 AnalysisIdentity를 사용한다.
"""
import hashlib
import json
from copy import deepcopy


def canonical(value):
    """2026-11-04: 객체 키는 UTF-16 코드 단위 정렬, 배열·문자열 원문은 보존한다. 사용: digest."""
    if isinstance(value, dict):
        return '{' + ','.join(json.dumps(key, ensure_ascii=False) + ':' + canonical(value[key])
            for key in sorted(value, key=lambda text: text.encode('utf-16-be'))) + '}'
    if isinstance(value, list):
        return '[' + ','.join(canonical(item) for item in value) + ']'
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':'))


def digest(value):
    """2026-11-04: 공백 없는 정규 JSON의 UTF-8 바이트를 SHA-256으로 만든다. 사용: identities."""
    return 'sha256:' + hashlib.sha256(canonical(value).encode('utf-8')).hexdigest()


def identities(payload):
    """2026-11-04: 검증된 공개 입력의 직접 식별·관계 확장·근거·요청 지문을 산출한다. 사용: hint."""
    task = payload['semanticTaskKind']
    rows = []
    keys = set()
    for item in payload['items']:
        direct = set(item['evidenceTransactionIds'])
        identity = {'kind': task}
        identity.update({'target': item['targetTransactionId']} if task == 'transactionMeaning'
                        else {'evidence': sorted(direct)})
        key = digest(identity)
        if key in keys:
            raise ValueError('Duplicate semantic target')
        keys.add(key)
        ids = direct.copy()
        while True:
            previous = ids.copy()
            for transaction in payload['transactions']:
                if transaction['transactionId'] in ids and transaction['originalTransactionId']:
                    ids.add(transaction['originalTransactionId'])
            for relation in payload['relations']:
                if relation['fromId'] in ids or relation['toId'] in ids:
                    ids.update([relation['fromId'], relation['toId']])
            if previous == ids:
                break
        facts = {field: sorted((row for row in payload[field] if row['transactionId'] in ids),
                               key=lambda row: row['transactionId'])
                 for field in ('transactions', 'currentClassifications', 'unavailableReferences')}
        facts['relations'] = sorted((row for row in payload['relations']
            if row['fromId'] in ids or row['toId'] in ids), key=canonical)
        for candidate in payload['candidates']:
            if candidate['candidateKey'] == item['candidateKey']:
                local = deepcopy(candidate)
                for field in ('candidateKey', 'sourceVersion', 'ruleVersion'):
                    del local[field]
                local['evidenceTransactionIds'] = sorted(direct)
                local['features']['observedMonths'].sort()
                facts['candidate'] = local
        rows.append({'itemKey': item['itemKey'], 'memoryKey': key,
                     'evidenceHash': digest(facts), 'canonicalEvidence': canonical(facts)})
    material = {'semanticTaskKind': task, 'items': [
        {field: row[field] for field in ('memoryKey', 'evidenceHash')}
        for row in sorted(rows, key=lambda row: row['memoryKey'])]}
    return {'items': rows, 'canonicalHint': canonical(material), 'inputHashHint': digest(material)}


def hint(payload):
    """2026-11-04: 공개 입력 부분만 반환한다. 서버 DB 결합 지문과 비교하지 않는다. 사용: mock smoke."""
    return identities(payload)['inputHashHint']
