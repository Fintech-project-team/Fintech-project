"""2026-11-01: 재현 실행의 성공·실패를 비공개 정답과 별도로 채점한다. 사용: CLI/테스트.

공급자 배치 실패와 독립 재사용 성공을 분리한다. 운영 적용 분류·금융 금액·분기
합계는 계산하지 않으며 합성 기록을 실제 모델 성능으로 인증하지 않는다.
"""
import argparse
from collections import Counter
from pathlib import Path

from evaluate import item_errors, rate, read_json, validate_labels
from replay import replay, write_new


def score_replay(cases, expected, envelopes):
    """2026-11-01: 정답을 실행기에 전달하지 않고 재현 뒤 항목별로 채점한다. 사용: CLI/테스트."""
    execution = replay(cases, envelopes)
    inputs = {key: case['payload'] for key, case in cases.items()}
    validate_labels(inputs, expected, execution['routes'])
    counts, reasons, outcomes = {}, Counter(), {}
    total, errors, transaction_total, transaction_errors, llm_total, llm_errors = (0,) * 6
    for case_id, payload in inputs.items():
        transaction = payload['semanticTaskKind'] == 'transactionMeaning'
        outcomes[case_id] = {}
        for truth in expected[case_id]['items']:
            key = truth['itemKey']
            row = execution['items'][case_id][key]
            if row['error']:
                item_reasons = [row['error']]
                if truth.get('coverageGap', False):
                    item_reasons.append('taxonomy_gap')
            else:
                item_reasons = item_errors(truth, row['result'], transaction, row['route'])
            wrong = bool(item_reasons)
            total += 1
            errors += wrong
            transaction_total += transaction
            transaction_errors += transaction and wrong
            llm_total += transaction and row['providerAttemptRecorded']
            llm_errors += transaction and row['providerAttemptRecorded'] and wrong
            route = counts.setdefault(row['route'], {'items': 0, 'errors': 0})
            route['items'] += 1
            route['errors'] += wrong
            reasons.update(item_reasons)
            outcomes[case_id][key] = {'correct': not wrong, 'errors': item_reasons}
    return {'evaluationKind': 'offline_replay_candidate_evaluation', 'wholePipelineMeasured': False,
            'actualModelPerformanceMeasured': False, 'externalCalls': 0,
            'jointError': rate(errors, total), 'transactionJointError': rate(transaction_errors, transaction_total),
            'recordedLlmTransactionError': rate(llm_errors, llm_total),
            'byDecisionSource': counts, 'failureReasons': dict(sorted(reasons.items())),
            'itemOutcomes': outcomes, 'actualTokens': None, 'actualCost': None,
            'targetStatus': 'not_evaluated',
            'limits': '후보 경로의 기록 재현이며 실모델·DB 적용·독립 최종 평가가 아니다. '
                      '전송 기록이 결합된 실패도 기록된 LLM 분모에 포함한다. '
                      '불완전 responses만 기존 score에 넘기면 재사용 성공이 실패로 섞이므로 이 채점기를 사용한다.'}


def main():
    """2026-11-01: 실행 입력·응답·정답을 별도 파일에서 읽는다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('cases', 'expected', 'responses', 'output'):
        parser.add_argument('--' + key, type=Path, required=True)
    args = parser.parse_args()
    cases = read_json(args.cases)
    expected = read_json(args.expected)
    responses = read_json(args.responses)
    report = score_replay(cases, expected, responses)
    write_new(args.output, report)


if __name__ == '__main__':
    main()
