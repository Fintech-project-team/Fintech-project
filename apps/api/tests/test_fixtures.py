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
from unittest.mock import patch

FIXTURES=Path(__file__).resolve().parents[1]/'fixtures'
sys.path.insert(0,str(FIXTURES))
sys.path.insert(0,str(FIXTURES.parent))
import generate
from generate import build, uid, write_files, owned_row
from validate import validate_snapshot, validate_directory
from export_sql import literal, export
from testing.scenarios.export_state import export as export_scenario
from reference_data.export_sql import export as export_reference
from identity_contract import validate_server_seeds, validate_stored_identity
sys.path.insert(0,str(FIXTURES.parent))
from reference_data.banks import load_bank_directory, validate_bank_directory


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

    def test_financial_labels_are_not_test_markers(self):
        """2026-10-23: Keep technical provenance while financial display values read naturally."""
        for snapshot in self.cases.values():
            for collection in ('accounts','cards','transactions','relatedTransactions','recurringPlanRevisions','recurringDecisions'):
                for row in snapshot.get(collection,[]):
                    for field in ('productName','maskedNumber','merchantName','description','label','normalizedName'):
                        if isinstance(row.get(field),str):
                            self.assertFalse(any(marker in row[field] for marker in ('합성','DEMO','TEST')))

    def test_transaction_selection_ignores_labels(self):
        """2026-10-23: Equal labels must retain salary, recurring evidence, refund and cancellation identities."""
        with patch.dict(generate.TRANSACTION_NAMES,{key:'같은 거래명' for key in generate.TRANSACTION_NAMES}):
            cases,_,catalog=build()
        self.assertEqual(catalog,self.catalog)
        for name, snapshot in cases.items():
            validate_snapshot(snapshot)
            original=self.cases[name]
            self.assertEqual(snapshot.get('settings'),original.get('settings'))
            self.assertEqual(snapshot.get('transactionRelations'),original.get('transactionRelations'))
            self.assertEqual([x['evidenceTransactionIds'] for x in snapshot.get('recurringDecisions',[])],
                             [x['evidenceTransactionIds'] for x in original.get('recurringDecisions',[])])
            for collection in ('transactions','relatedTransactions'):
                def facts(rows):
                    return {row['transactionId']:{key:value for key,value in row.items() if key not in {'merchantName','description'}} for row in rows}
                self.assertEqual(facts(snapshot.get(collection,[])),facts(original.get(collection,[])))

    def test_template_selection_ignores_order(self):
        """2026-10-23: Reverse source rows to expose accidental first-row scenario selection."""
        original_make=generate.make_snapshot
        def reversed_rows(*args,**kwargs):
            snapshot=original_make(*args,**kwargs)
            snapshot['transactions'].reverse()
            return snapshot
        with patch.object(generate,'make_snapshot',side_effect=reversed_rows):
            cases,_,catalog=build()
        self.assertEqual(catalog,self.catalog)
        for name,snapshot in cases.items():
            validate_snapshot(snapshot)
            self.assertEqual({row['transactionId']:row for row in snapshot.get('transactions',[])},
                             {row['transactionId']:row for row in self.cases[name].get('transactions',[])})

    def test_owned_lookup_rejects_missing_duplicate_foreign_rows(self):
        """2026-10-23: Stop preparation before ambiguous/missing/foreign source facts can be cloned."""
        source=self.case('salary-partial')
        transaction_id=source['settings']['salary']['receiptEvidence'][0]['transactionIds'][0]
        row=owned_row(source,'transactions','transactionId',transaction_id)
        for change in ('missing','duplicate','foreign'):
            with self.subTest(change=change):
                snapshot=copy.deepcopy(source)
                if change=='missing':
                    snapshot['transactions']=[x for x in snapshot['transactions'] if x['transactionId']!=transaction_id]
                elif change=='duplicate':
                    snapshot['transactions'].append(copy.deepcopy(row))
                else:
                    owned_row(snapshot,'transactions','transactionId',transaction_id)['userId']=self.cases['beta-ready']['userId']
                with self.assertRaisesRegex(ValueError,'Expected one owned'):
                    owned_row(snapshot,'transactions','transactionId',transaction_id)

    def test_bank_directory_does_not_create_accounts(self):
        """2026-10-23: The reviewed 20-bank directory must not create 20 banks of user accounts."""
        directory=load_bank_directory()
        self.assertEqual(len(directory['banks']),20)
        for category,count in {'commercial':7,'regional':5,'internet':3,'special':5}.items():
            self.assertEqual(sum(bank['category']==category for bank in directory['banks']),count)
        for snapshot in self.cases.values():
            self.assertEqual(sum(bank['kind']=='bank' for bank in snapshot['institutions']),5)
            if 'accounts' in snapshot:
                self.assertEqual(len(snapshot['accounts']),6)
                self.assertEqual(len(snapshot['cards']),4)
        with temporary_directory() as temp:
            folder=temp/'new';write_files(folder)
            seed=export(folder)
            self.assertEqual(seed.count('INSERT INTO payse.institutions '),0)
            self.assertEqual(seed.count('INSERT INTO payse.financial_accounts '),18)
            self.assertEqual(seed.count('INSERT INTO payse.financial_cards '),12)
            self.assertNotIn('INSERT INTO payse.institution_links ',seed)

    def test_bank_directory_rejects_unverified_or_conflicting_rows(self):
        """2026-10-23: Reject duplicate keys, unsupported classes, fake evidence and provider-code drift."""
        directory=load_bank_directory()
        mutations=(
            lambda d:d['banks'].append(copy.deepcopy(d['banks'][0])),
            lambda d:d['banks'][0].update(kind='card'),
            lambda d:d['banks'][0].update(category='savings_bank'),
            lambda d:d['banks'][0].update(sourceRefs=['missing']),
            lambda d:d['banks'][0].update(providerCode='guessed'),
            lambda d:d['banks'][0].update(code='004'),
            lambda d:d.update(countryCode='US'),
            lambda d:d['sources'].update(bok='http://example.invalid'),
        )
        for index,mutate in enumerate(mutations):
            with self.subTest(index=index):
                bad=copy.deepcopy(directory);mutate(bad)
                with self.assertRaises(ValueError):
                    validate_bank_directory(bad)

    def test_published_bundle_matches_generator(self):
        """2026-10-23: Check tracked JSON semantic values after formatting and manifest validation.

        2026-10-26: Include the independent eighteenth demo case; used by unittest.
        """
        self.assertEqual(validate_directory(FIXTURES/'generated'),18)
        for name,snapshot in self.cases.items():
            stored=json.loads((FIXTURES/'generated'/'snapshots'/f'{name}.json').read_text(encoding='utf-8'))
            self.assertEqual(stored,snapshot)
        self.assertEqual(load_bank_directory(FIXTURES/'generated'/'bank-directory.json'),load_bank_directory())

    def test_deterministic_bytes_and_manifest(self):
        """2026-10-26: Verify the expanded bundle remains deterministic; used by unittest."""
        with temporary_directory() as temp:
            a,b=Path(temp)/'a',Path(temp)/'b';write_files(a);write_files(b)
            self.assertEqual(validate_directory(a),18)
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

    def test_stored_identity_rejects_invalid_input(self):
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
            lambda s:s['users'][0].update(phone='01000000009'),
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
        """2026-10-22: A valid seed must point to its own dated initial snapshot.

        2026-10-26: Resolve the initial case from the seed mapping; used by unittest.
        """
        for value in [None,'invalid','2026-10-19','2026-10-19T00:00:00',123]:
            with self.subTest(value=value):
                seeds=copy.deepcopy(self.seeds);seeds['users'][0]['createdAt']=value
                with self.assertRaises(ValueError):
                    validate_server_seeds(seeds,self.cases)
        initial_case=self.seeds['users'][0]['initialCase']
        snapshots=copy.deepcopy(self.cases);snapshots.pop(initial_case)
        with self.assertRaises(ValueError):
            validate_server_seeds(self.seeds,snapshots)
        snapshots=copy.deepcopy(self.cases);snapshots[initial_case]['userId']=uid('beta')
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

    def test_salary_evidence_requires_owned_income(self):
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
                self.assertEqual(s['schemaVersion'],'PAYSE-DRAFT-3')
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

    def test_plan_rejects_invalid_revision_links(self):
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

    def test_plan_preserves_pinned_history(self):
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
        """2026-10-26: 생성 SQL 형식과 무관하게 초기/연결 자료 및 파괴 명령 배제를 검사한다. 사용: unittest."""
        with temporary_directory() as temp:
            p=Path(temp)/'fixtures';write_files(p)
            initial=export(p);ready=export_scenario(p,['alpha-ready','beta-ready','gamma-month-end'])
            self.assertRegex(initial,r'INSERT INTO payse\.users\s*\(\s*id,\s*name,\s*phone,')
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
