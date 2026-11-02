"""2026-11-01: 분석 계약의 구조·참조·금융 경계를 오프라인 검증한다. 사용: 평가/테스트.

DB 소유권·세션·현재 원천 대조는 실제 서비스에서 별도로 구현해야 한다.
여기서는 금액·급여일·반복 수치를 계산하지 않는다.
"""
from datetime import datetime
from build_schemas import schemas
from schema_check import check


def keyed(rows, field):
    """2026-11-01: 중복 식별을 덮어쓰지 않고 거절한다. 사용: 입력/출력 검사."""
    result = {row[field]: row for row in rows}
    if len(result) != len(rows):
        raise ValueError(f'Duplicate {field}')
    return result


def unique(values):
    """2026-11-01: 참조 집합 중복을 거절한다. 사용: validate_input/validate_output."""
    if len(set(values)) != len(values):
        raise ValueError('Duplicate reference')


def validate_input(payload):
    """2026-11-01: 업무별 입력과 공개된 참조의 내부 일관성을 검사한다. 사용: 평가 CLI."""
    task = payload.get('semanticTaskKind')
    all_schemas = schemas()
    if not isinstance(task, str) or task + '.input.schema.json' not in all_schemas:
        raise ValueError('Unknown semantic task')
    check(all_schemas[task + '.input.schema.json'], payload)
    context = payload['context']
    if int(context['dataVersion']) > 9223372036854775807:
        raise ValueError('dataVersion overflow')
    if datetime.fromisoformat(context['asOf'].replace('Z', '+00:00')).utcoffset() is None:
        raise ValueError('Missing offset')
    unique(context['selectedAccountIds'])
    transactions = keyed(payload['transactions'], 'transactionId')
    unavailable = keyed(payload['unavailableReferences'], 'transactionId')
    if transactions.keys() & unavailable.keys():
        raise ValueError('Conflicting reference availability')
    candidates = keyed(payload['candidates'], 'candidateKey')
    classifications = keyed(payload['currentClassifications'], 'transactionId')
    if classifications.keys() - transactions.keys():
        raise ValueError('Classification outside evidence')
    for row in transactions.values():
        if row['recordKind'] == 'account_entry' and row['status'] not in ('posted', 'unknown'):
            raise ValueError('Unsupported account status')
        original = row['originalTransactionId']
        if original == row['transactionId'] or (original and original not in transactions and original not in unavailable):
            raise ValueError('Unresolved original reference')
    for transaction_id in transactions:
        visited, current = set(), transaction_id
        while current in transactions:
            if current in visited:
                raise ValueError('Cyclic original transaction reference')
            visited.add(current)
            current = transactions[current]['originalTransactionId']
    seen_relations = set()
    for relation in payload['relations']:
        key = (relation['kind'], tuple(sorted((relation['fromId'], relation['toId']))))
        if key in seen_relations or relation['fromId'] == relation['toId']:
            raise ValueError('Duplicate or self relation')
        seen_relations.add(key)
        if {relation['fromId'], relation['toId']} - transactions.keys():
            raise ValueError('Relation outside evidence')
        first, second = transactions[relation['fromId']], transactions[relation['toId']]
        if relation['kind'] == 'internal_transfer' and (
                first['recordKind'] != 'account_entry' or second['recordKind'] != 'account_entry'
                or first['direction'] == second['direction']):
            raise ValueError('Invalid internal transfer source semantics')
        if relation['kind'] == 'card_account_pair' and {
                first['recordKind'], second['recordKind']} != {'account_entry', 'card_purchase'}:
            raise ValueError('Invalid account/card source semantics')
    items = keyed(payload['items'], 'itemKey')
    targets = set()
    used_evidence = set()
    for item in items.values():
        refs = item['evidenceTransactionIds']
        unique(refs)
        used_evidence.update(refs)
        if set(refs) - transactions.keys():
            raise ValueError('Item outside evidence')
        if task == 'transactionMeaning':
            target = item['targetTransactionId']
            if target not in refs or item['candidateKey'] is not None:
                raise ValueError('Transaction target mismatch')
        else:
            target = item['candidateKey']
            candidate = candidates.get(target)
            if candidate is None or item['targetTransactionId'] is not None:
                raise ValueError('Candidate target mismatch')
            unique(candidate['evidenceTransactionIds'])
            if set(candidate['evidenceTransactionIds']) != set(refs):
                raise ValueError('Candidate evidence mismatch')
            if any(candidate[key] != context[key] for key in ('ruleVersion', 'sourceVersion')):
                raise ValueError('Candidate version mismatch')
            unique(candidate['features']['observedMonths'])
            # These are Dart's supplied assertions, not a server recurrence calculation.
            features = candidate['features']
            if (features['occurrenceCount'] < 3 or len(features['observedMonths']) < 3
                    or features['dayWithinRule'] is not True or features['amountWithinRule'] is not True
                    or features['hasUnresolvedReversal']):
                raise ValueError('Local candidate not ready')
        if target in targets:
            raise ValueError('Duplicate semantic target')
        targets.add(target)
    if task == 'recurringMeaning' and targets != candidates.keys():
        raise ValueError('Unused candidate')
    if transactions.keys() != used_evidence:
        raise ValueError('Unused evidence must not be sent')
    if unavailable.keys() - {row['originalTransactionId'] for row in transactions.values()}:
        raise ValueError('Unused unavailable reference')


def validate_output(payload, output):
    """2026-11-01: 항목 완전성·허용 ID·후보/unknown 일관성을 검사한다. 사용: 평가 CLI."""
    validate_input(payload)
    task = payload['semanticTaskKind']
    check(schemas()[task + '.output.schema.json'], output)
    requested = keyed(payload['items'], 'itemKey')
    received = keyed(output['items'], 'itemKey')
    if requested.keys() != received.keys():
        raise ValueError('Missing or unexpected item')
    for key, row in received.items():
        unique(row['evidenceTransactionIds'])
        if set(row['evidenceTransactionIds']) - set(requested[key]['evidenceTransactionIds']):
            raise ValueError('Output outside item evidence')
        for field in ('meaning', 'classification') if task == 'transactionMeaning' else ('meaning',):
            decision = row[field]
            known = decision['status'] == 'candidate'
            if known != (decision['value'] is not None) or known != (decision['reasonCode'] == 'supported'):
                raise ValueError('Decision status mismatch')
        if task == 'recurringMeaning' and row['candidateKey'] != requested[key]['candidateKey']:
            raise ValueError('Invented candidate')
        if task == 'transactionMeaning':
            target = requested[key]['targetTransactionId']
            basic = row['classification']['value']
            classifications = {entry['transactionId']: entry['value'] for entry in payload['currentClassifications']}
            current = classifications.get(target)
            if basic is not None and current is not None and basic != current:
                raise ValueError('Existing classification conflict')
            if basic == 'card_payment' and current != 'card_payment':
                raise ValueError('Card bill settlement evidence not in this input contract')
            item_refs = set(requested[key]['evidenceTransactionIds'])
            if basic == 'internal_transfer' and current != basic:
                has_transfer_evidence = any(
                    r['kind'] == 'internal_transfer' and target in (r['fromId'], r['toId'])
                    and {r['fromId'], r['toId']} <= item_refs for r in payload['relations'])
                if not has_transfer_evidence:
                    raise ValueError('Basic relation classification without explicit relation')


def model_input(payload):
    """2026-11-01: 모델용 최소 투영을 만든다. 사용: 평가 export; 운영 전송 미연결."""
    validate_input(payload)
    return {
        'semanticTaskKind': payload['semanticTaskKind'],
        'items': payload['items'],
        'transactions': payload['transactions'],
        'relations': payload['relations'],
        'unavailableReferences': payload['unavailableReferences'],
        'existingClassifications': payload['currentClassifications'],
        'candidates': [{key: row[key] for key in ('candidateKey', 'evidenceTransactionIds', 'normalizedName', 'features')}
                       for row in payload['candidates']],
    }
