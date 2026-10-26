"""Common storage preparation rules; no database or HTTP service is started."""
import sys
import re
from pathlib import Path
import unittest

API=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(API));sys.path.insert(0,str(API/'fixtures'))
from export_sql import export, financial_rows, load_sources
from reference_data.export_sql import export as reference_sql
from reference_data.institutions import institution_rows
from testing.scenarios.export_state import export as scenario_sql


class CommonStorageTests(unittest.TestCase):
    """Preserve finance facts while separating reference, initial state and scenarios."""

    def test_initial_state_uses_common_fields(self):
        snapshots,seeds=load_sources(API/'fixtures/generated')
        for snapshot in snapshots:
            rows=financial_rows(snapshot,seeds[snapshot['userId']])
            rows_by_table={table:row for table,row in rows}
            self.assertEqual(rows_by_table['user_attributes'],{'user_id':snapshot['userId'],'salary_day':None,'salary_amount_krw':None,'salary_account_id':None,'card_plan_overrides':[]})
            self.assertFalse(set(rows_by_table)&{'recurring_plans','obligations','reserves','settlement_links','write_receipts','demo_event_receipts'})
            self.assertEqual(rows_by_table['users']['id'],snapshot['userId'])
            self.assertTrue(all(row['user_id']==snapshot['userId'] for table,row in rows if table!='users'))
            for table,row in rows:
                self.assertFalse(any(key.startswith(('demo_','test_','fixture_','synthetic_')) for key in row))

    def test_reference_seed_has_no_user_data(self):
        """2026-10-26: 줄바꿈과 무관하게 기관 수와 사용자 자료의 분리를 검사한다. 사용: unittest."""
        sql=reference_sql()
        self.assertEqual(len(re.findall(r'INSERT\s+INTO\s+payse\.institutions\s*\(',sql)),24)
        self.assertNotIn('payse.users',sql)
        self.assertNotIn('INSERT INTO payse.institutions',export(API/'fixtures/generated'))
        self.assertEqual(len({row['code'] for row in institution_rows()}),24)

    def test_scenario_requires_unique_owners(self):
        for cases in (None,[],['alpha-ready','alpha-shock']):
            with self.subTest(cases=cases),self.assertRaises(ValueError):
                scenario_sql(API/'fixtures/generated',cases)

    def test_scenario_retains_state_as_ordinary_history(self):
        sql=scenario_sql(API/'fixtures/generated',['alpha-ready'])
        for table in ('user_attributes','reserves','settlement_links','write_receipts'):
            self.assertIn('INSERT INTO payse.'+table,sql)
        for marker in ('demo_event_receipts','fixture_initial_state','fixtureInitialState','fixture-seed-not-api-request'):
            self.assertNotIn(marker,sql)
        self.assertIn("'import_user_state'",sql)

    def test_preparation_preserves_financial_facts(self):
        snapshots,seeds=load_sources(API/'fixtures/generated')
        for snapshot in snapshots:
            initial=financial_rows(snapshot,seeds[snapshot['userId']])
            prepared=financial_rows(snapshot,seeds[snapshot['userId']],connected=True)
            # Selection and permission rows are the only permitted differences here.
            def facts(rows):
                return [(table,{k:v for k,v in row.items() if k not in ('included','occurrence_links')}) for table,row in rows if table!='institution_links']
            self.assertEqual(facts(initial),facts(prepared))


if __name__=='__main__':unittest.main()
