"""2026-10-19: Validate prepared PAYSE snapshots; no application result calculation.

These checks cover the fixture contract and storage invariants. They are not
an API authorization implementation or the Flutter financial calculation engine.
"""
from __future__ import annotations

import argparse
import calendar
import hashlib
import json
import re
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID

from identity_contract import validate_server_seeds
from statement_items import validate_statement_items
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from reference_data.banks import load_bank_directory, check_fixture_banks

LIMIT=9_000_000_000_000
SEOUL=timezone(timedelta(hours=9))
COLLECTION_IDS={'accounts':'accountId','cards':'cardId','transactions':'transactionId','relatedTransactions':'transactionId','statements':'statementId','obligations':'obligationId','reserves':'reserveId','allocations':'allocationId','settlements':'linkId','recurringPlans':'planId','recurringPlanRevisions':'revisionId','recurringDecisions':'decisionId'}
ROOT_KEYS={'userId','schemaVersion','currency','dataVersion','sourceVersion','ruleVersion','asOf','institutions','institutionLinks','coverage'}
FINANCIAL_KEYS=set(COLLECTION_IDS)|{'settings','page','occurrenceOverrides','occurrenceLinks','referenceResolutions','transactionRelations'}
PLAN_KEYS={'userId','planId','firstOccurrenceMonth'}


def require(condition: bool, message: str) -> None:
    """2026-10-19: Raise a validation error instead of silently repairing an invalid fixture."""
    if not condition:
        raise ValueError(message)


def uuid(value) -> None:
    """2026-10-19: Validate a canonical UUID reference; return nothing, raise on failure."""
    require(isinstance(value,str) and str(UUID(value))==value,'invalid UUID')


def money(value, positive=False, signed=False) -> None:
    """2026-10-19: Check integer KRW bounds, rejecting bools/fractions and invalid negative settings."""
    require(type(value) is int and (-LIMIT if signed else 1 if positive else 0)<=value<=LIMIT,'invalid money')


def day(value) -> date:
    """2026-10-19: Validate an ISO date without silently assigning a midnight timestamp."""
    require(isinstance(value,str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}',value),'invalid date')
    return date.fromisoformat(value)


def instant(value) -> datetime:
    """2026-10-19: Require an offset-bearing timestamp and return its parsed value."""
    require(isinstance(value,str),'invalid timestamp')
    parsed=datetime.fromisoformat(value)
    require(parsed.utcoffset() is not None,'timestamp offset missing')
    return parsed


def month(value) -> None:
    """2026-10-19: Validate nominal YYYY-MM without guessing a specific occurrence date."""
    require(isinstance(value,str) and re.fullmatch(r'\d{4}-\d{2}',value),'invalid month')
    day(value+'-01')


def validate_snapshot(snapshot: dict) -> None:
    """2026-10-19: Check one fixture's shape, ownership, versions, evidence and storage bounds."""
    require(ROOT_KEYS<=snapshot.keys(),'missing snapshot keys')
    require(not(set(snapshot)-ROOT_KEYS-FINANCIAL_KEYS),'unknown snapshot keys')
    uuid(snapshot['userId']);owner=snapshot['userId']
    require(snapshot['schemaVersion'] in ('PAYSE-DRAFT-3', 'PAYSE-DRAFT-4') and snapshot['ruleVersion']=='PAYSE-CALC-1' and snapshot['currency']=='KRW','unsupported contract')
    require(isinstance(snapshot['dataVersion'],str) and re.fullmatch('[1-9][0-9]*',snapshot['dataVersion']) and int(snapshot['dataVersion'])<=9223372036854775807,'bad dataVersion')
    as_of=instant(snapshot['asOf']);today=as_of.astimezone(SEOUL).date()
    institutions={i['code']:i for i in snapshot['institutions']}
    require(len(institutions)==9 and sum(i['kind']=='bank' for i in institutions.values())==5,'institution list')
    require(len(institutions)==len(snapshot['institutions']),'duplicate institutions')
    for link in snapshot['institutionLinks']:
        require(link['userId']==owner and link['institutionCode'] in institutions,'foreign institution link')
        uuid(link['linkId']);instant(link['consentedAt'])
    linked={x['institutionCode'] for x in snapshot['institutionLinks'] if x['disconnectedAt'] is None}
    if not linked:
        require(not(FINANCIAL_KEYS&snapshot.keys()) and snapshot['coverage']==[],'preconnection financial leak')
        return
    require(FINANCIAL_KEYS<=snapshot.keys(),'incomplete financial bundle')
    require(snapshot['page']=={'nextCursor':None,'dataVersion':snapshot['dataVersion'],'sourceVersion':snapshot['sourceVersion']},'fixture page/version mismatch')
    maps={}
    for name,id_field in COLLECTION_IDS.items():
        require(isinstance(snapshot[name],list),'collection must be array')
        if name=='recurringPlans':
            for row in snapshot[name]:
                require(isinstance(row,dict) and set(row)==PLAN_KEYS,'recurring plan must contain only identity and first occurrence month')
        maps[name]={x[id_field]:x for x in snapshot[name]}
        require(len(maps[name])==len(snapshot[name]),f'duplicate {name}')
        for row in snapshot[name]:
            require(row['userId']==owner,'cross-user entity');uuid(row[id_field])
            for key,value in row.items():
                if key.endswith('KRW'):
                    money(value,positive=key=='allocatedKRW',signed=(name=='accounts' and key=='balanceKRW'))
    accounts=maps['accounts'];cards=maps['cards'];transactions={**maps['transactions'],**maps['relatedTransactions']}
    require(len(transactions)==len(snapshot['transactions'])+len(snapshot['relatedTransactions']),'primary/related overlap')
    for name in ('accounts','cards','transactions','relatedTransactions','statements'):
        refs=set()
        for row in snapshot[name]:
            require(row['sourceVersion']==snapshot['sourceVersion'] and isinstance(row['sourceRef'],str) and row['sourceRef'].startswith('fixture/'),'source version/reference')
            require(row['sourceRef'] not in refs,'duplicate sourceRef');refs.add(row['sourceRef'])
    for account in accounts.values():
        require(account['institutionCode'] in linked and institutions[account['institutionCode']]['kind']=='bank','bank link')
        require(account['productType'] in ('demand','savings','time_deposit','other'),'product type')
        require(type(account['included']) is bool and account['asOf']==snapshot['asOf'],'account metadata')
    for card in cards.values():
        require(card['institutionCode'] in linked and institutions[card['institutionCode']]['kind']=='card','card link')
        require(card['cardType'] in ('credit','debit','unknown'),'card type')
        require(card['withdrawalAccountId'] is None or card['withdrawalAccountId'] in accounts,'card withdrawal owner')
        for schedule in card['scheduleEvidence']:
            require(bool(schedule['evidenceRef']),'schedule evidence')
            period_start,period_end,due_date=(schedule[x] for x in ('periodStart','periodEnd','dueDate'))
            require((period_start is None)==(period_end is None) and any(x is not None for x in (period_start,period_end,due_date)),'invalid schedule range')
            if period_start:
                require(day(period_start)<=day(period_end),'reversed schedule')
            if due_date:
                day(due_date)
    resolved={r['transactionId']:r for r in snapshot['referenceResolutions']}
    require(len(resolved)==len(snapshot['referenceResolutions']),'duplicate resolution')
    for ref in resolved.values():
        uuid(ref['transactionId']);require(ref['status'] in ('resolved','unavailable'),'reference status')
        if ref['status']=='resolved':
            require(ref['transactionId'] in transactions and ref['reason'] is None,'false resolved')
        else:
            require(ref['reason'] in ('outside_retention','not_provided','not_connected') and ref['transactionId'] not in transactions,'false unavailable')
    for transaction in transactions.values():
        needed={'accountId','cardId','recordKind','amountKRW','direction','status','merchantName','description','purchaseDate','withdrawalDate','refundDate','bookingDate','occurredAt','occurredAtBasis','balanceReflected','reflectionReason','originalTransactionId','payseTransactionType','installmentCurrent','installmentTotal'}
        require(needed<=transaction.keys(),'missing transaction field')
        require(transaction['accountId'] is not None or transaction['cardId'] is not None,'orphan transaction')
        require(transaction['accountId'] is None or transaction['accountId'] in accounts,'foreign account')
        require(transaction['cardId'] is None or transaction['cardId'] in cards,'foreign card')
        require(transaction['recordKind'] in ('account_entry','card_purchase','card_refund','card_cancellation') and transaction['direction'] in ('in','out') and transaction['status'] in ('approved','posted','cancelled','unknown'),'transaction enum')
        # 2026-10-30: 은행 내역은 확정 기록·미확인만 지원하며 카드 상태는 유지한다.
        if transaction['recordKind'] == 'account_entry':
            require(transaction['status'] in ('posted', 'unknown'), 'unsupported account status')
        require((transaction['recordKind']=='account_entry' and transaction['accountId']) or (transaction['recordKind']!='account_entry' and transaction['cardId']),'kind target')
        require(transaction['payseTransactionType'] in (None,'expense','income','internal_transfer','card_payment'),'transaction classification')
        reason=transaction['reflectionReason'];require(reason in ('reflected','not_reflected','not_applicable','unknown'),'reflection enum')
        expected={'reflected':True,'not_reflected':False,'not_applicable':None,'unknown':None}[reason]
        require(transaction['balanceReflected'] is expected and (transaction['accountId'] is not None or expected is None),'reflection disagreement')
        for field in ('purchaseDate','withdrawalDate','refundDate','bookingDate'):
            if transaction[field] is not None:
                require(day(transaction[field])<=today,'future actual transaction')
        cancellation_date = transaction.get('cancellationDate')
        if cancellation_date is not None:
            require(transaction['recordKind'] == 'card_cancellation', 'cancellation date kind')
            require(day(cancellation_date) <= today, 'future cancellation date')
        if transaction['occurredAt'] is None:
            require(transaction['occurredAtBasis'] is None,'invented time basis')
        else:
            moment=instant(transaction['occurredAt']);require(moment<=as_of,'future actual timestamp')
            basis=transaction['occurredAtBasis'];require(basis in ('purchase','booking','withdrawal','refund','cancellation'),'time basis')
            if basis!='cancellation':
                require(transaction[basis+'Date'] is not None and moment.astimezone(SEOUL).date()==day(transaction[basis+'Date']),'timestamp/date mismatch')
            if cancellation_date is not None:
                require(basis == 'cancellation' and moment.astimezone(SEOUL).date() == day(cancellation_date), 'cancellation timestamp/date mismatch')
        original_id=transaction['originalTransactionId']
        if original_id:
            require(original_id!=transaction['transactionId'] and (original_id in transactions or original_id in resolved),'dangling original')
            seen={transaction['transactionId']};current_id=original_id
            while current_id in transactions:
                require(current_id not in seen,'original cycle');seen.add(current_id);current_id=transactions[current_id]['originalTransactionId']
        for field in ('installmentCurrent','installmentTotal'):
            require(transaction[field] is None or type(transaction[field]) is int and transaction[field]>0,'installment count')
        if transaction['installmentCurrent'] and transaction['installmentTotal']:
            require(transaction['installmentCurrent']<=transaction['installmentTotal'],'installment order')
    for statement in maps['statements'].values():
        require(statement['cardId'] in cards and statement['detailCompleteness'] in ('complete','partial','unavailable'),'statement metadata')
        require(len(set(statement['includedTransactionRefs']))==len(statement['includedTransactionRefs']),'duplicate statement detail')
        for transaction_id in statement['includedTransactionRefs']:
            require(transaction_id in transactions and transactions[transaction_id]['cardId']==statement['cardId'],'statement foreign card/transaction')
        require((statement['periodStart'] is None)==(statement['periodEnd'] is None),'statement range pair')
        if statement['periodStart']:
            require(day(statement['periodStart'])<=day(statement['periodEnd']),'statement range')
        if statement['dueDate']:
            day(statement['dueDate'])
    if snapshot['schemaVersion'] == 'PAYSE-DRAFT-4':
        validate_statement_items(snapshot['statements'], transactions, owner, snapshot['sourceVersion'])
        for statement in snapshot['statements']:
            for item in statement['items']:
                require(item['purchaseDate'] is None or day(item['purchaseDate']) <= today, 'future statement item purchase')
    else:
        require(all('items' not in statement for statement in snapshot['statements']), 'v4 items in v3 source')
    relation_keys=set()
    for relation in snapshot['transactionRelations']:
        from_id,to_id=relation['fromId'],relation['toId'];require(from_id in transactions and to_id in transactions and from_id!=to_id and relation['evidenceRef'],'invalid relation')
        key=(relation['kind'],*sorted((from_id,to_id)));require(key not in relation_keys,'duplicate relation');relation_keys.add(key)
        from_transaction,to_transaction=transactions[from_id],transactions[to_id]
        require(from_transaction['amountKRW']==to_transaction['amountKRW'],'relation amount disagreement')
        if relation['kind']=='internal_transfer':
            require(from_transaction['recordKind']==to_transaction['recordKind']=='account_entry' and from_transaction['direction']!=to_transaction['direction'] and from_transaction['accountId']!=to_transaction['accountId'],'internal transfer semantics')
        else:
            require(relation['kind']=='card_account_pair' and {from_transaction['recordKind'],to_transaction['recordKind']}=={'card_purchase','account_entry'},'card pair semantics')
    plans=maps['recurringPlans'];revisions=maps['recurringPlanRevisions'];revision_keys=set()
    for revision in revisions.values():
        require(revision['planId'] in plans and revision['withdrawalAccountId'] in accounts,'plan revision ownership');month(revision['effectiveFromMonth'])
        require(type(revision['isCurrent']) is bool,'revision authority missing')
        key=(revision['planId'],revision['effectiveFromMonth'])
        if revision['isCurrent']:
            require(key not in revision_keys,'duplicate revision month');revision_keys.add(key)
        require(type(revision['monthlyDay']) is int and 1<=revision['monthlyDay']<=31 and revision['status'] in ('active','cancelled'),'plan fields')
        if revision['paymentTiming']=='immediate':
            require(revision['scheduleBasis']=='withdrawal' and revision['cardId'] is None,'immediate schedule basis')
        else:
            require(revision['paymentTiming']=='card_bill' and revision['scheduleBasis'] in ('purchase','withdrawal') and revision['cardId'] in cards and cards[revision['cardId']]['withdrawalAccountId']==revision['withdrawalAccountId'],'card schedule ownership')
        months=set()
        for override in revision['scheduleOverrides']:
            month(override['occurrenceMonth']);day(override['plannedDate'])
            require(override['occurrenceMonth'] not in months and override['evidenceRef'],'override duplicate/evidence');months.add(override['occurrenceMonth'])
    for plan in plans.values():
        month(plan['firstOccurrenceMonth'])
        first_revision_month=min((revision['effectiveFromMonth'] for revision in revisions.values() if revision['planId']==plan['planId']),default=None)
        require(first_revision_month==plan['firstOccurrenceMonth'],'plan first month differs from earliest revision')
    require(all((revision['planId'],revision['effectiveFromMonth']) in revision_keys for revision in revisions.values()),'retired revision without replacement')
    obligations=maps['obligations'];occurrence_keys=set();statement_obligations=set()
    for obligation in obligations.values():
        require(obligation['withdrawalAccountId'] in accounts and obligation['status'] in ('active','cancelled'),'obligation ownership/status');day(obligation['dueDate'])
        if obligation['statementId']:
            statement=maps['statements'].get(obligation['statementId']);require(statement is not None,'missing statement')
            require(statement['dueDate']==obligation['dueDate'] and statement['amountKRW']==obligation['amountKRW'] and cards[statement['cardId']]['withdrawalAccountId']==obligation['withdrawalAccountId'],'statement obligation disagreement')
            if obligation['status']=='active':
                require(obligation['statementId'] not in statement_obligations,'duplicate statement obligation');statement_obligations.add(obligation['statementId'])
        if obligation['recurrenceKey']:
            require(obligation['recurringPlanId'] in plans and obligation['planRevisionId'] in revisions,'occurrence references')
            require(obligation['recurrenceKey'].startswith(obligation['recurringPlanId']+':'),'recurrence namespace');month(obligation['recurrenceKey'][-7:])
            require(revisions[obligation['planRevisionId']]['planId']==obligation['recurringPlanId'],'wrong pinned revision')
            require(plans[obligation['recurringPlanId']]['firstOccurrenceMonth']<=obligation['recurrenceKey'][-7:],'occurrence precedes plan first month')
            require(revisions[obligation['planRevisionId']]['effectiveFromMonth']<=obligation['recurrenceKey'][-7:],'occurrence precedes pinned revision')
            require(obligation['recurrenceKey'] not in occurrence_keys,'duplicate recurrence');occurrence_keys.add(obligation['recurrenceKey'])
        else:
            require(obligation['recurringPlanId'] is None and obligation['planRevisionId'] is None,'partial recurrence')
    for override in snapshot['occurrenceOverrides']:
        require(override['userId']==owner and override['planRevisionId'] in revisions and override['withdrawalAccountId'] in accounts,'override ownership')
        plan_id=override['recurrenceKey'][:-8];require(plan_id in plans and revisions[override['planRevisionId']]['planId']==plan_id,'override plan');month(override['recurrenceKey'][-7:]);day(override['dueDate']);money(override['amountKRW'])
        require(plans[plan_id]['firstOccurrenceMonth']<=override['recurrenceKey'][-7:],'override precedes plan first month')
        require(revisions[override['planRevisionId']]['effectiveFromMonth']<=override['recurrenceKey'][-7:],'override precedes pinned revision')
        require(override['recurrenceKey'] not in occurrence_keys,'override/materialized duplicate');occurrence_keys.add(override['recurrenceKey'])
    for decision in maps['recurringDecisions'].values():
        require(decision['decision'] in ('approved','excluded'),'decision enum')
        require((decision['decision']=='approved' and decision['planId'] in plans) or (decision['decision']=='excluded' and decision['planId'] is None),'approval plan missing')
        require(all(t in transactions for t in decision['evidenceTransactionIds']),'decision evidence missing')
    settled_by_obligation={};settled_by_transaction={};pairs=set()
    for link in maps['settlements'].values():
        obligation=obligations.get(link['obligationId']);transaction=transactions.get(link['transactionId'])
        require(obligation is not None and transaction is not None and link['evidenceRefs'],'settlement references')
        require(transaction['recordKind']=='account_entry' and transaction['direction']=='out' and transaction['status']=='posted' and transaction['balanceReflected'] is True and transaction['accountId']==obligation['withdrawalAccountId'],'settlement requires confirmed matching withdrawal')
        require(link['method'] in ('automatic','manual'),'settlement method')
        if link['invalidatedAt'] is None:
            pair=(obligation['obligationId'],transaction['transactionId']);require(pair not in pairs,'duplicate active settlement');pairs.add(pair)
            settled_by_obligation[pair[0]]=settled_by_obligation.get(pair[0],0)+link['allocatedKRW'];settled_by_transaction[pair[1]]=settled_by_transaction.get(pair[1],0)+link['allocatedKRW']
    for obligation_id,value in settled_by_obligation.items():
        require(value<=obligations[obligation_id]['amountKRW'],'obligation over-settlement')
    for transaction_id,value in settled_by_transaction.items():
        require(value<=transactions[transaction_id]['amountKRW'],'transaction over-settlement')
    reserves=maps['reserves'];allocated_by_reserve={};allocated_by_obligation={};released_links={}
    for reserve in reserves.values():
        require(reserve['accountId'] in accounts,'reserve owner')
    for allocation in maps['allocations'].values():
        require(allocation['reserveId'] in reserves and allocation['obligationId'] in obligations,'allocation owner')
        money(allocation['amountKRW'],positive=True);require(0<=allocation['releasedKRW']<=allocation['amountKRW'],'invalid release')
        remaining=allocation['amountKRW']-allocation['releasedKRW'];allocated_by_reserve[allocation['reserveId']]=allocated_by_reserve.get(allocation['reserveId'],0)+remaining;allocated_by_obligation[allocation['obligationId']]=allocated_by_obligation.get(allocation['obligationId'],0)+remaining
        require(sum(evidence['amountKRW'] for evidence in allocation['releaseEvidence'])==allocation['releasedKRW'],'release evidence amount')
        for evidence in allocation['releaseEvidence']:
            require(evidence['settlementLinkId'] in maps['settlements'],'release settlement missing');uuid(evidence['writeReceiptId']);money(evidence['amountKRW'],positive=True)
            link=maps['settlements'][evidence['settlementLinkId']]
            require(link['invalidatedAt'] is None and link['obligationId']==allocation['obligationId'],'invalid release link')
            released_links[link['linkId']]=released_links.get(link['linkId'],0)+evidence['amountKRW']
    for link_id,amount in released_links.items():
        require(amount<=maps['settlements'][link_id]['allocatedKRW'],'duplicate release beyond settlement')
    for reserve_id,amount in allocated_by_reserve.items():
        require(amount<=reserves[reserve_id]['amountKRW'],'reserve allocation over limit')
    for obligation_id,amount in allocated_by_obligation.items():
        require(amount<=obligations[obligation_id]['amountKRW']-settled_by_obligation.get(obligation_id,0),'obligation allocation over limit')
    salary=snapshot['settings']['salary'];require(salary['salaryAccountId'] is None or salary['salaryAccountId'] in accounts,'salary account')
    require(salary['salaryDay'] is None or type(salary['salaryDay']) is int and 1<=salary['salaryDay']<=31,'salary day')
    if salary['salaryAmountKRW'] is not None:
        money(salary['salaryAmountKRW'])
    require(type(salary['receiptEvidence']) is list,'salary evidence array')
    pay_months=set()
    for proof in salary['receiptEvidence']:
        require(type(proof) is dict and set(proof)=={'payMonth','expectedPayDate','transactionIds','confirmation'},'salary evidence fields')
        month(proof['payMonth'])
        require(proof['payMonth'] not in pay_months,'duplicate salary payMonth')
        pay_months.add(proof['payMonth'])
        day(proof['expectedPayDate'])
        require(type(proof['transactionIds']) is list and all(type(transaction_id) is str for transaction_id in proof['transactionIds']),'salary transaction IDs')
        require(proof['confirmation'] in ('unknown','partial','confirmed'),'salary confirmation')
        require(proof['confirmation']=='unknown' or bool(proof['transactionIds']),'salary evidence missing')
        for transaction_id in proof['transactionIds']:
            require(transaction_id in transactions and transactions[transaction_id]['recordKind']=='account_entry' and transactions[transaction_id]['direction']=='in' and transactions[transaction_id]['status']=='posted' and transactions[transaction_id]['balanceReflected'] is True,'salary proof invalid')
    for link in snapshot['occurrenceLinks']:
        require(link['evidenceRef'] and link['recurrenceKey'][:-8] in plans,'occurrence link key')
        refs=[(link['purchaseTransactionId'],transactions),(link['statementId'],maps['statements']),(link['obligationId'],obligations)]
        require(any(v for v,_ in refs),'empty occurrence link')
        require(all(v is None or v in mapping for v,mapping in refs),'occurrence dangling reference')
    target_keys=set()
    for coverage in snapshot['coverage']:
        target=coverage['targetId'];kind=coverage['targetKind'];require((kind=='account' and target in accounts) or (kind=='card' and target in cards),'coverage target')
        require((kind,target) not in target_keys,'duplicate coverage');target_keys.add((kind,target))
        begin,end=day(coverage['requestedStart']),day(coverage['requestedEnd'])
        previous_year=date(today.year-1,today.month,min(today.day,calendar.monthrange(today.year-1,today.month)[1]))
        require(begin==previous_year+timedelta(days=1) and end==today,'not one calendar year')
        buckets=[]
        for group in ('coveredRanges','missingRanges'):
            values=set()
            for date_range in coverage[group]:
                range_start,range_end=day(date_range['start']),day(date_range['end']);require(begin<=range_start<=range_end<=end,'coverage range outside request')
                days={range_start+timedelta(days=i) for i in range((range_end-range_start).days+1)}
                require(not(values&days),'overlapping ranges');values|=days
            buckets.append(values)
        covered,missing=buckets;wanted={begin+timedelta(days=i) for i in range((end-begin).days+1)}
        require(not(covered&missing) and covered|missing==wanted,'coverage gaps/overlap')
        require(coverage['status'] in ('complete','partial','failed','unconnected'),'coverage status')
        require(coverage['status']!='complete' or not missing,'false complete')
        require(coverage['status'] not in ('failed','unconnected') or not covered,'failed marked covered')
        require(coverage['status']!='partial' or bool(covered) and bool(missing),'false partial')
        for transaction in snapshot['transactions']:
            if transaction['accountId' if kind=='account' else 'cardId']!=target:
                continue
            stamp=transaction['bookingDate'] if kind=='account' else transaction.get('cancellationDate') or transaction['purchaseDate'] or transaction['refundDate'] or (instant(transaction['occurredAt']).astimezone(SEOUL).date().isoformat() if transaction['occurredAt'] else None)
            if stamp:
                require(day(stamp) in covered,'transaction outside covered range')
    require(len(target_keys)==len(accounts)+len(cards),'missing target coverage')


def validate_directory(path: Path) -> int:
    """2026-10-19: Verify manifest and complete fixtures; return validated snapshot count.

    2026-10-22: Also validate private seed identities and their financial owner links.
    """
    manifest=json.loads((path/'manifest.json').read_text(encoding='utf-8'))
    require(manifest['hashMode']=='canonical-json-utf8','unsupported fixture hash mode')
    require({'server-seeds.json', 'catalog.json', 'bank-directory.json'} <= set(manifest['sha256']), 'required fixture manifest entry missing')
    for name,digest in manifest['sha256'].items():
        require(not Path(name).is_absolute() and '..' not in Path(name).parts,'unsafe manifest path')
        obj=json.loads((path/name).read_text(encoding='utf-8'))
        canonical=json.dumps(obj,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')
        require(hashlib.sha256(canonical).hexdigest()==digest,'fixture manifest mismatch: '+name)
    catalog=json.loads((path/'catalog.json').read_text(encoding='utf-8'))
    releases = {'PAYSE-FIXTURE-3': 'PAYSE-DRAFT-3', 'PAYSE-FIXTURE-4': 'PAYSE-DRAFT-4'}
    require(manifest['fixtureVersion'] == catalog['fixtureVersion'] and catalog['fixtureVersion'] in releases, 'unsupported fixture release')
    require(catalog['schemaVersion'] == releases[catalog['fixtureVersion']], 'fixture release/schema mismatch')
    directory=load_bank_directory(path/'bank-directory.json')
    snapshots = {}
    for entry in catalog['cases']:
        require(entry['file'] in manifest['sha256'], 'catalog case missing from manifest')
        require(entry['id'] not in snapshots, 'duplicate catalog case ID')
        snapshot = json.loads((path/entry['file']).read_text(encoding='utf-8'))
        require(snapshot['schemaVersion'] == catalog['schemaVersion'], 'mixed fixture release')
        validate_snapshot(snapshot)
        check_fixture_banks(snapshot,directory)
        snapshots[entry['id']] = snapshot
    seeds = json.loads((path/'server-seeds.json').read_text(encoding='utf-8'))
    validate_server_seeds(seeds, snapshots)
    return len(snapshots)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('directory',type=Path)
    print(json.dumps({'validatedSnapshots':validate_directory(parser.parse_args().directory)}))
