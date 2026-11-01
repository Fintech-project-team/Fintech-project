"""2026-11-01: 사례군·관측 조건과 식별자 치환 중복을 점검한다. 사용: CLI/테스트.

중복 탐지는 검토 보조이며 의미적으로 독립이라는 증명은 아니다.
"""
from collections import Counter, defaultdict
import hashlib
import json
import re
from contract import model_input


def fingerprint(payload, ignore_surface=False):
    """2026-11-01: 참조 그래프를 보존하여 ID/순서 치환 중복을 찾는다. 사용: report.

    색상 정제 기반 보수적 검사다. 대칭 그래프의 완전한 동형 판정이나 의미 독립 증명은 아니다.
    """
    projected = model_input(payload)
    nodes, edges = {}, []

    def digest(value):
        """2026-11-01: 그래프 특징을 안정 직렬화한다. 사용: fingerprint."""
        text = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        return hashlib.sha256(text.encode('utf-8')).hexdigest()

    for row in projected['transactions']:
        key = ('transaction', row['transactionId'])
        nodes[key] = {field: value for field, value in row.items() if field not in ('transactionId', 'originalTransactionId')}
        if ignore_surface:
            nodes[key]['merchantName'] = '<provided>' if row['merchantName'] is not None else None
            if row['description'] is not None:
                nodes[key]['description'] = re.sub(r'\d+', '<number>', row['description'])
        if row['originalTransactionId']:
            edges.append((key, 'original', ('transaction', row['originalTransactionId'])))
    for row in projected['unavailableReferences']:
        nodes[('transaction', row['transactionId'])] = {'unavailable': row['reason']}
    for row in projected['existingClassifications']:
        nodes[('transaction', row['transactionId'])]['existingClassification'] = row['value']
    for row in projected['relations']:
        edges.append((('transaction', row['fromId']), row['kind'], ('transaction', row['toId'])))
    for row in projected['candidates']:
        key = ('candidate', row['candidateKey'])
        features = {**row['features'], 'observedMonths': sorted(row['features']['observedMonths'])}
        nodes[key] = {'normalizedName': '<provided>' if ignore_surface else row['normalizedName'], 'features': features}
        edges += [(key, 'candidateEvidence', ('transaction', ref)) for ref in row['evidenceTransactionIds']]
    for row in projected['items']:
        key = ('item', row['itemKey'])
        nodes[key] = {'task': projected['semanticTaskKind']}
        if row['targetTransactionId']:
            edges.append((key, 'target', ('transaction', row['targetTransactionId'])))
        if row['candidateKey']:
            edges.append((key, 'candidate', ('candidate', row['candidateKey'])))
        edges += [(key, 'evidence', ('transaction', ref)) for ref in row['evidenceTransactionIds']]
    colors = {key: digest([key[0], value]) for key, value in nodes.items()}
    for _ in range(len(nodes)):
        neighbors = defaultdict(list)
        for start, role, end in edges:
            neighbors[start].append(['out', role, colors[end]])
            neighbors[end].append(['in', role, colors[start]])
        colors = {key: digest([colors[key], sorted(neighbors[key])]) for key in nodes}
    return digest([sorted(colors.values()), sorted([colors[start], role, colors[end]] for start, role, end in edges)])


def report(inputs, expected):
    """2026-11-01: 건수 부풀리기와 빠진 조건을 확인할 요약을 만든다. 사용: CLI/테스트."""
    buckets = defaultdict(list)
    conditions = defaultdict(list)
    for key, payload in inputs.items():
        buckets[fingerprint(payload)].append(key)
        conditions[fingerprint(payload, ignore_surface=True)].append(key)
    rows = [row for payload in inputs.values() for row in payload['transactions']]
    targets = defaultdict(list)
    for key, payload in inputs.items():
        if payload['semanticTaskKind'] == 'transactionMeaning':
            for item in payload['items']:
                targets[item['targetTransactionId']].append(key)
    return {'cases': len(inputs), 'groups': len({row['groupId'] for row in expected.values()}),
            'distinctTransactionTargets': len(targets),
            'reusedTargetScenarioGroups': [keys for keys in targets.values() if len(keys) > 1],
            'taskKinds': dict(Counter(row['semanticTaskKind'] for row in inputs.values())),
            'recordKinds': dict(Counter(row['recordKind'] for row in rows)),
            'directions': dict(Counter(row['direction'] for row in rows)),
            'withRelations': sum(bool(row['relations']) for row in inputs.values()),
            'withUnavailableReference': sum(bool(row['unavailableReferences']) for row in inputs.values()),
            'withExistingClassification': sum(bool(row['currentClassifications']) for row in inputs.values()),
            'withMissingNameOrMemo': sum(row['merchantName'] is None or row['description'] is None for row in rows),
            'duplicateInputGroups': [keys for keys in buckets.values() if len(keys) > 1],
            'surfaceBlindDistinctInputs': len(conditions),
            'surfaceOnlyGroups': [keys for keys in conditions.values() if len(keys) > 1],
            'familyLinks': sorted({link for row in expected.values() for link in row.get('familyLinks', [])}),
            'holdoutReady': False,
            'note': '의미 독립성·실제 서비스 분포는 사람 검토 필요. ID/순서 변형은 정확도 표본으로 늘리지 않음.'}


if __name__ == '__main__':
    from build_cases import prepare
    print(json.dumps(report(*prepare()), ensure_ascii=False, indent=2))
