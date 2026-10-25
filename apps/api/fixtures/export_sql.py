"""Prepare ordinary user/financial INSERTs; no DB access, updates or scenario settings.
Load the independent institution reference SQL first. Only an empty owner is accepted.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from validate import require, validate_directory
from reference_data.institutions import institution_rows

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


def load_sources(directory: Path, cases=None):
    """2026-10-23: Validate one source snapshot per explicitly selected/default user."""
    validate_directory(directory)
    seeds=json.loads((directory/'server-seeds.json').read_text(encoding='utf-8'))['users']
    catalog=json.loads((directory/'catalog.json').read_text(encoding='utf-8'))
    case_files={case['id']:case['file'] for case in catalog['cases']}
    case_ids=cases or [user['initialCase'] for user in seeds]
    snapshots=[json.loads((directory/case_files[case_id]).read_text(encoding='utf-8')) for case_id in case_ids]
    require(len({snapshot['userId'] for snapshot in snapshots})==len(snapshots),'select only one case per user')
    require(all('accounts' in snapshot for snapshot in snapshots),'select a financial source case; default visibility is unconnected')
    return snapshots, {user['userId']:user for user in seeds}


def financial_rows(snapshot, seed, connected=False):
    """2026-10-23: Map source facts to common tables; selection is enabled only by scenario tooling."""
    rows=[]
    def add_row(table,row):
        rows.append((table,row))
    owner=snapshot['userId']
    add_row('users',{'id':owner,'name':seed['name'],'phone':seed['phone'],'code_verifier':seed['codeVerifier'],'data_version':int(snapshot['dataVersion']),'created_at':seed['createdAt']})
    add_row('source_contexts',{'user_id':owner,'source_version':snapshot['sourceVersion'],'schema_version':snapshot['schemaVersion'],'rule_version':snapshot['ruleVersion'],'as_of':snapshot['asOf'],'coverage':snapshot['coverage'],'salary_evidence':snapshot['settings']['salary']['receiptEvidence'],'occurrence_links':snapshot['occurrenceLinks'] if connected else []})
    if connected:
        for link in snapshot['institutionLinks']:
            add_row('institution_links',{'id':link['linkId'],'user_id':owner,'institution_code':link['institutionCode'],'consented_at':link['consentedAt'],'disconnected_at':link['disconnectedAt']})
    for account in snapshot['accounts']:
        add_row('financial_accounts',{'id':account['accountId'],'user_id':owner,'institution_code':account['institutionCode'],'source_ref':account['sourceRef'],'source_version':account['sourceVersion'],'product_type':account['productType'],'product_name':account['productName'],'masked_number':account['maskedNumber'],'balance_krw':account['balanceKRW'],'as_of':account['asOf'],'included':account['included'] if connected else False,'nickname':account['nickname']})
    for card in snapshot['cards']:
        add_row('financial_cards',{'id':card['cardId'],'user_id':owner,'institution_code':card['institutionCode'],'source_ref':card['sourceRef'],'source_version':card['sourceVersion'],'product_name':card['productName'],'masked_number':card['maskedNumber'],'card_type':card['cardType'],'withdrawal_account_id':card['withdrawalAccountId'],'schedule_evidence':card['scheduleEvidence']})
    transactions=snapshot['transactions']+snapshot['relatedTransactions']
    for transaction in transactions:
        add_row('transaction_references',{'user_id':owner,'transaction_id':transaction['transactionId'],'resolution':'resolved','reason':None})
    for ref in snapshot['referenceResolutions']:
        if ref['status']=='unavailable':
            add_row('transaction_references',{'user_id':owner,'transaction_id':ref['transactionId'],'resolution':ref['status'],'reason':ref['reason']})
    transaction_fields={'id':'transactionId','source_ref':'sourceRef','source_version':'sourceVersion','account_id':'accountId','card_id':'cardId','record_kind':'recordKind','amount_krw':'amountKRW','direction':'direction','status':'status','merchant_name':'merchantName','description':'description','purchase_date':'purchaseDate','withdrawal_date':'withdrawalDate','refund_date':'refundDate','booking_date':'bookingDate','occurred_at':'occurredAt','occurred_at_basis':'occurredAtBasis','reflection_reason':'reflectionReason','original_transaction_id':'originalTransactionId','payse_transaction_type':'payseTransactionType','installment_current':'installmentCurrent','installment_total':'installmentTotal'}
    for transaction in transactions:
        add_row('financial_transactions',{'user_id':owner,**{column:transaction[field] for column,field in transaction_fields.items()}})
    for statement in snapshot['statements']:
        add_row('card_statements',{'id':statement['statementId'],'user_id':owner,'source_ref':statement['sourceRef'],'source_version':statement['sourceVersion'],'card_id':statement['cardId'],'amount_krw':statement['amountKRW'],'due_date':statement['dueDate'],'period_start':statement['periodStart'],'period_end':statement['periodEnd'],'detail_completeness':statement['detailCompleteness']})
        for transaction_id in statement['includedTransactionRefs']:
            add_row('statement_items',{'user_id':owner,'statement_id':statement['statementId'],'card_id':statement['cardId'],'transaction_id':transaction_id})
    for relation in snapshot['transactionRelations']:
        add_row('transaction_relations',{'user_id':owner,'kind':relation['kind'],'from_id':relation['fromId'],'to_id':relation['toId'],'evidence_ref':relation['evidenceRef']})
    add_row('user_attributes',{'user_id':owner,'salary_day':None,'salary_amount_krw':None,'salary_account_id':None,'card_plan_overrides':[]})
    return rows


def render(rows):
    """2026-10-23: Render trusted fixed-mapping rows and require preloaded reference identities."""
    commands=['-- Ordinary initial user data; execute once in an empty owner scope.','BEGIN;','SET CONSTRAINTS ALL DEFERRED;']
    for institution in institution_rows():
        conditions=' AND '.join(k+'='+literal(v) for k,v in institution.items())
        commands.append("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM payse.institutions WHERE "+conditions+") THEN RAISE EXCEPTION 'Load matching institution reference data first'; END IF; END $$;")
    for table,row in rows:
        commands.append(f"INSERT INTO payse.{table} ({', '.join(row)}) VALUES ({', '.join(literal(v) for v in row.values())});")
    return '\n'.join(commands+['SET CONSTRAINTS ALL IMMEDIATE;','COMMIT;'])+'\n'


def export(directory: Path, cases=None) -> str:
    """2026-10-23: Prepare financial data with empty attributes and no preset plans/history."""
    snapshots,seeds=load_sources(directory,cases)
    return render([row for snapshot in snapshots for row in financial_rows(snapshot,seeds[snapshot['userId']])])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path);parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--cases',nargs='+')
    args=parser.parse_args()
    with args.out.open('x',encoding='utf-8',newline='\n') as file:
        file.write(export(args.directory,args.cases))
