"""2026-11-03: 연간 공개 입력·사전 정답을 동결하고 실제 저장 결과를 채점한다. 사용: CLI.

정답 파일은 모델 실행 후 로컬 채점에만 사용한다. 이 도구 자체는 공급자를 호출하지 않는다.
"""
import argparse
from collections import Counter, defaultdict
import copy
from datetime import datetime
import hashlib
import json
from pathlib import Path
import sys
from uuid import NAMESPACE_URL, uuid5

API = Path(__file__).resolve().parents[2]
ROOT = API.parents[1]
sys.path[:0] = [str(API), str(API / 'fixtures'), str(Path(__file__).resolve().parent)]
from contract import validate_input, validate_output
from evaluate import item_errors, rate, validate_labels

FIELDS = ('transactionId', 'recordKind', 'direction', 'status', 'reflectionReason',
          'merchantName', 'description', 'originalTransactionId')
FILES = ('source.json', 'inputs.json', 'expected.private.json')


def identity(value):
    """2026-11-03: 정답 문자열을 포함하지 않는 안정된 항목 ID를 만든다. 사용: requests."""
    return str(uuid5(NAMESPACE_URL, 'gamma-evaluation/' + value))


def recurring_candidates(source):
    """2026-11-03: 공개 원천만으로 최근 3개월 시험용 반복 입력을 준비한다. 사용: requests.

    월별 한 건·동일 일자/금액의 엄격한 부분집합이며 Flutter의 일반 탐지기를 대체하지 않는다.
    """
    groups = defaultdict(list)
    for row in source['transactions']:
        stamp = row['bookingDate']
        if row['recordKind'] != 'account_entry' or row['direction'] != 'out' or not stamp:
            continue
        if stamp[:7] not in ('2026-08', '2026-09', '2026-10') or not row['merchantName']:
            continue
        key = (row['accountId'], row['merchantName'], row['description'], stamp[8:], row['amountKRW'])
        groups[key].append(row)
    candidates = []
    for key, rows in sorted(groups.items(), key=lambda item: repr(item[0])):
        if len(rows) != 3 or len({row['bookingDate'][:7] for row in rows}) != 3:
            continue
        rows.sort(key=lambda row: row['bookingDate'])
        refs = [row['transactionId'] for row in rows]
        candidates.append({'candidateKey': identity('/'.join(refs)),
            'sourceVersion': source['sourceVersion'], 'ruleVersion': source['ruleVersion'],
            'evidenceTransactionIds': refs, 'normalizedName': key[1],
            'suggestedAmountKRW': rows[-1]['amountKRW'], 'suggestedDay': int(key[3]),
            'features': {'occurrenceCount': 3, 'observedMonths': ['2026-08', '2026-09', '2026-10'],
                'dayWithinRule': True, 'amountWithinRule': True, 'hasUnresolvedReversal': False}})
    return candidates


def requests(source, batch_size=10):
    """2026-11-03: 정답 없이 원천 관계·원거래를 보존한 10건 입력을 만든다. 사용: freeze."""
    context = {key: source[key] for key in
               ('schemaVersion', 'dataVersion', 'sourceVersion', 'ruleVersion', 'asOf')}
    context.update(schemaVersion='PAYSE-API-0.6-4', inputRevision=1,
                   localSessionEpoch=1, selectedAccountIds=[])
    base = {'contractVersion': 'PAYSE-ANALYSIS-1', 'semanticTaskKind': 'transactionMeaning',
            'context': context, 'items': [], 'transactions': [], 'relations': [],
            'unavailableReferences': [], 'currentClassifications': [], 'candidates': []}
    rows = sorted(source['transactions'], key=lambda row: (row['occurredAt'], row['transactionId']))
    by_id = {row['transactionId']: row for row in rows}
    links = defaultdict(set)
    for row in source['transactionRelations']:
        links[row['fromId']].add(row['toId'])
        links[row['toId']].add(row['fromId'])
    cases = []
    for offset in range(0, len(rows), batch_size):
        payload = copy.deepcopy(base)
        evidence = set()
        for row in rows[offset:offset + batch_size]:
            target = row['transactionId']
            refs = {target, *links[target]}
            if row['originalTransactionId']:
                refs.add(row['originalTransactionId'])
            payload['items'].append({'itemKey': identity(target), 'targetTransactionId': target,
                                     'candidateKey': None, 'evidenceTransactionIds': sorted(refs)})
            evidence.update(refs)
        payload['transactions'] = [{key: by_id[ref][key] for key in FIELDS} for ref in sorted(evidence)]
        payload['relations'] = [{key: row[key] for key in ('kind', 'fromId', 'toId')}
                                for row in source['transactionRelations']
                                if row['fromId'] in evidence and row['toId'] in evidence]
        validate_input(payload)
        cases.append({'name': f'T{offset // batch_size + 1:04}', 'input': payload})
    candidates = recurring_candidates(source)
    for offset in range(0, len(candidates), 20):
        payload = copy.deepcopy(base)
        payload['semanticTaskKind'] = 'recurringMeaning'
        payload['candidates'] = candidates[offset:offset + 20]
        evidence = set()
        for row in payload['candidates']:
            refs = row['evidenceTransactionIds']
            payload['items'].append({'itemKey': row['candidateKey'], 'targetTransactionId': None,
                                     'candidateKey': row['candidateKey'], 'evidenceTransactionIds': refs})
            evidence.update(refs)
        payload['transactions'] = [{key: by_id[ref][key] for key in FIELDS} for ref in sorted(evidence)]
        validate_input(payload)
        cases.append({'name': f'R{offset // 20 + 1:04}', 'input': payload})
    return cases


def category(truth):
    """2026-11-03: 정답의 사전 난점에 따라 보고 유형을 고정한다. 사용: freeze."""
    condition = truth['condition']
    if 'transfer' in condition or truth['meaning'] == 'self_transfer':
        return 'transfer'
    if any(word in condition for word in ('salary', 'employer', 'regular_amount', 'bonus', 'employee')):
        return 'salary_confounders'
    if any(word in condition for word in ('refund', 'cancel', 'reversed')):
        return 'cancellation_refund'
    if condition.startswith('monthly_'):
        return 'recurring_transactions'
    return 'other_transactions'


def freeze(directory):
    """2026-11-03: 모델 실행 전에 입력과 정답을 별도 파일·해시로 확정한다. 사용: CLI."""
    from testing.scenarios.gamma_challenge import build
    from testing.analysis.gamma_labels import label
    source, gold = build()
    cases = requests(source)
    expected = {}
    recurring = {tuple(sorted(row['transactionIds'])): row for row in gold['recurring']}
    for case in cases:
        labels = []
        for item in case['input']['items']:
            if item['targetTransactionId']:
                truth = copy.deepcopy(gold['transactions'][item['targetTransactionId']])
                truth['category'] = category(truth)
            else:
                original = recurring[tuple(sorted(item['evidenceTransactionIds']))]
                truth = label(original['meaning'], None, original['condition'],
                              'recurring_clear' if original['meaning'] else 'recurring_ambiguous')
                truth['category'] = 'recurring_candidates'
            truth.update(itemKey=item['itemKey'], targetTransactionId=item['targetTransactionId'],
                         requiredEvidenceTransactionIds=item['evidenceTransactionIds'])
            labels.append(truth)
        expected[case['name']] = {'items': labels}
    validate_labels({row['name']: row['input'] for row in cases}, expected, None)
    directory.mkdir(parents=True, exist_ok=False)
    documents = dict(zip(FILES, (source, cases, expected)))
    hashes = {}
    for name, value in documents.items():
        body = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode('utf-8')
        (directory / name).write_bytes(body)
        hashes[name] = hashlib.sha256(body).hexdigest()
    labels = [row for group in expected.values() for row in group['items']]
    manifest = {'version': 'gamma-evaluation-1', 'frozenAt': datetime.now().astimezone().isoformat(),
        'sha256': hashes, 'transactions': len(source['transactions']), 'analysisItems': len(labels),
        'batches': len(cases), 'recurringCandidates': sum(row['category'] == 'recurring_candidates' for row in labels),
        'categories': dict(Counter(row['category'] for row in labels)),
        'difficulties': dict(Counter(row['difficulty'] for row in labels)),
        'expectedReviews': dict(Counter(row['expectedReview'] for row in labels)),
        'independentHoldout': False, 'modelCalls': 0,
        'profile': {'inputLimit': 12000, 'outputLimit': 4000, 'timeoutSeconds': 20,
                    'concurrency': 1, 'runReserveKRW': 25000},
        'limits': '합성 개발 자료. 반복 후보는 엄격한 동일 일자/금액 부분집합. 실제 Flutter UI·전체 판단 어댑터 평가 아님.'}
    (directory / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    return manifest


def verify_bundle(directory):
    """2026-11-03: 실행 전후 동결 입력·정답 변경과 누락을 거절한다. 사용: runner, score_run."""
    manifest = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    if manifest['version'] != 'gamma-evaluation-1' or set(manifest['sha256']) != set(FILES):
        raise ValueError('Unknown evaluation manifest')
    for name in FILES:
        path = directory / name
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != manifest['sha256'][name]:
            raise ValueError('Frozen evaluation material changed')
    return manifest


def score_run(directory, summary):
    """2026-11-03: 저장·조회된 실제 의미값과 사전 정답을 항목별 채점한다. 사용: runner, CLI.

    2026-11-04: 전체 요청 완료 표식과 단조 시계 측정이 함께 있는 실행만 시간 실측으로 표시한다.
    """
    manifest = verify_bundle(directory)
    expected = json.loads((directory / 'expected.private.json').read_text(encoding='utf-8'))
    cases = json.loads((directory / 'inputs.json').read_text(encoding='utf-8'))
    inputs = {row['name']: row['input'] for row in cases}
    validate_labels(inputs, expected, None)
    observations = {row['name']: row for row in summary.get('cases', [])}
    if len(observations) != len(summary.get('cases', [])) or set(observations) - set(inputs):
        raise ValueError('Duplicate or unknown live result')
    outcomes = []
    for name, payload in inputs.items():
        observation = observations.get(name, {})
        predictions = observation.get('interpretations', [])
        indexed = {row['itemKey']: row for row in predictions}
        requested = {row['itemKey'] for row in payload['items']}
        invalid = len(indexed) != len(predictions) or bool(set(indexed) - requested)
        if predictions and not invalid:
            subset = copy.deepcopy(payload)
            subset['items'] = [row for row in subset['items'] if row['itemKey'] in indexed]
            refs = {ref for row in subset['items'] for ref in row['evidenceTransactionIds']}
            subset['transactions'] = [row for row in subset['transactions'] if row['transactionId'] in refs]
            subset['relations'] = [row for row in subset['relations'] if {row['fromId'], row['toId']} <= refs]
            subset['currentClassifications'] = [row for row in subset['currentClassifications'] if row['transactionId'] in refs]
            candidate_keys = {row['candidateKey'] for row in subset['items']}
            subset['candidates'] = [row for row in subset['candidates'] if row['candidateKey'] in candidate_keys]
            try:
                validate_output(subset, {'meaningPolicyVersion': 'PAYSE-MEANING-1', 'items': predictions})
            except (ValueError, KeyError, TypeError):
                invalid = True
        for truth in expected[name]['items']:
            row = indexed.get(truth['itemKey'])
            errors = []
            if row is None or invalid:
                errors = ['invalid_response' if invalid else 'missing_or_failed_result']
                row = None
            else:
                errors = item_errors(truth, row, payload['semanticTaskKind'] == 'transactionMeaning', 'llm')
                if row['meaning']['reasonCode'] != truth['expectedMeaningReason']:
                    errors.append('wrong_meaning_reason')
                if not set(truth['requiredEvidenceTransactionIds']).issubset(row['evidenceTransactionIds']):
                    errors.append('missing_required_evidence')
            predicted = row['meaning']['value'] if row else None
            review = None if row is None else 'candidate_confirmation' if predicted else (
                'taxonomy_review' if row['meaning']['reasonCode'] == 'outside_taxonomy'
                else 'ask_user_for_missing_information')
            decision_errors = [error for error in errors if error != 'taxonomy_gap']
            meaning_matches = row is not None and predicted == truth['meaning']
            basic_matches = row is not None and (payload['semanticTaskKind'] != 'transactionMeaning'
                or row['classification']['value'] == truth['basicType'])
            outcomes.append({'caseId': name, 'itemKey': truth['itemKey'], 'category': truth['category'],
                'taskKind': payload['semanticTaskKind'],
                'condition': truth['condition'], 'difficulty': truth['difficulty'],
                'expectedMeaning': truth['meaning'], 'predictedMeaning': predicted,
                'expectedBasic': truth['basicType'],
                'predictedBasic': row.get('classification', {}).get('value') if row else None,
                'expectedReview': truth['expectedReview'], 'actualReview': review,
                'expectedMeaningReason': truth['expectedMeaningReason'],
                'actualMeaningReason': row['meaning']['reasonCode'] if row else None,
                'reason': row['reason'] if row else None, 'validResult': row is not None,
                'correct': not errors, 'decisionMatches': not decision_errors,
                'meaningMatches': meaning_matches, 'basicMatches': basic_matches,
                'valueMatches': meaning_matches and basic_matches,
                'reviewMatches': row is not None and review == truth['expectedReview'],
                'errors': errors, 'expectedEvidenceIds': truth['requiredEvidenceTransactionIds'],
                'actualEvidenceIds': row['evidenceTransactionIds'] if row else [],
                'state': observation.get('state', 'not_executed')})
    transactions = [row for row in outcomes if row['taskKind'] == 'transactionMeaning']
    recurring = [row for row in outcomes if row['taskKind'] == 'recurringMeaning']
    elapsed = summary.get('pipelineElapsedMillis')
    measured = (summary.get('evaluationComplete') is True and len(observations) == len(inputs)
                and type(elapsed) is int and elapsed >= 0)
    return {'evaluationKind': 'gamma_year_live_saved_results', 'manifest': manifest,
            'wholePipelineMeasured': measured, 'pipelineElapsedMillis': elapsed if measured else None,
            'timingScope': 'first_http_request_to_last_saved_result_query' if measured else None,
            'byCategory': grouped(outcomes, 'category'),
            'byDifficulty': grouped(outcomes, 'difficulty'), 'overall': metrics(outcomes),
            'transactions': metrics(transactions), 'recurringCandidates': metrics(recurring),
            'perMeaning': confusion(transactions), 'perRecurringMeaning': confusion(recurring), 'items': outcomes,
            'limits': '모델에 공개한 근거만 채점. 설명의 자연어 타당성은 표본 검토가 필요하며 앱 확인 UI는 별도다.'}


def metrics(rows):
    """2026-11-03: 실패·정상 유보·불필요 유보의 분모를 분리한다. 사용: score_run, grouped."""
    total = len(rows)
    unknown = [row for row in rows if row['expectedReview'] == 'ask_user_for_missing_information']
    known = [row for row in rows if row['expectedMeaning'] is not None]
    return {'items': total, 'accuracy': rate(sum(row['correct'] for row in rows), total),
        'meaningAccuracy': rate(sum(row['meaningMatches'] for row in rows), total),
        'basicAccuracy': rate(sum(row['basicMatches'] for row in rows), total),
        'valueAccuracy': rate(sum(row['valueMatches'] for row in rows), total),
        'decisionMatch': rate(sum(row['decisionMatches'] for row in rows), total),
        'reviewMatch': rate(sum(row['reviewMatches'] for row in rows), total),
        'failures': sum(not row['validResult'] for row in rows),
        'abstention': rate(sum(row['validResult'] and row['predictedMeaning'] is None for row in rows), total),
        'correctUnknown': rate(sum(row['validResult'] and row['predictedMeaning'] is None and row['reviewMatches'] for row in unknown), len(unknown)),
        'unsupportedAssertion': rate(sum(row['validResult'] and row['predictedMeaning'] is not None for row in unknown), len(unknown)),
        'unnecessaryAbstention': rate(sum(row['validResult'] and row['predictedMeaning'] is None for row in known), len(known)),
        'errorReasons': dict(Counter(error for row in rows for error in row['errors']))}


def grouped(rows, field):
    """2026-11-03: 사전에 고정한 유형별로 같은 지표를 계산한다. 사용: score_run."""
    return {value: metrics([row for row in rows if row[field] == value])
            for value in sorted({row[field] for row in rows})}


def confusion(rows):
    """2026-11-03: 의미별 TP/FP/FN/TN과 정밀도·재현율·오탐률을 제공한다. 사용: score_run."""
    result = {}
    for meaning in sorted({row[key] for row in rows for key in ('expectedMeaning', 'predictedMeaning') if row[key]}):
        tp = sum(row['expectedMeaning'] == meaning and row['validResult'] and row['predictedMeaning'] == meaning for row in rows)
        fp = sum(row['expectedMeaning'] != meaning and row['validResult'] and row['predictedMeaning'] == meaning for row in rows)
        positive = sum(row['expectedMeaning'] == meaning for row in rows)
        negative = len(rows) - positive
        result[meaning] = {'truePositive': tp, 'falsePositive': fp, 'falseNegative': positive - tp,
            'trueNegative': negative - fp, 'precision': rate(tp, tp + fp),
            'recall': rate(tp, positive), 'falsePositiveRate': rate(fp, negative)}
    return result


def main():
    """2026-11-03: 오프라인 준비 또는 실제 결과 채점만 실행한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', type=Path)
    parser.add_argument('--dataset', type=Path)
    parser.add_argument('--summary', type=Path)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.prepare:
        print(json.dumps(freeze(args.prepare), ensure_ascii=False))
    elif args.dataset and args.summary and args.out:
        report = score_run(args.dataset, json.loads(args.summary.read_text(encoding='utf-8')))
        args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(report['overall'], ensure_ascii=False))
    else:
        parser.error('Use --prepare or --dataset --summary --out')


if __name__ == '__main__':
    main()
