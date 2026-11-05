"""2026-11-04: 같은 사전 정답의 직접 호출과 독립 재검토를 비교한다. API 호출이나 정답 변경 없음."""
import argparse
from collections import Counter
import json
from pathlib import Path

from testing.analysis.gamma_evaluation import metrics


def compare(baseline, reviewed):
    """2026-11-04: 실패 포함 요청 전체 점수와 양쪽 성공 항목의 변화량을 명시적으로 나눈다."""
    if baseline['manifest']['sha256']['source.json'] != reviewed['manifest']['sha256']['source.json']:
        raise ValueError('Different frozen source; not a paired comparison')
    indexed = {(row['caseId'], row['itemKey']): row for row in baseline['items']}
    if len(indexed) != len(baseline['items']):
        raise ValueError('Duplicate baseline judgment')
    selected = []
    common_baseline = []
    common_reviewed = []
    changes = Counter()
    seen = set()
    for row in reviewed['items']:
        key = (row['caseId'], row['itemKey'])
        if key not in indexed or key in seen:
            raise ValueError('Unmatched or duplicated review judgment')
        seen.add(key)
        previous = indexed[key]
        for field in ('expectedMeaning', 'expectedBasic', 'expectedReview', 'expectedMeaningReason'):
            if previous[field] != row[field]:
                raise ValueError('Ground truth differs between runs')
        selected.append(previous)
        if previous['validResult'] and row['validResult']:
            common_baseline.append(previous)
            common_reviewed.append(row)
            if not previous['meaningMatches'] and row['meaningMatches']:
                changes['meaningFixed'] += 1
            if previous['meaningMatches'] and not row['meaningMatches']:
                changes['meaningRegressed'] += 1
    return {'format': 'payse-agent-comparison-v1', 'requested': len(selected),
            'baselineIncludingFailures': metrics(selected),
            'reviewIncludingFailures': metrics(reviewed['items']),
            'commonCompleted': len(common_baseline),
            'commonBaseline': metrics(common_baseline), 'commonReview': metrics(common_reviewed),
            'changesOnCommonCompleted': dict(changes),
            'limitations': ['Sequential single runs, not a randomized repeated experiment.',
                           'New IDs/amounts share a wording family; not a new-language holdout.',
                           'Native Responses multi_agent and hosted Agents API were not executed.',
                           'Using a second opinion in sequence adds its time and cost.']}


def main():
    """2026-11-04: 비공개 채점 파일에서 집계만 만들며 개별 거래/정답은 내보내지 않는다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--reviewed', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = compare(json.loads(args.baseline.read_text(encoding='utf-8')),
                     json.loads(args.reviewed.read_text(encoding='utf-8')))
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
