"""2026-11-01: 작은 개발 표본의 JSON 크기만 측정한다. 사용: CLI; 실제 토큰/과금 측정 아님."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path

from build_schemas import CONTRACTS
from efficiency import byte_metrics, compact_criteria, criteria_only, pack
from evaluate import read_cases
from expansion import OUTPUT


def pilot(inputs, expected, limit=100):
    """2026-11-01: 조건/원천별 순환 선택으로 작은 개발 표본을 구성한다. 사용: measure.

    비공개 조건은 표본 층화에만 사용하고 모델 본문에는 보내지 않는다.
    """
    if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1:
        raise ValueError('Pilot size must be a positive integer')
    buckets = defaultdict(list)
    for key, payload in inputs.items():
        task = payload['semanticTaskKind']
        condition = expected[key].get('condition', expected[key]['groupId'])
        buckets[(task, condition, payload['transactions'][0]['recordKind'])].append(key)
    chosen, offset = [], 0
    while len(chosen) < min(limit, len(inputs)):
        for bucket in buckets.values():
            if offset < len(bucket):
                chosen.append(bucket[offset])
            if len(chosen) == min(limit, len(inputs)):
                break
        offset += 1
    return chosen


def byte_size(value):
    """2026-11-01: 같은 UTF-8 JSON 직렬화 조건으로 크기를 계산한다. 사용: measure."""
    return len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))


def measure(inputs, expected, limit=100):
    """2026-11-01: 원문/최소 투영/짧은 ID/기준 압축 크기를 비교한다. 사용: CLI/테스트."""
    selected = pilot(inputs, expected, limit)
    totals = {'requestBytes': 0, 'projectedBytes': 0, 'packedBytes': 0}
    schema_bytes = 0
    for key in selected:
        packed = pack(inputs[key])
        metrics = byte_metrics(inputs[key], packed)
        for field in totals:
            totals[field] += metrics[field]
        schema_bytes += byte_size(packed.output_schema)
    policy = json.loads((CONTRACTS / 'meaning-policy.json').read_text(encoding='utf-8-sig'))
    return {'sampleCases': len(selected), 'sampleIds': selected,
            'sampleTaskKinds': dict(Counter(inputs[key]['semanticTaskKind'] for key in selected)),
            'jsonBodyBytesTotal': totals,
            'projectedToPackedReduction': 1 - totals['packedBytes'] / totals['projectedBytes'] if selected else None,
            'packedOutputSchemaBytesTotal': schema_bytes,
            'criteriaBytesPerRequest': byte_size(criteria_only(policy)),
            'factoredCriteriaBytesPerRequest': byte_size(compact_criteria(policy)),
            'actualTokens': None, 'actualCostKRW': None, 'actualQuality': None, 'providerCalls': 0,
            'limits': ['요청 본문 바이트와 모델 토큰은 다름', '공통 지침·응답 스키마도 실제 토큰 상한에 포함해야 함',
                       '압축 기준/별칭의 모델 정확도·지연 효과 미측정', '표본 층화에 사용한 비공개 조건은 공급자 입력에 포함하지 않음'],
            'budgetKRW': {'total': 50000, 'paidCallCutoff': 45000, 'margin': 5000}}


def main():
    """2026-11-01: 이미 생성된 개발 입력으로 외부 호출 없는 크기 보고를 저장한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=OUTPUT)
    parser.add_argument('--limit', type=int, default=100)
    args = parser.parse_args()
    inputs = read_cases(args.directory / 'inputs.jsonl', 'input')
    expected = read_cases(args.directory / 'expected.private.jsonl', 'expected')
    report = measure(inputs, expected, args.limit)
    (args.directory / 'size-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    summary = {key: value for key, value in report.items() if key != 'sampleIds'}
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
