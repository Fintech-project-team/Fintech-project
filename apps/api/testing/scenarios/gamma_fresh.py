"""2026-11-04: 새 표현·관계의 연간 개발/평가 자료와 사전 정답. 사용: 평가 CLI.

운영에서 import하지 않는다. 기존 자료에서 달력·계좌 분포만 재사용한다.
"""
import argparse
from collections import Counter
import copy
from datetime import datetime
import hashlib
import json
from pathlib import Path
import random
import sys
from uuid import NAMESPACE_URL, uuid5

API = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(API), str(API / 'fixtures')]
from testing.scenarios.gamma_year import build as topology
from testing.analysis.fresh_cases import (ACCOUNT, CARD, RECURRING, UNSEEN_ACCOUNT,
                                           UNSEEN_CARD, UNSEEN_RECURRING)
from testing.analysis.gamma_labels import label
from testing.analysis.gamma_evaluation import requests, category, FILES
from testing.analysis.evaluate import validate_labels
from validate import validate_snapshot


def build(split='holdout', seed=20261104, variant=1):
    """2026-11-04: 365일 1825건을 새 ID·원천 문장·금액·관계로 구성한다. 사용: freeze."""
    if variant not in (1, 2):
        raise ValueError('Unknown wording variant')
    if split not in ('development', 'holdout'):
        raise ValueError('Unknown split')
    source, original = topology(seed)
    rng = random.Random(seed + (1301 if split == 'holdout' else 277))
    wording = 1 if split == 'holdout' else 0
    prefix = f'fixture:gamma-fresh:{split}:{seed}'
    ids = {row[field]: str(uuid5(NAMESPACE_URL, prefix + '/' + row[field]))
           for collection, field in (('accounts', 'accountId'), ('cards', 'cardId'),
                                      ('transactions', 'transactionId'))
           for row in source[collection]}

    def remap(value):
        """2026-11-04: 소유자는 보존하고 원천 참조 전체를 새 ID로 치환한다. 사용: build."""
        if isinstance(value, dict):
            return {ids.get(key, key): remap(item) for key, item in value.items()}
        if isinstance(value, list):
            return [remap(item) for item in value]
        return ids.get(value, value) if isinstance(value, str) else value

    source, original = remap(source), remap(original)
    source['sourceVersion'] = prefix
    source['page']['sourceVersion'] = prefix
    source['transactionRelations'] = []
    rows = sorted(source['transactions'], key=lambda row: (row['occurredAt'], row['sourceRef']))
    by_id = {row['transactionId']: row for row in rows}
    answers, reserved = {}, set()
    for number, row in enumerate(rows):
        row.update(sourceVersion=prefix, sourceRef=f'fixture/gamma-fresh/{split}/{seed}/row/{number}')
        if row['recordKind'] == 'account_entry':
            entry = ACCOUNT[(number * 17 + seed) % len(ACCOUNT)]
            condition, meaning, basic, direction, difficulty = entry[:5]
            memo = UNSEEN_ACCOUNT[condition] if variant == 2 else entry[5 + wording]
            row.update(direction=direction,
                       withdrawalDate=row['bookingDate'] if direction == 'out' else None)
        else:
            entry = CARD[(number * 7 + seed) % len(CARD)]
            condition, meaning, difficulty = entry[:3]
            basic = 'expense'
            memo = UNSEEN_CARD[condition] if variant == 2 else entry[3 + wording]
        row.update(merchantName=f'{"미담" if variant == 2 else "유선" if wording else "온결"}상사{number % 31:02}',
                   description=memo, amountKRW=rng.randrange(31, 1798) * 100)
        answers[row['transactionId']] = label(meaning, basic, condition, difficulty)

    groups = sorted((key, value) for key, value in original['groups'].items()
                    if key.startswith('own-transfer-'))
    for number, (_, values) in enumerate(groups):
        first, second = sorted((by_id[key] for key in values), key=lambda row: row['sourceRef'])
        amount = rng.randrange(71, 1901) * 1000
        first.update(direction='out', withdrawalDate=first['bookingDate'], amountKRW=amount)
        second.update(direction='in', withdrawalDate=None, amountKRW=amount)
        for row in (first, second):
            row.update(merchantName='윤서우' if wording else '한도율',
                       description='온라인 자금 송금분' if wording else '타행 자금 이동 처리')
            if variant == 2:
                row.update(merchantName='조아현', description='자동화 이체 접수 처리')
            reserved.add(row['transactionId'])
        if number % 5 in (0, 1):
            source['transactionRelations'].append({'kind': 'internal_transfer',
                'fromId': first['transactionId'], 'toId': second['transactionId'],
                'evidenceRef': prefix + '/bank-pair/' + str(number)})
            meaning, basic, difficulty = 'self_transfer', 'internal_transfer', 'verified_relation'
            if number % 10 == 1:
                first['description'], second['description'] = '성과 상여 지급', '차입 원금 수령'
                if variant == 2:
                    first['description'], second['description'] = '근로 임금 명목', '대여 원금 명목'
                difficulty = 'relation_over_memo'
        elif number % 5 == 2:
            first['description'] = '부모님에게 생활자금 송금' if wording else '동생에게 용돈 전달'
            second['description'] = '자녀에게 받은 생활자금' if wording else '누나에게 받은 용돈'
            if variant == 2:
                first['description'], second['description'] = '조카에게 개인 용돈 전달', '친척에게 받은 개인 용돈'
            meaning, basic, difficulty = 'personal_transfer', None, 'transfer_confounder'
        else:
            meaning, basic, difficulty = None, None, 'unverified_transfer'
            if number % 5 == 4:
                second['amountKRW'] -= 700
                difficulty = 'unverified_transfer_fee'
        for row in (first, second):
            answers[row['transactionId']] = label(meaning, basic, difficulty, difficulty)

    for number, key in enumerate(original['groups']['salary']):
        row = by_id[key]
        ambiguous = number % 3 == 1
        memo = ('정기적 대체 수령분' if wording else '월별 자금 접수') if ambiguous else (
            '당월 근로계약 보수 지급' if wording else '고용계약에 따른 월 보수')
        if variant == 2:
            memo = '일괄 대체 수령 내역' if ambiguous else '근로계약 직원 월정 임금'
        row.update(merchantName='다음제작' if variant == 2 else '로움기획' if wording else '이룸제작', description=memo,
                   amountKRW=3176500 if wording else 2967400, direction='in', withdrawalDate=None)
        answers[key] = label(None if ambiguous else 'salary', None if ambiguous else 'income',
                             'salary_monthly_missing' if ambiguous else 'salary_monthly_new',
                             'ambiguous' if ambiguous else 'clear')
        reserved.add(key)

    card_rows = [row for row in rows if row['recordKind'] == 'card_purchase']
    pairs = []
    for card in sorted({row['cardId'] for row in card_rows}):
        selected = [row for row in card_rows if row['cardId'] == card]
        pairs.extend(zip(selected[::2], selected[1::2]))
    rng.shuffle(pairs)
    for number, (original_row, reversal) in enumerate(pairs[:104]):
        amount = rng.randrange(120, 2200) * 100
        original_row.update(description='외투와 신발 구매' if wording else '침구 생활용품 구매',
                            amountKRW=amount)
        if variant == 2:
            original_row.update(description='책상과 사무용 의자 구입')
        answers[original_row['transactionId']] = label('retail', 'expense',
                                                       'reversed_original', 'reversal_context')
        day, cancellation = reversal['purchaseDate'], number % 2 == 0
        reversal.update(recordKind='card_cancellation' if cancellation else 'card_refund',
            direction='in', status='cancelled' if cancellation else 'posted',
            merchantName=original_row['merchantName'], amountKRW=amount if cancellation else amount // 2,
            description='보수 정산 입금' if number % 9 == 0 else
                ('결제 승인 철회 완료' if cancellation else '반품 차액 환급 완료'),
            originalTransactionId=original_row['transactionId'], purchaseDate=None,
            refundDate=None if cancellation else day, cancellationDate=day if cancellation else None,
            occurredAtBasis='cancellation' if cancellation else 'refund')
        if variant == 2:
            reversal['description'] = '임금 수령 메모' if number % 9 == 0 else (
                '승인 철회가 실제 처리됨' if cancellation else '반품 차액 실제 지급')
        meaning = 'cancellation' if cancellation else 'refund'
        answers[reversal['transactionId']] = label(meaning, None, meaning, 'reversal_context')

    recurring = []
    for number, definition in enumerate(RECURRING):
        meaning, basic = definition[:2]
        memo, group = definition[2 + wording], []
        if variant == 2:
            memo = UNSEEN_RECURRING[number]
        merchant = f'{"지음" if variant == 2 else "우솔" if wording else "한빛"}청구처{number}'
        amount, day = (number + 7) * 7300, number * 2 + 1
        for month in (8, 9, 10):
            selected = [row for row in rows if row['accountId'] == original['mainAccountId']
                        and row['bookingDate'] == f'2026-{month:02}-{day:02}'
                        and row['transactionId'] not in reserved]
            row = selected[0]
            row.update(merchantName=merchant, description=memo, amountKRW=amount,
                       direction='out', withdrawalDate=row['bookingDate'])
            reserved.add(row['transactionId'])
            group.append(row['transactionId'])
            answers[row['transactionId']] = label(meaning, basic, f'monthly_new_{number}',
                'recurring_clear' if meaning else 'recurring_ambiguous')
        recurring.append({'transactionIds': group, 'meaning': meaning, 'basicType': basic,
                          'condition': f'monthly_new_{number}'})
    balances = dict(original['openingBalancesKRW'])
    for row in rows:
        if row['accountId'] and row['balanceReflected'] is True:
            balances[row['accountId']] += row['amountKRW'] * (1 if row['direction'] == 'in' else -1)
    for row in source['accounts']:
        row.update(balanceKRW=balances[row['accountId']], sourceVersion=prefix)
    for row in source['cards']:
        row['sourceVersion'] = prefix
    source['transactions'] = rows
    for answer in answers.values():
        answer['split'] = 'synthetic_' + split
    validate_snapshot(source)
    return source, {'transactions': answers, 'recurring': recurring, 'split': split}


def freeze(directory, split, seed, variant=1, batch_size=20):
    """2026-11-04: 분석 전에 원천·입력·정답 해시를 확정한다. 사용: CLI·검사."""
    source, gold = build(split, seed, variant)
    cases = requests(source, batch_size=batch_size)
    recurring = {tuple(sorted(row['transactionIds'])): row for row in gold['recurring']}
    expected = {}
    for case in cases:
        labels = []
        for item in case['input']['items']:
            if item['targetTransactionId']:
                truth = copy.deepcopy(gold['transactions'][item['targetTransactionId']])
                truth['category'] = category(truth)
            else:
                entry = recurring[tuple(sorted(item['evidenceTransactionIds']))]
                truth = label(entry['meaning'], None, entry['condition'],
                              'recurring_clear' if entry['meaning'] else 'recurring_ambiguous')
                truth.update(category='recurring_candidates', split='synthetic_' + split)
            truth.update(itemKey=item['itemKey'], targetTransactionId=item['targetTransactionId'],
                         requiredEvidenceTransactionIds=item['evidenceTransactionIds'])
            labels.append(truth)
        expected[case['name']] = {'items': labels}
    validate_labels({row['name']: row['input'] for row in cases}, expected, None)
    directory.mkdir(parents=True, exist_ok=False)
    hashes = {}
    for name, value in zip(FILES, (source, cases, expected)):
        body = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode('utf-8')
        (directory / name).write_bytes(body)
        hashes[name] = hashlib.sha256(body).hexdigest()
    labels = [row for group in expected.values() for row in group['items']]
    manifest = {'version': 'gamma-evaluation-1', 'generator': 'gamma-fresh-1', 'seed': seed,
        'wordingVariant': variant, 'batchSize': batch_size,
        'split': split, 'frozenAt': datetime.now().astimezone().isoformat(), 'sha256': hashes,
        'transactions': len(source['transactions']), 'analysisItems': len(labels),
        'batches': len(cases), 'recurringCandidates': len(recurring),
        'categories': dict(Counter(row['category'] for row in labels)),
        'difficulties': dict(Counter(row['difficulty'] for row in labels)),
        'expectedReviews': dict(Counter(row['expectedReview'] for row in labels)),
        'independentHoldout': split == 'holdout', 'modelCalls': 0,
        'profile': {'inputLimit': 12000, 'outputLimit': 4000, 'concurrency': 6},
        'limits': '새 문장·금액·관계 합성 평가. 같은 분류 체계·달력 뼈대 사용. 실제 고객 모집단 추정 아님.'}
    (directory / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2),
                                           encoding='utf-8')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--split', choices=('development', 'holdout'), required=True)
    parser.add_argument('--seed', type=int, default=20261104)
    parser.add_argument('--variant', type=int, choices=(1, 2), default=1)
    parser.add_argument('--batch-size', type=int, choices=(10, 15, 20), default=20)
    options = parser.parse_args()
    print(json.dumps(freeze(options.directory, options.split, options.seed,
                            options.variant, options.batch_size), ensure_ascii=False))
