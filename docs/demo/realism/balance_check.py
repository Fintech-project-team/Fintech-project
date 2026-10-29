"""스냅샷의 계좌 잔액과 거래 이력이 맞는지 본다: 조회 시작 잔액 역산, 날짜별 최저 잔액.

잔액에 반영된(balanceReflected=True) 계좌 내역만 쓴다. 같은 날은 입금 먼저 반영한다.
사용: python3 -I balance_check.py <스냅샷.json>
"""
import json
import sys
from collections import defaultdict


def report(snapshot):
    rows = defaultdict(list)
    for t in snapshot['transactions']:
        if t['recordKind'] == 'account_entry' and t['balanceReflected']:
            signed = t['amountKRW'] if t['direction'] == 'in' else -t['amountKRW']
            rows[t['accountId']].append((t['bookingDate'], t['direction'] != 'in', signed))
    result = []
    for account in snapshot['accounts']:
        moves = sorted(rows[account['accountId']])
        opening = account['balanceKRW'] - sum(m[2] for m in moves)
        running, lowest, lowest_day = opening, opening, None
        for day, _, signed in moves:
            running += signed
            if running < lowest:
                lowest, lowest_day = running, day
        result.append((account['productName'], opening, lowest, lowest_day, account['balanceKRW'], len(moves)))
    return result


if __name__ == '__main__':
    with open(sys.argv[1], encoding='utf-8') as f:
        data = json.load(f)
    print('계좌 | 시작 잔액 | 최저 잔액(날짜) | 현재 잔액 | 반영 거래')
    for name, opening, lowest, day, balance, count in report(data):
        print(f'{name} | {opening:,} | {lowest:,}({day or "-"}) | {balance:,} | {count}')
