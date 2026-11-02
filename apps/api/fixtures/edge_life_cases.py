"""2026-11-02: 데모베타·데모감마 생활 흐름 사례(beta-life·gamma-life)를 만든다(B 작성, docs/demo/realism/README.md §0).

사용: generate.build의 add_case. 규칙·고정 시드만 쓰며 LLM·외부 자료를 쓰지 않는다.
- 기준 시각은 2026-11-05 12:00(시연일). 계정 골격(사용자·기관·계좌·카드 ID)은 make_snapshot 결과를 쓰고,
  거래·관계·청구·계획은 사람마다 새로 만든다. 알파(demo-life)와 거래명·생활권·금액이 겹치지 않는다.
- 베타는 비정기 현금 흐름, 감마는 급여 회차 해석이 어려운 거래를 1년 생활 흐름 안에 넣는다
  (docs/edgecase/베타_감마_데모_엣지케이스_초안.md의 B·G 사례).
- 사례의 실제 사정(정답 라벨)은 catalog expected에만 두며 거래 표시값·적요에 넣지 않는다.
- 계좌 잔액은 조회 시작 잔액(작성값)에 거래를 더해 정한다. 그래서 거래와 잔액이 맞고 날짜별 잔액이 0원 아래로 내려가지 않는다.
- 월급 확인 기록: 베타는 9·10월 회차 모두 확인(10월은 B02 세 건 중 급여 한 건), 감마는 9월만 확인하고 이번 회차(10월)는
  확인 전으로 둔다(G14, 월급 미입금). 앱에는 아직 회차 확인을 저장하는 기능이 없어 데이터로 정한다. 예정 지출·반복 계획은 넣지 않는다.
"""
import copy
import random
from datetime import date, timedelta
from uuid import UUID, uuid5

from life_cases import months, on, won

NAMESPACE = UUID('bdc76ac7-c7c9-4a66-8b3d-7fd0ef7bdb6b')
AS_OF = '2026-11-05T12:00:00+09:00'
SOURCE_SUFFIX = ':life-1'
EMPTY = ('statements', 'obligations', 'reserves', 'allocations', 'settlements', 'recurringPlans',
         'recurringDecisions', 'recurringPlanRevisions', 'occurrenceOverrides', 'relatedTransactions',
         'referenceResolutions', 'occurrenceLinks')


def payday(month, day):
    """월급일이 주말이면 앞 금요일로 당긴다(합성 규칙)."""
    target = on(month, day)
    while target.weekday() >= 5:
        target -= timedelta(days=1)
    return target


class Ledger:
    """한 사람의 합성 거래를 쌓는다. ID·sourceRef는 사람 별칭과 키에서 정해진다."""

    def __init__(self, snapshot, alias, owner, seed):
        self.s, self.alias, self.owner = snapshot, alias, owner
        self.rng = random.Random(seed)
        self.start = date.fromisoformat(snapshot['coverage'][0]['requestedStart'])
        self.today = date.fromisoformat(snapshot['asOf'][:10])
        self.rows, self.relations, self.labels = [], [], []
        self.base = {'userId': snapshot['userId'], 'sourceVersion': snapshot['sourceVersion']}
        self.blank = {k: None for k in ('accountId', 'cardId', 'recordKind', 'amountKRW', 'direction', 'status',
                                        'merchantName', 'description', 'purchaseDate', 'withdrawalDate',
                                        'refundDate', 'bookingDate', 'cancellationDate', 'occurredAt',
                                        'occurredAtBasis', 'balanceReflected', 'reflectionReason',
                                        'originalTransactionId', 'payseTransactionType', 'installmentCurrent',
                                        'installmentTotal')}

    def uid(self, key):
        return str(uuid5(NAMESPACE, f'payse-fixture-1/{self.alias}/life/{key}'))

    def inside(self, day):
        return self.start <= day <= self.today

    def account(self, key, day, amount, direction, account_id, name, desc, kind):
        if not self.inside(day):
            return None
        row = {**self.blank, **self.base, 'sourceRef': f'fixture/{self.alias}/transaction/life/{key}',
               'transactionId': self.uid(key), 'accountId': account_id, 'recordKind': 'account_entry',
               'amountKRW': amount, 'direction': direction, 'status': 'posted', 'merchantName': name,
               'description': desc, 'withdrawalDate': day.isoformat() if direction == 'out' else None,
               'bookingDate': day.isoformat(), 'balanceReflected': True, 'reflectionReason': 'reflected',
               'payseTransactionType': kind}
        self.rows.append(row)
        return row

    def card(self, key, day, amount, card_id, name, desc, direction='out', kind='card_purchase', **extra):
        if not self.inside(day):
            return None
        row = {**self.blank, **self.base, 'sourceRef': f'fixture/{self.alias}/transaction/life/{key}',
               'transactionId': self.uid(key), 'cardId': card_id, 'recordKind': kind, 'amountKRW': amount,
               'direction': direction, 'status': 'posted', 'merchantName': name, 'description': desc,
               'purchaseDate': day.isoformat() if kind == 'card_purchase' else None,
               'refundDate': day.isoformat() if kind == 'card_refund' else None,
               'cancellationDate': day.isoformat() if kind == 'card_cancellation' else None,
               'reflectionReason': 'not_applicable', 'payseTransactionType': 'expense', **extra}
        self.rows.append(row)
        return row

    def transfer(self, key, day, amount, source, target, desc='모바일이체'):
        out = self.account(key + '/out', day, amount, 'out', source, self.owner, desc, 'internal_transfer')
        incoming = self.account(key + '/in', day, amount, 'in', target, self.owner, desc, 'internal_transfer')
        if out and incoming:
            self.relations.append({'kind': 'internal_transfer', 'fromId': out['transactionId'],
                                   'toId': incoming['transactionId'], 'evidenceRef': f'fixture-life-transfer/{key}'})
        return out, incoming

    def debit(self, key, day, amount, card_id, account_id, name):
        """체크카드 사용 1건과 연결 계좌 출금 1건을 같은 날·같은 금액으로 만들고 card_account_pair로 잇는다."""
        purchase = self.card(key, day, amount, card_id, name, '일시불')
        entry = self.account(key + '/bank', day, amount, 'out', account_id, name, '체크카드승인', 'expense')
        if purchase and entry:
            self.relations.append({'kind': 'card_account_pair', 'fromId': purchase['transactionId'],
                                   'toId': entry['transactionId'], 'evidenceRef': f'fixture-life-debit/{key}'})
        return purchase, entry

    def spend(self, month, pools, prefix, make):
        for names, low, high, per_month in pools:
            for i in range(max(0, round(self.rng.gauss(per_month, per_month * 0.3)))):
                day = on(month, self.rng.randint(1, 31))
                if self.inside(day):
                    make(f'{prefix}/{month:%Y-%m}/{names[0]}/{i}', day, won(self.rng, low, high),
                         self.rng.choice(names))

    def label(self, case_id, rows, truth):
        """정답 라벨(평가용). 공개 거래에는 넣지 않고 catalog expected로만 내보낸다."""
        ids = [r['transactionId'] for r in rows if r]
        for entry in self.labels:
            if entry['id'] == case_id:
                entry['transactionIds'] += ids
                return
        self.labels.append({'id': case_id, 'transactionIds': ids, 'truth': truth})

    def card_bills(self, due_day, main, names, overrides=()):
        """신용카드 대금: 전월 사용액(환불·취소 차감)을 due_day에 주거래 계좌에서 낸다. overrides의 달은 따로 만든다."""
        skip = {(card_id, month) for card_id, month in overrides}
        for month in months(self.start, self.today):
            due = on(month, due_day)
            previous = on(month - timedelta(days=1), 1)
            for card_id, name in names.items():
                if (card_id, f'{due:%Y-%m}') in skip or not self.inside(due):
                    continue
                total = self.usage(card_id, previous)
                if total > 0:
                    self.account(f'card-bill/{card_id[:8]}/{due:%Y-%m}', due, total, 'out', main, name, '카드대금',
                                 'card_payment')

    def usage(self, card_id, period):
        total = 0
        for t in self.rows:
            if t['cardId'] != card_id or t['recordKind'] == 'account_entry':
                continue
            day = date.fromisoformat(t['purchaseDate'] or t['refundDate'] or t['cancellationDate'])
            if (day.year, day.month) == (period.year, period.month):
                total += t['amountKRW'] if t['direction'] == 'out' else -t['amountKRW']
        return total

    def finish(self, openings, product_names, included, salary, confirmed):
        """잔액을 조회 시작 잔액+거래로 정하고 빈 컬렉션·월급 설정을 채운다. 날짜별 잔액이 음수면 실패한다.

        [confirmed]는 이미 확인된 지난 회차 (payMonth, 예정일, 거래 행)이다. 이번 회차는 넣지 않아 확인 전 상태로 둔다.
        """
        s = self.s
        for collection in EMPTY:
            s[collection] = []
        s['transactions'] = sorted(self.rows, key=lambda t: t['transactionId'])
        s['transactionRelations'] = self.relations
        for account in s['accounts']:
            name = account['productName']
            moves = sorted((t['bookingDate'], t['direction'] != 'in',
                            t['amountKRW'] if t['direction'] == 'in' else -t['amountKRW'])
                           for t in self.rows if t['accountId'] == account['accountId'])
            running = openings[name]
            for _, _, signed in moves:
                running += signed
                if running < 0:
                    raise ValueError(f'{self.alias} {name} 잔액이 음수가 됨')
            account['balanceKRW'] = running
            account['included'] = name in included
            account['productName'] = product_names.get(name, name)
        evidence = [{'payMonth': month, 'expectedPayDate': expected, 'transactionIds': [row['transactionId']],
                     'confirmation': 'confirmed'} for month, expected, row in confirmed]
        s['settings'] = {'salary': {**salary, 'receiptEvidence': evidence}, 'cardPlans': []}
        return s


def ids(snapshot):
    accounts = {a['productName']: a['accountId'] for a in snapshot['accounts']}
    cards = {c['productName']: c['cardId'] for c in snapshot['cards']}
    return accounts, cards


# ---------------------------------------------------------------- 베타: 망원·합정·연남, 회사원 + 디자인 부업
BETA_OWNER = '데**타'
BETA_SAMSUNG = [
    (['망원 모래알로스터리', '합정 오월의커피', '연남 소금빵공방', '서교 바람다방'], 4800, 8900, 10),
    (['망원시장 진미국수', '합정 노을쌀국수', '연남 뜰안식당', '서교 한우리백반', '망원 돈까스바다'], 8000, 26000, 7),
    (['노을배달', '바람식탁'], 16000, 38000, 4),
    (['모래쇼핑', '들판마켓'], 12000, 68000, 3),
    (['노을택시'], 7200, 21000, 2),
    (['합정 그림재료상', '연남 활자서점', '망원 필름사진관'], 9000, 45000, 2),
]
BETA_CHECK = [
    (['망원 알뜰마트', '합정 새벽식자재', '망원시장 바다수산', '연남 초록채소'], 6000, 58000, 6),
    (['서교 노을약국', '망원역 편의점 모퉁이24'], 2200, 14000, 3),
]
BETA_HYUNDAI = [(['합정 맑은주유소', '망원 하늘치과의원', '서교 정다운이비인후과'], 9000, 72000, 1)]


def make_beta_life(beta):
    """데모베타(beta-life): 월급 25일·3,120,000원 예상, 급여 통장과 생활비 통장. 비정기 입출금 B01~B14를 담는다."""
    s = copy.deepcopy(beta)
    accounts, cards = ids(s)
    main, saving, living, emergency = (accounts[n] for n in ('입출금 통장', '자유 적금', '생활비 통장', '비상금 통장'))
    hyundai, samsung, woori, check = (cards[n] for n in ('현대 신용카드', '삼성 신용카드', '우리 신용카드', '국민 체크카드'))
    L = Ledger(s, 'beta', BETA_OWNER, 20261102)
    company = '주식회사노을빛'
    for month in months(L.start, L.today):
        m = f'{month:%Y-%m}'
        pay = payday(month, 25)
        # 급여: 10월은 B02(3건), 7월은 B03(600만 원 한 건), 9월은 B09(입금 직후 적금 이체)
        if m == '2026-10':
            october = L.account('salary/2026-10', pay, 3084620, 'in', main, company, '급여', 'income')
            L.label('B02', [october,
                            L.account('expense-refund/2026-10', pay, 187400, 'in', main, company, '이체', 'income'),
                            L.account('bonus/2026-10', pay, 1000000, 'in', main, company, '상여', 'income')],
                    '같은 회사 입금 3건: 급여 3,084,620·경비 정산 187,400·상여 1,000,000. 급여 회차는 첫 거래만')
        elif m == '2026-07':
            L.label('B03', [L.account('lump/2026-07', pay, 6000000, 'in', main, '입금', None, 'income')],
                    '급여 3,120,000과 일시금 2,880,000이 합쳐진 한 건. 입력만으로 분해 불가')
        elif m < '2026-11':
            row = L.account(f'salary/{m}', pay, 3120000, 'in', main, company, '급여', 'income')
            if m == '2026-09':
                september = row
                out, incoming = L.transfer('salary-to-saving/2026-09', pay, 1000000, main, saving, '자동이체')
                L.label('B09', [row, out, incoming], '급여 직후 본인 적금 계좌로 1,000,000 이체(양쪽 연결)')
        # 부업 입금(디자인 외주): 비정기
        if m in ('2026-02', '2026-05'):
            L.account(f'freelance/{m}', on(month, 11), {'2026-02': 520000, '2026-05': 640000}[m], 'in', main,
                      '스튜디오모래', '타행이체', 'income')
        # 월세: 7월까지 옛집 550,000, 8·9월 600,000, 10월 650,000, 11/3 미출금(B07)
        if m <= '2026-07':
            L.account(f'rent/{m}', on(month, 3), 550000, 'out', main, '한*수', '타행이체', 'expense')
        elif m in ('2026-08', '2026-09', '2026-10'):
            row = L.account(f'rent/{m}', on(month, 3), 650000 if m == '2026-10' else 600000, 'out', main, '오*진',
                            '타행이체', 'expense')
            L.label('B07', [row], '8월 이사 후 새 월세. 10월 금액 변경, 11월 3일 출금 없음')
        # 통신요금(B11): 매달 금액이 조금씩 다르다
        if m < '2026-11':
            amount = {'2026-08': 51320, '2026-09': 52840, '2026-10': 50970}.get(m, won(L.rng, 49000, 54000, 10))
            row = L.account(f'telecom/{m}', on(month, 21), amount, 'out', main, '바람통신', '통신요금', 'expense')
            if m >= '2026-08':
                L.label('B11', [row], '같은 통신 요금. 금액이 매달 다름')
        # 구독(B12): 매달 14,900, 10월은 같은 표시값 2건(가족 계정 별도 구독)
        if m < '2026-11':
            rows = [L.account(f'stream/{m}', on(month, 9), 14900, 'out', main, '구름플레이', 'CMS', 'expense')]
            if m == '2026-10':
                rows.append(L.account('stream-family/2026-10', on(month, 9), 14900, 'out', main, '구름플레이', 'CMS',
                                      'expense'))
                L.label('B12', rows, '개인 구독과 가족 구독 2건(중복 아님)')
        # 보험·관리비·생활비 이체·적금
        L.account(f'insurance/{m}', on(month, 7), 63000, 'out', main, '든든손해보험', 'CMS', 'expense')
        if m >= '2026-08':
            L.account(f'maintenance/{m}', on(month, 28), won(L.rng, 70000, 96000), 'out', main, '망원빌라관리',
                      '타행이체', 'expense')
        L.transfer(f'living/{m}', on(month, 26), 330000, main, living)
        L.account(f'invest/{m}', on(month, 26), 900000, 'out', main, '노을증권', '타행이체', None)
        L.account(f'housing-saving/{m}', on(month, 26), 100000, 'out', main, '바람은행 주택청약', '타행이체', None)
        L.account(f'allowance/{m}', on(month, 26), 300000, 'out', main, '데*순', '모바일이체', 'expense')
        L.account(f'student-loan/{m}', on(month, 28), 150000, 'out', main, '모래장학재단', 'CMS', 'expense')
        if m == '2026-08':
            L.transfer('deposit/2026-08', on(month, 1), 2000000, main, accounts['정기예금'], '신규')
        if m not in ('2026-09',):
            L.transfer(f'saving/{m}', on(month, 27), 150000, main, saving, '자동이체')
        # 카드 사용
        L.spend(month, BETA_SAMSUNG, 'samsung', lambda k, d, a, n: L.card(k, d, a, samsung, n, '일시불'))
        L.spend(month, BETA_CHECK, 'check', lambda k, d, a, n: L.debit(k, d, a, check, living, n))
        L.spend(month, BETA_HYUNDAI, 'hyundai', lambda k, d, a, n: L.card(k, d, a, hyundai, n, '일시불'))
        L.card(f'transit/{m}', on(month, 4), won(L.rng, 52000, 76000), samsung, '노을교통 후불교통', '일시불')
        L.card(f'font/{m}', on(month, 18), 16500, samsung, '모래폰트 구독', '정기결제')

    # B01 10/10 부업 입금
    L.label('B01', [L.account('freelance/2026-10', date(2026, 10, 10), 785000, 'in', main, '스튜디오모래', '타행이체',
                              'income')], '디자인 외주 대금(부수입). 반복 월급 아님')
    # B04 10/15 가족 입금 → 10/20 본인 비상금 통장으로 이체
    family = L.account('family/2026-10', date(2026, 10, 15), 1000000, 'in', main, '데*순', '모바일이체', None)
    out, incoming = L.transfer('to-emergency/2026-10', date(2026, 10, 20), 1000000, main, emergency)
    L.label('B04', [family, out, incoming], '어머니가 보낸 돈을 본인 비상금 통장으로 옮김. 소득·지출 아님')
    # B05 10/8 소비 398,600 → 10/12 298,600, 10/18 100,000 환불
    sofa = L.card('return-origin/2026-10', date(2026, 10, 8), 398600, samsung, '합정 리빙스토어', '일시불')
    L.label('B05', [sofa,
                    L.card('return-1/2026-10', date(2026, 10, 12), 298600, samsung, '합정 리빙스토어', '부분환불',
                           direction='in', kind='card_refund', originalTransactionId=sofa['transactionId']),
                    L.card('return-2/2026-10', date(2026, 10, 18), 100000, samsung, '합정 리빙스토어', '환불',
                           direction='in', kind='card_refund', originalTransactionId=sofa['transactionId'])],
            '같은 구매의 두 번 나눈 전액 환불')
    # B06 10/12 병원비 출금 → 10/21 보험금
    clinic = L.account('clinic/2026-10', date(2026, 10, 12), 687400, 'out', main, '망원 바른정형외과', '타행이체',
                       'expense')
    L.label('B06', [clinic, L.account('insurance-claim/2026-10', date(2026, 10, 21), 392600, 'in', main,
                                       '든든손해보험', '보험금', None)], '병원비와 실손 보험금. 같은 사건인지 거래만으로 모름')
    # B08 우리 신용카드 9/14 한 번 사용 → 10/10 카드대금 298,600(그 청구의 유일한 이용)
    audio = L.card('audio/2026-09', date(2026, 9, 14), 298600, woori, '연남 소리상점', '일시불')
    # B10 10/3 식사 86,400 → 다음 날 친구 정산 28,000·30,000
    dinner = L.card('dinner/2026-10', date(2026, 10, 3), 86400, samsung, '연남 화로구이', '일시불')
    L.label('B10', [dinner,
                    L.account('dutch-1/2026-10', date(2026, 10, 4), 28000, 'in', main, '김*솔', '모바일이체', None),
                    L.account('dutch-2/2026-10', date(2026, 10, 4), 30000, 'in', main, '박*윤', '모바일이체', None)],
            '친구들의 식사비 정산. 소득 아님')
    # B14 10/18 같은 편의점 8,900 두 번(체크카드)
    L.label('B14', [*L.debit('cvs-1/2026-10', date(2026, 10, 18), 8900, check, living, '망원역 편의점 모퉁이24'),
                    *L.debit('cvs-2/2026-10', date(2026, 10, 18), 8900, check, living, '망원역 편의점 모퉁이24')],
            '같은 날 같은 금액의 별도 구매 2건')

    # 카드대금: 10일. B13 현대카드 8월분 428,600은 9/10 300,000 + 9/18 128,600 분할 납부
    names = {hyundai: '현대카드', samsung: '삼성카드', woori: '우리카드'}
    L.card('appliance/2026-08', date(2026, 8, 16), 428600 - L.usage(hyundai, date(2026, 8, 1)), hyundai,
           '합정 가전나라', '일시불')
    L.card_bills(10, main, names, overrides=[(hyundai, '2026-09')])
    L.label('B13', [L.account('card-bill-split-1/2026-09', date(2026, 9, 10), 300000, 'out', main, '현대카드',
                              '카드대금', 'card_payment'),
                    L.account('card-bill-split-2/2026-09', date(2026, 9, 18), 128600, 'out', main, '현대카드',
                              '카드대금', 'card_payment')], '현대카드 8월분 428,600의 분할 납부 2회')
    bill = next(r for r in L.rows if r['sourceRef'].endswith(f'card-bill/{woori[:8]}/2026-10'))
    L.label('B08', [audio, bill], '같은 소비(카드 승인 1건)와 그 대금 출금. 이중 소비 아님')

    s = L.finish(
        openings={'입출금 통장': 1800000, '자유 적금': 1200000, '생활비 통장': 450000, '비상금 통장': 500000,
                  '내일채움 통장': 0, '정기예금': 3000000},
        product_names={'입출금 통장': '직장인 급여 통장', '생활비 통장': '생활비 통장'},
        included={'입출금 통장', '생활비 통장'},
        salary={'salaryDay': 25, 'salaryAmountKRW': 3120000, 'salaryAccountId': main},
        confirmed=[('2026-09', '2026-09-25', september), ('2026-10', '2026-10-25', october)])
    return s, L.labels


# ---------------------------------------------------------------- 감마: 상계·중계·공릉, 단일 주거래 계좌
GAMMA_OWNER = '데**마'
GAMMA_HYUNDAI = [
    (['상계 단풍커피', '중계 들꽃베이커리', '공릉 솔잎다방'], 4200, 7600, 6),
    (['상계 정든국밥', '중계 해바라기분식', '노원 큰솥칼국수', '공릉 소담한식'], 7000, 22000, 5),
    (['단풍배달', '솔잎식탁'], 15000, 33000, 3),
    (['들꽃몰'], 11000, 54000, 2),
]
GAMMA_CHECK = [
    (['상계 이웃마트', '중계 싱그런청과', '노원 한마음정육', '공릉 동네반찬'], 7000, 62000, 6),
    (['상계역 편의점 바른24', '중계 단비약국', '공릉 꽃담문구'], 2000, 13000, 3),
]
GAMMA_SALARY_LABELS = [('가을주식회사', '급여'), ('급여', '타행이체'), ('입금', None)]


def make_gamma_life(gamma):
    """데모감마(gamma-life): 월급 15일·2,850,000원 예상, 생활비·이체·급여가 섞인 주거래 계좌 하나.

    이번 회차(10/15)에는 '입금' 2,850,000원(정답: 대출금)만 있고 월급은 아직 없다(G14).
    """
    s = copy.deepcopy(gamma)
    accounts, cards = ids(s)
    main, saving = accounts['입출금 통장'], accounts['자유 적금']
    hyundai, check = cards['현대 신용카드'], cards['국민 체크카드']
    for card in s['cards']:
        card['withdrawalAccountId'] = main
        for evidence in card['scheduleEvidence']:
            evidence['dueDate'] = evidence['dueDate'][:8] + '15'
    L = Ledger(s, 'gamma', GAMMA_OWNER, 20261103)
    company = '가을주식회사'
    variant = 0
    for month in months(L.start, L.today):
        m = f'{month:%Y-%m}'
        if m >= '2026-11':
            pass
        elif m == '2026-01':  # G09 같은 회사 월급 1,425,000 두 번 분할
            L.label('G09', [L.account('salary-a/2026-01', date(2026, 1, 15), 1425000, 'in', main, company, '급여',
                                      'income'),
                            L.account('salary-b/2026-01', date(2026, 1, 16), 1425000, 'in', main, company, '급여',
                                      'income')], '같은 회차 월급의 분할 지급 2건')
        elif m == '2026-03':  # G03 지연: 3월분이 4/2에 입금
            L.label('G03-late', [L.account('salary/2026-03', date(2026, 4, 2), 2850000, 'in', main, company, '급여',
                                           'income')], '3월분 월급이 다음 달 2일에 늦게 입금')
        elif m == '2026-06':  # G01 회사명 없는 '김대표'
            L.label('G01', [L.account('salary/2026-06', date(2026, 6, 15), 2817450, 'in', main, '김대표', '이체',
                                      'income')], '대표 개인 명의로 들어온 6월 월급(회사명 없음, 금액 다름)')
        elif m == '2026-08':  # G03 이른 입금: 8/15 토요일 → 8/14
            L.label('G03-early', [L.account('salary/2026-08', date(2026, 8, 14), 2850000, 'in', main, company, '급여',
                                            'income')], '월급일 전날(8/14) 입금')
        elif m == '2026-09':  # G02 '급여'와 '김대표'가 같은 금액으로 같은 날
            september = L.account('salary/2026-09', date(2026, 9, 15), 2850000, 'in', main, '급여', '타행이체', 'income')
            L.label('G02', [september,
                            L.account('kim/2026-09', date(2026, 9, 15), 2850000, 'in', main, '김대표', '이체', None)],
                    '첫 거래만 월급. 둘째는 지인이 갚은 돈')
        elif m == '2026-10':  # G14 대출금이 월급처럼 보임, 월급은 미입금
            L.label('G14', [L.account('loan/2026-10', date(2026, 10, 15), 2850000, 'in', main, '입금', None, None)],
                    '신용대출 실행금. 10월 월급은 기준 시각까지 입금되지 않음')
        else:  # G13 같은 회사 월급인데 표시값이 달마다 '가을주식회사'→'급여'→'입금' 순으로 바뀐다
            name, desc = GAMMA_SALARY_LABELS[variant % len(GAMMA_SALARY_LABELS)]
            variant += 1
            row = L.account(f'salary/{m}', payday(month, 15), 2850000, 'in', main, name, desc, 'income')
            L.label('G13', [row], '같은 회사 월급(표시값 변형)')
        # 고정 지출: 월세 15일, 관리비·통신·보험, 부모님 용돈, 적금
        if m < '2026-11':
            rent = L.account(f'rent/{m}', on(month, 15), 650000, 'out', main, '노*은', '타행이체', 'expense')
            if m == '2026-07':
                rent_row = rent
        L.account(f'maintenance/{m}', on(month, 25), won(L.rng, 88000, 132000), 'out', main, '상계주공관리사무소', 'CMS',
                  'expense')
        L.account(f'telecom/{m}', on(month, 22), 55000, 'out', main, '솔잎통신', '자동이체', 'expense')
        L.account(f'insurance/{m}', on(month, 10), 48000, 'out', main, '한결생명', 'CMS', 'expense')
        L.account(f'parents/{m}', on(month, 1), 300000, 'out', main, '감*희', '모바일이체', 'expense')
        L.account(f'car-loan/{m}', on(month, 20), 350000, 'out', main, '들꽃캐피탈', 'CMS', 'expense')
        L.account(f'academy/{m}', on(month, 5), 180000, 'out', main, '노원 새벽영어학원', '타행이체', 'expense')
        L.account(f'invest/{m}', on(month, 16), 300000, 'out', main, '단풍증권', '타행이체', None)
        if m in ('2026-02', '2026-05', '2026-08'):
            L.transfer(f'saving/{m}', on(month, 20), 300000, main, saving, '자동이체')
        if L.rng.random() < 0.4:
            L.account(f'atm/{m}', on(month, 6), L.rng.choice([30000, 50000, 100000]), 'out', main, '상계역 ATM',
                      'ATM출금', 'expense')
        L.spend(month, GAMMA_HYUNDAI, 'hyundai', lambda k, d, a, n: L.card(k, d, a, hyundai, n, '일시불'))
        L.spend(month, GAMMA_CHECK, 'check', lambda k, d, a, n: L.debit(k, d, a, check, main, n))

    # G15 7/15: 월급 2,850,000·카드대금 428,600·월세 650,000이 같은 날(시각 없음)
    L.card('june-top-up/2026-06', date(2026, 6, 27), 428600 - L.usage(hyundai, date(2026, 6, 1)), hyundai,
           '공릉 생활가전', '일시불')
    L.card_bills(15, main, {hyundai: '현대카드'})
    july_bill = next(r for r in L.rows if r['sourceRef'].endswith(f'card-bill/{hyundai[:8]}/2026-07'))
    july_salary = next(r for r in L.rows if r['sourceRef'].endswith('salary/2026-07'))
    L.label('G15', [july_salary, july_bill, rent_row], '같은 날 입금 1건·출금 2건. 일중 순서 정보 없음')

    s = L.finish(
        openings={'입출금 통장': 1500000, '자유 적금': 400000, '생활비 통장': 0, '비상금 통장': 0,
                  '내일채움 통장': 0, '정기예금': 0},
        product_names={'입출금 통장': '주거래 통장'},
        included={'입출금 통장'},
        salary={'salaryDay': 15, 'salaryAmountKRW': 2850000, 'salaryAccountId': main},
        confirmed=[('2026-09', '2026-09-15', september)])
    return s, L.labels


def bump(snapshot):
    """원천 버전 끝에 SOURCE_SUFFIX를 붙인다(스냅샷·페이지·각 행)."""
    from life_cases import bump_source_version
    return bump_source_version(snapshot, SOURCE_SUFFIX)
