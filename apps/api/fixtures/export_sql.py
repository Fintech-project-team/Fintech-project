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
    bycase={x['id']:x['file'] for x in catalog['cases']}
    chosen=cases or [u['initialCase'] for u in seeds]
    snapshots=[json.loads((directory/bycase[x]).read_text(encoding='utf-8')) for x in chosen]
    require(len({s['userId'] for s in snapshots})==len(snapshots),'select only one case per user')
    require(all('accounts' in s for s in snapshots),'select a financial source case; default visibility is unconnected')
    return snapshots, {u['userId']:u for u in seeds}


def financial_rows(s, seed, connected=False):
    """2026-10-23: Map source facts to common tables; selection is enabled only by scenario tooling."""
    rows=[]
    def insert(table,row):
        rows.append((table,row))
    owner=s['userId']
    insert('users',{'id':owner,'name':seed['name'],'phone':seed['phone'],'code_verifier':seed['codeVerifier'],'data_version':int(s['dataVersion']),'created_at':seed['createdAt']})
    insert('source_contexts',{'user_id':owner,'source_version':s['sourceVersion'],'schema_version':s['schemaVersion'],'rule_version':s['ruleVersion'],'as_of':s['asOf'],'coverage':s['coverage'],'salary_evidence':s['settings']['salary']['receiptEvidence'],'occurrence_links':s['occurrenceLinks'] if connected else []})
    if connected:
        for link in s['institutionLinks']:
            insert('institution_links',{'id':link['linkId'],'user_id':owner,'institution_code':link['institutionCode'],'consented_at':link['consentedAt'],'disconnected_at':link['disconnectedAt']})
    for a in s['accounts']:
        insert('financial_accounts',{'id':a['accountId'],'user_id':owner,'institution_code':a['institutionCode'],'source_ref':a['sourceRef'],'source_version':a['sourceVersion'],'product_type':a['productType'],'product_name':a['productName'],'masked_number':a['maskedNumber'],'balance_krw':a['balanceKRW'],'as_of':a['asOf'],'included':a['included'] if connected else False,'nickname':a['nickname']})
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
    insert('user_attributes',{'user_id':owner,'salary_day':None,'salary_amount_krw':None,'salary_account_id':None,'card_plan_overrides':[]})
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
    return render([row for s in snapshots for row in financial_rows(s,seeds[s['userId']])])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path);parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--cases',nargs='+')
    args=parser.parse_args()
    with args.out.open('x',encoding='utf-8',newline='\n') as file:
        file.write(export(args.directory,args.cases))
