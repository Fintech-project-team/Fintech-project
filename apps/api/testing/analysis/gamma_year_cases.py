"""2026-11-03: 연간 원천에서 현재 의미 계약의 검증 입력만 만든다. 사용: 테스트 자료 생성.

정답 파일을 읽지 않으며 공급자를 호출하지 않는다. 반복 features는 명시적인 테스트 준비값이다.
"""
import copy
from pathlib import Path
import sys
from uuid import NAMESPACE_URL, uuid5

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from testing.scenarios.gamma_year import build
from contract import validate_input, validate_output
from build_cases import answer

FIELDS = ('transactionId', 'recordKind', 'direction', 'status', 'reflectionReason',
          'merchantName', 'description', 'originalTransactionId')


def prepare():
    """2026-11-03: 20건 단위 거래 입력·반복 후보 예시와 검증된 형식 예시를 분리한다."""
    source, _ = build()
    rows = sorted(source['transactions'], key=lambda row: (row['occurredAt'], row['sourceRef']))
    base = {'contractVersion': 'PAYSE-ANALYSIS-1', 'semanticTaskKind': 'transactionMeaning',
        'context': {'schemaVersion': 'PAYSE-API-0.6-4', 'dataVersion': '1',
            'sourceVersion': source['sourceVersion'], 'ruleVersion': source['ruleVersion'],
            'asOf': source['asOf'], 'inputRevision': 0, 'localSessionEpoch': 1,
            'selectedAccountIds': []},
        'items': [], 'transactions': [], 'relations': [], 'unavailableReferences': [],
        'currentClassifications': [], 'candidates': []}
    batches = []
    for offset in range(0, len(rows), 20):
        request = copy.deepcopy(base)
        for row in rows[offset:offset + 20]:
            identity = row['transactionId']
            request['transactions'].append({key: row[key] for key in FIELDS})
            request['items'].append({'itemKey': str(uuid5(NAMESPACE_URL, 'item/' + identity)),
                'targetTransactionId': identity, 'candidateKey': None,
                'evidenceTransactionIds': [identity]})
        validate_input(request)
        batches.append(request)
    by_ref = {row['sourceRef']: row for row in rows}
    for day, slot, amount in ((1, 2, 650000), (3, 2, 55000), (8, 2, 93000),
                              (25, 2, 420000), (23, 4, 11900)):
        evidence = [by_ref[f'fixture/gamma-year/1/2026-{month:02}-{day:02}/{slot}']
                    for month in (8, 9, 10)]
        if any(row['amountKRW'] != amount or row['userId'] != source['userId']
               or row['direction'] != 'out' for row in evidence):
            raise ValueError('Reviewed recurring test facts changed')
        refs = [row['transactionId'] for row in evidence]
        key = str(uuid5(NAMESPACE_URL, 'candidate/' + refs[0]))
        request = copy.deepcopy(base)
        request['semanticTaskKind'] = 'recurringMeaning'
        request['transactions'] = [{key: row[key] for key in FIELDS} for row in evidence]
        request['items'] = [{'itemKey': key, 'targetTransactionId': None, 'candidateKey': key,
                             'evidenceTransactionIds': refs}]
        request['candidates'] = [{'candidateKey': key, 'ruleVersion': source['ruleVersion'],
            'sourceVersion': source['sourceVersion'], 'evidenceTransactionIds': refs,
            'normalizedName': evidence[0]['merchantName'], 'suggestedAmountKRW': amount,
            'suggestedDay': day, 'features': {'occurrenceCount': 3,
                'observedMonths': ['2026-08', '2026-09', '2026-10'], 'dayWithinRule': True,
                'amountWithinRule': True, 'hasUnresolvedReversal': False}}]
        validate_input(request)
        batches.append(request)
    salary_id = by_ref['fixture/gamma-year/1/2026-10-15/3']['transactionId']
    salary = copy.deepcopy(next(r for r in batches if any(
        item['targetTransactionId'] == salary_id for item in r['items'])))
    salary['items'] = [item for item in salary['items'] if item['targetTransactionId'] == salary_id]
    salary['transactions'] = [row for row in salary['transactions'] if row['transactionId'] == salary_id]
    examples = {'salary': {'input': salary, 'output': answer(salary, 'salary', 'income')},
                'recurring': {'input': batches[-4],
                              'output': answer(batches[-4], 'telecom', name='통신요금')}}
    transfer_id = by_ref['fixture/gamma-year/1/2026-10-20/3']['transactionId']
    transfer = copy.deepcopy(next(r for r in batches if any(
        item['targetTransactionId'] == transfer_id for item in r['items'])))
    transfer['items'] = [item for item in transfer['items'] if item['targetTransactionId'] == transfer_id]
    refs = [by_ref[f'fixture/gamma-year/1/2026-10-20/{slot}']['transactionId'] for slot in (3, 4)]
    transfer['items'][0]['evidenceTransactionIds'] = refs
    transfer['transactions'] = [row for row in transfer['transactions'] if row['transactionId'] in refs]
    examples['transferUnknown'] = {'input': transfer, 'output': answer(transfer, None)}
    for example in examples.values():
        validate_input(example['input'])
        validate_output(example['input'], example['output'])
    return batches, examples
