"""2026-10-29: 청구 항목의 원천 계약·구 연결 식별자를 검증한다.

사용: v4 준비 도구, fixture 검증기, 일반 금융 SQL 내보내기.
금액·할부 회차를 산출하거나 공개 응답의 권한 검증을 대신하지 않는다.
"""
from datetime import date
import hashlib
import re
from uuid import UUID


LIMIT = 9_000_000_000_000
ITEM_KEYS = {
    'itemId', 'userId', 'sourceRef', 'sourceVersion', 'transactionId',
    'label', 'merchantName', 'purchaseDate', 'originalUsedAmountKRW',
    'billedPrincipalKRW', 'feeOrAdjustmentAmountKRW', 'billedAmountKRW',
    'installmentMonths', 'installmentRound',
}
NULL_FIELDS = ITEM_KEYS - {
    'itemId', 'userId', 'sourceRef', 'sourceVersion', 'transactionId',
}


def require(condition, message):
    """2026-10-29: 원천을 고치지 않고 계약 오류를 값 없는 메시지로 거절한다. 사용: 이 모듈."""
    if not condition:
        raise ValueError(message)


def check_id(value):
    """2026-10-29: 정규 UUID만 허용한다. 사용: 구 식별자 생성·청구 항목 검증."""
    require(isinstance(value, str), 'statement item UUID type')
    try:
        canonical = str(UUID(value))
    except (ValueError, AttributeError):
        raise ValueError('statement item UUID format') from None
    require(canonical == value, 'statement item UUID format')


def legacy_item_id(user_id, statement_id, transaction_id):
    """2026-10-29: 구 PK 관계에서 동일한 새 ID를 재현한다. 사용: 이행·v3 적재·v4 준비.

    MD5는 비밀 보호·인증 해시가 아닌 기존 관계의 결정적 식별 변환이다.
    날짜·금액·표시명·배열 위치는 사용하지 않는다.
    """
    for value in (user_id, statement_id, transaction_id):
        check_id(value)
    key = f'payse:statement-item:{user_id}:{statement_id}:{transaction_id}'
    return str(UUID(hashlib.md5(key.encode('utf-8'), usedforsecurity=False).hexdigest()))


def legacy_items(statement):
    """2026-10-29: 구 참조를 값 미상의 항목으로 명시 변환한다. 사용: v4 준비·SQL 내보내기."""
    owner = statement['userId']
    statement_id = statement['statementId']
    refs = statement['includedTransactionRefs']
    require(isinstance(refs, list), 'legacy statement references')
    for transaction_id in refs:
        check_id(transaction_id)
    require(len(refs) == len(set(refs)), 'legacy statement references')
    items = []
    for transaction_id in refs:
        item_id = legacy_item_id(owner, statement_id, transaction_id)
        items.append({
            'itemId': item_id,
            'userId': owner,
            'sourceRef': f'legacy-statement-item/{item_id}',
            'sourceVersion': statement['sourceVersion'],
            'transactionId': transaction_id,
            **{field: None for field in sorted(NULL_FIELDS)},
        })
    return items


def transaction_refs(items):
    """2026-10-29: 첫 출현 순서로 거래 ID를 중복 제거한다. 사용: v4 준비·검증·응답 조립 계약."""
    return list(dict.fromkeys(item['transactionId'] for item in items if item['transactionId'] is not None))


def check_amount(value, signed=False):
    """2026-10-29: 미상과 0을 구분하고 원화 정수 범위만 검사한다. 사용: 항목 검증."""
    if value is not None:
        require(type(value) is int and (-LIMIT if signed else 0) <= value <= LIMIT,
                'statement item money')


def check_purchase_date(value):
    """2026-10-29: 확인된 이용일 형식을 검사하고 미상을 유지한다. 사용: 항목 검증."""
    if value is None:
        return
    require(isinstance(value, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}', value),
            'statement item purchase date')
    try:
        date.fromisoformat(value)
    except ValueError:
        raise ValueError('statement item purchase date') from None


def check_item(item, transaction_omitted=False):
    """2026-10-29: 원천·공개 항목의 공통 필드 형식을 검사한다. 사용: 항목 검증·공개 투영.

    transaction_omitted=True는 호출자가 적합한 접근 제한 표식을 확인한 경우에만 쓴다.
    여기서는 생략 형태만 검사하며 소유권·부모·공개 권한을 확정하지 않는다.
    """
    require(type(transaction_omitted) is bool, 'statement item omission mode')
    expected_keys = ITEM_KEYS - {'transactionId'} if transaction_omitted else ITEM_KEYS
    require(isinstance(item, dict) and set(item) == expected_keys, 'statement item keys')
    check_id(item['itemId'])
    check_id(item['userId'])
    require(isinstance(item['sourceRef'], str) and bool(item['sourceRef'].strip()),
            'statement item sourceRef')
    require(isinstance(item['sourceVersion'], str) and bool(item['sourceVersion'].strip()),
            'statement item source version')
    if not transaction_omitted and item['transactionId'] is not None:
        check_id(item['transactionId'])
    for key in ('label', 'merchantName'):
        require(item[key] is None or isinstance(item[key], str), 'statement item text')
    check_purchase_date(item['purchaseDate'])
    for key in ('originalUsedAmountKRW', 'billedPrincipalKRW'):
        check_amount(item[key])
    for key in ('feeOrAdjustmentAmountKRW', 'billedAmountKRW'):
        check_amount(item[key], signed=True)
    months, round_no = item['installmentMonths'], item['installmentRound']
    for value in (months, round_no):
        require(value is None or type(value) is int and 0 < value <= 2_147_483_647,
                'statement item installment count')
    require(months is None or round_no is None or round_no <= months,
            'statement item installment order')


def validate_statement_items(statements, transactions, owner, source_version):
    """2026-10-29: v4 항목·부모·거래 관계를 검증한다. 사용: validate.validate_snapshot.

    같은 거래가 여러 항목·청구에 연결될 수 있다. 항목 ID/원천 키는 중복 불가다.
    금액 누락·차이는 원천으로 보존하고 총액·원금·조정액을 계산해 채우지 않는다.
    """
    check_id(owner)
    require(isinstance(source_version, str) and bool(source_version.strip()), 'statement item source version')
    identities, source_refs = set(), set()
    for statement in statements:
        require(statement['userId'] == owner and statement['sourceVersion'] == source_version,
                'statement item parent owner/version')
        require(isinstance(statement.get('items'), list), 'statement items required')
        for item in statement['items']:
            check_item(item)
            require(item['itemId'] not in identities, 'duplicate statement item ID')
            identities.add(item['itemId'])
            require(item['userId'] == owner and item['sourceVersion'] == source_version,
                    'statement item owner/version')
            source_ref = item['sourceRef']
            require(source_ref not in source_refs, 'duplicate statement item sourceRef')
            source_refs.add(source_ref)
            transaction_id = item['transactionId']
            if transaction_id is not None:
                require(transaction_id in transactions, 'statement item transaction unavailable')
                transaction = transactions[transaction_id]
                require(transaction['userId'] == owner and transaction['cardId'] == statement['cardId'],
                        'statement item foreign transaction/card')
        require(statement['includedTransactionRefs'] == transaction_refs(statement['items']),
                'statement item references differ')
