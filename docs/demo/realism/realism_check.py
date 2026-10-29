"""스냅샷 폴더의 모든 사례에 같은 현실성·정합성 기준을 적용해 표로 보인다(LLM 없음, 읽기 전용).

판정 기준(합격선):
- 거래명=적요 0건
- 계좌별 조회 시작 잔액 ≥ 0, 날짜별 잔액 ≥ 0 (잔액 반영 계좌 내역만, 같은 날은 입금 먼저)
- 카드대금 차이 0: 매월 10일 card_payment 합계 − 전월 신용카드 사용 합계(일시불 전액, 환불 차감, 할부 제외).
  할부가 있으면 차이는 그 달 할부 청구분과 같아야 하며, 그 값은 생성기의 명시 표로 설명할 수 있어야 한다.
  첫 달(조회 시작 전 사용분)과 기존 청구서로 정해진 출금은 참고로만 본다.
참고 지표: 거래 수, 월 평균 건수, 거래명 종류, 최다 거래명 비중, 연결 관계 수, 환불·할부 건수.

사용: python3 -I realism_check.py <snapshots 폴더 또는 파일>...
"""
import collections
import json
import sys
from pathlib import Path


def day_of(t):
    """거래 날짜. 날짜 필드가 모두 없는 기록(취소·미확인 등)은 빈 문자열로 두어 월 집계에서 뺀다."""
    return (t['bookingDate'] or t['purchaseDate'] or t['refundDate'] or t['withdrawalDate']
            or (t['occurredAt'] or '')[:10])


def opening_balances(snapshot):
    moves = collections.defaultdict(list)
    for t in snapshot['transactions']:
        if t['recordKind'] == 'account_entry' and t['balanceReflected']:
            moves[t['accountId']].append((t['bookingDate'], t['direction'] != 'in',
                                          t['amountKRW'] if t['direction'] == 'in' else -t['amountKRW']))
    worst_open, worst_low = None, None
    for account in snapshot['accounts']:
        rows = sorted(moves[account['accountId']])
        running = account['balanceKRW'] - sum(r[2] for r in rows)
        opening, low = running, running
        for _, _, signed in rows:
            running += signed
            low = min(low, running)
        worst_open = opening if worst_open is None else min(worst_open, opening)
        worst_low = low if worst_low is None else min(worst_low, low)
    return worst_open, worst_low


def card_bill_gaps(snapshot):
    credit = {c['cardId'] for c in snapshot['cards'] if c['cardType'] == 'credit'}
    start = snapshot['coverage'][0]['requestedStart'][:7] if snapshot['coverage'] else None
    usage = collections.Counter()
    for t in snapshot['transactions']:
        if t['cardId'] in credit and t['recordKind'] != 'account_entry' and not t['installmentTotal'] and day_of(t):
            usage[day_of(t)[:7]] += t['amountKRW'] if t['direction'] == 'out' else -t['amountKRW']
    pays = collections.Counter()
    for t in snapshot['transactions']:
        if t['payseTransactionType'] == 'card_payment' and t['recordKind'] == 'account_entry':
            pays[t['bookingDate'][:7]] += t['amountKRW']
    gaps = {}
    for month, paid in sorted(pays.items()):
        y, m = map(int, month.split('-'))
        previous = f'{y - (m == 1)}-{(m - 2) % 12 + 1:02d}'
        if start and previous <= start:
            continue
        gap = paid - usage.get(previous, 0)
        if gap:
            gaps[month] = gap
    return gaps


def report(path):
    s = json.loads(path.read_text(encoding='utf-8'))
    if 'transactions' not in s:
        return None
    T = s['transactions']
    names = collections.Counter(t['merchantName'] for t in T)
    months = {day_of(t)[:7] for t in T if day_of(t)}
    opening, low = opening_balances(s) if s['accounts'] else (None, None)
    gaps = card_bill_gaps(s)
    top = names.most_common(1)[0] if names else ('-', 0)
    return {
        'case': path.stem, 'tx': len(T), 'perMonth': round(len(T) / max(1, len(months))),
        'names': len(names), 'sameDesc': sum(t['merchantName'] == t['description'] for t in T),
        'top': f'{top[0]} {top[1] * 100 // max(1, len(T))}%', 'relations': len(s['transactionRelations']),
        'refund': sum(t['recordKind'] == 'card_refund' for t in T), 'installment': sum(bool(t['installmentTotal']) for t in T),
        'opening': opening, 'low': low, 'billGaps': gaps,
        'pass': sum(t['merchantName'] == t['description'] for t in T) == 0 and (low is None or (opening >= 0 and low >= 0)),
    }


if __name__ == '__main__':
    files = []
    for arg in sys.argv[1:]:
        p = Path(arg)
        files += sorted(p.glob('*.json')) if p.is_dir() else [p]
    print('사례 | 거래 | 월평균 | 거래명 종류 | 거래명=적요 | 최다 거래명 | 연결 | 환불 | 할부 | 최저 시작잔액 | 최저 일별잔액 | 카드대금 차이(월:원) | 기준 통과')
    for f in files:
        r = report(f)
        if r is None:
            continue
        gaps = ', '.join(f'{k}:{v:+,}' for k, v in r['billGaps'].items()) or '0'
        fmt = lambda v: '-' if v is None else f'{v:,}'
        print(f"{r['case']} | {r['tx']} | {r['perMonth']} | {r['names']} | {r['sameDesc']} | {r['top']} | {r['relations']} | "
              f"{r['refund']} | {r['installment']} | {fmt(r['opening'])} | {fmt(r['low'])} | {gaps} | {'예' if r['pass'] else '아니오'}")
