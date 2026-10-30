"""2026-10-30: 데모알파 생활 흐름 사례(demo-life)를 demo-ready 결과에서 만든다(B 작성, docs/demo/realism/README.md §0).

사용: generate.build의 add_case('demo-life', ...). 규칙·고정 시드만 쓰며 LLM·외부 자료를 쓰지 않는다.
- 다른 자료(급여 근거·반복 승인 근거·정산·청구서·거래 관계)가 참조하는 거래는 금액·날짜·계좌·분류를 그대로 두고
  거래명·적요만 바꾼다. 그래서 홈 계산(B·E·R−O·U)과 근거 연결은 demo-ready와 같다.
- 참조되지 않는 기존 거래는 지우고 생활 흐름(급여·고정비·카드 사용·체크카드·이체·할부·환불·부분 환불·승인 취소)으로 채운다.
- 계좌 잔액은 그대로 두고, 조회 시작 잔액이 양수이고 날짜별 잔액이 0원 아래로 내려가지 않게 흐름을 맞춘다
  (docs/demo/realism/balance_check.py).
- 신용카드 대금은 전월 사용액 합계를 매월 10일 입출금 통장에서 낸다. 현대 신용카드 9월분은 기존 청구서(110,000원)와 같다.
- 실존 인물·상호는 쓰지 않는다(카드사 이름은 기존 카드 상품명을 따른다).
- v4 청구 항목은 만들지 않는다. billing_cases.upgrade가 다른 사례와 같은 규칙(값 미상 항목)으로 바꾼다.
"""
import calendar
import copy
import json
import random
from datetime import date, timedelta
from uuid import UUID, uuid5

NAMESPACE = UUID('bdc76ac7-c7c9-4a66-8b3d-7fd0ef7bdb6b')
SEED = 20261028
OWNER = '데**파'  # 합성 사용자 '데모알파'의 가린 이름. 본인 이체 양쪽에 쓴다
# 원천 버전 꼬리표: 거래 이력 2차(부분 환불·승인 취소 추가)
SOURCE_SUFFIX = ':life-2'

# 합성 할부 시나리오. 아래 값은 모두 작성자가 정한 합성 원천 값이며 구매일·총액에서 계산하지 않는다.
# 가구: 무이자 24개월 가정, 기준 시각 원문 회차 8. 노트북: 무이자 3개월 가정, 6/10 청구로 끝난 할부(원문 회차 3).
INSTALLMENTS = {
    'sofa/2026-02': {
        'day': date(2026, 2, 14), 'amountKRW': 720000, 'card': '우리 신용카드', 'name': '왕십리 새봄가구',
        'installmentCurrent': 8, 'installmentTotal': 24,
        'billedByMonth': {'2026-02': 30000, '2026-03': 30000, '2026-04': 30000, '2026-05': 30000, '2026-06': 30000,
                          '2026-07': 30000, '2026-08': 30000, '2026-09': 30000, '2026-10': 30000},
    },
    'laptop/2026-03': {
        'day': date(2026, 3, 8), 'amountKRW': 1200000, 'card': '삼성 신용카드', 'name': '하늘전자 성수점',
        'installmentCurrent': 3, 'installmentTotal': 3,
        'billedByMonth': {'2026-03': 400000, '2026-04': 400000, '2026-05': 400000},
    },
}

# 참조 거래(sourceRef 끝부분) → (거래명, 적요). 금액·날짜는 원본 그대로다.
ANCHOR_NAMES = [
    ('/salary/', ('하늘주식회사', '급여')),
    ('/demo-ready/rent/', ('박*영', '타행이체')),
    ('/account-expense/0/', ('하늘텔레콤', '자동이체')),
    ('/bill-payment', ('현대카드', '카드대금')),
    ('/bill-purchase', ('행당동 살림백화점', '일시불')),
    ('/card-purchase/0/', ('구름TV', '정기결제')),
    ('/card-purchase/3/', ('응봉 스포츠센터', '일시불')),
    ('/debit-bank/', ('응봉 스포츠센터', '체크카드승인')),
    ('/internal-in', (OWNER, '자동이체')),
    ('/internal-out', (OWNER, '자동이체')),
    ('/repair-partial', ('성수동 바른가전서비스', '타행이체')),
]

# 삼성 신용카드: 주로 쓰는 카드. (거래명 목록, 최소, 최대, 월 평균 횟수)
SAMSUNG_SPEND = [
    (['옥수역 구름커피', '금호동 달빛카페', '성수 모래알커피', '왕십리 오후세시카페'], 4500, 7800, 9),
    (['왕십리 정가네국밥', '성수동 하루식당', '옥수 소담분식', '행당 꼬마김밥', '금호 바다횟집'], 7000, 32000, 7),
    (['배달바다', '한그릇배달'], 15000, 34000, 3),
    (['구름마켓', '하늘쇼핑'], 9900, 59000, 3),
    (['모두택시'], 6800, 18500, 2),
    (['옥수 단정헤어', '금호 시네마 별관', '성수 책방온기'], 12000, 28000, 1),
]
# 국민 체크카드(생활비 통장): 장보기·생활
CHECK_SPEND = [
    (['옥수동 최고마트', '금호점 싱싱마트', '행당시장 알뜰상회', '성수동 푸른마트', '응봉동 새벽마트'], 8000, 68000, 6),
    (['왕십리 해오름정육점', '금남시장 소담반찬', '응봉동 새싹베이커리'], 6000, 32000, 3),
    (['금호 푸른약국', '옥수역 편의점 별빛24'], 2500, 15000, 3),
]
# 현대 신용카드: 구독 외 가끔 쓰는 카드(9월은 기존 청구서 그대로라 추가하지 않는다)
HYUNDAI_SPEND = [
    (['성수 맑은주유소', '옥수 밝은내과의원', '왕십리 튼튼치과'], 7500, 62000, 1),
]


def uid(key):
    return str(uuid5(NAMESPACE, 'payse-fixture-1/alpha/life/' + key))


def months(start, end):
    current = date(start.year, start.month, 1)
    while current <= end:
        yield current
        current = date(current.year + current.month // 12, current.month % 12 + 1, 1)


def on(month, day):
    return date(month.year, month.month, min(day, calendar.monthrange(month.year, month.month)[1]))


def won(rng, low, high, step=100):
    return rng.randrange(low // step, high // step + 1) * step


def build(snapshot):
    rng = random.Random(SEED)
    start = date.fromisoformat(snapshot['coverage'][0]['requestedStart'])
    today = date.fromisoformat(snapshot['asOf'][:10])
    accounts = {a['productName']: a['accountId'] for a in snapshot['accounts']}
    cards = {c['productName']: c['cardId'] for c in snapshot['cards']}
    main, saving, living, emergency, deposit = (accounts[n] for n in ('입출금 통장', '자유 적금', '생활비 통장', '비상금 통장', '정기예금'))
    hyundai, samsung, woori, check = (cards[n] for n in ('현대 신용카드', '삼성 신용카드', '우리 신용카드', '국민 체크카드'))
    template = snapshot['transactions'][0]
    base = {'userId': snapshot['userId'], 'sourceVersion': snapshot['sourceVersion']}

    others = json.dumps({k: v for k, v in snapshot.items() if k != 'transactions'})
    anchors = [t for t in snapshot['transactions'] if t['transactionId'] in others]
    for t in anchors:
        name, desc = next(v for k, v in ANCHOR_NAMES if k in t['sourceRef'])
        t['merchantName'], t['description'] = name, desc
    anchor_refs = {t['sourceRef'] for t in anchors}
    rows, relations = list(anchors), list(snapshot['transactionRelations'])

    def in_window(day):
        return start <= day <= today

    def account(key, day, amount, direction, account_id, name, desc, kind):
        row = {**{k: None for k in template}, **base,
               'sourceRef': 'fixture/alpha/transaction/life/' + key, 'transactionId': uid(key),
               'accountId': account_id, 'recordKind': 'account_entry', 'amountKRW': amount,
               'direction': direction, 'status': 'posted', 'merchantName': name, 'description': desc,
               'withdrawalDate': day.isoformat() if direction == 'out' else None, 'bookingDate': day.isoformat(),
               'balanceReflected': True, 'reflectionReason': 'reflected', 'payseTransactionType': kind}
        rows.append(row)
        return row

    def card(key, day, amount, card_id, name, desc, direction='out', kind='card_purchase', **extra):
        row = {**{k: None for k in template}, **base,
               'sourceRef': 'fixture/alpha/transaction/life/' + key, 'transactionId': uid(key),
               'cardId': card_id, 'recordKind': kind, 'amountKRW': amount, 'direction': direction,
               'status': 'posted', 'merchantName': name, 'description': desc,
               'purchaseDate': day.isoformat() if kind == 'card_purchase' else None,
               'refundDate': day.isoformat() if kind == 'card_refund' else None,
               'cancellationDate': day.isoformat() if kind == 'card_cancellation' else None,
               'reflectionReason': 'not_applicable', 'payseTransactionType': 'expense', **extra}
        rows.append(row)
        return row

    def transfer(key, day, amount, source, target, desc='모바일이체'):
        out = account(key + '/out', day, amount, 'out', source, OWNER, desc, 'internal_transfer')
        incoming = account(key + '/in', day, amount, 'in', target, OWNER, desc, 'internal_transfer')
        relations.append({'kind': 'internal_transfer', 'fromId': out['transactionId'],
                          'toId': incoming['transactionId'], 'evidenceRef': 'fixture-life-transfer/' + key})

    def spend(month, pools, card_id, prefix):
        for names, low, high, per_month in pools:
            for i in range(max(0, round(rng.gauss(per_month, per_month * 0.3)))):
                day = on(month, rng.randint(1, 31))
                if not in_window(day):
                    continue
                name = rng.choice(names)
                key = f'{prefix}/{month:%Y-%m}/{names[0]}/{i}'
                amount = won(rng, low, high)
                purchase = card(key, day, amount, card_id, name, '일시불')
                if card_id == check:
                    entry = account(key + '/bank', day, amount, 'out', living, name, '체크카드승인', 'expense')
                    relations.append({'kind': 'card_account_pair', 'fromId': purchase['transactionId'],
                                      'toId': entry['transactionId'], 'evidenceRef': 'fixture-life-debit/' + key})

    def has(fragment):
        return any(fragment in ref for ref in anchor_refs)

    for month in months(start, today):
        m = f'{month:%Y-%m}'
        # 수입
        if in_window(on(month, 25)) and not has(f'/salary/{m}'):
            account(f'salary/{m}', on(month, 25), 3000000, 'in', main, '하늘주식회사', '급여', 'income')
        if m == '2026-02':
            account('bonus/2026-02', on(month, 13), 500000, 'in', main, '하늘주식회사', '상여', 'income')
        if month.month in (3, 6, 9, 12) and in_window(on(month, 20)):
            account(f'interest/{m}', on(month, 20), won(rng, 300, 1800, 10), 'in', main, '결산이자', '이자', 'income')
        # 고정비(입출금 통장)
        if in_window(on(month, 22)) and not has(f'/rent/{m}'):
            account(f'rent/{m}', on(month, 22), 300000, 'out', main, '박*영', '타행이체', 'expense')
        if in_window(on(month, 15)) and not has(f'/account-expense/0/{m}'):
            account(f'telecom/{m}', on(month, 15), 50000, 'out', main, '하늘텔레콤', '자동이체', 'expense')
        if in_window(on(month, 27)):
            heating = 60000 if month.month in (12, 1, 2) else 0
            account(f'maintenance/{m}', on(month, 27), won(rng, 82000, 118000) + heating, 'out', main,
                    '좋은아파트관리사무소', 'CMS', 'expense')
        if in_window(on(month, 28)):
            account(f'student-loan/{m}', on(month, 28), 200000, 'out', main, '나라장학재단', 'CMS', 'expense')
        if in_window(on(month, 5)):
            account(f'insurance/{m}', on(month, 5), 45000, 'out', main, '든든생명', 'CMS', 'expense')
        # 이체
        if in_window(on(month, 26)):
            transfer(f'living/{m}', on(month, 26), 400000, main, living)
            account(f'invest/{m}', on(month, 26), 700000, 'out', main, '하늘증권', '타행이체', None)
            account(f'subscription-saving/{m}', on(month, 26), 100000, 'out', main, '하늘은행 주택청약', '타행이체', None)
            account(f'allowance/{m}', on(month, 26), 300000, 'out', main, '데*숙', '모바일이체', 'expense')
        if m in ('2026-08', '2026-09'):
            transfer(f'emergency/{m}', on(month, 26), 100000, main, emergency)
        if m == '2026-04':
            transfer('deposit/2026-04', on(month, 1), 1000000, main, deposit, '신규')
        if date(2026, 1, 1) <= month < date(2026, 10, 1):
            transfer(f'saving/{m}', on(month, 17), 50000, main, saving, '자동이체')
        # 가끔 있는 거래
        if rng.random() < 0.35 and in_window(on(month, 9)):
            account(f'atm/{m}', on(month, 9), rng.choice([30000, 50000, 100000]), 'out', main, '옥수역 ATM', 'ATM출금', 'expense')
        if rng.random() < 0.5 and in_window(on(month, 19)):
            name = rng.choice(['김*현', '이*준', '최*아', '정*우'])
            account(f'dutch/{m}', on(month, 19), won(rng, 8000, 36000, 1000), 'in', main, name, '모바일이체', None)
        # 카드 사용
        spend(month, SAMSUNG_SPEND, samsung, 'samsung')
        spend(month, CHECK_SPEND, check, 'check')
        if m != '2026-09':
            spend(month, HYUNDAI_SPEND, hyundai, 'hyundai')
            if in_window(on(month, 12)):
                card(f'hyundai-tv/{m}', on(month, 12), 10000, hyundai, '구름TV', '정기결제')
        transit = on(month, 3)
        if in_window(transit):
            card(f'transit/{m}', transit, won(rng, 48000, 71000), samsung, '바른교통 후불교통', '일시불')
        if in_window(on(month, 20)):
            card(f'ebook/{m}', on(month, 20), 9900, samsung, '책바다 전자책', '정기결제')

    # 할부: 구매 기록은 1건이고 회차마다 복제하지 않는다. 회차·카드대금 반영액은 INSTALLMENTS에 적은 합성 원천 값이다.
    for key, spec in INSTALLMENTS.items():
        card(key, spec['day'], spec['amountKRW'], cards[spec['card']], spec['name'], '할부',
             installmentCurrent=spec['installmentCurrent'], installmentTotal=spec['installmentTotal'])

    # 환불: 삼성 신용카드 옷 구매 후 반품
    coat = card('refund-origin/2026-06', date(2026, 6, 3), 89000, samsung, '성수 바람옷가게', '일시불')
    card('refund/2026-06', date(2026, 6, 7), 89000, samsung, '성수 바람옷가게', '환불', direction='in',
         kind='card_refund', originalTransactionId=coat['transactionId'])
    # 부분 환불: 삼성 신용카드 10/2 58,000원 구매 중 21,000원만 10/8 환불(이번 달이라 카드대금 전)
    order = card('partial-refund-origin/2026-10', date(2026, 10, 2), 58000, samsung, '하늘쇼핑', '일시불')
    card('partial-refund/2026-10', date(2026, 10, 8), 21000, samsung, '하늘쇼핑', '부분환불', direction='in',
         kind='card_refund', originalTransactionId=order['transactionId'])
    # 승인 취소: 삼성 신용카드 10/14 32,000원 승인을 10/15 10:30 취소. 원 승인은 status cancelled, 시각은 작성값
    held = card('cancel-origin/2026-10', date(2026, 10, 14), 32000, samsung, '구름마켓', '일시불', status='cancelled')
    card('cancel/2026-10', date(2026, 10, 15), 32000, samsung, '구름마켓', '승인취소', direction='in',
         kind='card_cancellation', status='cancelled', originalTransactionId=held['transactionId'],
         occurredAt='2026-10-15T10:30:00+09:00', occurredAtBasis='cancellation')

    # 신용카드 대금: 전월 사용액(환불 차감, 할부는 그 달 회차분)을 10일에 입출금 통장에서 낸다
    for month in months(start, today):
        due = on(month, 10)
        if not in_window(due):
            continue
        previous = on(month - timedelta(days=1), 1)
        for name, card_id in (('현대카드', hyundai), ('삼성카드', samsung), ('우리카드', woori)):
            if card_id == hyundai and f'{due:%Y-%m}' == '2026-10':
                continue  # 기존 청구서 출금(bill-payment) 그대로
            total = sum(billed_in(t, previous) for t in rows
                        if t['cardId'] == card_id and t['recordKind'] != 'account_entry')
            if total > 0:
                account(f'card-bill/{name}/{due:%Y-%m}', due, total, 'out', main, name, '카드대금', 'card_payment')

    for row in rows:
        row.setdefault('cancellationDate', None)  # #132 v3 선택 필드. 승인 취소가 아니면 null
    snapshot['transactions'] = sorted(rows, key=lambda t: t['transactionId'])
    snapshot['transactionRelations'] = relations
    return snapshot


def billed_in(t, period):
    """[period] 달 이용분으로 카드대금에 들어가는 데모 금액. 일시불은 이용한 달에 전액, 할부는 INSTALLMENTS의 명시 값이다.

    할부 금액을 총액÷개월로 계산하지 않는다(실제 자료 변환 규칙으로도 쓰지 않는다).
    """
    key = t['sourceRef'].removeprefix('fixture/alpha/transaction/life/')
    if key in INSTALLMENTS:
        return INSTALLMENTS[key]['billedByMonth'].get(f'{period:%Y-%m}', 0)
    day = date.fromisoformat(t['purchaseDate'] or t['refundDate'] or t['cancellationDate'])
    if (day.year, day.month) != (period.year, period.month):
        return 0
    return t['amountKRW'] if t['direction'] == 'out' else -t['amountKRW']


def bump_source_version(snapshot, suffix):
    """원본 원천 버전을 쓰는 모든 값(스냅샷·페이지·각 행)을 새 버전으로 바꾼다. 다른 버전 값(이전 원천에서 내린 반복 결정 등)은 그대로 둔다."""
    old = snapshot['sourceVersion']
    new = old + suffix

    def walk(value):
        if isinstance(value, dict):
            return {k: (new if k == 'sourceVersion' and v == old else walk(v)) for k, v in value.items()}
        if isinstance(value, list):
            return [walk(v) for v in value]
        return value
    return walk(snapshot)


def make_life_snapshot(demo_ready):
    """2026-10-30: demo-ready 결과로 demo-life 사례를 만든다. 입력은 바꾸지 않는다. 사용: generate.build."""
    return bump_source_version(build(copy.deepcopy(demo_ready)), SOURCE_SUFFIX)
