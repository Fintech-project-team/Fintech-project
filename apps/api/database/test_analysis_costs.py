"""2026-11-03: 폐기 PostgreSQL에서 비용 예약·전송·정산·권한·경합을 검사한다.
사용: 독립 CLI 또는 test_analysis_service. 실제 공급자/기존 서버에는 접속하지 않는다.
"""
from pathlib import Path
import argparse
import shutil
import unittest
import uuid

from auth_test_support import Cluster, SqlError, quote

DIRECTORY = Path(__file__).resolve().parent
DATABASE = 'payse_auth_test_costs'


class CostTests(unittest.TestCase):
    """2026-11-03: 새 프로젝트마다 고립된 비용 장부를 검사한다. 사용: run_checks."""

    def setUp(self):
        """2026-11-03: 테스트 식별과 단가 정책을 명시 준비한다. 사용: unittest."""
        self.project = uuid.uuid4().hex
        self.cluster.sql(f"""
          INSERT INTO payse.analysis_cost_projects (
            project_id, pricing_version, pricing, opening_micros, limit_micros,
            baseline_verified_at, enabled
          ) VALUES ({quote(self.project)}, 'test-v1', '{{}}', 0, 45000000000, now(), true);
        """, self.database)

    def runtime(self, sql):
        """2026-11-03: 최소 권한에서 실제 커밋을 검사한다. 사용: 각 검사."""
        return self.cluster.sql(
            "SET SESSION AUTHORIZATION payse_runtime; BEGIN; " + sql + " COMMIT;",
            self.database)

    def reserve_sql(self, call, maximum):
        """2026-11-03: 직접 준비한 ID만 SQL에 인용한다. 사용: reserve, 경합 검사."""
        return f"""SELECT payse.analysis_cost_reserve(
          {quote(self.project)}, {quote(call)}, 'test-v1', 'model', {int(maximum)}
        );"""

    def reserve(self, maximum=100):
        """2026-11-03: 신규 호출 하나를 예약한다. 사용: 각 검사."""
        call = str(uuid.uuid4())
        self.runtime(self.reserve_sql(call, maximum))
        return call

    def state(self, call):
        """2026-11-03: 관리자 조회로 비용 기록을 대조한다. 사용: 각 검사."""
        return self.cluster.sql(f"""
          SELECT state, coalesce(actual_micros::text, 'unknown'), dispatched_at IS NOT NULL
          FROM payse.analysis_cost_calls
          WHERE id={quote(call)};
        """, self.database)

    def test_exact_stop_line_is_closed(self):
        """2026-11-03: 차단선에 정확히 닿는 신규 예약도 보수적으로 차단한다. 사용: unittest."""
        self.cluster.sql(f"""
          UPDATE payse.analysis_cost_projects
          SET opening_micros=44900000000
          WHERE project_id={quote(self.project)};
        """, self.database)
        with self.assertRaises(SqlError) as error:
            self.reserve(100000000)
        self.assertEqual('P4501', error.exception.state)
        self.reserve(99999999)
        with self.assertRaises(SqlError):
            self.reserve(1)

    def test_idempotent_reservation_and_claim(self):
        """2026-11-03: 중복 예약은 증가하지 않고 전송권은 한 번만 생긴다. 사용: unittest."""
        call = self.reserve()
        self.runtime(self.reserve_sql(call, 100))
        start = f"SELECT payse.analysis_cost_start({quote(self.project)}, {quote(call)});"
        self.assertEqual(['t'], self.runtime(start))
        self.assertEqual(['f'], self.runtime(start))
        self.assertEqual(['reserved|unknown|t'], self.state(call))
        with self.assertRaises(SqlError) as error:
            self.runtime(self.reserve_sql(call, 101))
        self.assertEqual('23505', error.exception.state)

    def test_unknown_keeps_reservation(self):
        """2026-11-03: 호출 불명·오래된 예약은 취소나 재접속으로 자동 반납하지 않는다. 사용: unittest."""
        call = self.reserve()
        self.runtime(f"SELECT payse.analysis_cost_start({quote(self.project)}, {quote(call)});")
        self.cluster.sql(f"""
          UPDATE payse.analysis_cost_calls
          SET created_at=now()-interval '1 year'
          WHERE id={quote(call)};
        """, self.database)
        self.runtime(f"SELECT payse.analysis_cost_release({quote(self.project)}, {quote(call)});")
        self.assertEqual(['reserved|unknown|t'], self.state(call))

    def test_unstarted_can_release(self):
        """2026-11-03: 전송 전 취소만 반납하고 같은 ID로 되살리지 않는다. 사용: unittest."""
        call = self.reserve()
        self.runtime(f"SELECT payse.analysis_cost_release({quote(self.project)}, {quote(call)});")
        self.runtime(self.reserve_sql(call, 100))
        self.assertEqual(['released|0|f'], self.state(call))
        self.assertEqual(['f'], self.runtime(
            f"SELECT payse.analysis_cost_start({quote(self.project)}, {quote(call)});"))

    def test_settlement_is_independent_and_final(self):
        """2026-11-03: 다른 업무 롤백·중복 콜백이 확정 비용을 지우지 않는다. 사용: unittest."""
        call = self.reserve()
        self.runtime(f"SELECT payse.analysis_cost_start({quote(self.project)}, {quote(call)});")
        finish = f"SELECT payse.analysis_cost_finish({quote(self.project)}, {quote(call)}, 71, false);"
        self.runtime(finish)
        self.runtime(finish)
        with self.assertRaises(SqlError):
            self.runtime("SELECT 1/0;")
        self.assertEqual(['settled|71|t'], self.state(call))
        with self.assertRaises(SqlError) as error:
            self.runtime(f"""
              SELECT payse.analysis_cost_finish({quote(self.project)}, {quote(call)}, 0, true);
            """)
        self.assertEqual('23505', error.exception.state)

    def test_overage_is_recorded_and_blocks_next(self):
        """2026-11-03: 예약보다 큰 실제 청구도 기록하고 이후 호출을 차단한다. 사용: unittest."""
        call = self.reserve()
        self.runtime(f"""
          SELECT payse.analysis_cost_finish(
            {quote(self.project)}, {quote(call)}, 45000000001, false
          );
        """)
        self.assertEqual(['settled|45000000001|f'], self.state(call))
        with self.assertRaises(SqlError) as error:
            self.reserve()
        self.assertEqual('P4501', error.exception.state)

    def test_policy_revocation_prevents_dispatch(self):
        """2026-11-03: 예약 이후 정책이 닫히면 전송을 허용하지 않는다. 사용: unittest."""
        call = self.reserve()
        self.cluster.sql(f"""
          UPDATE payse.analysis_cost_projects
          SET enabled=false
          WHERE project_id={quote(self.project)};
        """, self.database)
        self.assertEqual(['f'], self.runtime(
            f"SELECT payse.analysis_cost_start({quote(self.project)}, {quote(call)});"))
        with self.assertRaises(SqlError) as error:
            self.reserve()
        self.assertEqual('P4500', error.exception.state)

    def test_runtime_cannot_edit_policy_or_raw_ledger(self):
        """2026-11-03: runtime은 정책·원장 직접 읽기/쓰기를 할 수 없다. 사용: unittest."""
        for sql in [
            "SELECT * FROM payse.analysis_cost_projects;",
            "DELETE FROM payse.analysis_cost_calls;",
            "UPDATE payse.analysis_cost_projects SET enabled=true;"
        ]:
            with self.assertRaises(SqlError) as error:
                self.runtime(sql)
            self.assertEqual('42501', error.exception.state)

    def test_concurrent_reservations_share_one_limit(self):
        """2026-11-03: 두 연결이 같은 여유액을 중복 예약하지 못한다. 사용: unittest."""
        first, second = str(uuid.uuid4()), str(uuid.uuid4())
        with self.cluster.connect(self.database, 'cost_first') as left:
            with self.cluster.connect(self.database, 'cost_second') as right:
                left.sql("SET SESSION AUTHORIZATION payse_runtime; BEGIN;")
                left.sql(self.reserve_sql(first, 30000000000))
                marker = right.submit(
                    "SET SESSION AUTHORIZATION payse_runtime; BEGIN;"
                    + self.reserve_sql(second, 30000000000) + "COMMIT;")
                left.sql("COMMIT;")
                with self.assertRaises(SqlError) as error:
                    right.receive(marker)
                self.assertEqual('P4501', error.exception.state)
        self.assertEqual(['1'], self.cluster.sql(f"""
          SELECT count(*)
          FROM payse.analysis_cost_calls
          WHERE project_id={quote(self.project)};
        """, self.database))

    def test_migration_and_business_rollback(self):
        """2026-11-03: 접수 롤백은 예약을 지우고 이행 중간 실패는 전부 롤백한다. 사용: unittest."""
        call = str(uuid.uuid4())
        with self.assertRaises(SqlError):
            self.runtime(self.reserve_sql(call, 100) + "SELECT 1/0;")
        self.assertEqual([], self.state(call))
        database = 'payse_auth_test_cost_rollback'
        self.cluster.sql('CREATE DATABASE ' + database + ';')
        self.cluster.sql('CREATE SCHEMA payse;', database)
        destination = self.cluster.work / 'cost-migration-failure'
        (destination / 'analysis').mkdir(parents=True)
        shutil.copyfile(DIRECTORY / '012_analysis_costs.sql',
                        destination / '012_analysis_costs.sql')
        sql = (DIRECTORY / 'analysis/costs.sql').read_text(encoding='utf-8')
        (destination / 'analysis/costs.sql').write_text(sql + '\nSELECT 1/0;\n', encoding='utf-8')
        with self.assertRaises(SqlError) as error:
            self.cluster.load(destination / '012_analysis_costs.sql', database)
        self.assertEqual('22012', error.exception.state)
        self.assertEqual(['t|t'], self.cluster.sql("""
          SELECT to_regclass('payse.analysis_cost_calls') IS NULL,
            to_regclass('payse.analysis_cost_projects') IS NULL;
        """, database))


def run_checks(cluster, base_sql_root):
    """2026-11-03: 격리 비용 DB에 실제 이행을 적용해 검사한다. 사용: CLI, 통합 runner."""
    cluster.sql('CREATE DATABASE ' + DATABASE + ';')
    for filename in ('001_initial.sql', '002_storage_guards.sql', '003_auth_access.sql'):
        cluster.load(base_sql_root / filename, DATABASE)
    cluster.load(DIRECTORY / '012_analysis_costs.sql', DATABASE)
    CostTests.cluster = cluster
    CostTests.database = DATABASE
    return unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(CostTests))


def main():
    """2026-11-03: 새 폐기 클러스터만 사용하고 결과·종료 확인을 저장한다. 사용: CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    arguments = parser.parse_args()
    with Cluster(arguments.pg_bin, arguments.work_dir) as cluster:
        result = run_checks(cluster, DIRECTORY)
        cluster.report.update({'costChecks': result.testsRun,
                              'costPassed': result.wasSuccessful(),
                              'paidProviderCalled': False})
        return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
