"""2026-10-29: 각 합성 사용자에 소수의 취소·환불 원천을 준비한다.

사용: generate.make_snapshot. 운영 환불 서비스나 잔액 계산기가 아니다.
기존 거래·청구·계좌 잔액을 고치지 않고 새 원결제와 연결된 사건만 추가한다.
"""


def add_returns(add_transaction, cards, month):
    """2026-10-29: 승인 취소·전액 환불·부분 환불을 각각 1건 작성한다. 사용: make_snapshot.

    날짜·취소 시각은 시연 작성값이다. 실제 금융 원천의 미상 시각을 추정하거나
    환불/취소를 은행 입금으로 바꾸지 않는다. 금액은 부호 없는 크기로 유지한다.
    """
    cases = (
        ('cancel', 'card.hyundai', 30000, 30000, 12, 13, 'card_cancellation'),
        ('full', 'card.samsung', 18000, 18000, 8, 14, 'card_refund'),
        ('partial', 'card.woori', 40000, 12000, 9, 15, 'card_refund'),
    )
    for key, institution, purchased, returned, purchase_day, return_day, kind in cases:
        matches = [card for card in cards if card['institutionCode'] == institution]
        if len(matches) != 1 or matches[0]['cardType'] != 'credit':
            raise ValueError('Card return requires one prepared credit card')
        card_id = matches[0]['cardId']
        purchase_date = month.replace(day=purchase_day).isoformat()
        return_date = month.replace(day=return_day).isoformat()
        cancelled = kind == 'card_cancellation'
        original_id = add_transaction(
            f'card-return/{key}-purchase', purchase_date, purchased,
            card=card_id, kind='card_purchase', status='cancelled' if cancelled else 'posted',
        )
        # 10:30은 명시적으로 작성한 합성 시각이며 날짜에 임의 자정을 붙인 값이 아니다.
        add_transaction(
            f'card-return/{key}', return_date, returned, card=card_id, kind=kind,
            direction='in', status='cancelled' if cancelled else 'posted',
            originalTransactionId=original_id,
            occurredAt=return_date + 'T10:30:00+09:00' if cancelled else None,
            occurredAtBasis='cancellation' if cancelled else None,
        )
