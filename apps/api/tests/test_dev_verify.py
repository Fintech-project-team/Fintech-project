"""2026-10-30: 실제 HTTP 실행기의 안내 대상·응답·불변 조건 검사를 검증한다. DB·네트워크를 사용하지 않는다."""
import copy
import importlib.util
import inspect
from pathlib import Path
import sys
import unittest
import uuid
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('payse_dev_verify', Path(__file__).parents[1] / 'tools/dev_verify.py')
VERIFY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFY
SPEC.loader.exec_module(VERIFY)


def prepared_user():
    """2026-10-30: 임의 ID로 소유자·계좌·입금·명목 회차 관계를 구성한다. 사용: NoticeVerificationTests."""
    owner, account, transaction = (str(uuid.uuid4()) for _ in range(3))
    source = {
        'userId': owner, 'schemaVersion': 'PAYSE-DRAFT-3', 'asOf': '2026-10-19T12:00:00+09:00',
        'settings': {'salary': {'salaryAccountId': account, 'receiptEvidence': [{
            'payMonth': '2026-09', 'expectedPayDate': '2026-09-25',
            'confirmation': 'confirmed', 'transactionIds': [transaction],
        }]}},
        'transactions': [{'transactionId': transaction, 'userId': owner, 'accountId': account,
                          'recordKind': 'account_entry', 'direction': 'in', 'balanceReflected': True}],
    }
    return VERIFY._User(seed={'userId': owner}, source=source, code='000001', token=uuid.uuid4().hex)


class NoticeClient:
    """2026-10-30: 소유자별 안내와 불변 Snapshot 응답을 제공한다. 사용: 실행기 자체 검사."""

    def __init__(self, users):
        """2026-10-30: 로그인 토큰과 테스트 사용자 관계를 준비한다. 사용: NoticeVerificationTests."""
        self.users = {user.token: user for user in users}
        self.notices = {}
        self.mutate_finance = False
        self.corrupt = None
        self.requests = []

    def request(self, method, path, body=None, token=None):
        """2026-10-30: 저장 결과·미저장 상태를 반환하고 검사할 계약 위반을 주입한다. 사용: dev_verify 안내 함수."""
        self.requests.append((method, path))
        user = self.users[token]
        owner = user.seed['userId']
        if path == '/snapshot':
            return 200, {'userId': owner, 'schemaVersion': 'PAYSE-API-0.6-3',
                         'dataVersion': '2' if self.mutate_finance and self.notices else '1',
                         'page': {'nextCursor': 'random-cursor'}}
        month = path.split('/')[2]
        key = (owner, month)
        if method == 'PUT':
            if body is not None:
                raise AssertionError('Notice API must not receive a body')
            self.notices.setdefault(key, '2026-10-30T03:00:00Z')
        timestamp = self.notices.get(key)
        result = {'contractVersion': 'PAYSE-SALARY-NOTICE-1', 'userId': owner, 'payMonth': month,
                  'dismissed': timestamp is not None, 'dismissedAt': timestamp}
        if self.corrupt is not None:
            self.corrupt(result)
        return 200, result


class NoticeVerificationTests(unittest.TestCase):
    """2026-10-30: 안내 검사기가 원천 추정·격리 오류·잘못된 성공을 놓치지 않는지 확인한다. 사용: unittest."""

    def setUp(self):
        """2026-10-30: 서로 다른 소유자와 API 응답 대역을 준비한다. 사용: unittest."""
        self.main = prepared_user()
        self.other = prepared_user()
        self.client = NoticeClient([self.main, self.other])

    def test_legacy_verification_keeps_notices_disabled(self):
        """2026-10-30: 이전 호출자에서 안내 기능 검사를 암묵 활성화하지 않는다. 사용: unittest."""
        parameter = inspect.signature(VERIFY.verify).parameters['salary_notices']
        self.assertIs(parameter.default, False)
        self.assertEqual(parameter.kind, inspect.Parameter.KEYWORD_ONLY)

    def test_month_comes_from_evidence_not_expected_date(self):
        """2026-10-30: 예정일이 다른 달로 이동해도 명목 회차를 직접 사용한다. 사용: unittest."""
        self.main.source['settings']['salary']['receiptEvidence'][0]['expectedPayDate'] = '2026-11-02'
        self.assertEqual(VERIFY._notice_months(self.main), ('2026-09', '2026-10'))

    def test_ownership_failure_precedes_notice_write(self):
        """2026-10-30: 연결 거래가 다른 사용자 것이면 HTTP 저장 전에 거절한다. 사용: unittest."""
        self.main.source['transactions'][0]['userId'] = self.other.seed['userId']
        with self.assertRaises(VERIFY.VerificationError):
            VERIFY._notice_checks(self.client, self.main, self.other)
        self.assertEqual(self.client.requests, [])

    def test_duplicate_source_month_fails_preparation(self):
        """2026-10-30: 중복 회차를 배열 첫 항목으로 선택하지 않는다. 사용: unittest."""
        evidence = self.main.source['settings']['salary']['receiptEvidence']
        evidence.append(copy.deepcopy(evidence[0]))
        with self.assertRaises(VERIFY.VerificationError):
            VERIFY._notice_months(self.main)

    def test_notice_changes_remain_separate_from_financial_source(self):
        """2026-10-30: 안내 저장은 별도 기대 상태만 변경하고 월·사용자 독립을 확인한다. 사용: unittest."""
        source = copy.deepcopy(self.main.source)
        VERIFY._notice_checks(self.client, self.main, self.other)
        self.assertEqual(self.main.source, source)
        self.assertTrue(self.main.notices['2026-09']['dismissed'])
        self.assertFalse(self.main.notices['2026-10']['dismissed'])
        self.assertFalse(self.other.notices['2026-09']['dismissed'])
        self.assertEqual(len(self.client.notices), 1)

    def test_financial_version_change_is_rejected(self):
        """2026-10-30: 안내 저장이 금융 버전을 바꾸면 검사를 통과하지 못한다. 사용: unittest."""
        self.client.mutate_finance = True
        with self.assertRaisesRegex(VERIFY.VerificationError, 'Snapshot'):
            VERIFY._notice_checks(self.client, self.main, self.other)

    def test_notice_contract_rejects_wrong_owner_or_false_timestamp(self):
        """2026-10-30: 다른 사용자 응답과 미저장 상태의 시각을 성공으로 받아들이지 않는다. 사용: unittest."""
        for update in ({'userId': self.other.seed['userId']}, {'dismissedAt': '2026-10-30T03:00:00Z'},
                       {'dismissed': True, 'dismissedAt': '2026-10-30T03:00:00'}, {'extra': True}):
            with self.subTest(update=update):
                self.client.corrupt = lambda row: row.update(update)
                with self.assertRaises(VERIFY.VerificationError):
                    VERIFY._notice(self.client, self.main, '2026-09')

    def test_initial_notice_must_not_already_be_saved(self):
        """2026-10-30: 재사용 DB의 기존 닫기를 신규 상태로 오인하지 않는다. 사용: unittest."""
        self.client.notices[(self.main.seed['userId'], '2026-09')] = '2026-10-30T03:00:00Z'
        with self.assertRaisesRegex(VERIFY.VerificationError, '신규 검증 DB'):
            VERIFY._notice_checks(self.client, self.main, self.other)

    def test_persistence_compares_first_saved_timestamp(self):
        """2026-10-30: 재조회 시 최초 저장 시각이 바뀌는 회귀를 발견한다. 사용: unittest."""
        VERIFY._notice_checks(self.client, self.main, self.other)
        self.client.notices[(self.main.seed['userId'], '2026-09')] = '2026-10-30T03:01:00Z'
        with self.assertRaises(VERIFY.VerificationError):
            VERIFY._notice_state(self.client, self.main)

    def test_smoke_attempts_all_logouts_after_failure(self):
        """2026-10-30: 한 로그아웃 실패가 다른 계정의 세션 정리 시도를 막지 않는다. 사용: unittest."""
        self.main.source['settings']['salary']['receiptEvidence'] = []
        self.other.source['settings']['salary']['receiptEvidence'] = []
        users = [self.main, self.other]
        self.client.request = unittest.mock.Mock(side_effect=[(500, {}), (204, None)])
        with patch.object(VERIFY, '_Client', return_value=self.client), \
                patch.object(VERIFY, '_users', return_value=users), \
                patch.object(VERIFY, '_login'), \
                patch.object(VERIFY, '_complete', return_value=({'schemaVersion': 'PAYSE-API-0.6-3'}, [], 1)):
            for user in users:
                user.seed['initialCase'] = 'test-prepared'
            with self.assertRaisesRegex(VERIFY.VerificationError, '로그아웃'):
                VERIFY.smoke('http://127.0.0.1:18080', Path('.'))
        self.assertEqual(2, self.client.request.call_count)
        self.assertTrue(all(user.token is None for user in users))


if __name__ == '__main__':
    unittest.main()
