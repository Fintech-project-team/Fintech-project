"""2026-10-29: 서버·Fake·Flutter가 공유할 청구 항목 공개 규칙의 오프라인 참조 구현.

전체 Snapshot/HTTP 제공기나 인증 서비스가 아니다. 호출자는 인증 사용자와 기관 연결로
확정한 가시성 집합을 전달한다. 클라이언트 입력을 권한 집합으로 사용하면 안 된다.
sourceRef의 숨김 카드·거래·청구·항목 ID만 이 fragment에서 검사한다. 계좌 등 다른
모델의 ID·비밀·계좌 번호 노출 검사는 전체 Snapshot 조립부와 원천 adapter 책임이다.
"""
from copy import deepcopy

from statement_items import check_id as check_source_id, check_item, transaction_refs, validate_statement_items


SOURCE_SCHEMA = 'PAYSE-DRAFT-4'
API_SCHEMA = 'PAYSE-API-0.6-4'
RESTRICTIONS = {
    ('response', 'statements', 'card'),
    ('statement', 'includedTransactionRefs', 'transaction'),
    ('statementItem', 'transactionId', 'transaction'),
}


class BillingContractError(ValueError):
    """2026-10-29: 값·식별자를 노출하지 않는 공개 계약 실패. 사용: 이 모듈.

후속 HTTP 조립부는 원천·권한 근거 부족을 정상 빈 응답으로 바꾸지 않고 503으로 처리한다.
이 오프라인 예외 자체는 HTTP 응답을 보내지 않는다.
"""


def require(condition, message):
    """2026-10-29: 계약 전제 실패를 안전한 오류로 바꾼다. 사용: 청구 fragment 검증."""
    if not condition:
        raise BillingContractError(message)



def check_id(value):
    """2026-10-29: 공통 UUID 오류를 공개 계약 오류로 통일한다. 사용: 원천/공개 조각 검사."""
    try:
        check_source_id(value)
    except ValueError:
        raise BillingContractError('invalid billing identity') from None


def owned_rows(rows, id_key, owner, source_version):
    """2026-10-29: 전체 조회 근거의 단일 ID·소유권을 확인한다. 사용: project_statements."""
    require(isinstance(rows, list), 'billing evidence must be an array')
    indexed = {}
    for row in rows:
        require(isinstance(row, dict) and row.get('userId') == owner, 'billing evidence owner')
        require(row.get('sourceVersion') == source_version, 'billing evidence version')
        identity = row.get(id_key)
        check_id(identity)
        require(identity not in indexed, 'duplicate billing evidence')
        indexed[identity] = row
    return indexed


def restriction(owner_type, owner_id, field, target_kind):
    """2026-10-29: 숨겨진 대상의 ID·금액을 담지 않는 표식을 만든다. 사용: project_statements."""
    return {'ownerType': owner_type, 'ownerId': owner_id, 'field': field,
            'targetKind': target_kind, 'reason': 'not_connected'}


def validate_fragment(fragment):
    """2026-10-29: v4 청구 fragment의 형태·파생 참조·제한 표식을 검사한다. 사용: 투영·계약 검사.

전체 응답/페이지 조립 검사는 대체하지 않는다. 다음 페이지 참조의 실제 소유권은
투영 전에 전체 원천 근거로 확인하며 현재 페이지에 없다는 이유만으로 거절하지 않는다.
"""
    require(isinstance(fragment, dict) and set(fragment) == {
        'schemaVersion', 'statements', 'accessRestrictions'}, 'billing fragment keys')
    require(fragment['schemaVersion'] == API_SCHEMA, 'unsupported billing response schema')
    require(isinstance(fragment['statements'], list)
            and isinstance(fragment['accessRestrictions'], list), 'billing fragment arrays')
    statements, items, missing_links, source_refs = {}, {}, set(), set()
    for statement in fragment['statements']:
        require(isinstance(statement, dict), 'billing statement type')
        identity = statement.get('statementId')
        check_id(identity)
        check_id(statement.get('userId'))
        check_id(statement.get('cardId'))
        require(isinstance(statement.get('sourceVersion'), str)
                and bool(statement['sourceVersion'].strip()), 'public statement source version')
        require(identity not in statements, 'duplicate public statement')
        statements[identity] = statement
        require(isinstance(statement.get('items'), list), 'public statement items')
        refs = []
        for item in statement['items']:
            require(isinstance(item, dict), 'public statement item type')
            try:
                check_item(item, transaction_omitted='transactionId' not in item)
            except (KeyError, TypeError, ValueError):
                raise BillingContractError('invalid public billing item') from None
            require(item['userId'] == statement['userId']
                    and item['sourceVersion'] == statement['sourceVersion'],
                    'public billing item owner/version')
            require(item['sourceRef'] not in source_refs, 'duplicate public item source reference')
            source_refs.add(item['sourceRef'])
            item_id = item.get('itemId')
            check_id(item_id)
            require(item_id not in items, 'duplicate public statement item')
            items[item_id] = (identity, item)
            if 'transactionId' not in item:
                missing_links.add(item_id)
            elif item['transactionId'] is not None:
                check_id(item['transactionId'])
                refs.append(item['transactionId'])
        require(statement.get('includedTransactionRefs') == list(dict.fromkeys(refs)),
                'public statement references differ')
    tuples, item_marks, statement_marks = set(), set(), set()
    for mark in fragment['accessRestrictions']:
        require(isinstance(mark, dict) and set(mark) == {
            'ownerType', 'ownerId', 'field', 'targetKind', 'reason'}, 'billing restriction keys')
        require(all(isinstance(mark[key], str) for key in ('ownerType', 'field', 'targetKind', 'reason'))
                and (mark['ownerId'] is None or isinstance(mark['ownerId'], str)),
                'billing restriction types')
        registered = (mark['ownerType'], mark['field'], mark['targetKind'])
        require(registered in RESTRICTIONS and mark['reason'] == 'not_connected',
                'unregistered billing restriction')
        key = (mark['ownerType'], mark['ownerId'], mark['field'], mark['targetKind'], mark['reason'])
        require(key not in tuples, 'duplicate billing restriction')
        tuples.add(key)
        if mark['ownerType'] == 'response':
            require(mark['ownerId'] is None, 'billing root owner')
        elif mark['ownerType'] == 'statement':
            require(mark['ownerId'] in statements, 'billing restriction parent')
            statement_marks.add(mark['ownerId'])
        else:
            require(mark['ownerId'] in missing_links, 'billing restriction item')
            item_marks.add(mark['ownerId'])
    require(item_marks == missing_links, 'missing billing item restriction')
    require(statement_marks == {items[item_id][0] for item_id in missing_links},
            'missing billing statement restriction')


def project_statements(source, visible_card_ids, visible_transaction_ids, page_transaction_ids=()):
    """2026-10-29: v4 청구·항목만 공개 투영하고 원천과 계산 입력을 수정하지 않는다.

    사용: test_billing_projection; 후속 서버·Fake·Flutter 구현의 검증 기준.
    visible_*는 인증·기관 연결로 검증한 전체 권한 집합이며 페이지 집합이 아니다.
    조회 범위 안의 다음 페이지 거래는 ID를 유지하고 relatedTransactions나
    referenceResolutions에 가짜 미확보/복사본을 생성하지 않는다.
    """
    require(isinstance(source, dict) and source.get('schemaVersion') == SOURCE_SCHEMA,
            'unsupported billing source schema')
    owner = source.get('userId')
    check_id(owner)
    source_version = source.get('sourceVersion')
    require(isinstance(source_version, str) and bool(source_version.strip()), 'billing source version')
    cards = owned_rows(source.get('cards'), 'cardId', owner, source_version)
    primary, related = source.get('transactions', []), source.get('relatedTransactions', [])
    require(isinstance(primary, list) and isinstance(related, list), 'billing transaction evidence arrays')
    transactions = owned_rows(primary + related, 'transactionId', owner, source_version)
    statements = owned_rows(source.get('statements'), 'statementId', owner, source_version)
    visible_cards, visible_transactions, page_transactions = (
        set(visible_card_ids), set(visible_transaction_ids), set(page_transaction_ids))
    require(visible_cards <= cards.keys() and visible_transactions <= transactions.keys(),
            'billing visibility lacks source evidence')
    require(page_transactions <= visible_transactions, 'billing page outside visibility')
    for statement in statements.values():
        require(statement.get('cardId') in cards, 'billing statement card evidence')
        require(isinstance(statement.get('sourceRef'), str) and bool(statement['sourceRef'].strip()),
                'billing statement source reference')
    try:
        validate_statement_items(list(statements.values()), transactions, owner, source.get('sourceVersion'))
    except (KeyError, TypeError, ValueError):
        raise BillingContractError('invalid billing item source') from None
    hidden_ids = (cards.keys() - visible_cards) | (transactions.keys() - visible_transactions)
    for statement in statements.values():
        if statement['cardId'] not in visible_cards:
            hidden_ids.add(statement['statementId'])
            hidden_ids.update(item['itemId'] for item in statement['items'])
    output, marks = [], []
    hidden_statements = False
    for statement in statements.values():
        if statement['cardId'] not in visible_cards:
            hidden_statements = True
            continue
        public = deepcopy(statement)
        restricted = False
        for item in public['items']:
            target = item['transactionId']
            if target is not None and target not in visible_transactions:
                del item['transactionId']
                restricted = True
                marks.append(restriction('statementItem', item['itemId'], 'transactionId', 'transaction'))
        public['includedTransactionRefs'] = transaction_refs([
            {**item, 'transactionId': item.get('transactionId')} for item in public['items']])
        if restricted:
            marks.append(restriction('statement', public['statementId'], 'includedTransactionRefs', 'transaction'))
        for row in [public, *public['items']]:
            require(not any(identity in row['sourceRef'] for identity in hidden_ids),
                    'billing source reference contains hidden identity')
        output.append(public)
    if hidden_statements:
        marks.append(restriction('response', None, 'statements', 'card'))
    fragment = {'schemaVersion': API_SCHEMA, 'statements': output, 'accessRestrictions': marks}
    validate_fragment(fragment)
    return fragment
