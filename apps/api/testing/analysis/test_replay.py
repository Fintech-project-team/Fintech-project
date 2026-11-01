"""2026-11-01: 저장 응답 재현의 결합·부분 실패·정답 분리를 검사한다. 사용: unittest."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from build_cases import answer, recurring, request
from efficiency import transform_ids
from replay import prepare, replay
from replay_score import score_replay
from routing import evidence_key


def case_for(payload):
    """2026-11-01: 모델 연결 없는 독립 실행 문맥을 준비한다. 사용: ReplayTest."""
    return {'payload': payload, 'ownerScope': 'test-owner', 'records': [],
            'versions': {'policy': 'PAYSE-MEANING-1', 'schema': 'PAYSE-ANALYSIS-1',
                         'model': 'test-model', 'prompt': 'test-prompt'},
            'now': '2026-11-01T12:00:00+09:00', 'requestId': 'request-a', 'attemptId': 'attempt-a'}


def proof(case, payload, output, route='reused_result'):
    """2026-11-01: 실제 권한 증명이 아닌 합성 검증 기록을 준비한다. 사용: ReplayTest."""
    return {'verified': True, 'route': route, 'ownerScope': case['ownerScope'],
            'targetKey': payload['items'][0]['targetTransactionId'] or payload['items'][0]['candidateKey'],
            'evidenceFingerprint': evidence_key(payload, payload['items'][0]['itemKey']),
            'versions': copy.deepcopy(case['versions']), 'active': True, 'deleted': False, 'expired': False,
            'sourceValid': True, 'userCorrected': False, 'isReference': False, 'important': False,
            'accountPurgeAt': None, 'storedAt': '2026-10-31T12:00:00+09:00',
            'normalExpiresAt': '2027-01-31T12:00:00+09:00', 'result': output['items'][0]}


def envelope(case_id, case, output, status='completed'):
    """2026-11-01: 합성 공급자 응답을 해당 요청의 별칭·문맥에 결합한다. 사용: ReplayTest."""
    prepared, requests = prepare({case_id: case})
    packed = prepared[case_id]['packed']
    aliases = {(kind, original): alias for alias, (kind, original) in packed.ids.items()}
    aliased = transform_ids(output, lambda kind, value: aliases[(kind, value)]) if output else None
    request_row = requests[0]
    return {**{key: request_row[key] for key in ('caseId', 'requestId', 'attemptId', 'requestFingerprint')},
            'status': status, 'output': aliased}


class ReplayTest(unittest.TestCase):
    """2026-11-01: 실제 호출 없이 기록 처리·채점 경계를 검증한다. 사용: unittest."""

    def setUp(self):
        """2026-11-01: 금액/정답이 없는 거래 입력과 별도 기대값을 준비한다. 사용: unittest."""
        self.payload = request('replay-salary', {'recordKind': 'account_entry', 'direction': 'in',
                               'merchantName': '가상 고용주', 'description': '근로 급여'})
        self.case = case_for(self.payload)
        self.output = answer(self.payload, 'salary', 'income')
        self.key = self.payload['items'][0]['itemKey']
        self.labels = {'A': {'items': [{'itemKey': self.key, 'meaning': 'salary',
                                       'basicType': 'income', 'inputSufficient': True}]}}

    def test_bound_output_preserves_source_and_does_not_apply_candidate(self):
        """2026-11-01: 후보 성공이 저장·외부 연결·전체 판단 완료로 바뀌지 않는다. 사용: unittest."""
        before = copy.deepcopy(self.case)
        saved = envelope('A', self.case, self.output)
        result = replay({'A': self.case}, [saved])
        self.assertEqual(result['responses']['A'], self.output)
        self.assertEqual(result['routes']['A'][self.key], 'llm')
        self.assertEqual(result['persistedClassifications']['A'], [])
        self.assertEqual(self.case, before)
        self.assertFalse(result['wholePipelineMeasured'])
        self.assertFalse(result['productionAuthorityVerified'])
        self.assertEqual(result['externalCalls'], 0)

    def test_cross_request_alias_response_is_rejected(self):
        """2026-11-01: 같은 i1/t1라도 다른 요청에서 온 응답을 복원하지 않는다. 사용: unittest."""
        saved = envelope('A', self.case, self.output)
        changed = copy.deepcopy(self.case)
        changed['payload']['transactions'][0]['description'] = '대출 실행금'
        result = replay({'A': changed}, [saved])
        self.assertEqual(result['items']['A'][self.key]['error'], 'request_binding_mismatch')
        self.assertIsNone(result['items']['A'][self.key]['result'])

    def test_context_owner_attempt_and_versions_bind_output(self):
        """2026-11-01: 같은 거래라도 현재 문맥·소유자·버전·시도 변경을 대조한다. 사용: unittest."""
        saved = envelope('A', self.case, self.output)
        mutations = [('ownerScope', 'other-owner'), ('requestId', 'request-b'), ('attemptId', 'attempt-b'),
                     ('now', '2026-11-01T12:00:01+09:00')]
        for field, value in mutations:
            changed = {**self.case, field: value}
            with self.subTest(field=field):
                self.assertEqual(replay({'A': changed}, [saved])['items']['A'][self.key]['error'],
                                 'request_binding_mismatch')
        for field, value in [('dataVersion', '2'), ('inputRevision', 1), ('localSessionEpoch', 2),
                             ('asOf', '2026-11-01T12:01:00+09:00')]:
            changed = copy.deepcopy(self.case)
            changed['payload']['context'][field] = value
            with self.subTest(context=field):
                self.assertEqual(replay({'A': changed}, [saved])['items']['A'][self.key]['error'],
                                 'request_binding_mismatch')
        changed = copy.deepcopy(self.case)
        changed['versions']['model'] = 'different-model'
        self.assertEqual(replay({'A': changed}, [saved])['items']['A'][self.key]['error'],
                         'request_binding_mismatch')

    def test_reuse_and_provider_failure_are_scored_separately(self):
        """2026-11-01: 독립 재사용 성공을 유지하고 나머지 공급자 실패 한 건만 센다. 사용: unittest."""
        second = request('replay-bonus', {'recordKind': 'account_entry', 'direction': 'in',
                         'merchantName': '가상 고용주', 'description': '상여금'})
        combined = copy.deepcopy(self.payload)
        combined['items'] += second['items']
        combined['transactions'] += second['transactions']
        case = case_for(combined)
        case['records'] = [proof(case, self.payload, self.output)]
        saved = envelope('A', case, None, 'failed')
        result = replay({'A': case}, [saved])
        second_key = second['items'][0]['itemKey']
        self.assertEqual(result['items']['A'][self.key]['result'], self.output['items'][0])
        self.assertEqual(result['items']['A'][second_key]['error'], 'provider_failed')
        self.assertNotIn('A', result['responses'])
        labels = copy.deepcopy(self.labels)
        labels['A']['items'].append({'itemKey': second_key, 'meaning': 'bonus',
                                     'basicType': 'income', 'inputSufficient': True})
        report = score_replay({'A': case}, labels, [saved])
        self.assertEqual(report['jointError'], {'numerator': 1, 'denominator': 2, 'rate': 0.5})
        self.assertEqual(report['recordedLlmTransactionError']['denominator'], 1)
        self.assertEqual(report['recordedLlmTransactionError']['numerator'], 1)
        self.assertEqual(report['byDecisionSource']['reused_result']['errors'], 0)

    def test_incomplete_provider_batch_is_rejected_atomically(self):
        """2026-11-01: 일부만 맞는 공급자 배치에서 성공 항목을 골라 채택하지 않는다. 사용: unittest."""
        second = request('replay-batch', {'recordKind': 'account_entry', 'direction': 'in',
                         'merchantName': '가상 고용주', 'description': '근로 급여'})
        combined = copy.deepcopy(self.payload)
        combined['items'] += second['items']
        combined['transactions'] += second['transactions']
        case = case_for(combined)
        saved = envelope('A', case, self.output)
        result = replay({'A': case}, [saved])
        self.assertEqual(len(result['items']['A']), 2)
        self.assertTrue(all(row['error'] == 'invalid_provider_output' for row in result['items']['A'].values()))

    def test_partial_reuse_exports_only_unresolved_complete_evidence(self):
        """2026-11-01: 독립 재사용 항목은 전송에서 빼고 두 결과를 원래 항목에 합친다. 사용: unittest."""
        second = request('replay-independent', {'recordKind': 'account_entry', 'direction': 'in',
                         'merchantName': '가상 고용주', 'description': '상여금'})
        combined = copy.deepcopy(self.payload)
        combined['items'] += second['items']
        combined['transactions'] += second['transactions']
        case = case_for(combined)
        case['records'] = [proof(case, self.payload, self.output, 'source_fact')]
        prepared, requests = prepare({'A': case})
        self.assertEqual(len(requests), 1)
        self.assertEqual(len(requests[0]['input']['items']), 1)
        self.assertEqual(len(requests[0]['input']['transactions']), 1)
        self.assertEqual(prepared['A']['packed'].payload['items'], second['items'])
        saved = envelope('A', case, answer(second, 'bonus', 'income'))
        result = replay({'A': case}, [saved])
        self.assertEqual(len(result['responses']['A']['items']), 2)
        self.assertEqual(result['routes']['A'][self.key], 'source_fact')
        self.assertEqual(result['routes']['A'][second['items'][0]['itemKey']], 'llm')

    def test_full_reuse_has_no_prepared_provider_request(self):
        """2026-11-01: 유효한 원천 결과만으로 끝나면 공급자 요청을 만들지 않는다. 사용: unittest."""
        case = {**self.case, 'records': [proof(self.case, self.payload, self.output, 'source_fact')]}
        _, requests = prepare({'A': case})
        self.assertEqual(requests, [])
        result = replay({'A': case}, [])
        self.assertEqual(result['responses']['A'], self.output)
        report = score_replay({'A': case}, self.labels, [])
        self.assertEqual(report['jointError']['numerator'], 0)
        self.assertEqual(report['recordedLlmTransactionError']['denominator'], 0)
        self.assertFalse(report['actualModelPerformanceMeasured'])

    def test_reuse_rejections_and_unknown_do_not_hide_errors(self):
        """2026-11-01: 삭제·만료·다른 소유자·정정 자료를 거절하고 정상 unknown은 따로 센다. 사용: unittest."""
        record = proof(self.case, self.payload, self.output)
        for field, value in [('deleted', True), ('ownerScope', 'other'), ('expired', True),
                             ('userCorrected', True), ('sourceValid', False)]:
            case = {**self.case, 'records': [{**record, field: value}]}
            with self.subTest(field=field):
                report = score_replay({'A': case}, self.labels, [])
                self.assertEqual(report['jointError']['numerator'], 1)
                self.assertEqual(report['failureReasons'], {'missing_saved_response': 1})
        unknown = answer(self.payload, None, None)
        case = {**self.case, 'records': [proof(self.case, self.payload, unknown)]}
        result = replay({'A': case}, [])
        self.assertEqual(result['preparedRequests'], 0)
        self.assertIsNone(result['items']['A'][self.key]['error'])
        self.assertEqual(result['routes']['A'][self.key], 'reused_result')
        report = score_replay({'A': case}, self.labels, [])
        self.assertEqual(report['jointError']['numerator'], 1)
        self.assertIn('unnecessary_meaning_abstention', report['failureReasons'])
        self.assertIsNone(report['recordedLlmTransactionError']['rate'])

    def test_invalid_alias_and_provider_refusal_remain_failures(self):
        """2026-11-01: 잘못된 ID·거절·미완료를 정상 유보로 바꾸지 않는다. 사용: unittest."""
        saved = envelope('A', self.case, self.output)
        saved['output']['items'][0]['evidenceTransactionIds'] = ['t999']
        self.assertEqual(replay({'A': self.case}, [saved])['items']['A'][self.key]['error'],
                         'invalid_provider_output')
        for status in ('refused', 'incomplete', 'failed'):
            saved = envelope('A', self.case, None, status)
            with self.subTest(status=status):
                self.assertEqual(replay({'A': self.case}, [saved])['items']['A'][self.key]['error'],
                                 'provider_' + status)

    def test_wrong_meaning_and_taxonomy_gap_remain_errors(self):
        """2026-11-01: 형식 정상인 오분류와 분류표 부족도 총 오류에서 제외하지 않는다. 사용: unittest."""
        wrong = envelope('A', self.case, answer(self.payload, 'bonus', 'income'))
        report = score_replay({'A': self.case}, self.labels, [wrong])
        self.assertEqual(report['jointError']['numerator'], 1)
        self.assertEqual(report['failureReasons'], {'wrong_meaning': 1})
        labels = copy.deepcopy(self.labels)
        labels['A']['items'][0].update(meaning=None, coverageGap=True)
        saved = envelope('A', self.case, answer(self.payload, None, 'income'))
        report = score_replay({'A': self.case}, labels, [saved])
        self.assertEqual(report['jointError']['numerator'], 1)
        self.assertEqual(report['failureReasons'], {'taxonomy_gap': 1})

    def test_duplicate_unknown_and_fully_reused_envelopes_are_rejected(self):
        """2026-11-01: 중복·다른 사례·불필요 응답을 조용히 덮거나 버리지 않는다. 사용: unittest."""
        saved = envelope('A', self.case, self.output)
        for saved_rows in ([saved, saved], [{**saved, 'caseId': 'B'}]):
            with self.assertRaises(ValueError):
                replay({'A': self.case}, saved_rows)
        case = {**self.case, 'records': [proof(self.case, self.payload, self.output)]}
        with self.assertRaises(ValueError):
            replay({'A': case}, [saved])
        with self.assertRaises(ValueError):
            prepare({'A': self.case, 'B': self.case})
        for field, value in [('requestId', ' '), ('attemptId', ''), ('privateAnswer', 'salary')]:
            with self.assertRaises(ValueError):
                prepare({'A': {**self.case, field: value}})
        invalid = copy.deepcopy(self.case)
        invalid['versions']['policy'] = 'unrecognized'
        with self.assertRaises(ValueError):
            prepare({'A': invalid})

    def test_existing_value_and_explicit_null_remain_distinct(self):
        """2026-11-01: 분류 없음·저장 null·기존 분류를 후보와 별도로 보존한다. 사용: unittest."""
        for current in ([], [{'transactionId': self.payload['items'][0]['targetTransactionId'], 'value': None}],
                        [{'transactionId': self.payload['items'][0]['targetTransactionId'], 'value': 'income'}]):
            case = copy.deepcopy(self.case)
            case['payload']['currentClassifications'] = current
            saved = envelope('A', case, answer(case['payload'], 'salary', None))
            result = replay({'A': case}, [saved])
            self.assertEqual(result['persistedClassifications']['A'], current)
            self.assertIsNone(result['responses']['A']['items'][0]['classification']['value'])

    def test_dependent_batch_keeps_both_sides(self):
        """2026-11-01: 재사용 분리로 관계 한쪽이 빠질 때 전체 근거를 유지한다. 사용: unittest."""
        other = request('replay-out', {'recordKind': 'account_entry', 'direction': 'out',
                        'merchantName': '가상 본인', 'description': '본인 이체'})
        combined = copy.deepcopy(self.payload)
        combined['items'] += other['items']
        combined['transactions'] += other['transactions']
        combined['relations'] = [{'kind': 'internal_transfer', 'fromId': other['transactions'][0]['transactionId'],
                                  'toId': self.payload['transactions'][0]['transactionId']}]
        case = case_for(combined)
        _, requests = prepare({'A': case})
        self.assertEqual(len(requests[0]['input']['transactions']), 2)
        self.assertEqual(len(requests[0]['input']['items']), 2)
        self.assertEqual(len(requests[0]['input']['relations']), 1)

    def test_recurring_results_do_not_enter_transaction_denominator(self):
        """2026-11-01: 반복 후보는 유지하되 거래 10만 건 분모에는 넣지 않는다. 사용: unittest."""
        payload = recurring('replay-monthly', 'unused', {'recordKind': 'account_entry', 'direction': 'out',
                            'merchantName': '가상통신', 'description': '통신 요금'})
        case = case_for(payload)
        output = answer(payload, 'telecom', name='통신비')
        saved = envelope('A', case, output)
        labels = {'A': {'items': [{'itemKey': payload['items'][0]['itemKey'], 'meaning': 'telecom',
                                   'basicType': None, 'inputSufficient': True}]}}
        report = score_replay({'A': case}, labels, [saved])
        self.assertEqual(report['jointError']['numerator'], 0)
        self.assertEqual(report['transactionJointError']['denominator'], 0)

    def test_cli_exports_without_labels_and_preserves_existing_files(self):
        """2026-11-01: 정답 파일 없이 입력을 내보내고 기존 산출물 덮어쓰기를 거절한다. 사용: unittest."""
        script = Path(__file__).with_name('replay.py')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, target = root / 'cases.json', root / 'requests.json'
            source.write_text(json.dumps({'A': self.case}), encoding='utf-8')
            command = [sys.executable, '-B', str(script), '--cases', str(source), '--export-requests', str(target)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            exported = json.loads(target.read_text(encoding='utf-8'))
            self.assertNotIn('ownerScope', exported[0])
            self.assertNotIn('records', exported[0])
            self.assertNotIn('expected', exported[0])
            before = target.read_bytes()
            repeat = subprocess.run(command, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(repeat.returncode, 0)
            self.assertEqual(target.read_bytes(), before)
            source.write_text('{"A":{},"A":{}}', encoding='utf-8')
            duplicate = subprocess.run(command, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(duplicate.returncode, 0)
            self.assertIn('Duplicate JSON field', duplicate.stderr)


if __name__ == '__main__':
    unittest.main()
