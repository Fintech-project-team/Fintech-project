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


def validate_snapshot(s: dict) -> None:
    """2026-10-19: Check one fixture's shape, ownership, versions, evidence and storage bounds."""
    require(ROOT_KEYS<=s.keys(),'missing snapshot keys')
    require(not(set(s)-ROOT_KEYS-FINANCIAL_KEYS),'unknown snapshot keys')
    uuid(s['userId']);owner=s['userId']
    require(s['schemaVersion']=='PAYSE-DRAFT-2' and s['ruleVersion']=='PAYSE-CALC-1' and s['currency']=='KRW','unsupported contract')
    require(isinstance(s['dataVersion'],str) and re.fullmatch('[1-9][0-9]*',s['dataVersion']) and int(s['dataVersion'])<=9223372036854775807,'bad dataVersion')
    asof=instant(s['asOf']);today=asof.astimezone(SEOUL).date()
    institutions={i['code']:i for i in s['institutions']}
    require(len(institutions)==9 and sum(i['kind']=='bank' for i in institutions.values())==5,'institution list')
    require(len(institutions)==len(s['institutions']),'duplicate institutions')
    for link in s['institutionLinks']:
        require(link['userId']==owner and link['institutionCode'] in institutions,'foreign institution link')
        uuid(link['linkId']);instant(link['consentedAt'])
    linked={x['institutionCode'] for x in s['institutionLinks'] if x['disconnectedAt'] is None}
    if not linked:
        require(not(FINANCIAL_KEYS&s.keys()) and s['coverage']==[],'preconnection financial leak')
        return
    require(FINANCIAL_KEYS<=s.keys(),'incomplete financial bundle')
    require(s['page']=={'nextCursor':None,'dataVersion':s['dataVersion'],'sourceVersion':s['sourceVersion']},'fixture page/version mismatch')
    maps={}
    for name,idfield in COLLECTION_IDS.items():
        require(isinstance(s[name],list),'collection must be array')
        if name=='recurringPlans':
            for row in s[name]:
                require(isinstance(row,dict) and set(row)==PLAN_KEYS,'recurring plan must contain only identity and first occurrence month')
        maps[name]={x[idfield]:x for x in s[name]}
        require(len(maps[name])==len(s[name]),f'duplicate {name}')
        for row in s[name]:
            require(row['userId']==owner,'cross-user entity');uuid(row[idfield])
            for key,value in row.items():
                if key.endswith('KRW'):
                    money(value,positive=key=='allocatedKRW',signed=(name=='accounts' and key=='balanceKRW'))
    accounts=maps['accounts'];cards=maps['cards'];txs={**maps['transactions'],**maps['relatedTransactions']}
    require(len(txs)==len(s['transactions'])+len(s['relatedTransactions']),'primary/related overlap')
    for name in ('accounts','cards','transactions','relatedTransactions','statements'):
        refs=set()
        for row in s[name]:
            require(row['sourceVersion']==s['sourceVersion'] and isinstance(row['sourceRef'],str) and row['sourceRef'].startswith('fixture/'),'source version/reference')
            require(row['sourceRef'] not in refs,'duplicate sourceRef');refs.add(row['sourceRef'])
    for a in accounts.values():
        require(a['institutionCode'] in linked and institutions[a['institutionCode']]['kind']=='bank','bank link')
        require(a['productType'] in ('demand','savings','time_deposit','other'),'product type')
        require(type(a['included']) is bool and a['asOf']==s['asOf'],'account metadata')
    for c in cards.values():
        require(c['institutionCode'] in linked and institutions[c['institutionCode']]['kind']=='card','card link')
        require(c['cardType'] in ('credit','debit','unknown'),'card type')
        require(c['withdrawalAccountId'] is None or c['withdrawalAccountId'] in accounts,'card withdrawal owner')
        for schedule in c['scheduleEvidence']:
            require(bool(schedule['evidenceRef']),'schedule evidence')
            a,b,d=(schedule[x] for x in ('periodStart','periodEnd','dueDate'))
            require((a is None)==(b is None) and any(x is not None for x in (a,b,d)),'invalid schedule range')
            if a:
                require(day(a)<=day(b),'reversed schedule')
            if d:
                day(d)
    resolved={r['transactionId']:r for r in s['referenceResolutions']}
    require(len(resolved)==len(s['referenceResolutions']),'duplicate resolution')
    for ref in resolved.values():
        uuid(ref['transactionId']);require(ref['status'] in ('resolved','unavailable'),'reference status')
        if ref['status']=='resolved':
            require(ref['transactionId'] in txs and ref['reason'] is None,'false resolved')
        else:
            require(ref['reason'] in ('outside_retention','not_provided','not_connected') and ref['transactionId'] not in txs,'false unavailable')
    for t in txs.values():
        needed={'accountId','cardId','recordKind','amountKRW','direction','status','merchantName','description','purchaseDate','withdrawalDate','refundDate','bookingDate','occurredAt','occurredAtBasis','balanceReflected','reflectionReason','originalTransactionId','payseTransactionType','installmentCurrent','installmentTotal'}
        require(needed<=t.keys(),'missing transaction field')
        require(t['accountId'] is not None or t['cardId'] is not None,'orphan transaction')
        require(t['accountId'] is None or t['accountId'] in accounts,'foreign account')
        require(t['cardId'] is None or t['cardId'] in cards,'foreign card')
        require(t['recordKind'] in ('account_entry','card_purchase','card_refund','card_cancellation') and t['direction'] in ('in','out') and t['status'] in ('approved','posted','cancelled','unknown'),'transaction enum')
        require((t['recordKind']=='account_entry' and t['accountId']) or (t['recordKind']!='account_entry' and t['cardId']),'kind target')
        require(t['payseTransactionType'] in (None,'expense','income','internal_transfer','card_payment'),'transaction classification')
        reason=t['reflectionReason'];require(reason in ('reflected','not_reflected','not_applicable','unknown'),'reflection enum')
        expected={'reflected':True,'not_reflected':False,'not_applicable':None,'unknown':None}[reason]
        require(t['balanceReflected'] is expected and (t['accountId'] is not None or expected is None),'reflection disagreement')
        for field in ('purchaseDate','withdrawalDate','refundDate','bookingDate'):
            if t[field] is not None:
                require(day(t[field])<=today,'future actual transaction')
        if t['occurredAt'] is None:
            require(t['occurredAtBasis'] is None,'invented time basis')
        else:
            moment=instant(t['occurredAt']);require(moment<=asof,'future actual timestamp')
            basis=t['occurredAtBasis'];require(basis in ('purchase','booking','withdrawal','refund','cancellation'),'time basis')
            if basis!='cancellation':
                require(t[basis+'Date'] is not None and moment.astimezone(SEOUL).date()==day(t[basis+'Date']),'timestamp/date mismatch')
        orig=t['originalTransactionId']
        if orig:
            require(orig!=t['transactionId'] and (orig in txs or orig in resolved),'dangling original')
            seen={t['transactionId']};cur=orig
            while cur in txs:
                require(cur not in seen,'original cycle');seen.add(cur);cur=txs[cur]['originalTransactionId']
        for field in ('installmentCurrent','installmentTotal'):
            require(t[field] is None or type(t[field]) is int and t[field]>0,'installment count')
        if t['installmentCurrent'] and t['installmentTotal']:
            require(t['installmentCurrent']<=t['installmentTotal'],'installment order')
    for st in maps['statements'].values():
        require(st['cardId'] in cards and st['detailCompleteness'] in ('complete','partial','unavailable'),'statement metadata')
        require(len(set(st['includedTransactionRefs']))==len(st['includedTransactionRefs']),'duplicate statement detail')
        for tid in st['includedTransactionRefs']:
            require(tid in txs and txs[tid]['cardId']==st['cardId'],'statement foreign card/transaction')
        require((st['periodStart'] is None)==(st['periodEnd'] is None),'statement range pair')
        if st['periodStart']:
            require(day(st['periodStart'])<=day(st['periodEnd']),'statement range')
        if st['dueDate']:
            day(st['dueDate'])
    relation_keys=set()
    for rel in s['transactionRelations']:
        a,b=rel['fromId'],rel['toId'];require(a in txs and b in txs and a!=b and rel['evidenceRef'],'invalid relation')
        key=(rel['kind'],*sorted((a,b)));require(key not in relation_keys,'duplicate relation');relation_keys.add(key)
        x,y=txs[a],txs[b]
        require(x['amountKRW']==y['amountKRW'],'relation amount disagreement')
        if rel['kind']=='internal_transfer':
            require(x['recordKind']==y['recordKind']=='account_entry' and x['direction']!=y['direction'] and x['accountId']!=y['accountId'],'internal transfer semantics')
        else:
            require(rel['kind']=='card_account_pair' and {x['recordKind'],y['recordKind']}=={'card_purchase','account_entry'},'card pair semantics')
    plans=maps['recurringPlans'];revisions=maps['recurringPlanRevisions'];versionkeys=set()
    for rev in revisions.values():
        require(rev['planId'] in plans and rev['withdrawalAccountId'] in accounts,'plan revision ownership');month(rev['effectiveFromMonth'])
        require(type(rev['isCurrent']) is bool,'revision authority missing')
        key=(rev['planId'],rev['effectiveFromMonth'])
        if rev['isCurrent']:
            require(key not in versionkeys,'duplicate revision month');versionkeys.add(key)
        require(type(rev['monthlyDay']) is int and 1<=rev['monthlyDay']<=31 and rev['status'] in ('active','cancelled'),'plan fields')
        if rev['paymentTiming']=='immediate':
            require(rev['scheduleBasis']=='withdrawal' and rev['cardId'] is None,'immediate schedule basis')
        else:
            require(rev['paymentTiming']=='card_bill' and rev['scheduleBasis'] in ('purchase','withdrawal') and rev['cardId'] in cards and cards[rev['cardId']]['withdrawalAccountId']==rev['withdrawalAccountId'],'card schedule ownership')
        months=set()
        for override in rev['scheduleOverrides']:
            month(override['occurrenceMonth']);day(override['plannedDate'])
            require(override['occurrenceMonth'] not in months and override['evidenceRef'],'override duplicate/evidence');months.add(override['occurrenceMonth'])
    for p in plans.values():
        month(p['firstOccurrenceMonth'])
        first_revision_month=min((r['effectiveFromMonth'] for r in revisions.values() if r['planId']==p['planId']),default=None)
        require(first_revision_month==p['firstOccurrenceMonth'],'plan first month differs from earliest revision')
    require(all((r['planId'],r['effectiveFromMonth']) in versionkeys for r in revisions.values()),'retired revision without replacement')
    obligations=maps['obligations'];occurrencekeys=set();statement_obligations=set()
    for o in obligations.values():
        require(o['withdrawalAccountId'] in accounts and o['status'] in ('active','cancelled'),'obligation ownership/status');day(o['dueDate'])
        if o['statementId']:
            st=maps['statements'].get(o['statementId']);require(st is not None,'missing statement')
            require(st['dueDate']==o['dueDate'] and st['amountKRW']==o['amountKRW'] and cards[st['cardId']]['withdrawalAccountId']==o['withdrawalAccountId'],'statement obligation disagreement')
            if o['status']=='active':
                require(o['statementId'] not in statement_obligations,'duplicate statement obligation');statement_obligations.add(o['statementId'])
        if o['recurrenceKey']:
            require(o['recurringPlanId'] in plans and o['planRevisionId'] in revisions,'occurrence references')
            require(o['recurrenceKey'].startswith(o['recurringPlanId']+':'),'recurrence namespace');month(o['recurrenceKey'][-7:])
            require(revisions[o['planRevisionId']]['planId']==o['recurringPlanId'],'wrong pinned revision')
            require(plans[o['recurringPlanId']]['firstOccurrenceMonth']<=o['recurrenceKey'][-7:],'occurrence precedes plan first month')
            require(revisions[o['planRevisionId']]['effectiveFromMonth']<=o['recurrenceKey'][-7:],'occurrence precedes pinned revision')
            require(o['recurrenceKey'] not in occurrencekeys,'duplicate recurrence');occurrencekeys.add(o['recurrenceKey'])
        else:
            require(o['recurringPlanId'] is None and o['planRevisionId'] is None,'partial recurrence')
    for ov in s['occurrenceOverrides']:
        require(ov['userId']==owner and ov['planRevisionId'] in revisions and ov['withdrawalAccountId'] in accounts,'override ownership')
        plan_id=ov['recurrenceKey'][:-8];require(plan_id in plans and revisions[ov['planRevisionId']]['planId']==plan_id,'override plan');month(ov['recurrenceKey'][-7:]);day(ov['dueDate']);money(ov['amountKRW'])
        require(plans[plan_id]['firstOccurrenceMonth']<=ov['recurrenceKey'][-7:],'override precedes plan first month')
        require(revisions[ov['planRevisionId']]['effectiveFromMonth']<=ov['recurrenceKey'][-7:],'override precedes pinned revision')
        require(ov['recurrenceKey'] not in occurrencekeys,'override/materialized duplicate');occurrencekeys.add(ov['recurrenceKey'])
    for decision in maps['recurringDecisions'].values():
        require(decision['decision'] in ('approved','excluded'),'decision enum')
        require((decision['decision']=='approved' and decision['planId'] in plans) or (decision['decision']=='excluded' and decision['planId'] is None),'approval plan missing')
        require(all(t in txs for t in decision['evidenceTransactionIds']),'decision evidence missing')
    settled_o={};settled_t={};pairs=set()
    for link in maps['settlements'].values():
        o=obligations.get(link['obligationId']);t=txs.get(link['transactionId'])
        require(o is not None and t is not None and link['evidenceRefs'],'settlement references')
        require(t['recordKind']=='account_entry' and t['direction']=='out' and t['status']=='posted' and t['balanceReflected'] is True and t['accountId']==o['withdrawalAccountId'],'settlement requires confirmed matching withdrawal')
        require(link['method'] in ('automatic','manual'),'settlement method')
        if link['invalidatedAt'] is None:
            pair=(o['obligationId'],t['transactionId']);require(pair not in pairs,'duplicate active settlement');pairs.add(pair)
            settled_o[pair[0]]=settled_o.get(pair[0],0)+link['allocatedKRW'];settled_t[pair[1]]=settled_t.get(pair[1],0)+link['allocatedKRW']
    for oid,value in settled_o.items():
        require(value<=obligations[oid]['amountKRW'],'obligation over-settlement')
    for tid,value in settled_t.items():
        require(value<=txs[tid]['amountKRW'],'transaction over-settlement')
    reserves=maps['reserves'];allocated_r={};allocated_o={};released_links={}
    for r in reserves.values():
        require(r['accountId'] in accounts,'reserve owner')
    for a in maps['allocations'].values():
        require(a['reserveId'] in reserves and a['obligationId'] in obligations,'allocation owner')
        money(a['amountKRW'],positive=True);require(0<=a['releasedKRW']<=a['amountKRW'],'invalid release')
        remaining=a['amountKRW']-a['releasedKRW'];allocated_r[a['reserveId']]=allocated_r.get(a['reserveId'],0)+remaining;allocated_o[a['obligationId']]=allocated_o.get(a['obligationId'],0)+remaining
        require(sum(e['amountKRW'] for e in a['releaseEvidence'])==a['releasedKRW'],'release evidence amount')
        for e in a['releaseEvidence']:
            require(e['settlementLinkId'] in maps['settlements'],'release settlement missing');uuid(e['writeReceiptId']);money(e['amountKRW'],positive=True)
            link=maps['settlements'][e['settlementLinkId']]
            require(link['invalidatedAt'] is None and link['obligationId']==a['obligationId'],'invalid release link')
            released_links[link['linkId']]=released_links.get(link['linkId'],0)+e['amountKRW']
    for lid,amount in released_links.items():
        require(amount<=maps['settlements'][lid]['allocatedKRW'],'duplicate release beyond settlement')
    for rid,amount in allocated_r.items():
        require(amount<=reserves[rid]['amountKRW'],'reserve allocation over limit')
    for oid,amount in allocated_o.items():
        require(amount<=obligations[oid]['amountKRW']-settled_o.get(oid,0),'obligation allocation over limit')
    salary=s['settings']['salary'];require(salary['salaryAccountId'] is None or salary['salaryAccountId'] in accounts,'salary account')
    require(salary['salaryDay'] is None or type(salary['salaryDay']) is int and 1<=salary['salaryDay']<=31,'salary day')
    if salary['salaryAmountKRW'] is not None:
        money(salary['salaryAmountKRW'])
    for proof in salary['receiptEvidence']:
        day(proof['expectedPayDate']);require(proof['confirmation'] in ('unknown','partial','confirmed'),'salary confirmation')
        require(proof['confirmation']=='unknown' or bool(proof['transactionIds']),'salary evidence missing')
        for tid in proof['transactionIds']:
            require(tid in txs and txs[tid]['recordKind']=='account_entry' and txs[tid]['direction']=='in' and txs[tid]['status']=='posted' and txs[tid]['balanceReflected'] is True,'salary proof invalid')
    for link in s['occurrenceLinks']:
        require(link['evidenceRef'] and link['recurrenceKey'][:-8] in plans,'occurrence link key')
        refs=[(link['purchaseTransactionId'],txs),(link['statementId'],maps['statements']),(link['obligationId'],obligations)]
        require(any(v for v,_ in refs),'empty occurrence link')
        require(all(v is None or v in mapping for v,mapping in refs),'occurrence dangling reference')
    targetkeys=set()
    for cov in s['coverage']:
        target=cov['targetId'];kind=cov['targetKind'];require((kind=='account' and target in accounts) or (kind=='card' and target in cards),'coverage target')
        require((kind,target) not in targetkeys,'duplicate coverage');targetkeys.add((kind,target))
        begin,end=day(cov['requestedStart']),day(cov['requestedEnd'])
        prev=date(today.year-1,today.month,min(today.day,calendar.monthrange(today.year-1,today.month)[1]))
        require(begin==prev+timedelta(days=1) and end==today,'not one calendar year')
        buckets=[]
        for group in ('coveredRanges','missingRanges'):
            values=set()
            for r in cov[group]:
                a,b=day(r['start']),day(r['end']);require(begin<=a<=b<=end,'coverage range outside request')
                days={a+timedelta(days=i) for i in range((b-a).days+1)}
                require(not(values&days),'overlapping ranges');values|=days
            buckets.append(values)
        covered,missing=buckets;wanted={begin+timedelta(days=i) for i in range((end-begin).days+1)}
        require(not(covered&missing) and covered|missing==wanted,'coverage gaps/overlap')
        require(cov['status'] in ('complete','partial','failed','unconnected'),'coverage status')
        require(cov['status']!='complete' or not missing,'false complete')
        require(cov['status'] not in ('failed','unconnected') or not covered,'failed marked covered')
        require(cov['status']!='partial' or bool(covered) and bool(missing),'false partial')
        for t in s['transactions']:
            if t['accountId' if kind=='account' else 'cardId']!=target:
                continue
            stamp=t['bookingDate'] if kind=='account' else t['purchaseDate'] or t['refundDate'] or (instant(t['occurredAt']).astimezone(SEOUL).date().isoformat() if t['occurredAt'] else None)
            if stamp:
                require(day(stamp) in covered,'transaction outside covered range')
    require(len(targetkeys)==len(accounts)+len(cards),'missing target coverage')


def validate_directory(path: Path) -> int:
    """2026-10-19: Verify manifest and complete fixtures; return validated snapshot count.

    2026-10-22: Also validate private seed identities and their financial owner links.
    """
    manifest=json.loads((path/'manifest.json').read_text(encoding='utf-8'))
    require(manifest['hashMode']=='canonical-json-utf8','unsupported fixture hash mode')
    require({'server-seeds.json', 'catalog.json'} <= set(manifest['sha256']), 'required fixture manifest entry missing')
    for name,digest in manifest['sha256'].items():
        require(not Path(name).is_absolute() and '..' not in Path(name).parts,'unsafe manifest path')
        obj=json.loads((path/name).read_text(encoding='utf-8'))
        canonical=json.dumps(obj,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')
        require(hashlib.sha256(canonical).hexdigest()==digest,'fixture manifest mismatch: '+name)
    snapshots = {}
    for entry in json.loads((path/'catalog.json').read_text(encoding='utf-8'))['cases']:
        require(entry['file'] in manifest['sha256'], 'catalog case missing from manifest')
        require(entry['id'] not in snapshots, 'duplicate catalog case ID')
        snapshot = json.loads((path/entry['file']).read_text(encoding='utf-8'))
        validate_snapshot(snapshot)
        snapshots[entry['id']] = snapshot
    seeds = json.loads((path/'server-seeds.json').read_text(encoding='utf-8'))
    validate_server_seeds(seeds, snapshots)
    return len(snapshots)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('directory',type=Path)
    print(json.dumps({'validatedSnapshots':validate_directory(parser.parse_args().directory)}))
