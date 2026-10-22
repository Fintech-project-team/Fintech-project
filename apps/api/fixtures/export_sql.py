"""2026-10-19: Export fixtures to initial INSERT SQL; never connects to a database.

Existing databases must not receive this seed. It is not an update/upsert API.
Default restores unconnected/unselected; --ready enables explicit integration fixtures.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from validate import require, validate_directory


def literal(value) -> str:
    """2026-10-19: Encode one trusted fixture value as a PostgreSQL literal, preserving null and UTF-8."""
    if value is None:
        return 'NULL'
    if type(value) is bool:
        return 'TRUE' if value else 'FALSE'
    if type(value) is int:
        return str(value)
    if isinstance(value,(list,dict)):
        return literal(json.dumps(value,ensure_ascii=False,separators=(',',':')))+'::jsonb'
    return "'"+str(value).replace("'","''")+"'"


def export(directory: Path, ready=False, cases=None) -> str:
    """2026-10-19: Build an all-or-nothing seed script for unique owners; no source refresh or deletion."""
    validate_directory(directory)
    seeds=json.loads((directory/'server-seeds.json').read_text(encoding='utf-8'))['users']
    catalog=json.loads((directory/'catalog.json').read_text(encoding='utf-8'))
    bycase={x['id']:x['file'] for x in catalog['cases']}
    chosen=cases or [u['initialCase'] for u in seeds]
    snapshots=[json.loads((directory/bycase[x]).read_text(encoding='utf-8')) for x in chosen]
    require(len({s['userId'] for s in snapshots})==len(snapshots),'select only one case per user')
    require(all('accounts' in s for s in snapshots),'select a financial source case; default visibility is unconnected')
    commands=['-- Initial synthetic seed only. No real credentials, no updates/deletes.','BEGIN;','SET CONSTRAINTS ALL DEFERRED;']
    def insert(table,row):
        """2026-10-19: Append an INSERT for a fixed mapping table; keys come only from this exporter."""
        commands.append(f"INSERT INTO payse.{table} ({', '.join(row)}) VALUES ({', '.join(literal(v) for v in row.values())});")
    for i in snapshots[0]['institutions']:
        insert('institutions',{k:i[k] for k in ('code','kind','name')})
    for s in snapshots:
        owner=s['userId'];seed=next(u for u in seeds if u['userId']==owner)
        insert('demo_users',{'id':owner,'name':seed['name'],'synthetic_phone':seed['syntheticPhone'],'code_verifier':seed['codeVerifier'],'data_version':int(s['dataVersion']),'created_at':seed['createdAt']})
        insert('source_contexts',{'user_id':owner,'source_version':s['sourceVersion'],'schema_version':s['schemaVersion'],'rule_version':s['ruleVersion'],'as_of':s['asOf'],'coverage':s['coverage'],'salary_evidence':s['settings']['salary']['receiptEvidence'],'occurrence_links':s['occurrenceLinks']})
        if ready:
            for link in s['institutionLinks']:
                insert('institution_links',{'id':link['linkId'],'user_id':owner,'institution_code':link['institutionCode'],'consented_at':link['consentedAt'],'disconnected_at':link['disconnectedAt']})
        for a in s['accounts']:
            insert('financial_accounts',{'id':a['accountId'],'user_id':owner,'institution_code':a['institutionCode'],'source_ref':a['sourceRef'],'source_version':a['sourceVersion'],'product_type':a['productType'],'product_name':a['productName'],'masked_number':a['maskedNumber'],'balance_krw':a['balanceKRW'],'as_of':a['asOf'],'included':a['included'] if ready else False,'nickname':a['nickname']})
        for c in s['cards']:
            insert('financial_cards',{'id':c['cardId'],'user_id':owner,'institution_code':c['institutionCode'],'source_ref':c['sourceRef'],'source_version':c['sourceVersion'],'product_name':c['productName'],'masked_number':c['maskedNumber'],'card_type':c['cardType'],'withdrawal_account_id':c['withdrawalAccountId'],'schedule_evidence':c['scheduleEvidence']})
        alltx=s['transactions']+s['relatedTransactions']
        for t in alltx:
            insert('transaction_references',{'user_id':owner,'transaction_id':t['transactionId'],'resolution':'resolved','reason':None})
        for ref in s['referenceResolutions']:
            if ref['status']=='unavailable':
                insert('transaction_references',{'user_id':owner,'transaction_id':ref['transactionId'],'resolution':ref['status'],'reason':ref['reason']})
        mapping={'id':'transactionId','source_ref':'sourceRef','source_version':'sourceVersion','account_id':'accountId','card_id':'cardId','record_kind':'recordKind','amount_krw':'amountKRW','direction':'direction','status':'status','merchant_name':'merchantName','description':'description','purchase_date':'purchaseDate','withdrawal_date':'withdrawalDate','refund_date':'refundDate','booking_date':'bookingDate','occurred_at':'occurredAt','occurred_at_basis':'occurredAtBasis','reflection_reason':'reflectionReason','original_transaction_id':'originalTransactionId','payse_transaction_type':'payseTransactionType','installment_current':'installmentCurrent','installment_total':'installmentTotal'}
        for t in alltx:
            insert('financial_transactions',{'user_id':owner,**{db:t[api] for db,api in mapping.items()}})
        for st in s['statements']:
            insert('card_statements',{'id':st['statementId'],'user_id':owner,'source_ref':st['sourceRef'],'source_version':st['sourceVersion'],'card_id':st['cardId'],'amount_krw':st['amountKRW'],'due_date':st['dueDate'],'period_start':st['periodStart'],'period_end':st['periodEnd'],'detail_completeness':st['detailCompleteness']})
            for tid in st['includedTransactionRefs']:
                insert('statement_items',{'user_id':owner,'statement_id':st['statementId'],'card_id':st['cardId'],'transaction_id':tid})
        for rel in s['transactionRelations']:
            insert('transaction_relations',{'user_id':owner,'kind':rel['kind'],'from_id':rel['fromId'],'to_id':rel['toId'],'evidence_ref':rel['evidenceRef']})
        salary=s['settings']['salary']
        insert('user_settings',{'user_id':owner,'salary_day':salary['salaryDay'],'salary_amount_krw':salary['salaryAmountKRW'],'salary_account_id':salary['salaryAccountId'],'card_plan_overrides':s['settings']['cardPlans']})
        for p in s['recurringPlans']:
            insert('recurring_plans',{'id':p['planId'],'user_id':owner,'first_occurrence_month':p['firstOccurrenceMonth']+'-01'})
        for r in s['recurringPlanRevisions']:
            insert('recurring_plan_revisions',{'id':r['revisionId'],'user_id':owner,'plan_id':r['planId'],'effective_from_month':r['effectiveFromMonth']+'-01','label':r['label'],'amount_krw':r['amountKRW'],'monthly_day':r['monthlyDay'],'payment_timing':r['paymentTiming'],'schedule_basis':r['scheduleBasis'],'withdrawal_account_id':r['withdrawalAccountId'],'card_id':r['cardId'],'status':r['status'],'schedule_overrides':r['scheduleOverrides'],'is_current':r['isCurrent']})
        for o in s['obligations']:
            insert('obligations',{'id':o['obligationId'],'user_id':owner,'label':o['label'],'withdrawal_account_id':o['withdrawalAccountId'],'amount_krw':o['amountKRW'],'due_date':o['dueDate'],'status':o['status'],'statement_id':o['statementId'],'plan_id':o['recurringPlanId'],'plan_revision_id':o['planRevisionId'],'occurrence_month':o['recurrenceKey'][-7:]+'-01' if o['recurrenceKey'] else None})
        for o in s['occurrenceOverrides']:
            insert('occurrence_overrides',{'user_id':owner,'plan_id':o['recurrenceKey'][:-8],'occurrence_month':o['recurrenceKey'][-7:]+'-01','plan_revision_id':o['planRevisionId'],'amount_krw':o['amountKRW'],'due_date':o['dueDate'],'withdrawal_account_id':o['withdrawalAccountId'],'status':o['status']})
        for d in s['recurringDecisions']:
            insert('recurring_decisions',{'id':d['decisionId'],'user_id':owner,'candidate_key':d['candidateKey'],'rule_version':d['ruleVersion'],'source_version':d['sourceVersion'],'evidence_refs':d['evidenceTransactionIds'],'normalized_name':d['normalizedName'],'decision':d['decision'],'plan_id':d['planId']})
        for link in s['settlements']:
            insert('settlement_links',{'id':link['linkId'],'user_id':owner,'obligation_id':link['obligationId'],'transaction_id':link['transactionId'],'allocated_krw':link['allocatedKRW'],'method':link['method'],'evidence':link['evidenceRefs'],'invalidated_at':link['invalidatedAt']})
        for r in s['reserves']:
            insert('reserves',{'id':r['reserveId'],'user_id':owner,'account_id':r['accountId'],'label':r['label'],'amount_krw':r['amountKRW'],'cancelled_at':r['cancelledAt']})
        receipt_ids=set()
        for a in s['allocations']:
            insert('reserve_allocations',{'id':a['allocationId'],'user_id':owner,'reserve_id':a['reserveId'],'obligation_id':a['obligationId'],'amount_krw':a['amountKRW'],'released_krw':a['releasedKRW'],'release_evidence':a['releaseEvidence']})
            receipt_ids.update(e['writeReceiptId'] for e in a['releaseEvidence'])
        for rid in sorted(receipt_ids):
            insert('write_receipts',{'id':rid,'user_id':owner,'operation_key':'fixture-initial/'+rid,'request_digest':'fixture-seed-not-api-request','action':'fixture_initial_state','changed_refs':[{'allocationId':a['allocationId']} for a in s['allocations']],'before_after':{'fixtureInitialState':True,'notAnExecutedApiRequest':True},'result_version':int(s['dataVersion']),'created_at':s['asOf']})
    commands+=['SET CONSTRAINTS ALL IMMEDIATE;','COMMIT;']
    return '\n'.join(commands)+'\n'


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('directory',type=Path);parser.add_argument('--out',type=Path,required=True);parser.add_argument('--ready',action='store_true');parser.add_argument('--cases',nargs='+')
    args=parser.parse_args();body=export(args.directory,args.ready,args.cases)
    with args.out.open('x',encoding='utf-8',newline='\n') as file:
        file.write(body)
