"""2026-10-19: Fixture preparation tests, independent from Flutter product tests."""
import copy
import json
import os
import shutil
import sys
import unittest
from contextlib import contextmanager
from pathlib import Path
from uuid import uuid4

FIXTURES=Path(__file__).resolve().parents[1]/'fixtures'
sys.path.insert(0,str(FIXTURES))
from generate import build, uid, write_files
from validate import validate_snapshot, validate_directory
from export_sql import literal, export


@contextmanager
def temporary_directory():
    """2026-10-19: Use a writable test root; remove only the verified newly-created child path."""
    base=Path(os.environ.get('PAYSE_TEST_TEMP',str(Path.cwd()/'.harness/fixture-tests'))).resolve()
    base.mkdir(parents=True,exist_ok=True)
    target=base/str(uuid4());target.mkdir()
    try:
        yield target
    finally:
        resolved=target.resolve()
        if resolved.parent!=base or resolved==base or target.is_symlink():
            raise RuntimeError('Unexpected cleanup path')
        shutil.rmtree(resolved)


class FixtureTests(unittest.TestCase):
    """2026-10-19: Verify cross-record facts and rejection behavior of offline fixture tooling."""
    @classmethod
    def setUpClass(cls):
        """2026-10-19: Build immutable reference fixtures once for independent copies in tests."""
        cls.cases,cls.seeds,cls.catalog=build()

    def case(self,name='alpha-ready'):
        """2026-10-19: Return a deep fixture copy so failure mutations cannot affect other checks."""
        return copy.deepcopy(self.cases[name])

    def rejects(self,mutate,name='alpha-ready'):
        """2026-10-19: Apply one invalid mutation and require a fixture validation failure."""
        s=self.case(name);mutate(s)
        with self.assertRaises((ValueError,KeyError)):
            validate_snapshot(s)

    def test_all_cases(self):
        for name,s in self.cases.items():
            with self.subTest(name=name):
                validate_snapshot(s)

    def test_deterministic_bytes_and_manifest(self):
        with temporary_directory() as temp:
            a,b=Path(temp)/'a',Path(temp)/'b';write_files(a);write_files(b)
            self.assertEqual(validate_directory(a),15)
            for p in a.rglob('*.json'):
                self.assertEqual(p.read_bytes(),(b/p.relative_to(a)).read_bytes())

    def test_refuse_overwrite(self):
        with temporary_directory() as temp:
            with self.assertRaises(FileExistsError):
                write_files(Path(temp))

    def test_annual_coverage_including_empty_account(self):
        s=self.case();empty=s['accounts'][4]['accountId']
        self.assertEqual(s['accounts'][4]['balanceKRW'],0)
        self.assertFalse(any(t['accountId']==empty for t in s['transactions']))
        self.assertTrue(all(c['requestedStart']=='2025-10-20' and c['requestedEnd']=='2026-10-19' for c in s['coverage']))
        self.assertEqual(next(c for c in s['coverage'] if c['targetId']==empty)['status'],'complete')

    def test_restore_exposes_no_financial_ids(self):
        s=self.case('alpha-unconnected')
        self.assertNotIn('accounts',s);self.assertEqual(s['coverage'],[])
        self.rejects(lambda x:x.update(accounts=[]),'alpha-unconnected')

    def test_cross_owner(self):
        self.rejects(lambda s:s['transactions'][0].update(userId=uid('beta')))
        self.rejects(lambda s:s['cards'][0].update(withdrawalAccountId=uid('beta/account/0')))

    def test_stale_version(self):
        self.rejects(lambda s:s['accounts'][0].update(sourceVersion='old'))
        self.rejects(lambda s:s['page'].update(dataVersion='999'))

    def test_same_source_version_never_changes_shared_facts(self):
        seen={}
        for s in self.cases.values():
            for kind,idfield in [('accounts','accountId'),('cards','cardId'),('transactions','transactionId'),('relatedTransactions','transactionId'),('statements','statementId')]:
                for row in s.get(kind,[]):
                    key=(s['userId'],s['sourceVersion'],row[idfield])
                    if key in seen:
                        self.assertEqual(row,seen[key])
                    seen[key]=row

    def test_integer_money_bounds(self):
        for value in (True,1.5,-1,9_000_000_000_001):
            self.rejects(lambda s:s['transactions'][0].update(amountKRW=value))
        s=self.case();s['accounts'][0]['balanceKRW']=-100;validate_snapshot(s)

    def test_unknown_values_are_not_zero(self):
        self.rejects(lambda s:s['accounts'][0].update(balanceKRW=None))
        self.assertEqual(self.case('failed-card-history')['coverage'][-2]['status'],'failed')
        self.assertEqual(self.case('unknown-card-schedule')['cards'][1]['scheduleEvidence'],[])

    def test_date_only_and_confirmed_time(self):
        self.assertTrue(all(t['occurredAt'] is None for t in self.case()['transactions']))
        self.rejects(lambda s:s['transactions'][0].update(occurredAt='2026-10-19T00:00:00'))
        self.rejects(lambda s:s['transactions'][0].update(occurredAt='2026-10-19T00:00:00+09:00',occurredAtBasis='booking'))

    def test_card_purchase_statement_withdrawal_evidence(self):
        s=self.case();st=s['statements'][0];tx={t['transactionId']:t for t in s['transactions']}
        self.assertEqual(sum(tx[i]['amountKRW'] for i in st['includedTransactionRefs']),110000)
        obligation=next(o for o in s['obligations'] if o['statementId']==st['statementId'])
        link=next(l for l in s['settlements'] if l['obligationId']==obligation['obligationId'])
        self.assertEqual(link['allocatedKRW'],110000)
        self.assertEqual(tx[link['transactionId']]['payseTransactionType'],'card_payment')
        self.assertTrue(all(tx[i]['balanceReflected'] is None for i in st['includedTransactionRefs']))

    def test_internal_transfer_and_debit_pairs(self):
        s=self.case();tx={t['transactionId']:t for t in s['transactions']}
        for link in s['transactionRelations']:
            a,b=tx[link['fromId']],tx[link['toId']]
            self.assertEqual(a['amountKRW'],b['amountKRW'])
        self.rejects(lambda s:s['transactionRelations'].append(copy.deepcopy(s['transactionRelations'][0])))

    def test_partial_settlement_and_correction(self):
        a,b=self.case(),self.case('settlement-corrected')
        self.assertEqual(a['accounts'],b['accounts']);self.assertEqual(a['transactions'],b['transactions'])
        self.assertEqual(a['sourceVersion'],b['sourceVersion']);self.assertNotEqual(a['dataVersion'],b['dataVersion'])
        self.assertEqual(a['allocations'][0]['releasedKRW'],40000);self.assertEqual(b['allocations'][0]['releasedKRW'],0)
        self.assertEqual(b['reserves'][0]['amountKRW']-a['reserves'][0]['amountKRW'],40000)

    def test_reject_over_settlement_and_wrong_account(self):
        self.rejects(lambda s:s['settlements'][1].update(allocatedKRW=40001))
        self.rejects(lambda s:s['obligations'][1].update(withdrawalAccountId=s['accounts'][2]['accountId']))

    def test_allocation_limits(self):
        self.rejects(lambda s:s['allocations'][0].update(releasedKRW=100001))
        self.rejects(lambda s:s['allocations'][0].update(amountKRW=101000))
        self.rejects(lambda s:s['allocations'][0]['releaseEvidence'][0].update(amountKRW=1))

    def test_salary_explicit_confirmation(self):
        wait,partial,confirmed=(self.case(n) for n in ('salary-wait','salary-partial','salary-confirmed'))
        self.assertEqual([x['settings']['salary']['receiptEvidence'][0]['confirmation'] for x in (wait,partial,confirmed)],['unknown','partial','confirmed'])
        self.assertEqual(partial['accounts'][0]['balanceKRW']-wait['accounts'][0]['balanceKRW'],1000000)
        self.assertEqual(confirmed['accounts'][0]['balanceKRW']-partial['accounts'][0]['balanceKRW'],2000000)
        self.assertEqual(wait['obligations'],confirmed['obligations'])

    def test_event_preserves_ids_and_protection(self):
        a,b=self.case(),self.case('alpha-shock')
        self.assertEqual([x['accountId'] for x in a['accounts']],[x['accountId'] for x in b['accounts']])
        self.assertEqual(a['reserves'],b['reserves'])
        self.assertEqual(b['accounts'][0]['balanceKRW'],-200000)

    def test_partial_refund_outside_window(self):
        s=self.case('refund-outside-window');original=s['relatedTransactions'][0]
        refund=next(t for t in s['transactions'] if t['originalTransactionId']==original['transactionId'])
        self.assertEqual(refund['amountKRW'],80000);self.assertEqual(original['amountKRW'],200000)
        self.assertEqual(refund['refundDate'],'2026-10-05')
        self.assertFalse(any(t['transactionId']==original['transactionId'] for t in s['transactions']))
        missing=self.case('refund-unavailable-original')
        self.assertEqual(missing['referenceResolutions'][0]['transactionId'],original['transactionId'])

    def test_missing_original_and_cycle(self):
        self.rejects(lambda s:s['referenceResolutions'].clear(),'refund-unavailable-original')
        self.rejects(lambda s:s['transactions'][0].update(originalTransactionId=s['transactions'][0]['transactionId']))

    def test_month_end_and_pinned_revision(self):
        s=self.case('gamma-month-end');revs=s['recurringPlanRevisions'];plan=s['recurringPlans'][0]
        self.assertEqual(plan['monthlyDay'],31)
        self.assertEqual(revs[0]['scheduleOverrides'][0]['plannedDate'],'2027-02-26')
        self.assertEqual(revs[1]['effectiveFromMonth'],'2027-03')
        march=next(o for o in s['obligations'] if o['recurrenceKey'] and o['recurrenceKey'].endswith('2027-03'))
        self.assertEqual(march['planRevisionId'],revs[0]['revisionId']);self.assertEqual(march['amountKRW'],100000)
        self.assertEqual(revs[1]['amountKRW'],110000);self.assertEqual(s['occurrenceOverrides'][0]['amountKRW'],120000)

    def test_duplicate_occurrence_and_revision(self):
        self.rejects(lambda s:s['obligations'].append({**s['obligations'][-1],'obligationId':uid('duplicate')}))
        self.rejects(lambda s:s['recurringPlanRevisions'].append({**s['recurringPlanRevisions'][0],'revisionId':uid('duplicate-revision')}))

    def test_coverage_lies_rejected(self):
        self.rejects(lambda s:s['coverage'][0].update(requestedStart='2025-10-19'))
        self.rejects(lambda s:s['coverage'][0].update(coveredRanges=[]))
        self.rejects(lambda s:next(c for c in s['coverage'] if c['status']=='partial').update(status='complete'),'partial-history')

    def test_fixture_ledger_conservation(self):
        for entry in self.catalog['cases']:
            s=self.cases[entry['id']]
            for opening in entry.get('ledgerOpeningBalances',[]):
                net=sum((1 if t['direction']=='in' else -1)*t['amountKRW'] for t in s['transactions'] if t['recordKind']=='account_entry' and t['accountId']==opening['accountId'] and t['balanceReflected'] is True)
                balance=next(a['balanceKRW'] for a in s['accounts'] if a['accountId']==opening['accountId'])
                self.assertEqual(opening['balanceKRW']+net,balance)
                self.assertGreaterEqual(opening['balanceKRW'],0)

    def test_export_initial_vs_ready_and_no_destruction(self):
        with temporary_directory() as temp:
            p=Path(temp)/'fixtures';write_files(p)
            initial=export(p);ready=export(p,ready=True)
            self.assertNotIn('INSERT INTO payse.institution_links',initial)
            self.assertIn('INSERT INTO payse.institution_links',ready)
            for command in ('DELETE FROM','DROP TABLE','TRUNCATE','UPDATE payse.'):
                self.assertNotIn(command,initial)
            with self.assertRaises(ValueError):
                export(p,cases=['alpha-ready','salary-wait'])
            self.assertEqual(literal("a'; DROP TABLE x;--"),"'a''; DROP TABLE x;--'")


if __name__=='__main__':
    unittest.main()
