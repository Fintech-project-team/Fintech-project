"""2026-11-01: 기록된 시도별 사용량만 오프라인 집계한다. 사용: 평가 CLI/테스트.

공급자가 기록한 토큰과 서버가 측정한 지연을 받는다. 원화 금액은 단가·환율·수수료를
확인한 PAYSE 비용 장부의 정산/미정산 금액이며 공급자 원화 응답이나 이 도구의 추정값이 아니다.
JSON 목록의 내부 평가 형식: requestId, attemptId, items[{caseId,itemKey}], state, adopted,
inputTokens, outputTokens, latencyMs, costState, settledCostKRW, pendingCostKRW, costLedgerRef.
requestId는 발신 전 로컬에서 부여한 요청 ID, attemptId는 전체 비용 장부에서 고유한 시도 ID다.
응답 유실 시 없을 수 있는 공급자 응답 ID나 작업 안의 단순 회차 번호로 대체하지 않는다.
미측정 값은 null이다. pendingCostKRW는 미정산 장부 금액이지 확정 실비가 아니다.
실제 호출·재시도·환율 계산·공개 API/DB 계약·기록의 진위 검증은 구현하지 않는다.
"""
from collections import Counter
from decimal import Decimal, InvalidOperation, localcontext
import json
import re

FIELDS = {'requestId', 'attemptId', 'items', 'state', 'adopted', 'inputTokens', 'outputTokens',
          'latencyMs', 'costState', 'settledCostKRW', 'pendingCostKRW', 'costLedgerRef'}
STATES = {'succeeded', 'failed', 'outcome_unknown', 'cancelled'}


def read_usage(path):
    """2026-11-01: 중복 JSON 키를 거절하며 내부 사용량 목록만 읽는다. 사용: 평가 CLI."""
    def unique_object(pairs):
        """2026-11-01: 중복 필드를 마지막 값으로 덮어쓰지 않는다. 사용: read_usage."""
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate usage JSON field')
            result[key] = value
        return result

    records = json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=unique_object)
    if not isinstance(records, list):
        raise ValueError('Usage records must be a list')
    return records


def decimal_cost(value):
    """2026-11-01: 0 이상 유한 원화 소수를 문자열로만 받는다. 사용: validate_record."""
    if value is None:
        return None
    if not isinstance(value, str) or re.fullmatch(r'(?:0|[1-9][0-9]*)(?:\.[0-9]+)?', value) is None:
        raise ValueError('Cost must be a nonnegative decimal string or null')
    try:
        parsed = Decimal(value)
    except InvalidOperation as failure:
        raise ValueError('Invalid decimal cost') from failure
    if not parsed.is_finite():
        raise ValueError('Non-finite cost')
    return parsed


def decimal_total(values):
    """2026-11-01: 장부 소수 합계를 반올림하거나 미측정 0으로 바꾸지 않는다. 사용: summarize."""
    if not values:
        return None
    whole_lengths = (max(0, len(value.as_tuple().digits) + value.as_tuple().exponent) for value in values)
    whole = max(whole_lengths)
    fractional_lengths = (max(0, -value.as_tuple().exponent) for value in values)
    scale = max(fractional_lengths)
    with localcontext() as context:
        context.prec = whole + scale + len(str(len(values))) + 2
        total = sum(values, Decimal(0))
        return format(total, 'f')


def validate_record(row, requested):
    """2026-11-01: 시도·거래 참조·사용량·정산 상태의 모순을 거절한다. 사용: summarize."""
    if not isinstance(row, dict) or set(row) != FIELDS:
        raise ValueError('Unexpected or missing usage record fields')
    for key in ('requestId', 'attemptId'):
        if not isinstance(row[key], str) or not row[key].strip():
            raise ValueError('Missing request or attempt identifier')
    if not isinstance(row['state'], str) or row['state'] not in STATES or not isinstance(row['adopted'], bool):
        raise ValueError('Invalid attempt outcome')
    if row['adopted'] and row['state'] != 'succeeded':
        raise ValueError('Failed or incomplete attempt cannot be adopted')
    for key in ('inputTokens', 'outputTokens', 'latencyMs'):
        value = row[key]
        if value is not None and (type(value) is not int or value < 0):
            raise ValueError('Usage and latency must be nonnegative integers or null')
    if not isinstance(row['items'], list) or not row['items']:
        raise ValueError('Attempt must reference evaluation items')
    refs = []
    for item in row['items']:
        if not isinstance(item, dict) or set(item) != {'caseId', 'itemKey'}:
            raise ValueError('Invalid usage item reference')
        pair = (item['caseId'], item['itemKey'])
        if any(not isinstance(value, str) for value in pair) or pair not in requested:
            raise ValueError('Unknown usage item reference')
        refs.append(pair)
    if len(refs) != len(set(refs)):
        raise ValueError('Duplicate item in one attempt')
    settled, pending = decimal_cost(row['settledCostKRW']), decimal_cost(row['pendingCostKRW'])
    state = row['costState']
    if state == 'settled':
        if settled is None or pending is not None:
            raise ValueError('Settled cost requires only the settled amount')
    elif state == 'pending':
        if settled is not None:
            raise ValueError('Pending cost is not a settled amount')
    elif state == 'unknown':
        if settled is not None or pending is not None or row['costLedgerRef'] is not None:
            raise ValueError('Unknown cost cannot contain ledger amounts')
    else:
        raise ValueError('Unknown cost state')
    if state != 'unknown' and (not isinstance(row['costLedgerRef'], str) or not row['costLedgerRef'].strip()):
        raise ValueError('Recorded costs require a PAYSE ledger reference')
    return refs, settled, pending


def token_metrics(records, field):
    """2026-11-01: 확인된 소계와 전건 누락 여부를 함께 반환한다. 사용: summarize."""
    known = [row[field] for row in records if row[field] is not None]
    complete = bool(records) and len(known) == len(records)
    return {'total': sum(known) if complete else None,
            'knownSubtotal': sum(known) if known else None,
            'measuredRequests': len(known), 'missingRequests': len(records) - len(known)}


def summarize(inputs, records):
    """2026-11-01: 채택·실패와 무관하게 모든 시도의 비용·토큰을 합산한다. 사용: 평가 CLI/테스트.

시도 수는 최종 LLM 판단 거래 수와 다르다. 재시도는 같은 거래 참조를 반복할 수 있지만
requestId/attemptId는 각각 고유해야 한다. 총예산 잔액은 과거 장부 없이는 계산하지 않는다.
"""
    if not isinstance(records, list):
        raise ValueError('Usage records must be a list')
    requested = {(case_id, item['itemKey']) for case_id, payload in inputs.items() for item in payload['items']}
    request_ids, attempt_ids, item_attempts, adopted_items = set(), set(), Counter(), set()
    settled_costs, pending_costs = [], []
    for row in records:
        refs, settled, pending = validate_record(row, requested)
        if row['requestId'] in request_ids or row['attemptId'] in attempt_ids:
            raise ValueError('Duplicate request or attempt identifier')
        request_ids.add(row['requestId'])
        attempt_ids.add(row['attemptId'])
        if row['adopted']:
            if adopted_items.intersection(refs):
                raise ValueError('One evaluation item cannot adopt multiple attempts')
            adopted_items.update(refs)
        item_attempts.update(refs)
        if settled is not None:
            settled_costs.append(settled)
        if pending is not None:
            pending_costs.append(pending)
    costs = Counter(row['costState'] for row in records)
    latencies = [row['latencyMs'] for row in records if row['latencyMs'] is not None]
    all_settled = bool(records) and costs['settled'] == len(records)
    return {'measurementKind': 'recorded_attempt_usage', 'requestCount': len(records),
            'attemptCount': len(attempt_ids), 'uniqueEvaluationItems': len(item_attempts),
            'itemsWithMultipleAttempts': sum(count > 1 for count in item_attempts.values()),
            'attemptStates': dict(Counter(row['state'] for row in records)),
            'adoptedAttempts': sum(row['adopted'] for row in records),
            'unadoptedAttempts': sum(not row['adopted'] for row in records),
            'tokens': {'input': token_metrics(records, 'inputTokens'),
                       'output': token_metrics(records, 'outputTokens')},
            'cost': {'settledCostKRW': decimal_total(settled_costs),
                     'knownPendingCostKRW': decimal_total(pending_costs),
                     'totalCostKRW': decimal_total(settled_costs) if all_settled else None,
                     'allRequestsSettled': all_settled, 'settledRequests': costs['settled'],
                     'pendingRequests': costs['pending'], 'unknownCostRequests': costs['unknown'],
                     'pendingAmountMissingRequests': sum(row['costState'] == 'pending' and
                                                        row['pendingCostKRW'] is None for row in records)},
            'latency': {'measuredRequests': len(latencies), 'missingRequests': len(records) - len(latencies),
                        'sumKnownMs': sum(latencies) if latencies else None,
                        'meanMeasuredMs': sum(latencies) / len(latencies) if latencies else None,
                        'maximumMeasuredMs': max(latencies) if latencies else None},
            'budgetPolicy': {'totalBudgetKRW': '50000', 'newPaidCallCutoffKRW': '45000', 'marginKRW': '5000'},
            'globalBudgetRemainingKRW': None, 'providerSourceVerified': False, 'ledgerSourceVerified': False,
            'externalCalls': 0,
            'limits': '기록의 진위를 인증하지 않는다. 원화는 확인된 PAYSE 장부 금액이며 공급자 원화 응답이 아니다. '
                      '미정산 금액은 확정 비용이 아니고 과거 비용을 포함한 잔여 예산·호출 허용은 판정하지 않는다.'}
