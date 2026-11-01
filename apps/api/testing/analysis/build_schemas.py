"""2026-11-01: A/B 의미 계약의 JSON Schema를 생성한다. 사용: CLI, 계약 검사.

운영 API에는 연결하지 않는다. 금융 Snapshot/DB 스키마는 생성하거나 변경하지 않는다.
"""
import argparse
import json
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT.parent / 'ai' / 'contracts'
BASIC_TYPES = ['expense', 'income', 'internal_transfer', 'card_payment', None]
UUID = {'type': 'string', 'pattern': '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'}
TEXT = {'type': 'string', 'minLength': 1}
MONTH = {'type': 'string', 'pattern': '^[0-9]{4}-(0[1-9]|1[0-2])$'}


def obj(properties):
    """2026-11-01: 모든 필드 필수·추가 필드 금지 객체를 만든다. 사용: schemas."""
    return {'type': 'object', 'properties': properties, 'required': list(properties),
            'additionalProperties': False}


def array(item, maximum=60, minimum=0):
    """2026-11-01: 승인된 근거/후보 상한을 표현한다. 사용: schemas."""
    result = {'type': 'array', 'items': item, 'minItems': minimum}
    if maximum is not None:
        result['maxItems'] = maximum
    return result


def nullable(value):
    """2026-11-01: null과 실제 미확정을 보존한다. 사용: schemas."""
    return {**value, 'type': [value['type'], 'null']}


@lru_cache(maxsize=1)
def schemas():
    """2026-11-01: 한 검사 프로세스의 고정 정책으로 규격을 만든다. 사용: main/contract.

    반환 규격은 읽기 전용으로 사용한다. 정책 수정 후에는 새 검사 프로세스를 실행한다.
    """
    policy = json.loads((CONTRACTS / 'meaning-policy.json').read_text(encoding='utf-8-sig'))
    codes = [row['code'] for row in policy['meanings']]
    context = obj({
        'schemaVersion': {'type': 'string', 'enum': ['PAYSE-API-0.6-4']},
        'dataVersion': {'type': 'string', 'pattern': '^[1-9][0-9]{0,18}$'},
        'sourceVersion': TEXT, 'ruleVersion': TEXT,
        'asOf': {'type': 'string', 'pattern': '^\\d{4}-\\d{2}-\\d{2}T.+(?:Z|[+-]\\d{2}:\\d{2})$'},
        'inputRevision': {'type': 'integer', 'minimum': 0},
        'localSessionEpoch': {'type': 'integer', 'minimum': 0},
        'selectedAccountIds': array(UUID, maximum=None),
    })
    evidence = obj({
        'transactionId': UUID,
        'recordKind': {'type': 'string', 'enum': ['account_entry', 'card_purchase', 'card_refund', 'card_cancellation']},
        'direction': {'type': 'string', 'enum': ['in', 'out']},
        'status': {'type': 'string', 'enum': ['posted', 'approved', 'cancelled', 'unknown']},
        'reflectionReason': {'type': 'string', 'enum': ['reflected', 'not_reflected', 'not_applicable', 'unknown']},
        'merchantName': nullable({'type': 'string'}), 'description': nullable({'type': 'string'}),
        'originalTransactionId': nullable(UUID),
    })
    relation = obj({'kind': {'type': 'string', 'enum': ['internal_transfer', 'card_account_pair']},
                    'fromId': UUID, 'toId': UUID})
    current = obj({'transactionId': UUID, 'value': {'type': ['string', 'null'], 'enum': BASIC_TYPES}})
    candidate = obj({
        'candidateKey': TEXT, 'ruleVersion': TEXT, 'sourceVersion': TEXT,
        'evidenceTransactionIds': array(UUID, minimum=1), 'normalizedName': TEXT,
        'suggestedAmountKRW': {'type': 'integer', 'minimum': 0, 'maximum': 9000000000000},
        'suggestedDay': nullable({'type': 'integer', 'minimum': 1, 'maximum': 31}),
        'features': obj({'occurrenceCount': {'type': 'integer', 'minimum': 0},
                         'observedMonths': array(MONTH, maximum=3),
                         'dayWithinRule': nullable({'type': 'boolean'}),
                         'amountWithinRule': nullable({'type': 'boolean'}),
                         'hasUnresolvedReversal': {'type': 'boolean'}}),
    })
    result = {}
    for task in ('transactionMeaning', 'recurringMeaning'):
        recurring = task == 'recurringMeaning'
        item = obj({'itemKey': TEXT, 'targetTransactionId': nullable(UUID),
                    'candidateKey': nullable(TEXT), 'evidenceTransactionIds': array(UUID, minimum=1)})
        inp = obj({'contractVersion': {'type': 'string', 'enum': ['PAYSE-ANALYSIS-1']},
                   'semanticTaskKind': {'type': 'string', 'enum': [task]},
                   'context': context, 'items': array(item, maximum=20 if recurring else 60, minimum=1),
                   'transactions': array(evidence, minimum=1), 'relations': array(relation, maximum=None),
                   'unavailableReferences': array(obj({'transactionId': UUID, 'reason': {
                       'type': 'string', 'enum': ['outside_retention', 'not_provided', 'not_connected']}})),
                   'currentClassifications': array(current),
                   'candidates': array(candidate, maximum=20 if recurring else 0)})
        decision = obj({'status': {'type': 'string', 'enum': ['candidate', 'unknown']},
                        'value': {'type': ['string', 'null'], 'enum': BASIC_TYPES},
                        'reasonCode': {'type': 'string', 'enum': ['supported', 'insufficient_evidence', 'conflicting_evidence', 'outside_taxonomy']}})
        meaning = obj({'status': {'type': 'string', 'enum': ['candidate', 'unknown']},
                       'value': {'type': ['string', 'null'], 'enum': codes + [None]},
                       'reasonCode': decision['properties']['reasonCode']})
        output_item = {'itemKey': TEXT, 'meaning': meaning,
                       'reason': {'type': 'string', 'minLength': 1, 'maxLength': 240},
                       'evidenceTransactionIds': array(UUID, minimum=1)}
        if recurring:
            output_item.update({'candidateKey': TEXT, 'name': nullable({'type': 'string', 'minLength': 1, 'maxLength': 80})})
        else:
            output_item['classification'] = decision
        result[task + '.input.schema.json'] = inp
        result[task + '.output.schema.json'] = obj({
            'meaningPolicyVersion': {'type': 'string', 'enum': [policy['version']]},
            'items': array(obj(output_item), maximum=20 if recurring else 60, minimum=1)})
    return result


def main():
    """2026-11-01: 명시적 생성 또는 파일 동일성 검사를 수행한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    for name, schema in schemas().items():
        path = CONTRACTS / name
        if args.write:
            path.write_text(json.dumps(schema, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        elif json.loads(path.read_text(encoding='utf-8-sig')) != schema:
            raise ValueError(f'Stale schema: {name}')
    print('Analysis schemas: PASS')


if __name__ == '__main__':
    main()
