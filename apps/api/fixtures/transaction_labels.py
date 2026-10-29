"""2026-10-28: 합성 원천의 거래명과 거래 방법을 따로 작성한다.

사용: generate, demo_cases. 원천 수집·분류 함수가 아니라 오프라인 작성 도구다.
인명은 가린 가상 이름, 상호·지점은 창작 이름이며 실거래 자료를 사용하지 않는다.
"""
from __future__ import annotations

SHOPS = (
    '별해울마트 모래별점', '소담결상점 달솔점', '나래온식품 물별점',
    '여울봄마켓 구름길점', '달무리생활 별나루점', '솔결식료품 노을숲점',
    '하루결장터 빛가람점', '다솜온마켓 달여울점', '새별결상점 은솔점',
    '모아결식품 해솔길점', '온새울생활 푸른별점', '별나래장터 바람솔점',
)
PEOPLE = ('소*연', '문*린', '서*온', '유*솔', '차*림', '노*하',
          '도*연', '연*우', '설*민', '진*율', '오*담', '류*빈')
SUBSCRIPTIONS = ('새온결플러스', '루미결음악', '달무리결서재')


def month_index(value):
    """2026-10-28: 명시한 작성 월로 표시값만 재현한다. 사용: display. 날짜 계산 API가 아니다."""
    year, month = map(int, value.split('-'))
    if not 1 <= month <= 12:
        raise ValueError('Invalid fixture label month')
    return year * 12 + month - 1


def display(key, alias):
    """2026-10-28: 안정된 작성 키에 대응하는 가상 거래명·적요를 반환한다. 사용: 생성 도구.

    금액·분류·잔액·급여 근거는 읽거나 변경하지 않는다. 미등록 키는 조용히
    종류 이름으로 대체하지 않고 실패시켜 작성자가 해당 사건을 확인하게 한다.
    """
    parts = key.split('/')
    kind = parts[0]
    if kind == 'salary' or kind in ('current-salary-part1', 'current-salary-part2'):
        return '주식회사별무리결', '급여'
    if kind == 'account-expense':
        account = int(parts[1])
        if account == 0:
            return '여울결통신', 'CMS'
        return SHOPS[(month_index(parts[2]) + account) % len(SHOPS)], '모바일이체'
    if kind == 'living':
        return PEOPLE[month_index(parts[1]) % len(PEOPLE)], '타행이체'
    if kind == 'rent-history':
        return '문*린', '자동이체'
    if kind == 'demo-ready' and parts[1] == 'rent':
        return '서*온', '자동이체'
    if kind == 'interest':
        return ('자유적금' if parts[1] == '1' else '정기예금') + ' 이자입금', '이자'
    if kind == 'card-purchase':
        card = int(parts[1])
        if card == 3:
            return SHOPS[month_index(parts[2]) % len(SHOPS)], '체크카드'
        return SUBSCRIPTIONS[card], '신용카드'
    if kind == 'debit-bank':
        return SHOPS[month_index(parts[1]) % len(SHOPS)], '체크카드'
    if kind == 'historical-card-payment':
        return f'카드납부 {int(parts[1]) + 1:04}', '자동이체'
    if kind == 'bill-payment':
        return '카드납부 0001', '자동이체'
    if kind == 'bill-purchase':
        return '모아결생활용품 별빛점', '신용카드'
    if kind == 'repair-partial':
        return '다솜결수리 별나루점', '모바일이체'
    if kind == 'shock-1':
        return '솔여울정비 다온점', '모바일이체'
    if kind in ('old-purchase', 'partial-refund'):
        return '나래결전자 별빛점', '카드환불' if kind == 'partial-refund' else '신용카드'
    if kind in ('cancelled-approval', 'cancellation'):
        return SUBSCRIPTIONS[0], '승인취소' if kind == 'cancellation' else '신용카드'
    if kind in ('internal-in', 'internal-out'):
        return {'alpha': '데**파', 'beta': '데**타', 'gamma': '데**마'}[alias], '계좌이체'
    if kind == 'card-return':
        name = {'cancel': '별온결생활 달솔점', 'full': '소담별문구 은솔점',
                'partial': '달여울잡화 노을점'}[parts[1].split('-')[0]]
        method = '신용카드' if parts[1].endswith('-purchase') else '승인취소' if parts[1] == 'cancel' else '카드환불'
        return name, method
    if kind == 'demo-edge':
        return {
            'appliance': ('나래결전자 별빛점', '신용카드'),
            'computer': ('여울결컴퓨터 달솔점', '신용카드'),
            'side-income': ('주식회사새온결디자인', '타행이체'),
            'medical': ('소담결의원 별나루점', '모바일이체'),
            'purchase-a': ('달해울편의점 은솔점', '모바일이체'),
            'purchase-b': ('달해울편의점 은솔점', '모바일이체'),
            # 감마의 공개 원천에는 대출/급여 정답을 넣지 않는다.
            'ambiguous-income': ('유*솔', '타행이체'),
        }[parts[1]]
    raise ValueError('Fixture transaction label is not defined')


def apply(snapshot):
    """2026-10-28: 복제된 환불·취소까지 작성 키로 표시값을 맞춘다. 사용: generate.build."""
    for collection in ('transactions', 'relatedTransactions'):
        for row in snapshot.get(collection, []):
            owner, key = row['sourceRef'].split('/transaction/', 1)
            alias = owner.removeprefix('fixture/')
            row['merchantName'], row['description'] = display(key, alias)
