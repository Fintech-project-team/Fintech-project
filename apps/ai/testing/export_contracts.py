"""2026-11-01: Python/Java 계약 대조 자료를 빌드 폴더에 만든다. 사용: Gradle 테스트.

정답은 검증기 대조에만 쓰며 AnalysisService나 모델 입력으로 전달하지 않는다.
실제 의미 정확도·외부 호출·운영 권한 검증은 수행하지 않는다.
"""
import copy
import json
import sys
from pathlib import Path

API_TESTS = Path(__file__).resolve().parents[2] / 'api' / 'testing' / 'analysis'
sys.path.insert(0, str(API_TESTS))
from build_cases import answer
from contract import validate_input, validate_output
from efficiency import pack, transform_ids
from expansion import prepare_expanded


def write_cases(folder):
    """2026-11-01: 개발 전건·입력 반례를 Python 판정과 함께 내보낸다. 사용: CLI.

    2026-11-02 수정: 직렬화·파일 쓰기와 날짜 사례 목록을 분리한다.
    2026-11-03 수정: 감마 연간 원천의 입력·형식 예시를 평가 정답과 분리해 추가한다.
    """
    folder.mkdir(parents=True, exist_ok=True)
    inputs, expected = prepare_expanded()
    first = next(iter(inputs.values()))
    service_file = folder / 'service-input.json'
    service_json = json.dumps(first, ensure_ascii=False)
    service_file.write_text(service_json, encoding='utf-8')
    with (folder / 'parity.jsonl').open('w', encoding='utf-8') as stream:
        for case_id, payload in inputs.items():
            truth = expected[case_id]['items'][0]
            output = answer(payload, truth['meaning'], truth['basicType'], '반복 비용')
            validate_input(payload)
            validate_output(payload, output)
            packed = pack(payload)
            aliases = {(kind, original): alias for alias, (kind, original) in packed.ids.items()}
            response = transform_ids(output, lambda kind, value: aliases[(kind, value)])
            row = {'caseId': case_id, 'input': payload, 'projected': packed.input,
                   'schema': packed.output_schema, 'output': output, 'response': response}
            encoded_row = json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n'
            stream.write(encoded_row)
    invalid = []
    mutations = [
        ('context', 'dataVersion', '9223372036854775808'),
        ('context', 'asOf', '2026-11-01T12:00:00'),
        ('context', 'asOf', '2026-02-30T12:00:00Z'),
        ('context', 'asOf', '0000-11-01T12:00:00Z'),
        ('context', 'inputRevision', True),
        ('context', 'inputRevision', 1.5),
        ('transactions', 'status', 'approved'),
        ('transactions', 'originalTransactionId', first['transactions'][0]['transactionId']),
        ('items', 'targetTransactionId', '00000000-0000-0000-0000-000000000000'),
    ]
    for group, field, value in mutations:
        payload = copy.deepcopy(first)
        target = payload[group][0] if isinstance(payload[group], list) else payload[group]
        target[field] = value
        try:
            validate_input(payload)
        except ValueError:
            invalid.append(payload)
        else:
            raise AssertionError(f'Negative fixture was accepted: {group}/{field}')
    for group in ('items', 'transactions'):
        payload = copy.deepcopy(first)
        payload[group].append(copy.deepcopy(payload[group][0]))
        try:
            validate_input(payload)
        except ValueError:
            invalid.append(payload)
        else:
            raise AssertionError('Duplicate fixture was accepted')
    invalid_file = folder / 'invalid-inputs.json'
    invalid_json = json.dumps(invalid, ensure_ascii=False)
    invalid_file.write_text(invalid_json, encoding='utf-8')
    date_inputs = []
    timestamp_cases = (
        '2026-11-01T12:00:00.1234567891Z', '2026-11-01T12Z',
        '2026-11-01T1230Z', '2026-11-01T12:30,2Z', '2026-11-01T12:00:00+23:59')
    for date in timestamp_cases:
        precision = copy.deepcopy(first)
        precision['context']['asOf'] = date
        validate_input(precision)
        date_inputs.append(precision)
    dates_file = folder / 'date-inputs.json'
    dates_json = json.dumps(date_inputs, ensure_ascii=False)
    dates_file.write_text(dates_json, encoding='utf-8')
    from gamma_year_cases import prepare as gamma_cases
    gamma_inputs, gamma_examples = gamma_cases()
    (folder / 'gamma-year-inputs.json').write_text(
        json.dumps(gamma_inputs, ensure_ascii=False), encoding='utf-8')
    (folder / 'gamma-year-format-examples.json').write_text(
        json.dumps(gamma_examples, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'Contract parity fixtures: {len(inputs)} valid, {len(invalid)} invalid; model calls 0')


if __name__ == '__main__':
    write_cases(Path(sys.argv[1]))
