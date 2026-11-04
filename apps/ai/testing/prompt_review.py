"""2026-11-04: 동결된 사례를 분류하고 동일 표본의 프롬프트 결과를 비교한다. 사용: CLI.

오프라인 도구다. 정답은 평가에만 사용하고 공개 교육 프롬프트로 자동 추출하지 않는다.
"""
import argparse
from collections import Counter, defaultdict
import copy
from datetime import datetime
import hashlib
import json
from pathlib import Path
import statistics
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'apps/api/testing/analysis'))
from gamma_evaluation import FILES, score_run, verify_bundle


def read(path):
    """2026-11-04: 명시적으로 지정한 JSON만 읽는다. 사용: CLI, catalog, subset, compare."""
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write(path, value):
    """2026-11-04: 비밀·원문이 없는 집계 또는 명시된 로컬 평가 자료를 기록한다. 사용: CLI."""
    Path(path).write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n',
                          encoding='utf-8')


def catalog(dataset, summary):
    """2026-11-04: 유형별 정답·오류 빈도와 가명 합성 예시 한 개를 정리한다. 사용: CLI.

    출력에는 사용자/계좌/거래 ID나 결과 원문이 없으며 운영 리소스로 사용하지 않는다.
    """
    scored = score_run(dataset, summary)
    source = read(dataset / 'source.json')
    by_id = {row['transactionId']: row for row in source['transactions']}
    expected = read(dataset / 'expected.private.json')
    truth = {(case, row['itemKey']): row for case, group in expected.items() for row in group['items']}
    groups = defaultdict(list)
    for row in scored['items']:
        groups[(row['category'], row['condition'], row['difficulty'])].append(row)
    result = []
    for (category, condition, difficulty), rows in sorted(groups.items()):
        first = rows[0]
        label = truth[first['caseId'], first['itemKey']]
        target = label['targetTransactionId'] or label['requiredEvidenceTransactionIds'][0]
        example = by_id[target]
        result.append({'category': category, 'condition': condition, 'difficulty': difficulty,
            'items': len(rows), 'meaning': first['expectedMeaning'], 'basicType': first['expectedBasic'],
            'meaningReason': first['expectedMeaningReason'], 'review': first['expectedReview'],
            'example': {key: example[key] for key in ('recordKind', 'direction', 'status', 'description')},
            'baselineErrors': dict(Counter(error for row in rows for error in row['errors'])),
            'baselineMeaningCorrect': sum(row['meaningMatches'] for row in rows),
            'baselineBothCorrect': sum(row['valueMatches'] for row in rows)})
    return {'version': 'PAYSE-PROMPT-CASES-1', 'sourceHashes': scored['manifest']['sha256'],
        'independentHoldout': False, 'runtimePromptInput': False,
        'items': len(scored['items']), 'families': len(result),
        'byCategory': dict(Counter(row['category'] for row in scored['items'])),
        'byReview': dict(Counter(row['expectedReview'] for row in scored['items'])),
        'cases': result}


def select_cases(cases, expected, count):
    """2026-11-04: 기존 오답을 보지 않고 사전 유형의 범위를 넓히는 고정 표본을 선택한다."""
    if not isinstance(count, int) or not 1 <= count <= len(cases):
        raise ValueError('Invalid sample batch count')
    tags = {case['name']: {(row['condition'], row['difficulty'], row['expectedReview'])
                          for row in expected[case['name']]['items']} for case in cases}
    chosen, covered = set(), set()
    for _ in range(count):
        remaining = [case for case in cases if case['name'] not in chosen]
        best = min(remaining, key=lambda case: (-len(tags[case['name']] - covered), case['name']))
        chosen.add(best['name'])
        covered.update(tags[best['name']])
    return [case for case in cases if case['name'] in chosen]


def subset(dataset, destination, count):
    """2026-11-04: 부모 원천/정답을 바꾸지 않고 사전 고정 표본을 별도 동결한다. 사용: CLI."""
    parent = verify_bundle(dataset)
    if destination.exists():
        raise ValueError('Sample destination must be new')
    if not destination.resolve().is_relative_to(ROOT / '.harness'):
        raise ValueError('Private sample must stay in ignored .harness')
    cases = read(dataset / 'inputs.json')
    expected = read(dataset / 'expected.private.json')
    selected = select_cases(cases, expected, count)
    labels = {case['name']: expected[case['name']] for case in selected}
    destination.mkdir(parents=True)
    (destination / 'source.json').write_bytes((dataset / 'source.json').read_bytes())
    write(destination / 'inputs.json', selected)
    write(destination / 'expected.private.json', labels)
    manifest = copy.deepcopy(parent)
    all_labels = [row for group in labels.values() for row in group['items']]
    manifest.update(frozenAt=datetime.now().astimezone().isoformat(), batches=len(selected),
        analysisItems=len(all_labels), recurringCandidates=sum(
            row['category'] == 'recurring_candidates' for row in all_labels),
        categories=dict(Counter(row['category'] for row in all_labels)),
        difficulties=dict(Counter(row['difficulty'] for row in all_labels)),
        expectedReviews=dict(Counter(row['expectedReview'] for row in all_labels)),
        parentHashes=parent['sha256'], selection='greedy_condition_difficulty_review_then_case_name',
        selectedCases=[case['name'] for case in selected], modelCalls=0)
    manifest['sha256'] = {name: hashlib.sha256((destination / name).read_bytes()).hexdigest()
                          for name in FILES}
    write(destination / 'manifest.json', manifest)
    return verify_bundle(destination)


def timing(cases):
    """2026-11-04: 누락 시간을 0초로 만들지 않고 관측한 HTTP 완료 지연만 요약한다."""
    values = sorted(row['elapsedMillis'] / 1000 for row in cases if 'elapsedMillis' in row)
    return {'measured': len(values), 'meanSeconds': statistics.mean(values) if values else None,
            'medianSeconds': statistics.median(values) if values else None,
            'maxSeconds': max(values) if values else None}


def compare(dataset, baseline, revised):
    """2026-11-04: 동일 항목 분모로 개선·악화·유보·실패를 보존한다. 사용: CLI."""
    names = {case['name'] for case in read(dataset / 'inputs.json')}
    before = {'cases': [case for case in baseline['cases'] if case['name'] in names]}
    if {case['name'] for case in revised.get('cases', [])} - names:
        raise ValueError('Revised run contains items outside the frozen comparison')
    old = score_run(dataset, before)
    new = score_run(dataset, revised)
    old_items = {(row['caseId'], row['itemKey']): row for row in old['items']}
    transitions = Counter()
    for row in new['items']:
        previous = old_items[row['caseId'], row['itemKey']]
        transitions[('correct' if previous['valueMatches'] else 'wrong') + '_to_' +
                    ('correct' if row['valueMatches'] else 'wrong')] += 1
    fields = ('overall', 'transactions', 'recurringCandidates', 'byCategory', 'byDifficulty', 'perMeaning')
    return {'version': 'PAYSE-PROMPT-COMPARISON-1', 'independentHoldout': False,
        'sameTimeAB': False, 'sampleManifest': new['manifest'], 'valueTransitions': dict(transitions),
        'baseline': {key: old[key] for key in fields}, 'revised': {key: new[key] for key in fields},
        'baselineLatency': timing(before['cases']), 'revisedLatency': timing(revised.get('cases', [])),
        'limits': '프롬프트 개발에 사용한 합성 자료의 회귀 비교. 서로 다른 시각의 실행이며 독립 정확도·모델 간 동일 속도 보장이 아님.'}


def main():
    """2026-11-04: 분류·표본 동결·결과 비교만 실행하며 유료 호출은 하지 않는다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('catalog', 'subset', 'compare'))
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--revised', type=Path)
    parser.add_argument('--batches', type=int, default=16)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'subset':
        result = subset(args.dataset, args.out, args.batches)
    elif args.action == 'catalog' and args.baseline:
        result = catalog(args.dataset, read(args.baseline))
        write(args.out, result)
    elif args.action == 'compare' and args.baseline and args.revised:
        result = compare(args.dataset, read(args.baseline), read(args.revised))
        write(args.out, result)
    else:
        parser.error('catalog needs --baseline; compare needs --baseline and --revised')
    print(json.dumps({key: result[key] for key in ('version', 'items', 'families', 'batches')
                      if key in result}, ensure_ascii=False))


if __name__ == '__main__':
    main()
