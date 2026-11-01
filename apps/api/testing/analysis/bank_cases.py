"""2026-11-01: 짧은 적요·불확실 상태·관계 범위의 개발 사례를 보완한다. 사용: 확장 평가.

합성 기관명은 역할 단서이며 실제 기관·개인의 자료가 아니다. 이 파일은 원천 상태를
금융 효과로 바꾸지 않으며 독립 최종 평가 자료나 실거래 분포를 주장하지 않는다.
"""
from build_cases import identity, request


# condition, merchant, memo, kind, direction, status, reflection, meaning, basic
SHORT_CASES = [
    ('employer_method_only', '합성고용주', '모바일이체', 'account_entry', 'in', 'posted', 'reflected', None, None),
    ('salary_unknown_state', '합성고용주', '급여', 'account_entry', 'in', 'unknown', 'unknown', 'salary', 'income'),
    ('employer_loan_unreflected', '합성고용주', '직원대여금', 'account_entry', 'in', 'posted', 'not_reflected', 'loan_proceeds', None),
    ('pension_state_not_reflection', '합성연금기금', '퇴직연금지급', 'account_entry', 'in', 'unknown', 'reflected', 'pension', 'income'),
    ('interest_unreflected', '합성은행', '예금이자', 'account_entry', 'in', 'posted', 'not_reflected', 'interest', 'income'),
    ('loan_components_unspecified', '합성은행', '대출원리금상환', 'account_entry', 'out', 'unknown', 'unknown', 'loan_repayment', None),
    ('insurer_ambiguous_refund', '합성보험기관', '환급', 'account_entry', 'in', 'posted', 'reflected', None, None),
    ('premium_return', '합성보험기관', '보험료반환', 'account_entry', 'in', 'posted', 'reflected', 'account_refund', None),
    ('insurer_loan', '합성보험기관', '보험계약대출', 'account_entry', 'in', 'posted', 'reflected', 'loan_proceeds', None),
    ('housing_method_only', '합성주택관리', 'CMS', 'account_entry', 'out', 'posted', 'reflected', None, None),
    ('housing_unknown_state', '합성주택관리', '주택관리비', 'account_entry', 'out', 'unknown', 'unknown', 'housing_management', 'expense'),
    ('utility_no_merchant', None, '가스요금', 'account_entry', 'out', 'posted', 'not_reflected', 'utility', 'expense'),
    ('device_not_telecom', '합성통신판매소', '단말기구매', 'card_purchase', 'out', 'unknown', 'not_applicable', 'retail', 'expense'),
    ('hospital_store_not_medical', '합성의원부설매점', '생수·과자구매', 'card_purchase', 'out', 'approved', 'not_applicable', 'groceries', 'expense'),
    ('medical_unknown_state', '합성의원', '진료비', 'card_purchase', 'out', 'unknown', 'not_applicable', 'medical', 'expense'),
    ('hospital_donation', '합성의원', '후원금', 'account_entry', 'out', 'posted', 'not_reflected', 'donation', 'expense'),
    ('room_reservation', '합성숙박시설', '객실예약', 'card_purchase', 'out', 'approved', 'not_applicable', 'lodging', 'expense'),
    ('hotel_dining_unknown_state', '합성숙박시설', '식사대금', 'card_purchase', 'out', 'unknown', 'not_applicable', 'dining', 'expense'),
    ('parking_unknown_state', '합성차량관리소', '주차료', 'card_purchase', 'out', 'unknown', 'not_applicable', 'vehicle_cost', 'expense'),
    ('tuition_unknown_state', '합성교육서비스', '수강료', 'card_purchase', 'out', 'unknown', 'not_applicable', 'education', 'expense'),
    ('subscription_short_memo', '합성영상서비스', '영상월정액', 'card_purchase', 'out', 'approved', 'not_applicable', 'subscription', 'expense'),
    ('private_asset_not_business', '합성영상서비스', '개인보유기기매각대금', 'account_entry', 'in', 'posted', 'reflected', 'asset_sale', None),
    ('cash_deposit_unconfirmed', '합성금융창구', '창구현금입금', 'account_entry', 'in', 'unknown', 'not_reflected', 'cash_deposit', None),
    ('atm_fee_not_withdrawal', '합성ATM', '현금인출수수료', 'account_entry', 'out', 'posted', 'reflected', 'bank_fee', 'expense'),
    ('refund_over_salary_memo', None, '급여', 'card_refund', 'in', 'unknown', 'unknown', 'refund', None),
    ('cancellation_over_loan_memo', None, '대출입금', 'card_cancellation', 'in', 'unknown', 'not_applicable', 'cancellation', None),
    ('cancellation_inquiry_not_event', '합성교통서비스', '승인취소문의', 'card_purchase', 'out', 'approved', 'not_applicable', None, 'expense'),
    ('account_refund_not_card_event', '합성가맹점', '물품대금환불', 'account_entry', 'in', 'unknown', 'unknown', 'account_refund', None),
]


def append_case(inputs, expected, index, payload, condition, meaning, basic, gap=None):
    """2026-11-01: 비공개 기준과 공개 입력을 다른 사전에 기록한다. 사용: add_cases."""
    key = f'X{index:05}'
    if key in inputs or key in expected:
        raise ValueError('Duplicate bank case identifier')
    inputs[key] = payload
    expected[key] = {
        'split': 'calibration', 'groupId': 'bank-conditions/' + condition,
        'familyLinks': ['synthetic-bank-conditions-v1', 'development-policy-v1'],
        'condition': condition,
        'items': [{'itemKey': payload['items'][0]['itemKey'], 'labelOrigin': 'authored_short_source_condition',
                   'inputSufficient': meaning is not None or gap is not None,
                   'meaning': meaning, 'basicType': basic, 'coverageGap': gap is not None,
                   'gapReason': gap,
                   'mustPreserve': ['source', 'salaryEvidence', 'settings', 'balance']}],
    }


def graph_case(index, condition):
    """2026-11-01: 목표 거래의 연결과 다른 거래의 연결을 구분한다. 사용: add_cases."""
    payload = request(index, {'recordKind': 'account_entry', 'direction': 'out',
                               'merchantName': None, 'description': '모바일이체'})
    target = payload['transactions'][0]
    peer_count = 3 if condition == 'two_disjoint_transfer_edges' else 2
    for offset in range(peer_count):
        peer = {**target, 'transactionId': identity(f'{index}/bank-peer/{offset}'),
                'direction': 'in' if offset % 2 == 0 else 'out', 'description': '계좌이체'}
        payload['transactions'].append(peer)
        payload['items'][0]['evidenceTransactionIds'].append(peer['transactionId'])
    rows = payload['transactions']
    if condition == 'relation_only_between_peers':
        payload['relations'] = [{'kind': 'internal_transfer', 'fromId': rows[2]['transactionId'],
                                 'toId': rows[1]['transactionId']}]
        return payload, None, None
    if condition == 'card_pair_not_bill_settlement':
        # One published account/card event pair is not a bill-payment settlement relation.
        payload['transactions'] = rows[:2]
        payload['items'][0]['evidenceTransactionIds'] = [row['transactionId'] for row in rows[:2]]
        rows[1].update(recordKind='card_purchase', direction='out', status='approved',
                       reflectionReason='not_applicable', description='온라인결제')
        payload['relations'] = [{'kind': 'card_account_pair', 'fromId': target['transactionId'],
                                 'toId': rows[1]['transactionId']}]
        return payload, None, None
    payload['relations'] = [{'kind': 'internal_transfer', 'fromId': target['transactionId'],
                             'toId': rows[1]['transactionId']}]
    if condition == 'two_disjoint_transfer_edges':
        payload['relations'].append({'kind': 'internal_transfer', 'fromId': rows[2]['transactionId'],
                                      'toId': rows[3]['transactionId']})
        return payload, 'self_transfer', 'internal_transfer'
    # Keep only target/peer for the existing-classification conflict; unrelated evidence is not needed.
    payload['transactions'] = rows[:2]
    payload['items'][0]['evidenceTransactionIds'] = [row['transactionId'] for row in rows[:2]]
    payload['currentClassifications'] = [{'transactionId': target['transactionId'], 'value': 'expense'}]
    return payload, 'self_transfer', None


def add_cases(inputs, expected, index, policy):
    """2026-11-01: 36개 짧은 근거·상태·관계 사례를 추가하고 마지막 ID를 반환한다. 사용: 확장 생성기."""
    for condition, merchant, memo, kind, direction, status, reflection, meaning, basic in SHORT_CASES:
        if meaning is not None and meaning not in policy:
            raise ValueError('Bank case meaning outside policy')
        index += 1
        payload = request(index, {'recordKind': kind, 'direction': direction,
                                  'merchantName': merchant, 'description': memo})
        payload['transactions'][0].update(status=status, reflectionReason=reflection)
        append_case(inputs, expected, index, payload, condition, meaning, basic)
    for condition in ('relation_only_between_peers', 'two_disjoint_transfer_edges',
                      'card_pair_not_bill_settlement', 'source_relation_existing_conflict'):
        index += 1
        payload, meaning, basic = graph_case(index, condition)
        append_case(inputs, expected, index, payload, condition, meaning, basic)
    for condition, memo, direction, current, meaning, basic in (
            ('matching_existing_income', '급여', 'in', 'income', 'salary', 'income'),
            ('explicit_null_existing_type', '통신요금', 'out', None, 'telecom', 'expense')):
        index += 1
        payload = request(index, {'recordKind': 'account_entry', 'direction': direction,
                                  'merchantName': None, 'description': memo})
        payload['currentClassifications'] = [{'transactionId': payload['transactions'][0]['transactionId'],
                                               'value': current}]
        append_case(inputs, expected, index, payload, condition, meaning, basic)
    for condition, memo, gap in (
            ('short_combined_purpose', '통신요금+수강료합산', 'multiple_explicit_purposes_without_primary'),
            ('short_storage_service', '물품보관서비스요금', 'explicit_service_outside_41_codes')):
        index += 1
        payload = request(index, {'recordKind': 'account_entry', 'direction': 'out',
                                  'merchantName': None, 'description': memo})
        append_case(inputs, expected, index, payload, condition, None, 'expense', gap)
    return index
