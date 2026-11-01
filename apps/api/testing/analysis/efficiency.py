"""2026-11-01: 근거 보존과 요청 내부 ID 압축을 오프라인 검증한다. 사용: 평가 준비.

실제 공급자 전송·재사용 권한 판정·과금 측정은 하지 않는다. 짧은 ID는
공급자 전용 내부 표현이며 공개 분석 계약이나 DB 식별자를 변경하지 않는다.
"""
import copy
from dataclasses import dataclass
import json

from contract import model_input, validate_input, validate_output
from build_schemas import schemas
from schema_check import check


@dataclass(frozen=True)
class PackedRequest:
    """2026-11-01: 모델 본문과 서버 전용 역매핑을 분리한다. 사용: pack/unpack.

모델에는 input만 전달한다. ids/payload는 평가 및 역매핑용이며 전송하지 않는다.
"""
    input: dict
    ids: dict
    payload: dict
    output_schema: dict


def select_items(payload, item_keys):
    """2026-11-01: 근거가 완결된 항목만 선택하며 관계 분할은 거절한다. 사용: 오프라인 배치 준비."""
    validate_input(payload)
    keys = list(item_keys)
    if not keys or len(set(keys)) != len(keys):
        raise ValueError('Empty or duplicate selected item')
    requested = {row['itemKey']: row for row in payload['items']}
    if set(keys) - requested.keys():
        raise ValueError('Unknown selected item')
    transactions = {row['transactionId']: row for row in payload['transactions']}
    selected = copy.deepcopy(payload)
    selected['items'] = [copy.deepcopy(row) for row in payload['items'] if row['itemKey'] in keys]
    all_refs = {ref for item in selected['items'] for ref in item['evidenceTransactionIds']}
    for ref in all_refs:
        original = transactions[ref]['originalTransactionId']
        if original in transactions and original not in all_refs:
            raise ValueError('Cannot split original-reference-dependent items')
    for relation in payload['relations']:
        ends = {relation['fromId'], relation['toId']}
        if ends & all_refs and not ends <= all_refs:
            raise ValueError('Cannot split relation-dependent items')
    selected['transactions'] = [row for row in selected['transactions'] if row['transactionId'] in all_refs]
    selected['relations'] = [row for row in selected['relations']
                             if {row['fromId'], row['toId']} <= all_refs]
    originals = {row['originalTransactionId'] for row in selected['transactions']}
    selected['unavailableReferences'] = [row for row in selected['unavailableReferences']
                                         if row['transactionId'] in originals]
    selected['currentClassifications'] = [row for row in selected['currentClassifications']
                                          if row['transactionId'] in all_refs]
    candidate_keys = {row['candidateKey'] for row in selected['items']}
    selected['candidates'] = [row for row in selected['candidates'] if row['candidateKey'] in candidate_keys]
    validate_input(selected)
    return selected


def criteria_only(policy):
    """2026-11-01: 허용 필드만 내보내 정답 예시·반례·작성자 메타를 제외한다. 사용: 평가 프롬프트 준비."""
    fields = ('code', 'label', 'requiredEvidence', 'insufficientEvidence')
    return {'version': policy['version'],
            'meanings': [{key: copy.deepcopy(row[key]) for key in fields}
                         for row in policy['meanings']]}


def compact_criteria(policy):
    """2026-11-01: 동일 기준 문장을 한 번만 보관하는 실험 표현을 만든다. 사용: 오프라인 크기 비교.

    실제 프롬프트에 적용하지 않는다. 복원 일치와 모델의 이해 성능은 별도 검증이다.
    """
    criteria = criteria_only(policy)
    rules, rule_ids, meanings = {}, {}, []
    for row in criteria['meanings']:
        mapped = {'code': row['code'], 'label': row['label']}
        for field in ('requiredEvidence', 'insufficientEvidence'):
            refs = []
            for rule in row[field]:
                if rule not in rule_ids:
                    key = f'r{len(rule_ids) + 1}'
                    rule_ids[rule], rules[key] = key, rule
                refs.append(rule_ids[rule])
            mapped[field] = refs
        meanings.append(mapped)
    return {'version': criteria['version'], 'rules': rules, 'meanings': meanings}


def id_kind(field):
    """2026-11-01: 식별자 필드의 명목 공간을 구분한다. 사용: pack/unpack."""
    if field in ('transactionId', 'targetTransactionId', 'originalTransactionId', 'fromId', 'toId',
                 'evidenceTransactionIds'):
        return 't'
    if field == 'itemKey':
        return 'i'
    if field == 'candidateKey':
        return 'c'
    return None


def transform_ids(value, convert, field=None):
    """2026-11-01: 명시된 ID 필드만 변환하고 거래명·적요는 그대로 둔다. 사용: pack/unpack."""
    if isinstance(value, dict):
        return {key: transform_ids(item, convert, key) for key, item in value.items()}
    if isinstance(value, list):
        return [transform_ids(item, convert, field) for item in value]
    kind = id_kind(field)
    return convert(kind, value) if kind and value is not None else value


def pack(payload):
    """2026-11-01: 모델 투영의 식별자를 요청 내부 별칭으로 압축한다. 사용: 오프라인 크기 비교."""
    aliases, reverse, counts = {}, {}, {'t': 0, 'i': 0, 'c': 0}

    def shorten(kind, value):
        """2026-11-01: 타입별 일대일 별칭을 준비한다. 사용: pack."""
        key = (kind, value)
        if key not in aliases:
            counts[kind] += 1
            alias = kind + str(counts[kind])
            aliases[key] = alias
            reverse[alias] = (kind, value)
        return aliases[key]

    projected = transform_ids(model_input(payload), shorten)
    schema = alias_schema(schemas()[payload['semanticTaskKind'] + '.output.schema.json'], reverse)
    return PackedRequest(projected, reverse, copy.deepcopy(payload), schema)


def alias_schema(schema, aliases, field=None):
    """2026-11-01: 공개 UUID 계약 대신 요청별 별칭을 허용하는 공급자 전용 규격을 만든다. 사용: pack."""
    kind = id_kind(field)
    if kind:
        allowed = sorted(alias for alias, (category, _) in aliases.items() if category == kind)
        if schema.get('type') == 'array':
            return {**copy.deepcopy(schema), 'items': {'type': 'string', 'enum': allowed}}
        return {'type': 'string', 'enum': allowed}
    result = copy.deepcopy(schema)
    if 'properties' in result:
        result['properties'] = {key: alias_schema(value, aliases, key) for key, value in result['properties'].items()}
    if 'items' in result:
        result['items'] = alias_schema(result['items'], aliases)
    return result


def unpack(packed, response):
    """2026-11-01: 미발급·다른 타입 ID를 거절하고 원래 계약으로 검증한다. 사용: 오프라인 응답 검사."""

    def restore(kind, alias):
        """2026-11-01: 현재 요청에서 발급한 별칭만 복원한다. 사용: unpack."""
        if not isinstance(alias, str) or alias not in packed.ids or packed.ids[alias][0] != kind:
            raise ValueError('Unknown or mismatched response identifier')
        return packed.ids[alias][1]

    check(packed.output_schema, response)
    restored = transform_ids(response, restore)
    validate_output(packed.payload, restored)
    return restored


def byte_metrics(payload, packed):
    """2026-11-01: UTF-8 JSON 크기만 비교하며 토큰·비용 수치를 추정하지 않는다. 사용: 평가 보고."""

    def size(value):
        """2026-11-01: 동일 직렬화 조건으로 바이트를 센다. 사용: byte_metrics."""
        return len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))

    return {'requestBytes': size(payload), 'projectedBytes': size(model_input(payload)),
            'packedBytes': size(packed.input), 'actualTokens': None, 'actualCost': None,
            'providerCalls': 0}
