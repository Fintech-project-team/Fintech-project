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


def state_rows(snapshot):
    """2026-10-23: Preserve the established IDs, amounts, dates and release evidence."""
    rows=[]
    def add_row(table,row):
        rows.append((table,row))
    owner=snapshot['userId']
    salary=snapshot['settings']['salary']
    add_row('user_attributes',{'user_id':owner,'salary_day':salary['salaryDay'],'salary_amount_krw':salary['salaryAmountKRW'],'salary_account_id':salary['salaryAccountId'],'card_plan_overrides':snapshot['settings']['cardPlans']})
    for plan in snapshot['recurringPlans']:
        add_row('recurring_plans',{'id':plan['planId'],'user_id':owner,'first_occurrence_month':plan['firstOccurrenceMonth']+'-01'})
    for revision in snapshot['recurringPlanRevisions']:
        add_row('recurring_plan_revisions',{'id':revision['revisionId'],'user_id':owner,'plan_id':revision['planId'],'effective_from_month':revision['effectiveFromMonth']+'-01','label':revision['label'],'amount_krw':revision['amountKRW'],'monthly_day':revision['monthlyDay'],'payment_timing':revision['paymentTiming'],'schedule_basis':revision['scheduleBasis'],'withdrawal_account_id':revision['withdrawalAccountId'],'card_id':revision['cardId'],'status':revision['status'],'schedule_overrides':revision['scheduleOverrides'],'is_current':revision['isCurrent']})
    for obligation in snapshot['obligations']:
        add_row('obligations',{'id':obligation['obligationId'],'user_id':owner,'label':obligation['label'],'withdrawal_account_id':obligation['withdrawalAccountId'],'amount_krw':obligation['amountKRW'],'due_date':obligation['dueDate'],'status':obligation['status'],'statement_id':obligation['statementId'],'plan_id':obligation['recurringPlanId'],'plan_revision_id':obligation['planRevisionId'],'occurrence_month':obligation['recurrenceKey'][-7:]+'-01' if obligation['recurrenceKey'] else None})
    for override in snapshot['occurrenceOverrides']:
        add_row('occurrence_overrides',{'user_id':owner,'plan_id':override['recurrenceKey'][:-8],'occurrence_month':override['recurrenceKey'][-7:]+'-01','plan_revision_id':override['planRevisionId'],'amount_krw':override['amountKRW'],'due_date':override['dueDate'],'withdrawal_account_id':override['withdrawalAccountId'],'status':override['status']})
    for decision in snapshot['recurringDecisions']:
        add_row('recurring_decisions',{'id':decision['decisionId'],'user_id':owner,'candidate_key':decision['candidateKey'],'rule_version':decision['ruleVersion'],'source_version':decision['sourceVersion'],'evidence_refs':decision['evidenceTransactionIds'],'normalized_name':decision['normalizedName'],'decision':decision['decision'],'plan_id':decision['planId']})
    for link in snapshot['settlements']:
        add_row('settlement_links',{'id':link['linkId'],'user_id':owner,'obligation_id':link['obligationId'],'transaction_id':link['transactionId'],'allocated_krw':link['allocatedKRW'],'method':link['method'],'evidence':link['evidenceRefs'],'invalidated_at':link['invalidatedAt']})
    for reserve in snapshot['reserves']:
        add_row('reserves',{'id':reserve['reserveId'],'user_id':owner,'account_id':reserve['accountId'],'label':reserve['label'],'amount_krw':reserve['amountKRW'],'cancelled_at':reserve['cancelledAt']})
    receipt_ids=set()
    for allocation in snapshot['allocations']:
        add_row('reserve_allocations',{'id':allocation['allocationId'],'user_id':owner,'reserve_id':allocation['reserveId'],'obligation_id':allocation['obligationId'],'amount_krw':allocation['amountKRW'],'released_krw':allocation['releasedKRW'],'release_evidence':allocation['releaseEvidence']})
        receipt_ids.update(evidence['writeReceiptId'] for evidence in allocation['releaseEvidence'])
    for receipt_id in sorted(receipt_ids):
        add_row('write_receipts',{'id':receipt_id,'user_id':owner,'operation_key':'import-user-state/'+receipt_id,'request_digest':state_digest(snapshot),'action':'import_user_state','changed_refs':[{'allocationId':allocation['allocationId']} for allocation in snapshot['allocations']],'before_after':{'before':None,'after':{'allocations':snapshot['allocations'],'settlements':snapshot['settlements']}},'result_version':int(snapshot['dataVersion']),'created_at':snapshot['asOf']})
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
