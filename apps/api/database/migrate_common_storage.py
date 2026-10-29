"""Review, archive and apply the common-user schema transition on an explicit DB.

This historical transition uses its frozen column contract; later additive migrations run separately.
The batch installer never runs this tool. Take a full DB backup first. Removed
scenario receipts are preserved in the review archive; all remaining rows stay intact.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
from migrate_identity import MigrationError, require, run_psql, sql_literal, sql_digest, transaction_prefix

HERE=Path(__file__).resolve().parent
FORMAT='PAYSE-COMMON-STORAGE-1'
RENAMES={'demo_users':'users','user_settings':'user_attributes'}
LEGACY=HERE.parent/'tests/legacy/001_initial.sql'
# This historical transition preserves v2 evidence; v3 requires a separate reviewed mapping.
FROZEN_COMMON=HERE/'migrations/001_common_storage.v2.sql'
FROZEN_GUARDS=HERE/'migrations/002_storage_guards.v2.sql'


def table_contract(path):
    """2026-10-23: Read explicit DDL table/column names, not user-defined SQL."""
    contracts={}
    for table,body in re.findall(r'CREATE TABLE payse\.(\w+) \((.*?)\n\);',path.read_text(encoding='utf-8'),re.S):
        contracts[table]=[line.split()[0] for line in body.splitlines() if re.match(r'^  [a-z_]+\s+[a-z]',line)]
    require(bool(contracts),'DDL contract missing')
    return contracts


def snapshot_query(legacy):
    """2026-10-23: Archive removed records and digest every retained row under its common name.

    2026-10-29: Use the frozen target columns; later additive migrations remain separate.
    """
    contract=table_contract(LEGACY if legacy else FROZEN_COMMON)
    pairs=[]
    for table in sorted(contract):
        if table=='demo_event_receipts':continue
        expr="(to_jsonb(t)-'synthetic_phone')||jsonb_build_object('phone',t.synthetic_phone)" if table=='demo_users' else 'to_jsonb(t)'
        row='('+expr+')::text'
        content="COALESCE(string_agg("+row+", E'\\n' ORDER BY "+row+"),'')"
        pairs.append(sql_literal(RENAMES.get(table,table))+",(SELECT jsonb_build_object('count',count(*),'sha256',"+sql_digest(content)+') FROM payse.'+table+' t)')
    events="COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY user_id,event_id) FROM payse.demo_event_receipts t),'[]'::jsonb)" if legacy else "'[]'::jsonb"
    return """SELECT jsonb_build_object(
      'database',jsonb_build_object('name',current_database(),'oid',(SELECT oid FROM pg_database WHERE datname=current_database()),'systemIdentifier',(SELECT system_identifier::text FROM pg_control_system())),
      'columns',(SELECT jsonb_object_agg(table_name,cols) FROM (SELECT table_name,jsonb_agg(column_name ORDER BY ordinal_position) cols FROM information_schema.columns WHERE table_schema='payse' GROUP BY table_name) x),
      'catalog',(SELECT jsonb_agg(jsonb_build_object('name',c.relname,'kind',c.relkind,'rls',c.relrowsecurity,'forced',c.relforcerowsecurity,'owner',c.relowner,'acl',c.relacl) ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='payse'),
      'constraints',(SELECT jsonb_agg(jsonb_build_object('id',oid,'definition',pg_get_constraintdef(oid)) ORDER BY oid) FROM pg_constraint WHERE connamespace='payse'::regnamespace),
      'functions',(SELECT jsonb_agg(jsonb_build_object('name',p.proname,'body',p.prosrc,'definition',pg_get_functiondef(p.oid)) ORDER BY p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='payse'),
      'policies',(SELECT jsonb_agg(to_jsonb(p) ORDER BY tablename,policyname) FROM pg_policies p WHERE schemaname='payse'),
      'events',"""+events+",'data',jsonb_build_object("+','.join(pairs)+'))'


def validate(snapshot, legacy):
    """2026-10-23: Validate historical v2 guards; later salary-format migration is separate.

    2026-10-29: Validate against the reviewed historical column set, not new-install DDL.
    """
    require(snapshot['columns']==table_contract(LEGACY if legacy else FROZEN_COMMON),'Unexpected schema; separate review required')
    expected_sql=(HERE.parent/'tests/legacy/002_storage_guards.sql' if legacy else FROZEN_GUARDS).read_text(encoding='utf-8')
    known={name:body for name,body in re.findall(r'CREATE FUNCTION payse\.(\w+)\([^;]*?AS \$\$(.*?)\$\$;',expected_sql,re.S)}
    found={}
    for function in snapshot['functions'] or []:
        if function['name'] in known:
            require(function['name'] not in found,'Overloaded storage function requires review')
            require(function['body'].strip()==known[function['name']].strip(),'Storage function changed; separate review required')
            found[function['name']]=True
        elif re.search(r'\b(demo_users|synthetic_phone|user_settings|demo_event_receipts)\b',function['body']):
            raise MigrationError('Custom function references legacy storage')
    require(set(found)==set(known),'Storage guards missing')
    require(all(row['rls'] and row['forced'] for row in snapshot['catalog'] if row['kind']=='r' and row['name']!='institutions'),'Owner RLS missing')


def create_plan(psql,database,backup,timeout_seconds,lock_timeout_ms):
    """2026-10-23: Read and archive the exact legacy source; no source mutation occurs."""
    path=Path(backup)
    require(not path.exists() and not path.is_symlink(),'Archive must be a new regular file')
    raw=run_psql(psql,database,transaction_prefix(lock_timeout_ms,True)+snapshot_query(True)+';COMMIT;',timeout_seconds)
    state=json.loads(raw);validate(state,True)
    body=(json.dumps({'format':FORMAT,'sourceState':raw,'stateDigest':hashlib.sha256(raw.encode()).hexdigest()},ensure_ascii=False,indent=2)+'\n').encode()
    descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(descriptor,'wb') as stream:
        stream.write(body);stream.flush();os.fsync(stream.fileno())
    require(path.read_bytes()==body,'Archive verification failed')
    return hashlib.sha256(body).hexdigest()


def apply_plan(psql,database,backup,expected_sha256,timeout_seconds,lock_timeout_ms):
    """2026-10-23: Rename under frozen v2 guards, preserving salary facts for separate v3 review."""
    path=Path(backup)
    require(path.is_file() and not path.is_symlink(),'Archive must be a regular file')
    body=path.read_bytes()
    require(re.fullmatch('[0-9a-f]{64}',expected_sha256 or '') is not None and hashlib.sha256(body).hexdigest()==expected_sha256,'Archive hash mismatch')
    plan=json.loads(body)
    require(set(plan)=={'format','sourceState','stateDigest'} and plan['format']==FORMAT,'Unsupported archive')
    require(hashlib.sha256(plan['sourceState'].encode()).hexdigest()==plan['stateDigest'],'Source digest mismatch')
    state=json.loads(plan['sourceState']);validate(state,True)
    require(state['database']['name']==database,'Archive targets a different DB')
    guards=(FROZEN_GUARDS).read_text(encoding='utf-8')
    functions=re.findall(r'CREATE FUNCTION payse\.[\s\S]*?END \$\$;',guards)
    require(len(functions)==3,'Expected three storage guards')
    changes=['ALTER TABLE payse.demo_users RENAME TO users;',
             'ALTER TABLE payse.users RENAME COLUMN synthetic_phone TO phone;',
             'ALTER TABLE payse.user_settings RENAME TO user_attributes;',
             'DROP TABLE payse.demo_event_receipts RESTRICT;']
    # CREATE OR REPLACE preserves function identity, privileges and attached triggers.
    changes.extend(f.replace('CREATE FUNCTION','CREATE OR REPLACE FUNCTION',1) for f in functions)
    locks='LOCK TABLE '+','.join('payse.'+t for t in sorted(table_contract(LEGACY)))+' IN ACCESS EXCLUSIVE MODE;'
    sql=transaction_prefix(lock_timeout_ms)+locks+"\nDO $migration$ DECLARE original jsonb; result jsonb; BEGIN\n"
    sql+=snapshot_query(True)+' INTO original;\n'
    sql+='IF '+sql_digest('original::text')+'<>'+sql_literal(plan['stateDigest'])+" THEN RAISE EXCEPTION 'Reviewed source changed'; END IF;\n"
    sql+='\n'.join(changes)+'\n'+snapshot_query(False)+' INTO result;\n'
    sql+="IF original->'data' IS DISTINCT FROM result->'data' THEN RAISE EXCEPTION 'Retained rows changed'; END IF;\n"
    sql+="PERFORM payse.assert_user_storage(id) FROM payse.users; END $migration$;\nCOMMIT;SELECT 'APPLIED';"
    require(path.read_bytes()==body,'Archive changed before apply')
    result=run_psql(psql,database,sql,timeout_seconds)
    require(result=='APPLIED','Unexpected result; inspect DB before retrying')
    return result


def main():
    """2026-10-23: Require separate review hash before explicit application."""
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--plan',action='store_true');mode.add_argument('--apply',action='store_true')
    parser.add_argument('--database',required=True);parser.add_argument('--psql',required=True)
    parser.add_argument('--backup',type=Path,required=True)
    parser.add_argument('--timeout-seconds',type=int,required=True);parser.add_argument('--lock-timeout-ms',type=int,required=True)
    parser.add_argument('--expected-sha256')
    args=parser.parse_args()
    try:
        if args.plan:
            require(args.expected_sha256 is None,'Hash is accepted only for apply')
            result={'status':'PLANNED','sha256':create_plan(args.psql,args.database,args.backup,args.timeout_seconds,args.lock_timeout_ms)}
        else:
            result={'status':apply_plan(args.psql,args.database,args.backup,args.expected_sha256,args.timeout_seconds,args.lock_timeout_ms)}
        print(json.dumps(result));return 0
    except (ValueError,KeyError,TypeError,OSError):
        print(json.dumps({'status':'REJECTED','reason':'Schema/state/archive validation failed; no success reported'}));return 1


if __name__=='__main__':
    raise SystemExit(main())
