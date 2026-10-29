"""2026-10-29: v3 원본을 보존하며 v4 청구 항목 준비 묶음을 별도로 만든다.

사용: --out 새 폴더. 운영 응답 변환기·청구 계산기·DB 실행기가 아니다.
새 예시의 금액·회차는 작성한 합성 사실이며 누락된 원천을 추정하지 않는다.
"""
import argparse
import copy
from datetime import date
import hashlib
import json
from pathlib import Path

from generate import build, month_shift, uid, update_versions
from reference_data.banks import load_bank_directory
from statement_items import legacy_items, NULL_FIELDS, transaction_refs


SCHEMA = 'PAYSE-DRAFT-4'
RELEASE = 'PAYSE-FIXTURE-4'


def upgrade(snapshot):
    """2026-10-29: 준비 도구에서만 구 참조를 값 미상의 항목으로 명시 전환한다. 사용: build_billing."""
    result = copy.deepcopy(snapshot)
    result['schemaVersion'] = SCHEMA
    version = result['sourceVersion'] + ':billing-4'
    if 'accounts' in result:
        update_versions(result, version, result['dataVersion'])
        for statement in result['statements']:
            statement['items'] = legacy_items(statement)
    else:
        result['sourceVersion'] = version
    return result


def example(snapshot, alias):
    """2026-10-29: 독립 사례에 두 청구·한 구매·별도 의무를 명시 준비한다. 사용: build_billing.

    기존 사례는 보존한다. 항목 추가를 기존 의무에 재차 차감하는 로직은 만들지 않는다.
    """
    result = copy.deepcopy(snapshot)
    version = result['sourceVersion'] + ':items-example'
    update_versions(result, version, result['dataVersion'])
    for statement in result['statements']:
        for item in statement['items']:
            item['sourceVersion'] = version
    owner = result['userId']
    today = date.fromisoformat(result['asOf'][:10])
    cards = [c for c in result['cards'] if c['institutionCode'] == 'card.hyundai']
    if len(cards) != 1 or cards[0]['cardType'] != 'credit' or cards[0]['withdrawalAccountId'] is None:
        raise ValueError('Billing example requires one owned credit card and withdrawal account')
    card = cards[0]
    purchase_id = uid(f'{alias}/billing-example/purchase')
    purchase_day = month_shift(today, -1, 8).isoformat()
    result['transactions'].append({
        'userId': owner, 'sourceRef': f'fixture/{alias}/billing-example/purchase', 'sourceVersion': version,
        'transactionId': purchase_id, 'accountId': None, 'cardId': card['cardId'],
        'recordKind': 'card_purchase', 'amountKRW': 600000, 'direction': 'out', 'status': 'posted',
        'merchantName': '다온결가전 은솔점', 'description': '신용카드', 'purchaseDate': purchase_day,
        'withdrawalDate': None, 'refundDate': None, 'cancellationDate': None, 'bookingDate': None,
        'occurredAt': None, 'occurredAtBasis': None, 'balanceReflected': None,
        'reflectionReason': 'not_applicable', 'originalTransactionId': None,
        'payseTransactionType': 'expense', 'installmentCurrent': 2, 'installmentTotal': 6,
    })
    new_bills = []
    for offset, round_no, total in ((0, 2, 105000), (1, 3, 100000)):
        key = f'{alias}/billing-example/bill-{round_no}'
        bill_id = uid(key)
        due_date = month_shift(today, offset, 28).isoformat()
        source = {'userId': owner, 'sourceVersion': version}
        item = {**source, **{name: None for name in sorted(NULL_FIELDS)},
            'itemId': uid(key + '/purchase'), 'sourceRef': f'fixture/{key}/purchase',
            'transactionId': purchase_id, 'label': '가전 할부', 'merchantName': '다온결가전 은솔점',
            'purchaseDate': purchase_day, 'originalUsedAmountKRW': 600000,
            'billedPrincipalKRW': 100000, 'feeOrAdjustmentAmountKRW': -5000 if offset == 0 else 0,
            'billedAmountKRW': 95000 if offset == 0 else 100000,
            'installmentMonths': 6, 'installmentRound': round_no}
        items = [item]
        if offset == 0:
            for kind, label, adjustment, billed in (
                    ('annual', '카드 연회비', 20000, 20000),
                    ('credit', '청구 조정 환급', -10000, -10000),
                    ('unknown', '청구 조정', None, None)):
                items.append({**source, **{name: None for name in sorted(NULL_FIELDS)},
                    'itemId': uid(key + '/' + kind), 'sourceRef': f'fixture/{key}/{kind}',
                    'transactionId': None, 'label': label,
                    'feeOrAdjustmentAmountKRW': adjustment, 'billedAmountKRW': billed})
        bill = {**source, 'statementId': bill_id, 'sourceRef': f'fixture/{key}',
            'cardId': card['cardId'], 'amountKRW': total, 'dueDate': due_date,
            'periodStart': None, 'periodEnd': None, 'detailCompleteness': 'complete',
            'items': items, 'includedTransactionRefs': transaction_refs(items)}
        result['statements'].append(bill)
        result['obligations'].append({'userId': owner, 'obligationId': uid(key + '/obligation'),
            'label': '카드 청구', 'withdrawalAccountId': card['withdrawalAccountId'],
            'amountKRW': total, 'dueDate': due_date, 'status': 'active', 'statementId': bill_id,
            'recurringPlanId': None, 'recurrenceKey': None, 'planRevisionId': None})
        new_bills.append(bill_id)
    result['transactions'].sort(key=lambda row: row['transactionId'])
    return result, {'purchaseId': purchase_id, 'statementIds': new_bills,
        'billedTotalsKRW': [105000, 100000], 'scope': '독립 청구 원천 예시; 기존 기본 사례 변경 아님'}


def build_billing():
    """2026-10-29: 기존 사례 변환과 계정별 독립 청구 사례를 조립한다. 사용: write_files·검사."""
    old_cases, seeds, old_catalog = build()
    cases = {name: upgrade(snapshot) for name, snapshot in old_cases.items()}
    catalog = copy.deepcopy(old_catalog)
    catalog.update(fixtureVersion=RELEASE, schemaVersion=SCHEMA)
    for event in catalog['events']:
        # 기존 사건의 전이 버전만 새 묶음으로 이동하며 금액·기대 결과는 보존한다.
        event['sourceVersionBefore'] = cases[event['beforeCase']]['sourceVersion']
        event['sourceVersionAfter'] = cases[event['afterCase']]['sourceVersion']
    for alias, base in (('alpha', 'demo-installments'), ('beta', 'beta-cashflow-edge'), ('gamma', 'gamma-ai-misread')):
        name = alias + '-billing-items'
        snapshot, expected = example(cases[base], alias)
        cases[name] = snapshot
        catalog['cases'].append({'id': name, 'file': f'snapshots/{name}.json',
            'description': '독립 청구 항목: 복수 청구·할인·연회비·음수 조정·금액 미상', 'expected': expected})
    return cases, seeds, catalog


def write_files(out):
    """2026-10-29: 검증된 v4만 새 폴더에 저장하고 기존 v3 파일을 쓰지 않는다. 사용: CLI."""
    if out.exists():
        raise FileExistsError('Billing output must be a new directory')
    from validate import validate_snapshot
    cases, seeds, catalog = build_billing()
    for snapshot in cases.values():
        validate_snapshot(snapshot)
    contents = {f'snapshots/{name}.json': value for name, value in cases.items()}
    contents.update({'server-seeds.json': seeds, 'catalog.json': catalog, 'bank-directory.json': load_bank_directory()})
    out.mkdir(parents=True)
    hashes = {}
    for name, value in contents.items():
        target = out / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        hashes[name] = hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    (out / 'manifest.json').write_text(json.dumps({'fixtureVersion': RELEASE, 'hashMode': 'canonical-json-utf8', 'sha256': hashes}, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    write_files(parser.parse_args().out)
