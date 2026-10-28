"""2026-10-28: 기존 회귀 자료와 분리한 세 사용자 시연 원천을 만든다.

사용: generate.build. 일반 금융 필드만 만들며 AI 오판·정답은 넣지 않는다.
"""
from __future__ import annotations

import copy
from datetime import date


def one(rows, purpose):
    """2026-10-28: 관계로 식별한 한 행을 검증한다. 사용: add_transaction, make_cases."""
    matches = list(rows)
    if len(matches) != 1:
        raise ValueError(purpose + ' must identify one row')
    return matches[0]


def add_transaction(snapshot, alias, make_id, key, amount, day, label,
                    *, account_id=None, card_id=None, incoming=False, installment=None):
    """2026-10-28: 명시된 합성 거래를 추가한다. 사용: make_cases.

    은행 거래를 준비할 때만 그 원천 잔액에 같은 사건을 반영한다.
    앱 가용액·급여·회차별 청구액을 계산하는 서버 기능이 아니다.
    """
    if (account_id is None) == (card_id is None):
        raise ValueError('Select one source account or card')
    identity = make_id(f'{alias}/transaction/demo-edge/{key}')
    if any(row['transactionId'] == identity for row in snapshot['transactions']):
        raise ValueError('Duplicate scenario transaction')
    if date.fromisoformat(day) > date.fromisoformat(snapshot['asOf'][:10]):
        raise ValueError('Source transaction is after asOf')
    is_card = card_id is not None
    target = one((row for row in snapshot['cards' if is_card else 'accounts']
                  if row['cardId' if is_card else 'accountId'] == (card_id or account_id)),
                 'transaction owner')
    if target['userId'] != snapshot['userId']:
        raise ValueError('Foreign transaction source')
    row = {
        'userId': snapshot['userId'], 'sourceRef': f'fixture/{alias}/transaction/demo-edge/{key}',
        'sourceVersion': snapshot['sourceVersion'], 'transactionId': identity,
        'accountId': account_id, 'cardId': card_id,
        'recordKind': 'card_purchase' if is_card else 'account_entry',
        'amountKRW': amount, 'direction': 'in' if incoming else 'out', 'status': 'posted',
        'merchantName': label, 'description': label,
        'purchaseDate': day if is_card else None,
        'withdrawalDate': day if not is_card and not incoming else None,
        'refundDate': None, 'bookingDate': day if not is_card else None,
        'occurredAt': None, 'occurredAtBasis': None,
        'balanceReflected': None if is_card else True,
        'reflectionReason': 'not_applicable' if is_card else 'reflected',
        'originalTransactionId': None,
        'payseTransactionType': 'income' if incoming else 'expense',
        'installmentCurrent': installment[0] if installment else None,
        'installmentTotal': installment[1] if installment else None,
    }
    snapshot['transactions'].append(row)
    if not is_card:
        target['balanceKRW'] += amount if incoming else -amount
    return identity


def make_cases(alpha, beta, gamma, make_id):
    """2026-10-28: 독립 금융 사례와 준비용 ID를 반환한다. 사용: generate.build.

    원본 객체는 수정하지 않는다. 기존 거래·청구·설정·입금 근거를 보존하고
    할부 표시는 확인된 합성 원문으로만 추가한다. 회차별 청구는 생성하지 않는다.
    """
    prepared = []
    definitions = (
        ('alpha', 'demo-installments', alpha, '정상 시연과 할부 원문 2건'),
        ('beta', 'beta-cashflow-edge', beta, '부수입·일회성 큰 지출·동일 표시의 별도 구매'),
        ('gamma', 'gamma-ai-misread', gamma, 'AI 오판 평가용 정상 금융 원천; 오판 결과는 별도 도구'),
    )
    for alias, case_id, baseline, description in definitions:
        snapshot = copy.deepcopy(baseline)
        ids = {}
        for institution, key, amount, day, label, counts in (
            ('card.hyundai', 'appliance', 180000, '2026-10-18', '생활가전 매장', (1, 3)),
            ('card.samsung', 'computer', 360000, '2026-08-18', '누리컴퓨터', (2, 6)),
        ):
            card = one((row for row in snapshot['cards'] if row['institutionCode'] == institution), key)
            if card['cardType'] != 'credit':
                raise ValueError('Installment source must be a credit card')
            ids[key] = add_transaction(snapshot, alias, make_id, key, amount, day, label,
                                       card_id=card['cardId'], installment=counts)
        account_id = snapshot['settings']['salary']['salaryAccountId']
        if alias == 'beta':
            for key, amount, day, label, incoming in (
                ('side-income', 785000, '2026-10-10', '새봄디자인', True),
                ('medical', 687400, '2026-10-12', '푸른의원', False),
                ('purchase-a', 8900, '2026-10-18', '동네편의점', False),
                ('purchase-b', 8900, '2026-10-18', '동네편의점', False),
            ):
                ids[key] = add_transaction(snapshot, alias, make_id, key, amount, day, label,
                                           account_id=account_id, incoming=incoming)
        if alias == 'gamma':
            ids['ambiguous-income'] = add_transaction(
                snapshot, alias, make_id, 'ambiguous-income', 3000000, '2026-09-25', '입금',
                account_id=account_id, incoming=True,
            )
        snapshot['transactions'].sort(key=lambda row: row['transactionId'])
        expected = {
            'preparationTransactionIds': ids, 'installmentCount': 2,
            'installmentEvidence': '회차는 합성 원천 명시값; 날짜/총액에서 추정하지 않음',
            'newStatementCount': 0, 'sourceSalaryEvidenceUnchanged': True,
            'selectedBalanceKRW': {'alpha': 2000000, 'beta': 2079800, 'gamma': 5000000}[alias],
            'scope': '시나리오 검증 메타데이터이며 공개 Snapshot·LLM 입력에 포함하지 않음',
        }
        prepared.append((case_id, snapshot, description, expected))
    return prepared
