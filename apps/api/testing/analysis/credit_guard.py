"""2026-11-04: 사용자 확인 USD 잔액과 하한을 보수적으로 예약한다. 사용: gamma_local.

실시간 청구 API가 아니다. 계수 요금은 미확정이며 승인한 예약 정책을 별도 기록한다.
호출 실패/사용량 불명은 최대 생성 비용을 보류하며 기존 KRW 제한도 별도로 유지한다.
"""
import json
import os
from decimal import Decimal
from datetime import datetime

COUNT_MICROS = 100_000
MODEL_MICROS = 5_000  # 12000 * $0.25/M + 4000 * $0.50/M, cache writes included.
MIN_FLOOR_MICROS = 20_000_000
SHARED_POLICY = 'approved-shared-count-2usd-20261104'
SHARED_COUNT_MICROS = 2_000_000
SHARED_COUNT_KRW = 6_000_000_000  # Approved reserve at the existing 3000 KRW/USD bound.


def save(path, ledger):
    """2026-11-04: 실행 잠금 안에서 장부를 원자적으로 교체한다. 사용: reserve·settle."""
    pending = path.with_suffix('.pending')
    pending.write_text(json.dumps(ledger, indent=2), encoding='utf-8')
    os.replace(pending, path)


def reserve(path, run_id, calls, model_multiplier=1):
    """2026-11-04: 전송 전에 전체 실행의 최악 비용과 계수 보류액을 예약한다."""
    if type(calls) is not int or not 1 <= calls <= 200:
        raise ValueError('Invalid call bound')
    if type(model_multiplier) is not int or model_multiplier not in (1, 2):
        raise ValueError('Unsupported model price multiplier')
    ledger = load(path)
    if any(row['id'] == run_id for row in ledger['runs']):
        raise ValueError('Duplicate run')
    shared = ledger.get('countingPolicy') == SHARED_POLICY
    amount = calls * (MODEL_MICROS * model_multiplier + (0 if shared else COUNT_MICROS))
    occupied = occupied_usd(ledger)
    if ledger['startMicros'] - occupied - amount < ledger['floorMicros']:
        raise RuntimeError('Credit floor would be crossed')
    ledger['runs'].append({'id': run_id, 'calls': calls, 'reservedMicros': amount,
                           'modelMultiplier': model_multiplier,
                           'state': 'reserved', 'countingRateVerified': False})
    save(path, ledger)


def settle(path, run_id, model_calls, count_calls, usages):
    """2026-11-04: 검증된 사용량만 정산하고 계수 미확정·사용량 불명은 남긴다."""
    ledger = load(path)
    entry = next(row for row in ledger['runs'] if row['id'] == run_id)
    if entry['state'] != 'reserved':
        raise ValueError('Run already settled')
    if not 0 <= model_calls <= entry['calls'] or not 0 <= count_calls <= entry['calls']:
        raise ValueError('Unexpected additional provider dispatch')
    known = [row for row in usages if row.get('known') is True]
    if len(known) > model_calls:
        raise ValueError('Usage identity/count mismatch')
    # All input tokens use the conservative cache-write price, with no cache discount.
    generation = sum((int(row['inputTokens']) + 3) // 4
                     + (int(row['outputTokens']) + 1) // 2 for row in known)
    generation += (model_calls - len(known)) * MODEL_MICROS
    generation *= entry.get('modelMultiplier', 1)
    shared = ledger.get('countingPolicy') == SHARED_POLICY
    count_reserve = 0 if shared else count_calls * COUNT_MICROS
    entry.update(reservedMicros=generation + count_reserve,
                 generationUpperMicros=generation, countReserveMicros=count_reserve,
                 modelCalls=model_calls, countCalls=count_calls, state='settled_with_count_reserve')
    if ledger['startMicros'] - occupied_usd(ledger) < ledger['floorMicros']:
        raise RuntimeError('Unexpected usage crossed conservative floor')
    save(path, ledger)
    return {'startingUSD': ledger['startMicros'] / 1_000_000,
            'floorUSD': ledger['floorMicros'] / 1_000_000,
            'conservativeRemainingUSD': (ledger['startMicros'] - occupied_usd(ledger)) / 1_000_000,
            'generationUpperUSD': generation / 1_000_000,
            'unverifiedCountingReserveUSD': (SHARED_COUNT_MICROS if shared else count_reserve) / 1_000_000,
            'countReserveScope': 'all_runs' if shared else 'this_run'}


def occupied_usd(ledger):
    """2026-11-04: 승인된 공통 예약은 한 번만, 불명 생성은 실행별로 합산한다."""
    reserve = SHARED_COUNT_MICROS if ledger.get('countingPolicy') == SHARED_POLICY else 0
    return reserve + sum(row['reservedMicros'] for row in ledger['runs'])


def occupied_krw(ledger):
    """2026-11-04: 원래 원장 금액을 보존하며 승인된 세대별 유효 예약을 합산한다."""
    if ledger.get('countingPolicy') != SHARED_POLICY:
        return ledger['onboardingReserveMicros'] + sum(row['budgetMicros'] for row in ledger['runs'])
    return ledger['onboardingReserveMicros'] + SHARED_COUNT_KRW + sum(
        row.get('generationBudgetMicros', row['budgetMicros']) for row in ledger['runs'])


def approve_shared_counting(credit_path, krw_path, reports):
    """2026-11-04: 사용자 명시 승인 후에만 호출한다. 원장 백업·예약 이력을 보존한다.

    실행기와 같은 run.lock을 호출자가 먼저 보유해야 한다. 청구 확인/무료 판정이 아니다.
    """
    ledger = load(credit_path)
    krw = json.loads(krw_path.read_text(encoding='utf-8'))
    if ledger.get('countingPolicy') or krw.get('countingPolicy'):
        raise ValueError('Counting policy already reconciled')
    if any(row['state'] == 'reserved' for row in ledger['runs'] + krw['runs']):
        raise ValueError('Active or unresolved reservation must stay intact')
    original_usd, original_krw = occupied_usd(ledger), occupied_krw(krw)
    for row in ledger['runs']:
        if 'generationUpperMicros' not in row:
            raise ValueError('Generation upper bound is missing')
        row['previousReservedMicros'] = row['reservedMicros']
        row['previousCountReserveMicros'] = row['countReserveMicros']
        row['reservedMicros'] = row['generationUpperMicros']
        row['countReserveMicros'] = 0
    for row in krw['runs']:
        report = reports.get(row['id'])
        if not report or report.get('budgetUpperMicros') != row['budgetMicros']:
            raise ValueError('KRW run evidence mismatch')
        count = report['dispatchedCalls'] - report['modelCalls']
        generation = row['budgetMicros'] - count * 100_000_000
        if count < 0 or generation < 0:
            raise ValueError('Unexpected legacy counting policy')
        row['generationBudgetMicros'] = generation
        row['previousCountReserveMicros'] = count * 100_000_000
    stamp = datetime.now().astimezone().isoformat()
    for item, old in ((ledger, original_usd), (krw, original_krw)):
        item.update(countingPolicy=SHARED_POLICY, countingFeeVerified=False,
                    reconciliation={'approvedAt': stamp, 'previousOccupiedMicros': old,
                        'basis': 'Explicit user approval: generation costs plus shared USD2 contingency'})
    if ledger['startMicros'] - occupied_usd(ledger) < ledger['floorMicros']:
        raise RuntimeError('Approved policy would cross the credit floor')
    for path in (credit_path, krw_path):
        backup = path.with_suffix('.before-shared-counting.json')
        with backup.open('xb') as stream:
            stream.write(path.read_bytes())
    save(credit_path, ledger)
    save(krw_path, krw)


def initialize(path, balance_usd, floor_usd):
    """2026-11-04: 확인된 금액만 비공개 장부에 기록하며 기존 사용 이력 초기화를 금지한다."""
    if path.exists():
        raise ValueError('Existing credit ledger must not be reset')
    values = [Decimal(str(value)) * 1_000_000 for value in (balance_usd, floor_usd)]
    if any(not value.is_finite() or value != int(value) for value in values):
        raise ValueError('Invalid currency precision')
    start, floor = map(int, values)
    if not start > floor >= MIN_FLOOR_MICROS:
        raise ValueError('Invalid credit floor')
    save(path, {'basis': 'User-confirmed balance; no other API use reported',
                'startMicros': start, 'floorMicros': floor, 'runs': []})


def load(path):
    """2026-11-04: 확인되지 않은 잔액을 기본값으로 추측하지 않는다. 사용: reserve·settle."""
    ledger = json.loads(path.read_text(encoding='utf-8'))
    if any(type(ledger.get(key)) is not int for key in ('startMicros', 'floorMicros')):
        raise ValueError('Invalid credit basis')
    if not ledger['startMicros'] > ledger['floorMicros'] >= MIN_FLOOR_MICROS:
        raise ValueError('Invalid credit floor')
    if not isinstance(ledger.get('runs'), list):
        raise ValueError('Missing credit history')
    return ledger
