"""2026-10-19: Fixture preparation tests, independent from Flutter product tests."""
import copy
import hashlib
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
from identity_contract import validate_server_seeds, validate_stored_identity


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

    def test_seed_identity_mapping_and_uuid_stability(self):
        """2026-10-22: Keep existing owners while exposing exactly one canonical name."""
        self.assertEqual([u['name'] for u in self.seeds['users']],['데모알파','데모베타','데모감마'])
        self.assertEqual([u['userId'] for u in self.seeds['users']],[uid('alpha'),uid('beta'),uid('gamma')])
        for user in self.seeds['users']:
            self.assertNotIn('syntheticName',user)
            self.assertNotIn('displayName',user)
        validate_server_seeds(self.seeds,self.cases)

    def test_stored_identity_rejects_whitespace_unicode_and_invalid_bounds(self):
        """2026-10-22: Storage accepts canonical values only, without silent normalization."""
        invalid_names=['가','A'*21,' 데모알파','데모 알파','데모알파 ','데모알파\n','데모\t알파','데모\u00a0알파','데모\u200b알파','데모１','ㄱㄴ',None,123]
        for name in invalid_names:
            with self.subTest(name=repr(name)),self.assertRaises(ValueError):
                validate_stored_identity(name,'01000000001')
        for phone in ['0100000000','010000000001','01100000001','010-0000-0001','010 0000 0001','01000000001\n','０１００００００００１','+821000000001',None,1000000001]:
            with self.subTest(phone=repr(phone)),self.assertRaises(ValueError):
                validate_stored_identity('데모알파',phone)
        for name in ['가나','Ab','A'*20,'가'*20]:
            validate_stored_identity(name,'01000000001')

    def test_seed_shape_and_credential_mapping_tampering_rejected(self):
        """2026-10-22: Reject legacy keys, changed identities and active credentials."""
        mutations=[
            lambda s:s['users'][0].pop('name'),
            lambda s:s['users'][0].update(syntheticName='데모알파'),
            lambda s:s['users'][0].update(displayName='데모알파'),
            lambda s:s['users'].append(copy.deepcopy(s['users'][0])),
            lambda s:s['users'][0].update(userId=str(uuid4())),
            lambda s:s['users'][0].update(name='다른이름'),
            lambda s:s['users'][0].update(syntheticPhone='01000000009'),
            lambda s:s['users'][0].update(initialCase='beta-ready'),
            lambda s:s['users'][0].update(codeVerifier='000001'),
            lambda s:s['users'][0].update(codeVerifier='enabled-digest'),
            lambda s:s['users'].pop(),
            lambda s:s.update(extra=True),
        ]
        for index,mutate in enumerate(mutations):
            with self.subTest(index=index):
                seeds=copy.deepcopy(self.seeds);mutate(seeds)
                with self.assertRaises(ValueError):
                    validate_server_seeds(seeds,self.cases)

    def test_seed_creation_timestamp_and_snapshot_owner_required(self):
        """2026-10-22: A valid seed must point to its own dated initial snapshot."""
        for value in [None,'invalid','2026-10-19','2026-10-19T00:00:00',123]:
            with self.subTest(value=value):
                seeds=copy.deepcopy(self.seeds);seeds['users'][0]['createdAt']=value
                with self.assertRaises(ValueError):
                    validate_server_seeds(seeds,self.cases)
        snapshots=copy.deepcopy(self.cases);snapshots.pop('alpha-ready')
        with self.assertRaises(ValueError):
            validate_server_seeds(self.seeds,snapshots)
        snapshots=copy.deepcopy(self.cases);snapshots['alpha-ready']['userId']=uid('beta')
        with self.assertRaises(ValueError):
            validate_server_seeds(self.seeds,snapshots)

    def test_rehashed_invalid_private_seed_still_rejected(self):
        """2026-10-22: Hash integrity alone must not authorize an invalid identity."""
        with temporary_directory() as temp:
            directory=Path(temp)/'fixtures';write_files(directory)
            path=directory/'server-seeds.json'
            seeds=json.loads(path.read_text(encoding='utf-8'))
            seeds['users'][0]['name']='데모 알파'
            path.write_text(json.dumps(seeds,ensure_ascii=False),encoding='utf-8')
            manifest_path=directory/'manifest.json'
            manifest=json.loads(manifest_path.read_text(encoding='utf-8'))
            manifest['sha256']['server-seeds.json']=hashlib.sha256(json.dumps(seeds,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')).hexdigest()
            manifest_path.write_text(json.dumps(manifest),encoding='utf-8')
            for check in [validate_directory,export]:
                with self.subTest(check=check.__name__),self.assertRaisesRegex(ValueError,'stored identity name'):
                    check(directory)

    def test_manifest_requires_seed_and_catalog_case_coverage(self):
        """2026-10-22: Omitting a file from integrity coverage cannot bypass validation."""
        for missing in ['server-seeds.json','catalog.json','alpha-ready.json']:
            with self.subTest(missing=missing),temporary_directory() as temp:
                directory=Path(temp)/'fixtures';write_files(directory)
                manifest_path=directory/'manifest.json'
                manifest=json.loads(manifest_path.read_text(encoding='utf-8'))
                actual=next((key for key in manifest['sha256'] if key.endswith(missing)),missing)
                manifest['sha256'].pop(actual)
                manifest_path.write_text(json.dumps(manifest),encoding='utf-8')
                with self.assertRaises(ValueError):
                    validate_directory(directory)

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

    def test_salary_evidence_survives_account_setting_change(self):
        """2026-10-21: Keep source salary proofs unchanged when the selected salary account changes or clears."""
        for case in ('salary-partial','salary-confirmed'):
            for target in (None, 1):
                with self.subTest(case=case,target=target):
                    s=self.case(case)
                    source=copy.deepcopy((s['transactions'],s['settings']['salary']['receiptEvidence']))
                    s['settings']['salary']['salaryAccountId']=None if target is None else s['accounts'][target]['accountId']
                    validate_snapshot(s)
                    self.assertEqual((s['transactions'],s['settings']['salary']['receiptEvidence']),source)

    def test_salary_evidence_still_requires_owned_posted_incoming_fact(self):
        """2026-10-21: Reject missing, foreign, outgoing and unconfirmed salary evidence after separating settings."""
        for changes in ({'direction':'out'}, {'status':'approved'}, {'status':'cancelled'}, {'status':'unknown'}, {'balanceReflected':False,'reflectionReason':'not_reflected'}):
            with self.subTest(changes=changes):
                def mutate(s):
                    proof=s['settings']['salary']['receiptEvidence'][0]['transactionIds'][0]
                    next(t for t in s['transactions'] if t['transactionId']==proof).update(changes)
                self.rejects(mutate,'salary-confirmed')
        for transaction_id in (uid('missing-salary'),uid('beta/transaction/salary/2026-09')):
            self.rejects(lambda s:s['settings']['salary']['receiptEvidence'][0].update(transactionIds=[transaction_id]),'salary-confirmed')

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
        self.assertEqual(plan['firstOccurrenceMonth'],'2027-01')
        self.assertEqual(revs[0]['monthlyDay'],31)
        self.assertEqual(revs[0]['scheduleOverrides'][0]['plannedDate'],'2027-02-26')
        self.assertEqual(revs[1]['effectiveFromMonth'],'2027-03')
        february=next(o for o in s['obligations'] if o['recurrenceKey'] and o['recurrenceKey'].endswith('2027-02'))
        self.assertEqual(february['planRevisionId'],revs[0]['revisionId'])
        self.assertEqual(february['dueDate'],'2027-02-26')
        march=next(o for o in s['obligations'] if o['recurrenceKey'] and o['recurrenceKey'].endswith('2027-03'))
        self.assertEqual(march['planRevisionId'],revs[0]['revisionId']);self.assertEqual(march['amountKRW'],100000)
        self.assertEqual(revs[1]['amountKRW'],110000);self.assertEqual(s['occurrenceOverrides'][0]['amountKRW'],120000)
        self.assertEqual(s['occurrenceOverrides'][0]['planRevisionId'],revs[1]['revisionId'])
        self.assertEqual(s['occurrenceOverrides'][0]['recurrenceKey'],plan['planId']+':2027-04')
        before=copy.deepcopy(s)
        validate_snapshot(s)
        self.assertEqual(s,before)

    def test_recurring_plan_has_one_value_authority(self):
        for name,s in self.cases.items():
            with self.subTest(name=name):
                self.assertEqual(s['schemaVersion'],'PAYSE-DRAFT-2')
                for plan in s.get('recurringPlans',[]):
                    self.assertEqual(set(plan),{'userId','planId','firstOccurrenceMonth'})
        self.rejects(lambda s:s.update(schemaVersion='PAYSE-DRAFT-1'))

    def test_recurring_plan_rejects_missing_and_extra_keys(self):
        for key in ('userId','planId','firstOccurrenceMonth'):
            with self.subTest(missing=key):
                s=self.case()
                del s['recurringPlans'][0][key]
                with self.assertRaisesRegex(ValueError,'recurring plan must contain only'):
                    validate_snapshot(s)
        revision=self.case()['recurringPlanRevisions'][0]
        for key,value in revision.items():
            if key not in ('userId','planId'):
                with self.subTest(forbidden=key):
                    self.rejects(lambda s:s['recurringPlans'][0].update({key:value}))
        self.rejects(lambda s:s['recurringPlans'][0].update(unknownPlanKey='unexpected'))

    def test_recurring_plan_rejects_duplicate_identity_and_missing_revision(self):
        self.rejects(lambda s:s['recurringPlans'].append(copy.deepcopy(s['recurringPlans'][0])))
        self.rejects(lambda s:s['recurringPlanRevisions'].clear())
        self.rejects(lambda s:s['recurringPlans'][0].update(firstOccurrenceMonth='2026-11'))

    def test_recurring_plan_first_month_matches_earliest_revision(self):
        """2026-10-22: Reject shifting a plan boundary away from its earliest retained revision."""
        for first_month in ('2026-12','2027-02','2027-03','2027-04'):
            with self.subTest(first_month=first_month):
                self.rejects(lambda s:s['recurringPlans'][0].update(firstOccurrenceMonth=first_month),'gamma-month-end')
        s=self.case('gamma-month-end')
        earlier={**s['recurringPlanRevisions'][0],'revisionId':uid('gamma/earlier-revision'),'effectiveFromMonth':'2026-12'}
        s['recurringPlanRevisions'].append(earlier)
        with self.assertRaisesRegex(ValueError,'plan first month differs from earliest revision'):
            validate_snapshot(s)

    def test_recurring_plan_first_month_preserves_retired_pinned_history(self):
        """2026-10-22: Allow a same-month replacement while old pinned revisions and occurrences remain."""
        s=self.case('gamma-month-end')
        original=copy.deepcopy((s['obligations'],s['occurrenceOverrides']))
        initial=s['recurringPlanRevisions'][0]
        initial['isCurrent']=False
        replacement={**copy.deepcopy(initial),'revisionId':uid('gamma/initial-replacement'),'amountKRW':100001,'isCurrent':True}
        s['recurringPlanRevisions'].append(replacement)
        validate_snapshot(s)
        self.assertEqual(s['recurringPlans'][0]['firstOccurrenceMonth'],'2027-01')
        self.assertEqual((s['obligations'],s['occurrenceOverrides']),original)
        self.assertEqual(s['obligations'][-1]['planRevisionId'],initial['revisionId'])

    def test_duplicate_occurrence_and_revision(self):
        self.rejects(lambda s:s['obligations'].append({**s['obligations'][-1],'obligationId':uid('duplicate')}))
        self.rejects(lambda s:s['recurringPlanRevisions'].append({**s['recurringPlanRevisions'][0],'revisionId':uid('duplicate-revision')}))

    def test_occurrence_cannot_precede_its_pinned_revision(self):
        """2026-10-21: Reject impossible revision dates for saved obligations and individual overrides."""
        self.rejects(lambda s:s['occurrenceOverrides'][0].update(recurrenceKey=s['recurringPlans'][0]['planId']+':2026-12'),'gamma-month-end')
        self.rejects(lambda s:next(o for o in s['obligations'] if o['recurrenceKey']).update(recurrenceKey=s['recurringPlans'][0]['planId']+':2026-12'),'gamma-month-end')
        s=self.case('gamma-month-end')
        override=s['occurrenceOverrides'][0]
        revision=next(r for r in s['recurringPlanRevisions'] if r['revisionId']==override['planRevisionId'])
        revision['effectiveFromMonth']='2027-04'
        validate_snapshot(s)
        revision['effectiveFromMonth']='2027-05'
        with self.assertRaisesRegex(ValueError,'override precedes pinned revision'):
            validate_snapshot(s)

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
            self.assertIn('INSERT INTO payse.demo_users (id, name, synthetic_phone,',initial)
            self.assertNotIn('synthetic_name',initial)
            self.assertNotIn('display_name',initial)
            self.assertNotIn('INSERT INTO payse.institution_links',initial)
            self.assertIn('INSERT INTO payse.institution_links',ready)
            for command in ('DELETE FROM','DROP TABLE','TRUNCATE','UPDATE payse.'):
                self.assertNotIn(command,initial)
            with self.assertRaises(ValueError):
                export(p,cases=['alpha-ready','salary-wait'])
            self.assertEqual(literal("a'; DROP TABLE x;--"),"'a''; DROP TABLE x;--'")


if __name__=='__main__':
    unittest.main()
