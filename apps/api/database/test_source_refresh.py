"""2026-11-02: 새 PostgreSQL에서 원천 갱신·설정 보존·중복·경합·실패 원자성을 검사한다.

사용: 독립 CLI, test_analysis_service의 기존 격리 CI. 기존 DB 접속 정보를 받지 않는다.
"""
import argparse
import copy
import json
from pathlib import Path
import sys
import unittest
import uuid

DIRECTORY = Path(__file__).resolve().parent
API = DIRECTORY.parent
sys.path.insert(0, str(API))
from tools.refresh_source import render


def refresh_pair():
    """2026-11-02: 기존 자료와 명시한 하루 뒤 합성 사실을 준비하며 제품 생성기는 변경하지 않는다."""
    before = json.loads((API / 'fixtures/generated-v4/snapshots/demo-ready.json')
                       .read_text(encoding='utf-8'))
    after = copy.deepcopy(before)
    after['sourceVersion'] += ':refresh-test'
    after['asOf'] = '2026-10-20T12:00:00+09:00'
    after['page']['sourceVersion'] = after['sourceVersion']
    for group in ('accounts', 'cards', 'transactions', 'relatedTransactions', 'statements'):
        for row in after[group]:
            row['sourceVersion'] = after['sourceVersion']
            if group == 'accounts':
                row['asOf'] = after['asOf']
            for item in row.get('items', []):
                item['sourceVersion'] = after['sourceVersion']
    account_id = before['settings']['salary']['salaryAccountId']
    accounts = [row for row in after['accounts'] if row['accountId'] == account_id]
    if len(accounts) != 1 or accounts[0]['userId'] != before['userId']:
        raise AssertionError('The prepared salary account must identify one owned account')
    accounts[0]['balanceKRW'] = 1_700_000
    transaction_id = str(uuid.uuid4())
    after['transactions'].append({
        'userId': before['userId'], 'transactionId': transaction_id,
        'sourceRef': 'fixture/source-refresh/' + transaction_id,
        'sourceVersion': after['sourceVersion'], 'accountId': account_id, 'cardId': None,
        'recordKind': 'account_entry', 'amountKRW': 200_000, 'direction': 'in', 'status': 'posted',
        'merchantName': '가상 급여 정산', 'description': '확인된 추가 입금',
        'purchaseDate': None, 'withdrawalDate': None, 'refundDate': None,
        'cancellationDate': None, 'bookingDate': '2026-10-20',
        'occurredAt': '2026-10-20T09:00:00+09:00', 'occurredAtBasis': 'booking',
        'balanceReflected': True, 'reflectionReason': 'reflected', 'originalTransactionId': None,
        'payseTransactionType': None, 'installmentCurrent': None, 'installmentTotal': None,
    })
    for coverage in after['coverage']:
        if coverage['status'] != 'complete':
            raise AssertionError('This test expects explicitly complete synthetic coverage')
        coverage['requestedStart'] = '2025-10-21'
        coverage['requestedEnd'] = '2026-10-20'
        coverage['coveredRanges'] = [{'start': '2025-10-21', 'end': '2026-10-20'}]
    return before, after


class SourceRefreshTests(unittest.TestCase):
    """2026-11-02: 매 검사에서 새 DB를 만들고 기존 구조·자료·실제 사용자 잠금을 사용한다."""

    @classmethod
    def setUpClass(cls):
        """2026-11-02: 합성 자료 준비만 별도 제한 시간을 두고 한 번 적재해 테스트 원본을 만든다."""
        from reference_data.export_sql import export as institutions
        from testing.scenarios.export_state import export as scenarios
        cls.template = 'payse_auth_test_refresh_base_' + uuid.uuid4().hex[:12]
        cls.cluster.sql('CREATE DATABASE ' + cls.template + ';')
        for name in ('001_initial.sql', '002_storage_guards.sql', '003_auth_access.sql',
                     '004_auth_sessions.sql', '007_financial_access.sql'):
            cls.cluster.load(cls.base_sql_root / name, cls.template)
        cls.cluster.sql(institutions(), cls.template)
        seed = scenarios(API / 'fixtures/generated-v4', ['demo-ready', 'beta-ready'])
        with cls.cluster.connect(cls.template, name='source_fixture_preparation') as connection:
            connection.sql("SET statement_timeout='120s';\n" + seed, timeout=130)

    def setUp(self):
        """2026-11-02: 검증된 전용 원본 DB의 독립 복사본에서 소유자·초기 버전을 확인한다."""
        self.database = 'payse_auth_test_refresh_' + uuid.uuid4().hex[:12]
        self.cluster.sql('CREATE DATABASE ' + self.database + ' TEMPLATE ' + self.template + ';')
        self.before, self.after = refresh_pair()
        self.owner = self.before['userId']
        self.assertEqual(['1'], self.cluster.sql(
            'SELECT data_version FROM payse.users WHERE id=' + quote(self.owner) + ';',
            self.database))

    def sql(self, *, apply=True, expected=1, after=None):
        """2026-11-02: 검사 대상의 실제 SQL 생성 경로를 사용한다."""
        return render(self.before, after or self.after, expected, self.database, apply=apply)

    def fingerprint(self):
        """2026-11-02: 두 사용자 전체 상태의 값은 출력하지 않고 행 순서 독립 해시만 비교한다."""
        tables = ('users', 'source_contexts', 'financial_accounts', 'financial_cards',
                  'financial_transactions', 'transaction_references', 'card_statements',
                  'statement_items', 'transaction_relations', 'institution_links', 'user_attributes',
                  'obligations', 'reserves', 'reserve_allocations', 'settlement_links',
                  'recurring_plans', 'recurring_plan_revisions', 'recurring_decisions',
                  'occurrence_overrides', 'write_receipts', 'demo_sessions')
        return {table: self.cluster.sql(
            "SELECT md5(coalesce(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) "
            + 'FROM payse.' + table + ' t;', self.database) for table in tables}

    def test_check_rolls_back_all_changes(self):
        """2026-11-02: 기본 SQL은 같은 제약까지 검사한 뒤 모든 상태를 원복한다."""
        initial = self.fingerprint()
        self.cluster.sql(self.sql(apply=False), self.database)
        self.assertEqual(initial, self.fingerprint())

    def test_apply_replay_and_user_settings(self):
        """2026-11-02: 새 사실은 한 번 반영하고 별칭·선택·급여 설정·사용자 분류는 보존한다."""
        owner = quote(self.owner)
        self.cluster.sql(f'''
          BEGIN;
          UPDATE payse.financial_accounts
          SET nickname='사용자 별칭', included=true
          WHERE user_id={owner};
          UPDATE payse.user_attributes
          SET salary_day=20
          WHERE user_id={owner};
          UPDATE payse.financial_transactions
          SET payse_transaction_type='expense'
          WHERE user_id={owner};
          UPDATE payse.users
          SET data_version=9
          WHERE id={owner};
          COMMIT;
        ''', self.database)
        initial = self.fingerprint()
        self.cluster.sql(self.sql(expected=9), self.database)
        result = self.fingerprint()
        for table in ('institution_links', 'user_attributes', 'obligations', 'reserves',
                      'reserve_allocations', 'settlement_links', 'recurring_plans',
                      'recurring_plan_revisions', 'recurring_decisions', 'occurrence_overrides',
                      'write_receipts', 'demo_sessions'):
            self.assertEqual(initial[table], result[table], table)
        self.assertEqual(['10'], self.cluster.sql(
            'SELECT data_version FROM payse.users WHERE id=' + owner + ';', self.database))
        self.assertEqual(['t'], self.cluster.sql(f'''
          SELECT bool_and(nickname='사용자 별칭' AND included)
          FROM payse.financial_accounts
          WHERE user_id={owner};
        ''', self.database))
        self.assertEqual([str(len(self.before['transactions']))], self.cluster.sql(f'''
          SELECT count(*)
          FROM payse.financial_transactions
          WHERE user_id={owner} AND payse_transaction_type='expense';
        ''', self.database))
        self.assertEqual([str(len(self.after['transactions']))], self.cluster.sql(f'''
          SELECT count(*)
          FROM payse.financial_transactions
          WHERE user_id={owner};
        ''', self.database))
        self.cluster.sql(self.sql(expected=9), self.database)
        self.assertEqual(result, self.fingerprint())

    def test_stale_version_and_wrong_database(self):
        """2026-11-02: 대상 DB 또는 현재 사용자 버전이 다르면 쓰기 전에 거절한다."""
        initial = self.fingerprint()
        commands = (self.sql(expected=2),
                    render(self.before, self.after, 1, 'unrelated_database', apply=True))
        for command in commands:
            with self.assertRaises(SqlError):
                self.cluster.sql(command, self.database)
            self.assertEqual(initial, self.fingerprint())

    def test_changed_baseline_and_reused_source_version(self):
        """2026-11-02: 버전명이 같아도 실제 원천이 다르면 적용·재시도를 모두 거절한다."""
        account = quote(self.before['settings']['salary']['salaryAccountId'])
        self.cluster.sql(f'''
          UPDATE payse.financial_accounts
          SET balance_krw=balance_krw+1
          WHERE user_id={quote(self.owner)} AND id={account};
        ''', self.database)
        changed = self.fingerprint()
        with self.assertRaises(SqlError):
            self.cluster.sql(self.sql(), self.database)
        self.assertEqual(changed, self.fingerprint())
        self.cluster.sql(f'''
          UPDATE payse.financial_accounts
          SET balance_krw=balance_krw-1
          WHERE user_id={quote(self.owner)} AND id={account};
        ''', self.database)
        self.cluster.sql(self.sql(), self.database)
        applied = self.fingerprint()
        conflicting = copy.deepcopy(self.after)
        for row in conflicting['accounts']:
            if row['accountId'] == self.before['settings']['salary']['salaryAccountId']:
                row['balanceKRW'] = 1_800_000
        with self.assertRaises(SqlError):
            self.cluster.sql(self.sql(after=conflicting), self.database)
        self.assertEqual(applied, self.fingerprint())

    def test_failure_after_balance_update_is_atomic(self):
        """2026-11-02: 원천·잔액 변경 다음 거래 갱신이 실패해도 앞선 변경과 버전이 남지 않는다."""
        self.cluster.sql('''
          CREATE FUNCTION payse.refresh_test_failure() RETURNS trigger
          LANGUAGE plpgsql AS $$
          BEGIN
            RAISE EXCEPTION 'Injected source refresh failure';
          END $$;
          CREATE TRIGGER refresh_test_failure
            BEFORE UPDATE ON payse.financial_transactions
            FOR EACH ROW EXECUTE FUNCTION payse.refresh_test_failure();
        ''', self.database)
        initial = self.fingerprint()
        with self.assertRaises(SqlError):
            self.cluster.sql(self.sql(), self.database)
        self.assertEqual(initial, self.fingerprint())

    def test_foreign_source_identity_is_not_reassigned(self):
        """2026-11-02: 다른 사용자에게 이미 속한 신규 ID를 가져와도 양쪽 사용자 자료를 보존한다."""
        beta = json.loads((API / 'fixtures/generated-v4/snapshots/beta-ready.json')
                          .read_text(encoding='utf-8'))
        matches = [row for row in beta['transactions']
                   if row['sourceRef'] == 'fixture/beta/transaction/salary/2026-09']
        self.assertEqual(1, len(matches))
        self.assertEqual(beta['userId'], matches[0]['userId'])
        self.assertEqual('account_entry', matches[0]['recordKind'])
        identity = matches[0]['transactionId']
        self.assertEqual(['1'], self.cluster.sql(
            'SELECT count(*) FROM payse.financial_transactions WHERE id=' + quote(identity)
            + ' AND user_id=' + quote(beta['userId']) + ';', self.database))
        existing = {row['transactionId'] for row in self.before['transactions']}
        added = [row for row in self.after['transactions'] if row['transactionId'] not in existing]
        self.assertEqual(1, len(added))
        added[0]['transactionId'] = identity
        initial = self.fingerprint()
        with self.assertRaises(SqlError):
            self.cluster.sql(self.sql(), self.database)
        self.assertEqual(initial, self.fingerprint())

    def test_concurrent_settings_change_wins_without_partial_refresh(self):
        """2026-11-02: 같은 사용자 잠금에서 설정 저장이 먼저 확정되면 갱신이 재조회 요구로 끝난다."""
        owner = quote(self.owner)
        with self.cluster.connect(self.database, name='refresh_settings') as settings:
            settings.sql(f'''
              BEGIN;
              UPDATE payse.users SET data_version=data_version+1 WHERE id={owner};
            ''')
            with self.cluster.connect(self.database, name='refresh_waiter') as refresh:
                marker = refresh.submit(self.sql())
                self.cluster.wait_for_lock('refresh_waiter')
                settings.sql('COMMIT;')
                with self.assertRaises(SqlError):
                    refresh.receive(marker)
        self.assertEqual(['2'], self.cluster.sql(
            'SELECT data_version FROM payse.users WHERE id=' + owner + ';', self.database))
        self.assertEqual([self.before['sourceVersion']], self.cluster.sql(
            'SELECT source_version FROM payse.source_contexts WHERE user_id=' + owner + ';',
            self.database))

    def test_inactive_owner_is_rejected(self):
        """2026-11-02: 탈퇴한 사용자의 원천을 갱신해 접근 상태를 되살리지 않는다."""
        self.cluster.sql(f'''
          UPDATE payse.users
          SET deactivated_at=now(), purge_after=now()+interval '1 year'
          WHERE id={quote(self.owner)};
        ''', self.database)
        initial = self.fingerprint()
        with self.assertRaises(SqlError):
            self.cluster.sql(self.sql(), self.database)
        self.assertEqual(initial, self.fingerprint())


def run_checks(cluster, base_sql_root):
    """2026-11-02: 소유한 격리 클러스터에서 새 DB만 만들어 회귀 검사한다."""
    global SqlError, quote
    from auth_test_support import SqlError, quote
    SourceRefreshTests.cluster = cluster
    SourceRefreshTests.base_sql_root = base_sql_root
    return unittest.TextTestRunner(verbosity=2, failfast=True).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SourceRefreshTests))


def main():
    """2026-11-02: 새 테스트 폴더·임의 포트만 사용하고 검사 후 소유한 PostgreSQL만 종료한다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    args = parser.parse_args()
    from auth_test_support import Cluster
    with Cluster(args.pg_bin, args.work_dir) as cluster:
        result = run_checks(cluster, DIRECTORY)
        cluster.report.update({'sourceRefreshChecks': result.testsRun,
                              'sourceRefreshPassed': result.wasSuccessful()})
        return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
