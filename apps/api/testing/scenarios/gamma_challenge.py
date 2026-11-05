"""2026-11-03: 어려운 합성 연간 원천과 별도 정답을 만든다. 사용: gamma_evaluation.

금융 테이블·실서비스에 분기를 추가하지 않는다. 기존 원천을 변경하지 않는 새 시험 버전이다.
"""
from collections import Counter
from datetime import datetime
import random

from testing.scenarios.gamma_year import build as annual_source
from testing.analysis.gamma_labels import ACCOUNT, CARD, label
from validate import validate_snapshot


def build(seed=20261103):
    """2026-11-03: 365일·1825행·계좌80/20을 유지하며 관찰 가능한 정답을 함께 확정한다."""
    source, old_gold = annual_source(seed)
    rng = random.Random(seed + 71)
    source['sourceVersion'] = f'fixture:gamma-challenge:1:{source["asOf"][:10]}:{seed}'
    source['page']['sourceVersion'] = source['sourceVersion']
    rows = sorted(source['transactions'], key=lambda row: (row['occurredAt'], row['sourceRef']))
    by_id = {row['transactionId']: row for row in rows}
    answers = {}
    reserved = set()

    for number, row in enumerate(rows):
        identity = row['transactionId']
        row['sourceVersion'] = source['sourceVersion']
        if row['recordKind'] == 'account_entry':
            condition, merchant, memo, direction, meaning, basic, difficulty = ACCOUNT[number % len(ACCOUNT)]
            row.update(merchantName=merchant, description=memo, direction=direction,
                       withdrawalDate=row['bookingDate'] if direction == 'out' else None)
            if meaning in ('salary', 'bonus', 'loan_proceeds'):
                row['amountKRW'] = rng.choice((1750000, 2480000, 2850000, 3200000))
            else:
                row['amountKRW'] = rng.randrange(20, 1400) * 100
        else:
            condition, merchant, memo, meaning, difficulty = CARD[number % len(CARD)]
            basic = 'expense'
            row.update(merchantName=merchant, description=memo)
        answers[identity] = label(meaning, basic, condition, difficulty)

    # 공개 명시 관계가 있는 80쌍과 금액/시간만 같은 경우를 구분한다.
    transfer_groups = sorted((key, values) for key, values in old_gold['groups'].items()
                             if key.startswith('own-transfer-'))
    for index, (_, ids) in enumerate(transfer_groups):
        first, second = sorted((by_id[key] for key in ids), key=lambda row: row['sourceRef'])
        amount = rng.choice((50000, 100000, 200000, 500000))
        first.update(direction='out', withdrawalDate=first['bookingDate'], amountKRW=amount)
        second.update(direction='in', withdrawalDate=None, amountKRW=amount)
        for row in (first, second):
            row.update(merchantName='김가온', description='계좌이체')
            reserved.add(row['transactionId'])
        if index < 80:
            source['transactionRelations'].append({'kind': 'internal_transfer',
                'fromId': first['transactionId'], 'toId': second['transactionId'],
                'evidenceRef': 'bank-link-' + str(index)})
            meaning, basic, difficulty = 'self_transfer', 'internal_transfer', 'verified_relation'
            if index >= 70:
                first['description'] = '급여'
                second['description'] = '대출금'
                difficulty = 'relation_over_memo'
        elif index < 110:
            first['description'] = '가족 생활비 전달'
            second['description'] = '가족 생활비 수령'
            meaning, basic, difficulty = 'personal_transfer', None, 'transfer_confounder'
        else:
            meaning, basic, difficulty = None, None, 'unverified_transfer'
            if index >= 180:
                second['amountKRW'] = amount - 500
                difficulty = 'unverified_transfer_fee'
        for row in (first, second):
            answers[row['transactionId']] = label(meaning, basic, difficulty, difficulty,
                '명시된 원천 연결을 우선한다.' if index < 80 else
                '동일 금액·시각이나 계좌명만으로 자기 계좌 간 연결을 확정하지 않는다.')

    # 매달 같은 날 들어온 돈이어도 목적이 빠진 네 회차는 급여로 확정하지 않는다.
    for key in old_gold['groups']['salary']:
        row = by_id[key]
        month = int(row['bookingDate'][5:7])
        ambiguous = month in (2, 5, 8, 11)
        row.update(merchantName='새봄디자인', description='대체입금' if ambiguous else '정기급여',
                   amountKRW=2850000, direction='in', withdrawalDate=None)
        answers[key] = label(None if ambiguous else 'salary', None if ambiguous else 'income',
                             'salary_monthly_missing_purpose' if ambiguous else 'salary_monthly',
                             'ambiguous' if ambiguous else 'clear')
        reserved.add(key)

    # 원거래가 실제 존재하는 취소/환불을 같은 카드의 시간순 인접 행으로 만든다.
    card_rows = [row for row in rows if row['recordKind'] == 'card_purchase']
    pairs = []
    for card in sorted({row['cardId'] for row in card_rows}):
        selected = [row for row in card_rows if row['cardId'] == card]
        pairs.extend(zip(selected[::2], selected[1::2]))
    rng.shuffle(pairs)
    for index, (original, reversal) in enumerate(pairs[:100]):
        original.update(merchantName='해온온라인', description='생활 물품 구입', amountKRW=80000)
        answers[original['transactionId']] = label('retail', 'expense', 'reversed_original', 'reversal_context')
        day = reversal['purchaseDate']
        cancellation = index < 50
        reversal.update(recordKind='card_cancellation' if cancellation else 'card_refund',
            direction='in', status='cancelled' if cancellation else 'posted',
            merchantName=original['merchantName'], amountKRW=80000 if cancellation else 30000,
            description='급여' if index % 7 == 0 else '부분 환불' if not cancellation else '승인 취소',
            originalTransactionId=original['transactionId'],
            purchaseDate=None, refundDate=None if cancellation else day,
            cancellationDate=day if cancellation else None,
            occurredAtBasis='cancellation' if cancellation else 'refund')
        meaning = 'cancellation' if cancellation else 'refund'
        answers[reversal['transactionId']] = label(meaning, None, meaning, 'reversal_context',
            '원천 종류가 취소·환불임을 우선한다. 입금 방향·급여 적요만으로 새 수입을 만들지 않는다.')

    # 반복 수치는 시험용 앱 입력 준비다. 실제 Flutter 계산기 구현을 대체하지 않는다.
    recurring = []
    definitions = [
        ('다온주택', '주택 월세', 650000, 'rent', 'expense'),
        ('해온통신', '휴대전화 요금', 55000, 'telecom', 'expense'),
        ('다온보험', '보험료 자동이체', 93000, 'insurance', 'expense'),
        ('미래은행', '대출 원리금 상환', 420000, 'loan_repayment', None),
        ('소리마루', '음원 서비스 월정액', 11900, 'subscription', 'expense'),
        ('다온주택', 'CMS', 66000, None, None),
        ('해온통신', '자동납부', 45000, None, None),
        ('다온보험', '보험계약대출 원리금 상환', 80000, 'loan_repayment', None),
        ('해온교육', '월 수강료', 200000, 'education', 'expense'),
        ('김가온', '정산', 100000, None, None),
        ('가온페이', None, 49900, None, None),
        ('다온센터', '정기 출금', 30000, None, None),
    ]
    for index, (merchant, memo, amount, meaning, basic) in enumerate(definitions):
        group = []
        selected_day = 1 + index * 2
        for month in (8, 9, 10):
            selected = [row for row in rows if row['accountId'] == old_gold['mainAccountId']
                        and row['bookingDate'] == f'2026-{month:02}-{selected_day:02}'
                        and row['transactionId'] not in reserved]
            if not selected:
                raise ValueError('Recurring source slot unavailable')
            row = selected[0]
            row.update(merchantName=merchant, description=memo, amountKRW=amount, direction='out',
                       withdrawalDate=row['bookingDate'])
            reserved.add(row['transactionId'])
            group.append(row['transactionId'])
            answers[row['transactionId']] = label(meaning, basic, 'monthly_' + str(index),
                'recurring_clear' if meaning else 'recurring_ambiguous')
        recurring.append({'transactionIds': group, 'meaning': meaning, 'basicType': basic,
                          'condition': 'monthly_' + str(index), 'name': merchant, 'amountKRW': amount,
                          'day': selected_day})

    balances = dict(old_gold['openingBalancesKRW'])
    for row in rows:
        if row['accountId'] and row['balanceReflected'] is True:
            balances[row['accountId']] += row['amountKRW'] * (1 if row['direction'] == 'in' else -1)
    for account in source['accounts']:
        account.update(sourceVersion=source['sourceVersion'], balanceKRW=balances[account['accountId']])
    for card in source['cards']:
        card['sourceVersion'] = source['sourceVersion']
    source['transactions'] = sorted(rows, key=lambda row: row['transactionId'])
    validate_snapshot(source)
    counts = Counter(row['accountId'] for row in rows if row['accountId'])
    if len(rows) != 1825 or counts[old_gold['mainAccountId']] != 800 or any(
            counts[key] != 40 for key in old_gold['secondaryAccountIds']):
        raise ValueError('Annual account distribution changed')
    return source, {'transactions': answers, 'recurring': recurring,
                    'openingBalancesKRW': old_gold['openingBalancesKRW'],
                    'generatedAt': datetime.now().astimezone().isoformat(),
                    'independentHoldout': False, 'family': 'gamma-challenge-development-v1'}
