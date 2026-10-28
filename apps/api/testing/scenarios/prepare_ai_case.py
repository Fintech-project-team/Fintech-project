"""2026-10-28: 감마의 모델 입력·모의 오판·비공개 정답을 파일별로 분리한다.

실제 LLM 호출·DB 저장·급여 확인 변경을 하지 않는다. 사용: CLI와 데이터 검증.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'fixtures'))
from demo_cases import one
from validate import validate_directory


def prepare(directory):
    """2026-10-28: 검증된 원천 ID로 세 가지 평가 자료를 만든다. 사용: main, 테스트."""
    validate_directory(directory)
    catalog = json.loads((directory / 'catalog.json').read_text(encoding='utf-8'))
    case = one((row for row in catalog['cases'] if row['id'] == 'gamma-ai-misread'), 'gamma case')
    snapshot = json.loads((directory / case['file']).read_text(encoding='utf-8'))
    transaction_id = case['expected']['preparationTransactionIds']['ambiguous-income']
    transaction = one((row for row in snapshot['transactions']
                       if row['transactionId'] == transaction_id), 'ambiguous deposit')
    if (transaction['userId'] != snapshot['userId'] or transaction['recordKind'] != 'account_entry'
            or transaction['direction'] != 'in' or transaction['balanceReflected'] is not True):
        raise ValueError('Expected one owned, reflected bank deposit')
    salary = snapshot['settings']['salary']
    model_input = {
        'asOf': snapshot['asOf'],
        'salarySettings': {key: salary[key] for key in ('salaryDay', 'salaryAmountKRW', 'salaryAccountId')},
        'transactions': [{key: transaction[key] for key in (
            'transactionId', 'accountId', 'recordKind', 'amountKRW', 'direction',
            'bookingDate', 'merchantName', 'description', 'balanceReflected',
        )}],
    }
    mock_output = {
        'simulationOnly': True, 'publicApiSchema': False, 'storedInDatabase': False,
        'items': [{'evidenceTransactionIds': [transaction_id], 'interpretation': 'salary',
                   'explanation': '월급 설정과 입금일·금액이 같아 급여라고 판단했습니다.'}],
    }
    expected = {
        'simulationOnly': True, 'userId': snapshot['userId'], 'transactionId': transaction_id,
        'sourceVersion': snapshot['sourceVersion'],
        'authorKnownMeaning': 'loan',
        'inputSufficientToEstablishMeaning': False,
        'acceptableInterpretation': 'unknown_or_unconfirmed_candidate',
        'incorrectInterpretation': 'salary_asserted_without_support',
        'sourceSalaryEvidence': salary['receiptEvidence'],
        'mustPreserve': ['amountKRW', 'bookingDate', 'accountBalance', 'receiptEvidence', 'salarySettings'],
        'followUpChecks': ['user_correction', 'individual_memory_deletion', 'same_evidence_suppression'],
        'runtimeChecksExecuted': False,
        'storageFollowUp': '#32 분석 저장 구현 후 일반 분석 테이블·암호화 경로로 적재 검증',
    }
    return {'model-input.json': model_input, 'mock-output.json': mock_output, 'expected.json': expected}


def main():
    """2026-10-28: 새 출력 폴더에만 평가 파일을 기록한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    payloads = prepare(args.directory)
    args.out.mkdir(parents=True, exist_ok=False)
    for name, payload in payloads.items():
        (args.out / name).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n',
                                    encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
