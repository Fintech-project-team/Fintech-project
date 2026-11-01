"""2026-11-01: 관련 사례군·원천·중복을 연결해 평가 분리 누락을 거절한다. 사용: evaluate/테스트.

분리 검사는 독립 자료의 필요조건이다. 사람이 본 정답이나 의미 유사성을 자동 인증하지 않는다.
"""
from collections import Counter, defaultdict
from diversity import fingerprint


def transaction_fingerprints(payload):
    """2026-11-01: 배치 포장을 제거한 거래별 근거 지문을 만든다. 사용: families/assert_final."""
    if payload['semanticTaskKind'] != 'transactionMeaning':
        return []
    transactions = {row['transactionId']: row for row in payload['transactions']}
    result = []
    for item in payload['items']:
        refs = set(item['evidenceTransactionIds'])
        pending = list(refs)
        while pending:
            original = transactions[pending.pop()]['originalTransactionId']
            if original in transactions and original not in refs:
                refs.add(original)
                pending.append(original)
        originals = {transactions[key]['originalTransactionId'] for key in refs}
        single = {**payload,
                  'items': [{**item, 'evidenceTransactionIds': sorted(refs)}],
                  'transactions': [row for row in payload['transactions'] if row['transactionId'] in refs],
                  'relations': [row for row in payload['relations'] if {row['fromId'], row['toId']} <= refs],
                  'unavailableReferences': [row for row in payload['unavailableReferences']
                                            if row['transactionId'] in originals],
                  'currentClassifications': [row for row in payload['currentClassifications']
                                              if row['transactionId'] in refs],
                  'candidates': []}
        result.append(fingerprint(single, ignore_surface=True))
    return result


def families(inputs, expected):
    """2026-11-01: 사례군·부모군·공유 원천·입력 지문을 연결한다. 사용: split_report/assert_final."""
    if set(inputs) != set(expected):
        raise ValueError('Evaluation input and label cases differ')
    parents = {key: key for key in inputs}
    owners = {}

    def root(key):
        """2026-11-01: 경로를 압축해 연결 성분을 찾는다. 사용: families."""
        while parents[key] != key:
            parents[key] = parents[parents[key]]
            key = parents[key]
        return key

    def connect(case_id, token):
        """2026-11-01: 같은 근거 토큰을 쓰는 사례를 한 군에 둔다. 사용: families."""
        if token in owners:
            parents[root(case_id)] = root(owners[token])
        else:
            owners[token] = case_id

    for case_id, payload in inputs.items():
        label = expected[case_id]
        groups = [label.get('groupId')]
        for field in ('alsoCoversGroups', 'familyLinks'):
            links = label.get(field, [])
            if not isinstance(links, list):
                raise ValueError('Family links must be lists')
            groups.extend(links)
        for group in groups:
            if not isinstance(group, str) or not group:
                raise ValueError('Missing or invalid evaluation family')
            connect(case_id, ('group', group))
        for row in payload['transactions']:
            connect(case_id, ('source', row['transactionId']))
        connect(case_id, ('fingerprint', fingerprint(payload)))
        for value in transaction_fingerprints(payload):
            connect(case_id, ('transaction-fingerprint', value))
    grouped = defaultdict(list)
    for key in inputs:
        grouped[root(key)].append(key)
    return sorted((sorted(keys) for keys in grouped.values()), key=lambda keys: keys[0])


def split_report(inputs, expected):
    """2026-11-01: 연결된 사례가 개발/최종 영역을 넘으면 실패한다. 사용: 평가 준비/테스트."""
    components = families(inputs, expected)
    for component in components:
        splits = {'development' if expected[key].get('split') == 'calibration'
                  else expected[key].get('split') for key in component}
        if len(splits) != 1 or not splits <= {'development', 'final'}:
            raise ValueError('Related families cross evaluation splits or have no valid split')
    return {'familyComponents': len(components),
            'splitCounts': dict(Counter(row['split'] for row in expected.values())),
            'largestFamilyCases': max((len(keys) for keys in components), default=0),
            'relatedSplitOverlap': False,
            'independenceProven': False}


def assert_final(inputs, expected, development_inputs, development_expected):
    """2026-11-01: 10만 고유 거래·최종 표시·개발군 비중복을 확인한다. 사용: --final; 실제 호출 아님."""
    split_report(inputs, expected)
    if not development_inputs:
        raise ValueError('Final evaluation requires the development exposure manifest')
    split_report(development_inputs, development_expected)
    if any(row['split'] != 'final' for row in expected.values()):
        raise ValueError('Calibration or development cases cannot be a final evaluation')
    if any(row['split'] == 'final' for row in development_expected.values()):
        raise ValueError('Development exposure cannot contain final cases')
    targets = []
    for payload in inputs.values():
        if payload['semanticTaskKind'] != 'transactionMeaning':
            raise ValueError('Final 100000 target contains transactions only')
        targets.extend(row['targetTransactionId'] for row in payload['items'])
    if len(targets) != 100000 or len(set(targets)) != 100000:
        raise ValueError('Final evaluation requires exactly 100000 distinct transaction targets')
    transaction_shapes = [value for payload in inputs.values() for value in transaction_fingerprints(payload)]
    if len(set(transaction_shapes)) != 100000:
        raise ValueError('Repeated transaction inputs cannot increase the final sample count')
    combined_inputs, combined_expected = {}, {}
    for prefix, data, labels in [('final/', inputs, expected),
                                 ('development/', development_inputs, development_expected)]:
        combined_inputs.update({prefix + key: row for key, row in data.items()})
        combined_expected.update({prefix + key: row for key, row in labels.items()})
    split_report(combined_inputs, combined_expected)
    return {'structuralEligibility': True, 'transactionTargets': len(targets),
            'independentAuthorReviewRequired': True, 'providerExecutionVerified': False}
