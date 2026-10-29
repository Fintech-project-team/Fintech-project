"""2026-10-29: 과거 이행 검사에만 쓰는, 취소 날짜 컬럼 추가 전 seed 생성기.

운영 적재에는 사용하지 않는다. 사용자·금융 값과 관계는 현재 fixture를 사용하고,
과거 스키마의 거래 컬럼과 4컬럼 청구 연결을 명시적으로 재현한다. v4 신규 청구항목은 입력으로 받지 않는다.
"""

from export_sql import financial_rows, load_sources, render
from testing.scenarios.export_state import state_rows


def export(directory, cases):
    """2026-10-29: 명시한 사례를 과거 컬럼으로 내보낸다. 사용: 두 과거 이행 테스트."""
    if not cases:
        raise ValueError('Explicit legacy scenario selection required')
    snapshots, seeds = load_sources(directory, cases)
    rows = []
    for snapshot in snapshots:
        if snapshot['schemaVersion'] != 'PAYSE-DRAFT-3':
            raise ValueError('Legacy schema requires an explicit v3 source')
        for table, original in financial_rows(snapshot, seeds[snapshot['userId']], connected=True):
            if table == 'user_attributes':
                continue
            row = dict(original)
            if table == 'financial_transactions':
                row.pop('cancellation_date', None)
            if table == 'statement_items':
                row = {key: row[key] for key in ('user_id', 'statement_id', 'card_id', 'transaction_id')}
            rows.append((table, row))
        rows.extend(state_rows(snapshot))
    return render(rows)
