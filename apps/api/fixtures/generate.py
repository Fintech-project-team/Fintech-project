"""2026-10-19: Offline PAYSE fixtures; standard-library only, no network or app calculations.

Run with --out NEW_DIRECTORY. Existing output is never overwritten.
This is a preparation tool, not the backend language/framework decision.
"""
from __future__ import annotations

import argparse
import calendar
import copy
import hashlib
import json
from datetime import date, timedelta
from pathlib import Path
from uuid import UUID, uuid5

import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from reference_data.banks import load_bank_directory
from reference_data.institutions import institution_rows
from identity_contract import DISABLED_CODE_VERIFIER, IDENTITY_USERS, validate_server_seeds

NAMESPACE = UUID('bdc76ac7-c7c9-4a66-8b3d-7fd0ef7bdb6b')
FIXTURE_BANK_CODES = ('bank.kb', 'bank.shinhan', 'bank.hana', 'bank.ibk', 'bank.kakao')
BANK_NAMES = {bank['code']: bank['name'] for bank in load_bank_directory()['banks']}
BANKS = [(code, BANK_NAMES[code]) for code in FIXTURE_BANK_CODES]
CARDS = [(row['code'],row['name']) for row in institution_rows() if row['kind']=='card']
SCHEMA = 'PAYSE-DRAFT-3'
RULE = 'PAYSE-CALC-1'
FIXTURE_VERSION = 'PAYSE-FIXTURE-3'
TRANSACTION_NAMES = {
    'expense': '생활비 결제', 'salary': '한빛테크 급여', 'telecom': '휴대폰 요금',
    'daily': '동네마트', 'living': '생활비', 'rent': '월세', 'interest': '예금이자',
    'subscription': '정기구독', 'debit': '국민카드 체크결제',
    'card_payment': '카드 결제대금', 'bill_purchase': '생활용품점',
    'repair': '가전수리비', 'shock': '자동차수리비', 'old_purchase': '가전제품점',
}


def uid(key: str) -> str:
    """2026-10-19: Return deterministic UUID from a semantic fixture key, not amount/date hashes."""
    return str(uuid5(NAMESPACE, 'payse-fixture-1/'+key))


def month_shift(value: date, count: int, day: int | None = None) -> date:
    """2026-10-19: Shift fixture calendar month; clamp day to month end; return a date."""
    y, m = divmod(value.year * 12 + value.month - 1 + count, 12)
    return date(y, m + 1, min(day or value.day, calendar.monthrange(y, m + 1)[1]))


def owned_row(snapshot: dict, collection: str, id_field: str, entity_id: str) -> dict:
    """2026-10-23: Resolve one owned fixture row by ID; used by scenario construction.

    Missing/duplicate IDs and foreign owners fail before copying any source fact.
    Display text and collection order are never selection criteria.
    """
    matches = [row for row in snapshot[collection] if row[id_field] == entity_id]
    if len(matches) != 1 or matches[0]['userId'] != snapshot['userId']:
        raise ValueError(f'Expected one owned {collection} row')
    return matches[0]


def make_snapshot(alias: str, as_of: str = '2026-10-19T12:00:00+09:00') -> dict:
    """2026-10-19: Create a complete one-year development fixture for one synthetic owner.

    2026-10-23: Use natural labels and capture recurrence evidence from created IDs.
    """
    user = uid(alias)
    today = date.fromisoformat(as_of[:10])
    start = month_shift(today, -12) + timedelta(days=1)
    version = f'fixture-3:{alias}:{today}:base'
    # Approval history keeps the source revision at which the decision was made.
    approval_version = f'fixture-2:{alias}:{today}:base'
    def ident(kind, key):
        """2026-10-19: Namespace an immutable entity ID under the fixture owner."""
        return uid(f'{alias}/{kind}/{key}')
    def source(kind, key):
        """2026-10-19: Provide internal provenance; this is not an external API identifier."""
        return {'userId':user,'sourceRef':f'fixture/{alias}/{kind}/{key}','sourceVersion':version}
    institutions = [{'code':code,'kind':kind,'name':name,'accountCount':(2 if code=='bank.kb' else 1) if kind=='bank' else 0,'cardCount':1 if kind=='card' else 0} for kind,listing in [('bank',BANKS),('card',CARDS)] for code,name in listing]
    accounts=[]
    for i in range(6):
        accounts.append({**source('account',str(i)),'accountId':ident('account',i),'institutionCode':BANKS[i%5][0],'productType':'savings' if i==1 else 'time_deposit' if i==5 else 'demand','productName':['입출금 통장','자유 적금','생활비 통장','비상금 통장','내일채움 통장','정기예금'][i],'maskedNumber':f'***-****-{i+1:04}','balanceKRW':[1500000,500000,300000,200000,0,1000000][i],'asOf':as_of,'included':i in (0,1),'nickname':None})
    cards=[]
    for i,(code,name) in enumerate(CARDS):
        schedules=[]
        for offset in range(-1,4):
            first=month_shift(today,offset,1)
            schedules.append({'periodStart':first.isoformat(),'periodEnd':month_shift(first,0,31).isoformat(),'dueDate':month_shift(first,1,10).isoformat(),'evidenceRef':f'fixture-schedule/{alias}/{i}/{first:%Y-%m}'})
        cards.append({**source('card',str(i)),'cardId':ident('card',i),'institutionCode':code,'productName':f'{name} 체크카드' if i==3 else f'{name} 신용카드','maskedNumber':f'****-****-****-{i+1:04}','cardType':'debit' if i==3 else 'credit','withdrawalAccountId':accounts[0 if i<3 else 2]['accountId'],'scheduleEvidence':[] if i==3 else schedules})
    transactions=[]
    telecom_evidence=[]
    relations=[]
    def tx(key, day, amount, account=None, card=None, kind='account_entry', direction='out', name=None, classification='expense', **extra):
        """2026-10-19: Append a confirmed date-only source fact with explicit accounting semantics."""
        name = TRANSACTION_NAMES['expense'] if name is None else name
        row={**source('transaction',key),'transactionId':ident('transaction',key),'accountId':account,'cardId':card,'recordKind':kind,'amountKRW':amount,'direction':direction,'status':'posted','merchantName':name,'description':name,'purchaseDate':day if kind=='card_purchase' else None,'withdrawalDate':day if kind=='account_entry' and direction=='out' else None,'refundDate':day if kind=='card_refund' else None,'bookingDate':day if kind=='account_entry' else None,'occurredAt':None,'occurredAtBasis':None,'balanceReflected':True if kind=='account_entry' else None,'reflectionReason':'reflected' if kind=='account_entry' else 'not_applicable','originalTransactionId':None,'payseTransactionType':classification,'installmentCurrent':None,'installmentTotal':None}
        row.update(extra)
        transactions.append(row)
        return row['transactionId']
    for offset in range(-12,1):
        month=month_shift(today,offset,1)
        def available(d):
            """2026-10-19: Limit source generation to the annual window and confirmed asOf day."""
            return start <= d <= today
        if offset < 0 and available(month_shift(month,0,25)):
            tx(f'salary/{month:%Y-%m}',month_shift(month,0,25).isoformat(),3000000,accounts[0]['accountId'],direction='in',name=TRANSACTION_NAMES['salary'],classification='income')
        for i in (0,2,3):
            day=month_shift(month,0,15)
            if available(day):
                transaction_id=tx(f'account-expense/{i}/{month:%Y-%m}',day.isoformat(),[50000,0,30000,20000][i],accounts[i]['accountId'],name=TRANSACTION_NAMES['telecom'] if i==0 else TRANSACTION_NAMES['daily'])
                if i==0:
                    telecom_evidence.append(transaction_id)
        if available(month_shift(month,0,15)):
            tx(f'living/{month:%Y-%m}',month_shift(month,0,15).isoformat(),1800000,accounts[0]['accountId'],name=TRANSACTION_NAMES['living'])
            tx(f'rent-history/{month:%Y-%m}',month_shift(month,0,15).isoformat(),1200000,accounts[0]['accountId'],name=TRANSACTION_NAMES['rent'])
        for i in (1,5):
            day=month_shift(month,0,15)
            if available(day):
                tx(f'interest/{i}/{month:%Y-%m}',day.isoformat(),1000,accounts[i]['accountId'],direction='in',name=TRANSACTION_NAMES['interest'],classification='income')
        for i,card in enumerate(cards):
            day=month_shift(month,0,12)
            if available(day):
                purchase=tx(f'card-purchase/{i}/{month:%Y-%m}',day.isoformat(),10000*(i+1),card=card['cardId'],kind='card_purchase',name=TRANSACTION_NAMES['subscription'])
                if i==3:
                    bank=tx(f'debit-bank/{month:%Y-%m}',day.isoformat(),40000,accounts[2]['accountId'],name=TRANSACTION_NAMES['debit'])
                    relations.append({'kind':'card_account_pair','fromId':purchase,'toId':bank,'evidenceRef':f'fixture-debit/{month:%Y-%m}'})
                elif available(month_shift(month,1,10)) and not (i==0 and offset==-1):
                    tx(f'historical-card-payment/{i}/{month:%Y-%m}',month_shift(month,1,10).isoformat(),10000*(i+1),accounts[0]['accountId'],name=TRANSACTION_NAMES['card_payment'],classification='card_payment')
    prior=month_shift(today,-1,15).isoformat()
    purchase=tx('bill-purchase',prior,100000,card=cards[0]['cardId'],kind='card_purchase',name=TRANSACTION_NAMES['bill_purchase'])
    payday=month_shift(today,0,10).isoformat()
    payment=tx('bill-payment',payday,110000,accounts[0]['accountId'],name=TRANSACTION_NAMES['card_payment'],classification='card_payment')
    statement={**source('statement','paid'),'statementId':ident('statement','paid'),'cardId':cards[0]['cardId'],'amountKRW':110000,'dueDate':payday,'periodStart':month_shift(today,-1,1).isoformat(),'periodEnd':month_shift(today,-1,31).isoformat(),'includedTransactionRefs':[purchase,ident('transaction',f'card-purchase/0/{month_shift(today,-1,1):%Y-%m}')],'detailCompleteness':'complete'}
    partial=tx('repair-partial',month_shift(today,0,16).isoformat(),40000,accounts[0]['accountId'],name=TRANSACTION_NAMES['repair'])
    outgoing=tx('internal-out',month_shift(today,0,17).isoformat(),50000,accounts[0]['accountId'],name='본인 계좌 이체',classification='internal_transfer')
    incoming=tx('internal-in',month_shift(today,0,17).isoformat(),50000,accounts[1]['accountId'],direction='in',name='본인 계좌 이체',classification='internal_transfer')
    relations.append({'kind':'internal_transfer','fromId':outgoing,'toId':incoming,'evidenceRef':'fixture-owned-transfer-1'})
    planid=ident('plan','telecom');revisionid=ident('revision','telecom-v1')
    firstmonth=f'{today:%Y-%m}'
    revision={'userId':user,'revisionId':revisionid,'planId':planid,'effectiveFromMonth':firstmonth,'label':TRANSACTION_NAMES['telecom'],'amountKRW':50000,'monthlyDay':25,'paymentTiming':'immediate','scheduleBasis':'withdrawal','withdrawalAccountId':accounts[0]['accountId'],'cardId':None,'status':'active','scheduleOverrides':[]}
    revision['isCurrent']=True
    plan={'userId':user,'planId':planid,'firstOccurrenceMonth':firstmonth}
    obligations=[]
    for key,label,amount,day in [('rent','월세',300000,22),('repair','수리비',100000,18),('bill','카드 청구',110000,10),('telecom','통신비',50000,25)]:
        obligations.append({'userId':user,'obligationId':ident('obligation',key),'label':label,'withdrawalAccountId':accounts[0]['accountId'],'amountKRW':amount,'dueDate':month_shift(today,0,day).isoformat(),'status':'active','statementId':statement['statementId'] if key=='bill' else None,'recurringPlanId':planid if key=='telecom' else None,'recurrenceKey':f'{planid}:{firstmonth}' if key=='telecom' else None,'planRevisionId':revisionid if key=='telecom' else None})
    settlements=[]
    for key,tid,amount in [('bill',payment,110000),('repair',partial,40000)]:
        settlements.append({'userId':user,'linkId':ident('settlement',key),'obligationId':ident('obligation',key),'transactionId':tid,'allocatedKRW':amount,'method':'automatic','evidenceRefs':[f'fixture-explicit-settlement/{key}'],'invalidatedAt':None})
    reserves=[{'userId':user,'reserveId':ident('reserve','emergency'),'accountId':accounts[0]['accountId'],'label':'현재 비상금','amountKRW':400000,'cancelledAt':None}]
    allocation={'userId':user,'allocationId':ident('allocation','repair'),'reserveId':reserves[0]['reserveId'],'obligationId':ident('obligation','repair'),'amountKRW':100000,'releasedKRW':40000,'releaseEvidence':[{'settlementLinkId':ident('settlement','repair'),'amountKRW':40000,'writeReceiptId':ident('receipt','initial-settlement')}]}
    evidence=telecom_evidence[-3:]
    decisions=[{'userId':user,'decisionId':ident('decision','telecom'),'candidateKey':'fixture/telecom/three-months','ruleVersion':RULE,'sourceVersion':approval_version,'evidenceTransactionIds':evidence,'normalizedName':TRANSACTION_NAMES['telecom'],'decision':'approved','planId':planid}]
    coverage=[{'targetKind':kind,'targetId':item[field],'requestedStart':start.isoformat(),'requestedEnd':today.isoformat(),'status':'complete','coveredRanges':[{'start':start.isoformat(),'end':today.isoformat()}],'missingRanges':[]} for kind,items,field in [('account',accounts,'accountId'),('card',cards,'cardId')] for item in items]
    snapshot={'userId':user,'schemaVersion':SCHEMA,'currency':'KRW','dataVersion':'1','sourceVersion':version,'ruleVersion':RULE,'asOf':as_of,'institutions':institutions,'institutionLinks':[{'userId':user,'linkId':ident('link',i['code']),'institutionCode':i['code'],'consentedAt':as_of,'disconnectedAt':None} for i in institutions],'coverage':coverage,'accounts':accounts,'cards':cards,'transactions':sorted(transactions,key=lambda x:x['transactionId']),'statements':[statement],'settings':{'salary':{'salaryDay':25,'salaryAmountKRW':3000000,'salaryAccountId':accounts[0]['accountId'],'receiptEvidence':[]},'cardPlans':[]},'obligations':obligations,'reserves':reserves,'allocations':[allocation],'settlements':settlements,'recurringPlans':[plan],'recurringDecisions':decisions,'recurringPlanRevisions':[revision],'occurrenceOverrides':[],'relatedTransactions':[],'referenceResolutions':[],'transactionRelations':relations,'occurrenceLinks':[{'recurrenceKey':f'{planid}:{firstmonth}','purchaseTransactionId':None,'statementId':None,'obligationId':ident('obligation','telecom'),'evidenceRef':'fixture-materialized-telecom'}],'page':{'nextCursor':None,'dataVersion':'1','sourceVersion':version}}
    return snapshot


def reversion(snapshot: dict, source_version: str, data_version: str, as_of: str | None = None) -> None:
    """2026-10-19: Change a prepared source snapshot atomically; preserve stable IDs and user settings."""
    snapshot['sourceVersion']=source_version;snapshot['dataVersion']=data_version
    if as_of:
        snapshot['asOf']=as_of
    for key in ('accounts','cards','transactions','relatedTransactions','statements'):
        for row in snapshot.get(key,[]):
            row['sourceVersion']=source_version
            if key=='accounts':
                row['asOf']=snapshot['asOf']
    snapshot['page']={'nextCursor':None,'dataVersion':data_version,'sourceVersion':source_version}


def build() -> tuple[dict, dict, dict]:
    """2026-10-19: Return named full snapshots, server-only synthetic seed metadata, and test catalog.

    2026-10-23: Resolve templates by owned IDs/relations, preserving scenario facts.
    """
    cases={};catalog={'fixtureVersion':FIXTURE_VERSION,'schemaVersion':SCHEMA,'ruleVersion':RULE,'cases':[],'events':[],'localVectors':[]}
    def add(name,snapshot,goal,expected):
        """2026-10-19: Register a standalone fixture and explicit expected behavior, not a UI result API."""
        cases[name]=snapshot;catalog['cases'].append({'id':name,'file':f'snapshots/{name}.json','goal':goal,'expected':expected})
    base=make_snapshot('alpha')
    add('alpha-ready',base,'연간 자료·선택 계좌·카드 정산·부분 정산·보호 배정',{'selectedAccountIds':[a['accountId'] for a in base['accounts'] if a['included']],'cardPurchaseCountForBill':2,'billRemainingKRW':0,'repairRemainingKRW':60000,'allocationUnreleasedKRW':60000,'emptyAccountId':base['accounts'][4]['accountId']})
    beta=make_snapshot('beta')
    add('beta-ready',beta,'동일한 표시 이름/금액을 가진 다른 사용자 격리',{'mustNotShareIdsWith':'alpha-ready'})
    disconnected={k:copy.deepcopy(base[k]) for k in ('userId','schemaVersion','currency','dataVersion','sourceVersion','ruleVersion','asOf','institutions')}
    disconnected.update(institutionLinks=[],coverage=[])
    add('alpha-unconnected',disconnected,'초기 복원: 연결0·금융 자료 미노출',{'financialKeysAbsent':True,'coverage':[],'homeCalculated':False})
    wait=make_snapshot('alpha','2026-10-25T08:00:00+09:00')
    wait['settings']['salary']['receiptEvidence']=[{'payMonth':'2026-10','expectedPayDate':'2026-10-25','transactionIds':[],'confirmation':'unknown'}]
    add('salary-wait',wait,'급여일 미입금; 당일/연체 예정 지출 홈 반영 대기',{'confirmation':'unknown','pendingObligationsRetained':True})
    partial=copy.deepcopy(wait)
    salary_month=month_shift(date.fromisoformat(wait['asOf'][:10]),-1,1)
    salarytx=copy.deepcopy(owned_row(partial,'transactions','transactionId',uid(f'alpha/transaction/salary/{salary_month:%Y-%m}')))
    salarytx.update(transactionId=uid('alpha/transaction/current-salary-part1'),sourceRef='fixture/alpha/transaction/current-salary-part1',amountKRW=1000000,bookingDate='2026-10-25',occurredAt='2026-10-25T09:00:00+09:00',occurredAtBasis='booking')
    partial['transactions'].append(salarytx);partial['accounts'][0]['balanceKRW']+=1000000
    partial['settings']['salary']['receiptEvidence'][0].update(transactionIds=[salarytx['transactionId']],confirmation='partial')
    reversion(partial,wait['sourceVersion']+':partial','2','2026-10-25T09:00:00+09:00')
    add('salary-partial',partial,'부분 입금도 원천 잔액에는 반영; confirmed 전까지 대기',{'confirmation':'partial','balanceIncrementKRW':1000000,'compareTo':'salary-wait'})
    confirmed=copy.deepcopy(partial);last=copy.deepcopy(salarytx)
    last.update(transactionId=uid('alpha/transaction/current-salary-part2'),sourceRef='fixture/alpha/transaction/current-salary-part2',amountKRW=2000000,occurredAt='2026-10-25T10:00:00+09:00')
    confirmed['transactions'].append(last);confirmed['accounts'][0]['balanceKRW']+=2000000
    confirmed['settings']['salary']['receiptEvidence'][0].update(transactionIds=[salarytx['transactionId'],last['transactionId']],confirmation='confirmed')
    reversion(confirmed,wait['sourceVersion']+':confirmed','3','2026-10-25T10:00:00+09:00')
    add('salary-confirmed',confirmed,'명시 confirmed 사건에서만 급여 입금 완료',{'confirmation':'confirmed','balanceIncrementKRW':2000000,'compareTo':'salary-partial'})
    shock=copy.deepcopy(base)
    repair_link=owned_row(base,'settlements','linkId',uid('alpha/settlement/repair'))
    expense=copy.deepcopy(owned_row(base,'transactions','transactionId',repair_link['transactionId']))
    expense.update(transactionId=uid('alpha/transaction/shock-1'),sourceRef='fixture/alpha/transaction/shock-1',accountId=base['accounts'][0]['accountId'],amountKRW=1700000,purchaseDate=None,withdrawalDate='2026-10-19',bookingDate='2026-10-19',merchantName=TRANSACTION_NAMES['shock'],description=TRANSACTION_NAMES['shock'],payseTransactionType='expense',occurredAt='2026-10-19T12:01:00+09:00',occurredAtBasis='withdrawal')
    shock['transactions'].append(expense);shock['accounts'][0]['balanceKRW']-=1700000
    reversion(shock,base['sourceVersion']+':shock','2','2026-10-19T12:01:00+09:00')
    add('alpha-shock',shock,'준비 사건으로 잔액 하락; 기존 보호액 유지',{'compareTo':'alpha-ready','accountBalanceKRW':-200000,'reserveAmountKRW':400000,'sourceEventOnceOnly':True})
    catalog['events'].append({'eventId':'fixture/shock-1','userId':base['userId'],'beforeCase':'alpha-ready','afterCase':'alpha-shock','sourceVersionBefore':base['sourceVersion'],'sourceVersionAfter':shock['sourceVersion']})
    refund=copy.deepcopy(base)
    original=copy.deepcopy(owned_row(base,'transactions','transactionId',uid('alpha/transaction/bill-purchase')))
    original.update(transactionId=uid('alpha/transaction/old-purchase'),sourceRef='fixture/alpha/transaction/old-purchase',cardId=base['cards'][0]['cardId'],purchaseDate='2025-09-15',amountKRW=200000,merchantName=TRANSACTION_NAMES['old_purchase'],description=TRANSACTION_NAMES['old_purchase'])
    returned=copy.deepcopy(original);returned.update(transactionId=uid('alpha/transaction/partial-refund'),sourceRef='fixture/alpha/transaction/partial-refund',recordKind='card_refund',purchaseDate=None,refundDate='2026-10-05',direction='in',amountKRW=80000,originalTransactionId=original['transactionId'])
    refund['relatedTransactions']=[original];refund['transactions'].append(returned)
    reversion(refund,base['sourceVersion']+':refund','2')
    add('refund-outside-window',refund,'기간 밖 원구매와 당기 부분 환불',{'excludedOriginalPurchaseDate':'2025-09-15','refundConsumptionKRW':-80000,'refundDate':'2026-10-05'})
    unavailable=copy.deepcopy(refund);unavailable['relatedTransactions']=[]
    unavailable['referenceResolutions']=[{'transactionId':original['transactionId'],'status':'unavailable','reason':'not_provided'}]
    add('refund-unavailable-original',unavailable,'확인된 환불 사실·미확보 원거래 참조 보존',{'originalReferenceRetained':True,'interpretationComplete':False})
    missing=copy.deepcopy(base);target=missing['accounts'][3]['accountId'];missing['transactions']=[t for t in missing['transactions'] if not(t['accountId']==target and t['bookingDate'] and t['bookingDate'].startswith('2026-08'))]
    cov=next(c for c in missing['coverage'] if c['targetId']==target)
    cov.update(status='partial',coveredRanges=[{'start':'2025-10-20','end':'2026-07-31'},{'start':'2026-09-01','end':'2026-10-19'}],missingRanges=[{'start':'2026-08-01','end':'2026-08-31'}])
    add('partial-history',missing,'한 계좌의 8월 자료 미확보; 0건으로 위장 금지',{'targetId':target,'missingMonth':'2026-08','annualComplete':False})
    failed=copy.deepcopy(base);target=failed['cards'][2]['cardId'];failed['transactions']=[t for t in failed['transactions'] if t['cardId']!=target]
    cov=next(c for c in failed['coverage'] if c['targetId']==target);cov.update(status='failed',coveredRanges=[],missingRanges=[{'start':cov['requestedStart'],'end':cov['requestedEnd']}])
    add('failed-card-history',failed,'카드 내역 조회 실패와 정상 빈 결과 구별',{'failedTargetId':target,'annualComplete':False})
    schedule=copy.deepcopy(base);schedule['cards'][1]['scheduleEvidence']=[]
    reversion(schedule,base['sourceVersion']+':missing-schedule','2')
    add('unknown-card-schedule',schedule,'카드 미래 출금 일정 미확보',{'cardId':schedule['cards'][1]['cardId'],'futureCardSimulationAllowed':False})
    corrected=copy.deepcopy(base);corrected['settlements'][1]['invalidatedAt']='2026-10-19T12:02:00+09:00';corrected['allocations'][0]['releasedKRW']=0;corrected['allocations'][0]['releaseEvidence']=[];corrected['reserves'][0]['amountKRW']+=40000;corrected['dataVersion']='2';corrected['page']['dataVersion']='2'
    add('settlement-corrected',corrected,'잘못된 지급 연결 해제·보호 배정 복원 상태',{'compareTo':'alpha-ready','sourceUnchanged':True,'repairRemainingKRW':100000,'reserveAmountKRW':440000,'allocationUnreleasedKRW':100000})
    cancelled=copy.deepcopy(base)
    purchase_month=month_shift(date.fromisoformat(base['asOf'][:10]),-4,1)
    p=copy.deepcopy(owned_row(base,'transactions','transactionId',uid(f'alpha/transaction/card-purchase/1/{purchase_month:%Y-%m}')))
    p.update(transactionId=uid('alpha/transaction/cancelled-approval'),sourceRef='fixture/alpha/transaction/cancelled-approval',purchaseDate='2026-10-18',status='cancelled',amountKRW=90000)
    cancellation=copy.deepcopy(p);cancellation.update(transactionId=uid('alpha/transaction/cancellation'),sourceRef='fixture/alpha/transaction/cancellation',recordKind='card_cancellation',purchaseDate=None,direction='in',originalTransactionId=p['transactionId'],occurredAt='2026-10-18T14:00:00+09:00',occurredAtBasis='cancellation')
    cancelled['transactions'] += [p,cancellation]
    reversion(cancelled,base['sourceVersion']+':cancelled-approval','2')
    add('cancelled-approval',cancelled,'미성립 승인 취소는 지급·환불과 별개',{'originalTransactionId':p['transactionId'],'extraNetConsumptionKRW':0})
    gamma=make_snapshot('gamma','2027-01-31T12:00:00+09:00')
    r=gamma['recurringPlanRevisions'][0];r.update(monthlyDay=31,amountKRW=100000,scheduleOverrides=[{'occurrenceMonth':'2027-02','plannedDate':'2027-02-26','evidenceRef':'fixture-confirmed-feb-date'}])
    plan=gamma['recurringPlans'][0]
    jan=gamma['obligations'][-1];jan.update(amountKRW=100000,dueDate='2027-01-31')
    future=copy.deepcopy(r);future.update(revisionId=uid('gamma/revision/march'),effectiveFromMonth='2027-03',amountKRW=110000,scheduleOverrides=[])
    gamma['recurringPlanRevisions'].append(future)
    feb=copy.deepcopy(jan);feb.update(obligationId=uid('gamma/obligation/feb'),dueDate='2027-02-26',recurrenceKey=f"{plan['planId']}:2027-02")
    march=copy.deepcopy(feb);march.update(obligationId=uid('gamma/obligation/march-pinned'),dueDate='2027-03-31',recurrenceKey=f"{plan['planId']}:2027-03")
    gamma['obligations'] += [feb,march]
    gamma['occurrenceOverrides']=[{'userId':gamma['userId'],'recurrenceKey':f"{plan['planId']}:2027-04",'planRevisionId':future['revisionId'],'amountKRW':120000,'dueDate':'2027-04-30','withdrawalAccountId':gamma['accounts'][0]['accountId'],'status':'active'}]
    add('gamma-month-end',gamma,'말일·확인 일정 우선·미래 이력·기존 회차 보존',{'withoutOverrideFebruary':'2027-02-28','confirmedFebruary':'2027-02-26','marchPinnedAmountKRW':100000,'futureRevisionAmountKRW':110000,'aprilIndividualAmountKRW':120000})
    for entry in catalog['cases']:
        s=cases[entry['id']]
        if 'accounts' in s and all(c['status']=='complete' for c in s['coverage']):
            entry['ledgerOpeningBalances']=[{'accountId':a['accountId'],'balanceKRW':a['balanceKRW']-sum((1 if t['direction']=='in' else -1)*t['amountKRW'] for t in s['transactions'] if t['recordKind']=='account_entry' and t['accountId']==a['accountId'] and t['balanceReflected'] is True),'purpose':'검증 전용 기초잔액; 앱 스냅샷 계산에서 거래를 다시 재생하지 않음'} for a in s['accounts']]
    catalog['localVectors']=[{'id':'same-day-no-time','scope':'Flutter 후속 검증 입력','incomeKRW':300000,'outflowKRW':400000,'date':'2026-10-25','timestamps':None,'expected':'일 마감 순액은 -100000; 일중 최초 부족 시각은 미상'}, {'id':'simulation-count-boundary','scope':'Flutter 후속 검증 입력','counts':[0,1,5,6],'expected':['결과 해제','계산 허용','계산 허용','거절']}, {'id':'three-salary-boundaries','scope':'Flutter 후속 검증 입력','asOf':'2027-01-31T12:00:00+09:00','paydays':['2027-02-28','2027-03-31','2027-04-30'],'expected':'반열린 3구간, 종료 상한 2027-04-30; 실제 거래/회차 자동 생성 금지'}]
    seeds = {
        'warning': '합성 개발 시드 전용. 금융 응답에 포함 금지. 실제 인증 구현 아님.',
        'users': [
            {
                'userId': identity['user_id'],
                'name': identity['name'],
                'phone': identity['phone'],
                'codeVerifier': DISABLED_CODE_VERIFIER,
                'createdAt': '2026-10-19T00:00:00+09:00',
                'initialCase': identity['initial_case'],
            }
            for identity in IDENTITY_USERS
        ],
    }
    validate_server_seeds(seeds, cases)
    return cases,seeds,catalog


def write_files(out: Path) -> None:
    """2026-10-19: Write deterministic UTF-8 fixtures into a new directory, refusing any overwrite."""
    if out.exists():
        raise FileExistsError(f'Output already exists: {out}')
    cases,seeds,catalog=build()
    from validate import validate_snapshot
    for snapshot in cases.values():
        validate_snapshot(snapshot)
    out.mkdir(parents=True)
    (out/'snapshots').mkdir()
    contents={f'snapshots/{name}.json':obj for name,obj in cases.items()}
    contents.update({'server-seeds.json':seeds,'catalog.json':catalog,'bank-directory.json':load_bank_directory()})
    hashes={}
    for filename,obj in contents.items():
        body=(json.dumps(obj,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
        (out/filename).write_bytes(body)
        canonical=json.dumps(obj,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')
        hashes[filename]=hashlib.sha256(canonical).hexdigest()
    (out/'manifest.json').write_text(json.dumps({'fixtureVersion':FIXTURE_VERSION,'hashMode':'canonical-json-utf8','sha256':hashes},indent=2)+'\n',encoding='utf-8')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    write_files(parser.parse_args().out)
