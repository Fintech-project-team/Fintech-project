"""2026-11-03: 감마 연간 합성 원천과 비공개 평가 정답을 분리한다. 사용: CLI·검사.

서비스에서 import하지 않는다. 날짜·난수 기준을 고정해 재생성하며 실제 금융 자료를 받지 않는다.
"""
import argparse
from collections import Counter
import copy
from datetime import date, datetime, timedelta
import hashlib
import json
from pathlib import Path
import random
import sys
from uuid import NAMESPACE_URL, uuid5

API = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(API / 'fixtures'))
from validate import validate_snapshot


def build(seed=20261103):
    """2026-11-03: 고정된 365일에 하루 다섯 원천 행과 독립 정답을 만든다. 사용: write·검사."""
    source = json.loads((API / 'fixtures/generated-v4/snapshots/gamma-life.json')
                       .read_text(encoding='utf-8'))
    source = copy.deepcopy(source)
    as_of = datetime.fromisoformat(source['asOf'])
    end = as_of.date()
    start = date(end.year - 1, end.month, end.day) + timedelta(days=1)
    if (end - start).days != 364:
        raise ValueError('This reviewed fixture requires a 365-day calendar year')
    rng = random.Random(seed)
    version = f'fixture:gamma-year:1:{end.isoformat()}:{seed}'
    source.update(sourceVersion=version, dataVersion='1')
    source['page'].update(sourceVersion=version, dataVersion='1')
    accounts = {row['sourceRef']: row for row in source['accounts']}
    cards = {row['sourceRef']: row for row in source['cards']}
    if len(accounts) != 6 or len(cards) != 4:
        raise ValueError('Reviewed gamma account/card structure changed')
    main = accounts['fixture/gamma/account/0']['accountId']
    secondary = [accounts[f'fixture/gamma/account/{index}']['accountId'] for index in range(1, 6)]
    accounts['fixture/gamma/account/5'].update(productType='demand', productName='자유입출금통장')
    unused = []
    for index, original in enumerate((0, 2, 3), start=6):
        account = copy.deepcopy(accounts[f'fixture/gamma/account/{original}'])
        ref = f'fixture/gamma-year/account/{index}'
        account.update(accountId=str(uuid5(NAMESPACE_URL, ref)), sourceRef=ref,
                       productType='demand', productName=('예비생활비통장', '비상금통장', '여행준비통장')[index - 6],
                       maskedNumber=f'***-****-{1000 + index}')
        source['accounts'].append(account)
        unused.append(account['accountId'])
        source['coverage'].append({'targetId': account['accountId'], 'targetKind': 'account',
                                   'status': 'complete', 'requestedStart': start.isoformat(),
                                   'requestedEnd': end.isoformat(), 'coveredRanges': [],
                                   'missingRanges': []})
    for institution in source['institutions']:
        institution['accountCount'] = sum(row['institutionCode'] == institution['code']
                                          for row in source['accounts'])
    credit = cards['fixture/gamma/card/0']['cardId']
    alternate = cards['fixture/gamma/card/1']['cardId']
    rows, gold, groups = [], [], {}
    balances = {row['accountId']: 20_000_000 for row in source['accounts']}
    for identity in unused:
        balances[identity] = 0
    opening = dict(balances)
    shops = [('달빛식당', '점심 식사'), ('해온마켓', '식료품 구입'),
             ('봄날서점', '도서 구입'), ('푸른약국', '일반 의약품 구입'),
             ('하루카페', '음료 구입'), ('도담주유소', '차량 주유')]

    def transaction(day, slot, kind, amount, direction, merchant, description,
                    account=None, card=None, truth=None, group=None, insufficient=False):
        """2026-11-03: 공개 원천에는 분류·정답 그룹을 넣지 않는다. 사용: build의 날짜별 준비."""
        ref = f'fixture/gamma-year/1/{day.isoformat()}/{slot}'
        identity = str(uuid5(NAMESPACE_URL, ref))
        stamp = datetime.combine(day, datetime.min.time(), as_of.tzinfo).replace(hour=9 + slot // 2)
        if truth == 'internal_transfer_candidate':
            stamp = stamp.replace(hour=10)
        row = {'userId': source['userId'], 'transactionId': identity, 'sourceRef': ref,
            'sourceVersion': version, 'accountId': account, 'cardId': card, 'recordKind': kind,
            'amountKRW': amount, 'direction': direction,
            'status': 'posted' if kind == 'account_entry' else 'approved',
            'merchantName': merchant, 'description': description,
            'purchaseDate': day.isoformat() if kind == 'card_purchase' else None,
            'withdrawalDate': day.isoformat() if kind == 'account_entry' and direction == 'out' else None,
            'refundDate': None, 'cancellationDate': None,
            'bookingDate': day.isoformat() if kind == 'account_entry' else None,
            'occurredAt': stamp.isoformat(),
            'occurredAtBasis': 'booking' if kind == 'account_entry' else 'purchase',
            'balanceReflected': True if kind == 'account_entry' else None,
            'reflectionReason': 'reflected' if kind == 'account_entry' else 'not_applicable',
            'originalTransactionId': None, 'payseTransactionType': None,
            'installmentCurrent': None, 'installmentTotal': None}
        rows.append(row)
        if account:
            balances[account] += amount if direction == 'in' else -amount
        gold.append({'transactionId': identity, 'scenarioTruth': truth,
                     'requiresUserConfirmation': True,
                     'allowedAbstention': insufficient,
                     'evidenceLimit': 'counterparty_ownership_absent' if insufficient else None})
        if group:
            groups.setdefault(group, []).append(identity)

    schedule = {}
    recurring = {
        1: ('다온주택', '주택 임차료', 650000, 'rent'),
        3: ('해온통신', '휴대전화 요금 자동이체', 55000, 'telecom'),
        8: ('다온손해보험', '보험료 자동이체', 93000, 'insurance'),
        25: ('미래은행', '대출 원리금 상환', 420000, 'loan_repayment'),
    }
    for offset in range(365):
        day = start + timedelta(days=offset)
        schedule[offset, 1] = dict(kind='account_entry', amount=rng.randrange(30, 350) * 100,
            direction='out', merchant='초록생활협동조합', description='생활용품 결제', account=main)
        if day.day in recurring:
            merchant, description, amount, group = recurring[day.day]
            schedule[offset, 2] = dict(kind='account_entry', amount=amount, direction='out',
                merchant=merchant, description=description, account=main,
                truth='recurring_expense_candidate', group=group)
        if day.day == 15:
            schedule[offset, 3] = dict(kind='account_entry', amount=2850000, direction='in',
                merchant='새봄디자인', description='급여', account=main,
                truth='salary_candidate', group='salary')
        if offset == 10:
            schedule[offset, 3] = dict(kind='account_entry', amount=12000000, direction='in',
                merchant='미래은행', description='대출 실행금', account=main, truth='loan_disbursement')
        if day.day == 23:
            schedule[offset, 4] = dict(kind='card_purchase', amount=11900, direction='out',
                merchant='소리마루', description='월간 이용료', card=credit,
                truth='recurring_expense_candidate', group='subscription')
    available = [offset for offset in range(365)
                 if (offset, 3) not in schedule and (offset, 4) not in schedule]
    transfer_days = rng.sample(available, 200)
    reviewed_example = (date(2026, 10, 20) - start).days
    if reviewed_example not in transfer_days:
        transfer_days[0] = reviewed_example
    for index, offset in enumerate(sorted(transfer_days)):
        day = start + timedelta(days=offset)
        amount = rng.choice([50000, 100000, 200000, 300000, 500000])
        outgoing, incoming = (main, secondary[index % 5]) if index % 2 == 0 else (secondary[index % 5], main)
        for slot, direction, account in ((3, 'out', outgoing), (4, 'in', incoming)):
            schedule[offset, slot] = dict(kind='account_entry', amount=amount, direction=direction,
                merchant='김가온', description='계좌이체', account=account,
                truth='internal_transfer_candidate', group='own-transfer-' + day.isoformat(),
                insufficient=True)
    bank_count = sum(row['kind'] == 'account_entry' for row in schedule.values())
    empty = [(offset, slot) for offset in range(365) for slot in range(5)
             if (offset, slot) not in schedule]
    for position in rng.sample(empty, 1000 - bank_count):
        schedule[position] = dict(kind='account_entry', amount=rng.randrange(10, 250) * 100,
            direction='out', merchant='가온페이', description='일반 송금', account=main,
            insufficient=True)
    for offset in range(365):
        for slot in range(5):
            if (offset, slot) not in schedule:
                merchant, description = rng.choice(shops)
                schedule[offset, slot] = dict(kind='card_purchase', amount=rng.randrange(25, 850) * 100,
                    direction='out', merchant=merchant, description=description,
                    card=credit if slot % 2 == 0 else alternate)
            transaction(start + timedelta(days=offset), slot, **schedule[offset, slot])
    for row in source['accounts']:
        row.update(sourceVersion=version, asOf=source['asOf'], included=False, nickname=None,
                   balanceKRW=balances[row['accountId']])
    for row in source['cards']:
        row['sourceVersion'] = version
    for coverage in source['coverage']:
        coverage.update(requestedStart=start.isoformat(), requestedEnd=end.isoformat(),
            status='complete', coveredRanges=[{'start': start.isoformat(), 'end': end.isoformat()}],
            missingRanges=[])
    source['transactions'] = sorted(rows, key=lambda row: row['transactionId'])
    for name in ('relatedTransactions', 'transactionRelations', 'statements', 'obligations',
                 'recurringPlans', 'recurringPlanRevisions', 'recurringDecisions', 'occurrenceOverrides',
                 'occurrenceLinks', 'reserves', 'allocations', 'settlements', 'referenceResolutions'):
        source[name] = []
    source['settings'] = {'salary': {'salaryDay': None, 'salaryAmountKRW': None,
                                   'salaryAccountId': None, 'receiptEvidence': []}, 'cardPlans': []}
    validate_snapshot(source)
    answers = {'warning': '합성 개발 평가 정답. 모델 입력·서비스 응답·운영 JAR에 포함 금지.',
               'sourceVersion': version, 'seed': seed, 'openingBalancesKRW': opening,
               'transactions': gold, 'groups': groups, 'mainAccountId': main,
               'secondaryAccountIds': secondary, 'unusedAccountIds': unused}
    return source, answers


def write(out, seed=20261103):
    """2026-11-03: 새 폴더에만 원천·별도 정답·검토 요약을 쓴다. 사용: CLI."""
    source, gold = build(seed)
    out.mkdir(parents=True, exist_ok=False)
    hashes = {}
    for name, value in [('source.json', source), ('evaluation-gold.json', gold)]:
        body = (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        (out / name).write_bytes(body)
        hashes[name] = hashlib.sha256(body).hexdigest()
    summary = {'sourceVersion': source['sourceVersion'], 'asOf': source['asOf'], 'days': 365,
        'transactions': len(source['transactions']), 'dailyAverage': 5,
        'accounts': len(source['accounts']), 'cards': len(source['cards']),
        'recordKinds': dict(Counter(row['recordKind'] for row in source['transactions'])),
        'accountEntries': 1000, 'mainAccountEntries': 800, 'otherAccountEntriesEach': 40,
        'unusedAccounts': 3, 'ownTransferPairs': 200,
        'sha256': hashes, 'modelCalls': 0}
    (out / 'manifest.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--seed', type=int, default=20261103)
    args = parser.parse_args()
    print(json.dumps(write(args.out, args.seed), ensure_ascii=False))
