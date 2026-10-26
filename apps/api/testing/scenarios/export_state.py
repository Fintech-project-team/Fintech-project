"""Optional scenario setup outside the service: insert ordinary persisted user state.
No scenario flag, event table or scenario HTTP API is needed in the application.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'fixtures'))
from export_sql import financial_rows, load_sources, render


def state_digest(snapshot):
    """2026-10-23: Digest actual imported state, without pretending an API request occurred."""
    state={k:snapshot[k] for k in ('settings','allocations','settlements')}
    return hashlib.sha256(json.dumps(state,sort_keys=True,ensure_ascii=False,separators=(',',':')).encode()).hexdigest()


def state_rows(s):
    """2026-10-23: Preserve the established IDs, amounts, dates and release evidence."""
    rows=[]
    def insert(table,row):
        rows.append((table,row))
    owner=s['userId']
    salary=s['settings']['salary']
    insert('user_attributes',{'user_id':owner,'salary_day':salary['salaryDay'],'salary_amount_krw':salary['salaryAmountKRW'],'salary_account_id':salary['salaryAccountId'],'card_plan_overrides':s['settings']['cardPlans']})
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
        insert('write_receipts',{'id':rid,'user_id':owner,'operation_key':'import-user-state/'+rid,'request_digest':state_digest(s),'action':'import_user_state','changed_refs':[{'allocationId':a['allocationId']} for a in s['allocations']],'before_after':{'before':None,'after':{'allocations':s['allocations'],'settlements':s['settlements']}},'result_version':int(s['dataVersion']),'created_at':s['asOf']})
    return rows


def export(directory: Path, cases) -> str:
    """2026-10-23: Explicitly select complete, connected scenarios for an empty test database."""
    if not cases:
        raise ValueError('Explicit scenario selection required')
    snapshots,seeds=load_sources(directory,cases)
    rows=[]
    for snapshot in snapshots:
        rows.extend(row for row in financial_rows(snapshot,seeds[snapshot['userId']],connected=True) if row[0]!='user_attributes')
        rows.extend(state_rows(snapshot))
    return render(rows)
