"""2026-11-01: 저장된 최종 판단을 오프라인 채점한다. 사용: CLI/테스트.

LLM·KMS·DB에 연결하지 않는다. --export-input은 비공개 정답을 읽지 않는다.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
from build_cases import CASES
from contract import model_input, validate_input, validate_output
from build_schemas import schemas

ROUTES = {'source_fact', 'user_confirmed', 'reused_result', 'llm', 'unresolved', 'processing_failure'}


def rate(numerator, denominator):
    """2026-11-01: 표본이 없으면 미측정을 유지한다. 사용: score."""
    return {'numerator': numerator, 'denominator': denominator,
            'rate': numerator / denominator if denominator else None}


def validate_labels(inputs, expected, routes):
    """2026-11-01: 정답·경로의 추가/누락/중복을 채점 전에 거절한다. 사용: score."""
    if set(inputs) != set(expected):
        raise ValueError('Evaluation input and label cases differ')
    if routes is not None and set(routes) != set(inputs):
        raise ValueError('Decision route cases differ')
    meaning_codes = schemas()['transactionMeaning.output.schema.json']['properties']['items']['items']['properties']['meaning']['properties']['value']['enum']
    for case_id, payload in inputs.items():
        validate_input(payload)
        requested = {row['itemKey'] for row in payload['items']}
        rows = expected[case_id]['items']
        keys = [row['itemKey'] for row in rows]
        if len(keys) != len(set(keys)) or set(keys) != requested:
            raise ValueError('Private labels do not match requested items')
        for truth in rows:
            if not isinstance(truth.get('inputSufficient'), bool):
                raise ValueError('Missing boolean evidence sufficiency')
            if not isinstance(truth.get('coverageGap', False), bool):
                raise ValueError('Invalid taxonomy coverage marker')
            if 'meaning' not in truth or 'basicType' not in truth:
                raise ValueError('Missing expected meaning or classification')
            if truth['meaning'] not in meaning_codes or truth['basicType'] not in (None, 'income', 'expense', 'internal_transfer', 'card_payment'):
                raise ValueError('Expected classification is outside the contract')
            if truth['inputSufficient'] != (truth['meaning'] is not None or truth.get('coverageGap', False)):
                raise ValueError('Contradictory private evidence sufficiency')
        if routes is not None:
            case_routes = routes[case_id]
            if set(case_routes) != requested or any(route not in ROUTES for route in case_routes.values()):
                raise ValueError('Missing or unsupported decision route')


def item_errors(truth, row, transaction_task, route):
    """2026-11-01: 오류 원인을 보존하고 한 항목의 합격 여부를 구분한다. 사용: score."""
    errors = []
    predicted = row['meaning']['value']
    if truth.get('coverageGap', False):
        errors.append('taxonomy_gap')
    if predicted != truth['meaning']:
        if predicted is None:
            errors.append('unnecessary_meaning_abstention')
        elif truth['meaning'] is None:
            errors.append('unsupported_meaning_assertion')
        else:
            errors.append('wrong_meaning')
    if transaction_task and row['classification']['value'] != truth['basicType']:
        if row['classification']['value'] is None:
            errors.append('unnecessary_basic_abstention')
        elif truth['basicType'] is None:
            errors.append('unsupported_basic_assertion')
        else:
            errors.append('wrong_basic_type')
    if route == 'processing_failure':
        errors.append('processing_failure')
    if route == 'unresolved' and (predicted is not None or
                                  transaction_task and row['classification']['value'] is not None):
        errors.append('route_conflict')
    return errors


def score(inputs, expected, responses, routes=None):
    """2026-11-01: 전건 오류와 LLM 거래 오류·실패 원인을 별도 기록한다. 사용: CLI/테스트."""
    validate_labels(inputs, expected, routes)
    if set(responses) - set(inputs):
        raise ValueError('Unknown evaluation case')
    truths = [row for case in expected.values() for row in case['items']]
    known = sum(row['inputSufficient'] and not row.get('coverageGap', False) for row in truths)
    total, unknown = len(truths), sum(not row['inputSufficient'] for row in truths)
    valid, known_correct, abstained, unsupported = 0, 0, 0, 0
    joint_correct, base_correct, base_total, transaction_correct = 0, 0, 0, 0
    route_counts = {} if routes is not None else None
    failures, categories, outcomes, reasons = [], {}, {}, Counter()

    def record(case_id, item_key, correct, transaction_task, errors):
        """2026-11-01: 실제 기록 경로와 항목별 오류를 누적한다. 사용: score."""
        route = routes[case_id][item_key] if routes is not None else None
        outcomes.setdefault(case_id, {})[item_key] = {
            'correct': correct, 'errors': errors,
            'taskKind': inputs[case_id]['semanticTaskKind'], 'route': route}
        reasons.update(errors)
        if routes is not None:
            counts = route_counts.setdefault(route, {'items': 0, 'errors': 0,
                                                     'transactionItems': 0, 'transactionErrors': 0})
            counts['items'] += 1
            counts['errors'] += not correct
            counts['transactionItems'] += transaction_task
            counts['transactionErrors'] += transaction_task and not correct

    for case_id, payload in inputs.items():
        labels = {row['itemKey']: row for row in expected[case_id]['items']}
        transaction_task = payload['semanticTaskKind'] == 'transactionMeaning'
        base_total += len(labels) if transaction_task else 0
        invalid = 'missing_response' if case_id not in responses else None
        if invalid is None:
            try:
                validate_output(payload, responses[case_id])
            except (ValueError, KeyError, TypeError):
                invalid = 'invalid_response'
        if invalid:
            failures.append(case_id)
            for truth in labels.values():
                errors = [invalid]
                if truth.get('coverageGap', False):
                    errors.append('taxonomy_gap')
                record(case_id, truth['itemKey'], False, transaction_task, errors)
                if truth['meaning']:
                    counts = categories.setdefault(truth['meaning'], {
                        'truePositive': 0, 'falsePositive': 0, 'falseNegative': 0})
                    counts['falseNegative'] += 1
            continue
        valid += len(labels)
        received = {row['itemKey']: row for row in responses[case_id]['items']}
        for item_key, truth in labels.items():
            row = received[item_key]
            route = routes[case_id][item_key] if routes is not None else None
            errors = item_errors(truth, row, transaction_task, route)
            correct = not errors
            record(case_id, item_key, correct, transaction_task, errors)
            joint_correct += correct
            predicted = row['meaning']['value']
            meaning_matches = predicted == truth['meaning'] and not truth.get('coverageGap', False)
            if truth['inputSufficient'] and not truth.get('coverageGap', False):
                known_correct += meaning_matches
                abstained += predicted is None
            elif not truth['inputSufficient']:
                unsupported += predicted is not None
            if transaction_task:
                base_correct += row['classification']['value'] == truth['basicType']
                transaction_correct += correct
            for code in set(filter(None, [predicted, truth['meaning']])):
                counts = categories.setdefault(code, {'truePositive': 0, 'falsePositive': 0, 'falseNegative': 0})
                counts['truePositive'] += predicted == code and truth['meaning'] == code and meaning_matches
                counts['falsePositive'] += predicted == code and truth['meaning'] != code
                counts['falseNegative'] += truth['meaning'] == code and not meaning_matches
    llm = route_counts.get('llm', {}) if route_counts is not None else None
    return {'evaluationKind': 'saved_response_evaluation', 'evaluationLayer': 'analysis_candidate_contract',
            'wholePipelineMeasured': False, 'cases': len(inputs), 'items': total,
            'jointError': rate(total - joint_correct, total),
            'contractPass': rate(valid, total), 'supportedCaseCorrect': rate(known_correct, known),
            'unnecessaryAbstention': rate(abstained, known), 'unsupportedAssertion': rate(unsupported, unknown),
            'basicTypeCorrect': rate(base_correct, base_total),
            'invalidOrMissingCases': failures, 'failureReasons': dict(sorted(reasons.items())),
            'itemOutcomes': outcomes, 'perMeaning': categories,
            'taxonomyCoverageGaps': sum(row.get('coverageGap', False) for row in truths),
            'answerableWithinTaxonomy': known, 'insufficientEvidenceItems': unknown,
            'transactionTarget': {'examples': 100000, 'maximumErrors': 10,
                                  'evaluationSubject': 'PAYSE whole decision pipeline; LLM subset reported separately',
                                  'scoredTransactions': base_total, 'jointErrors': base_total - transaction_correct,
                                  'status': 'not_evaluated',
                                  'reason': '저장 응답 채점은 독립 최종셋·실제 실행·비용 근거를 인증하지 않음'},
            'byDecisionSource': route_counts,
            'llmTransactionError': rate(llm.get('transactionErrors', 0), llm.get('transactionItems', 0))
                                   if llm is not None else None,
            'actualTokens': None, 'actualCost': None, 'latency': None,
            'limits': 'supportedCaseCorrect는 의미만 비교. jointError는 기본/의미/누락/실패/범위부족을 함께 센다. '
                      'failureReasons는 중복 사유이며 jointError는 항목당 최대 1건이다. 실제 성능·근거 사람 검토는 별도다.'}


def compare(inputs, expected, baseline, responses, baseline_routes=None, routes=None):
    """2026-11-01: 같은 항목의 개선과 악화를 상쇄하지 않고 보고한다. 사용: CLI/회귀 테스트."""
    before = score(inputs, expected, baseline, baseline_routes)
    after = score(inputs, expected, responses, routes)
    improved, regressed = [], []
    for case_id, items in before['itemOutcomes'].items():
        for key, prior in items.items():
            current = after['itemOutcomes'][case_id][key]
            if prior['correct'] != current['correct']:
                (improved if current['correct'] else regressed).append({'caseId': case_id, 'itemKey': key})
    return {'beforeJointError': before['jointError'], 'afterJointError': after['jointError'],
            'improvedItems': improved, 'regressedItems': regressed,
            'qualityMeasuredWithProvider': False}


def read_cases(path, field):
    """2026-11-01: JSON/JSONL 사례를 중복 ID 덮어쓰기 없이 읽는다. 사용: CLI."""
    if path.suffix != '.jsonl':
        return read_json(path)
    records = {}
    with path.open(encoding='utf-8') as source:
        for line in source:
            row = json.loads(line, object_pairs_hook=unique_fields)
            if set(row) != {'caseId', field} or row['caseId'] in records:
                raise ValueError('Invalid or duplicate JSONL case')
            records[row['caseId']] = row[field]
    return records


def unique_fields(pairs):
    """2026-11-01: JSON 중복 키가 기존 응답·정답을 덮어쓰지 않게 거절한다. 사용: read_json/read_cases."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON field')
        result[key] = value
    return result


def read_json(path):
    """2026-11-01: 응답·경로·정답 파일을 중복 필드 검사와 함께 읽는다. 사용: 평가 CLI."""
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=unique_fields)


def main():
    """2026-11-01: 입력 내보내기·저장 응답 채점·최종셋 적격성 검사만 수행한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--export-input', type=Path)
    mode.add_argument('--responses', type=Path)
    parser.add_argument('--dataset', choices=['base', 'expanded'], default='base')
    parser.add_argument('--inputs', type=Path)
    parser.add_argument('--labels', type=Path)
    parser.add_argument('--routes', type=Path)
    parser.add_argument('--usage', type=Path, help='Offline attempt usage records; no provider call')
    parser.add_argument('--baseline-responses', type=Path)
    parser.add_argument('--baseline-routes', type=Path)
    parser.add_argument('--final', action='store_true')
    parser.add_argument('--development-inputs', type=Path)
    parser.add_argument('--development-labels', type=Path)
    args = parser.parse_args()
    expanded = CASES.parents[4] / '.harness' / 'analysis-evaluation'
    default_input = expanded / 'inputs.jsonl' if args.dataset == 'expanded' else CASES / 'inputs.json'
    default_labels = expanded / 'expected.private.jsonl' if args.dataset == 'expanded' else CASES / 'expected.private.json'
    inputs = read_cases(args.inputs or default_input, 'input')
    if args.export_input:
        if args.routes or args.usage or args.baseline_responses or args.baseline_routes or args.final:
            parser.error('Scoring arguments require --responses')
        with args.export_input.open('x', encoding='utf-8') as output:
            json.dump({key: model_input(value) for key, value in inputs.items()}, output, ensure_ascii=False, indent=2)
        print(f'Exported {len(inputs)} inputs without private labels; external calls: 0')
        return
    expected = read_cases(args.labels or default_labels, 'expected')
    eligibility = None
    if args.final:
        if not args.development_inputs or not args.development_labels:
            parser.error('--final requires both development exposure files')
        from partitions import assert_final
        eligibility = assert_final(inputs, expected,
                                   read_cases(args.development_inputs, 'input'),
                                   read_cases(args.development_labels, 'expected'))
    responses = read_json(args.responses)
    routes = read_json(args.routes) if args.routes else None
    report = score(inputs, expected, responses, routes)
    if args.usage:
        from usage import read_usage, summarize
        report['recordedUsage'] = summarize(inputs, read_usage(args.usage))
    if eligibility is not None:
        report['finalDatasetChecks'] = eligibility
    if args.baseline_routes and not args.baseline_responses:
        parser.error('--baseline-routes requires --baseline-responses')
    if args.baseline_responses:
        baseline = read_json(args.baseline_responses)
        baseline_routes = read_json(args.baseline_routes) if args.baseline_routes else None
        report['comparison'] = compare(inputs, expected, baseline, responses, baseline_routes, routes)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
