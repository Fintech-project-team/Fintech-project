"""2026-10-19: Optional native multi-connection verification on an empty localhost test DB.

Requires psql, PGHOST=127.0.0.1/localhost, PGUSER/PGPORT as needed, and an existing
EMPTY database named payse_fixture_*. Never uses or edits an application DB.
Not executed by the PGlite single-connection test. Credentials stay in PG env vars.
"""
import argparse
import os
import subprocess
import time
from pathlib import Path

from run_sql_tests import DEFAULT_FIXTURES, require_disposable_database, run_sql, run_suites
from test_context import build_context


def run(psql, database, text):
    """2026-10-19: Run fixed test SQL using environment credentials; return checked stdout."""
    return run_sql(psql, database, text)


def race(psql,database,first,second,expected_error=None,expected_output=None):
    """2026-10-19: Hold a real connection lock, then submit a competing write on a second connection."""
    command=[psql,'-X','--no-password','-A','-t','-v','ON_ERROR_STOP=1','-d',database]
    proc=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8')
    try:
        proc.stdin.write('BEGIN;\n'+first+'\n\\echo OWNER_LOCKED\nSELECT pg_sleep(2);\nCOMMIT;\n')
        proc.stdin.close()
        while True:
            line=proc.stdout.readline()
            if line.strip()=='OWNER_LOCKED':
                break
            if not line:
                raise RuntimeError('First writer failed: '+proc.stderr.read())
        started=time.monotonic()
        other=subprocess.run(command,input='\\set VERBOSITY verbose\n'+second,text=True,encoding='utf-8',capture_output=True,timeout=20)
        waited=time.monotonic()-started
        code=proc.wait(timeout=20)
        if code:
            raise RuntimeError('First writer commit failed: '+proc.stderr.read())
        if expected_error:
            if other.returncode==0 or expected_error not in other.stderr:
                raise AssertionError('Expected competing write rejection: '+other.stderr)
        elif other.returncode or expected_output not in other.stdout:
            raise AssertionError('Wrong competing write result: '+other.stdout+other.stderr)
        if waited<1:
            raise AssertionError('Second connection did not encounter the held lock')
    finally:
        if proc.poll() is None:
            proc.terminate();proc.wait(timeout=10)


def main():
    """2026-10-19: Load new DDL/fixtures, execute SQL tests, then four real concurrent write cases.

    2026-10-22: Resolve target roles from validated fixtures; share SQL preparation.
    """
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database',required=True);parser.add_argument('--psql',default='psql');parser.add_argument('--seed',type=Path,required=True)
    parser.add_argument('--fixtures', type=Path, default=DEFAULT_FIXTURES)
    args=parser.parse_args()
    require_disposable_database(args.database)
    context = build_context(args.fixtures)
    os.environ['PGCLIENTENCODING']='UTF8';os.environ['PGCONNECT_TIMEOUT']='5'
    count=run(args.psql,args.database,"SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname<>'information_schema' AND c.relkind IN ('r','v','m','p');")
    if count!='0':
        raise ValueError('Database must be empty')
    folder=Path(__file__).resolve().parent
    for filename in ('001_initial.sql','002_storage_guards.sql'):
        run(args.psql,args.database,(folder/filename).read_text(encoding='utf-8'))
    run(args.psql,args.database,args.seed.read_text(encoding='utf-8'))
    run_suites(args.psql, args.database, context)
    # UUID roles were type-checked by preparation and matched to actual DB rows.
    owner = context['owner_id']
    receipt = context['write_receipt_id']
    session=f"INSERT INTO payse.demo_sessions (id,user_id,token_digest,issued_at,ended_at) VALUES (gen_random_uuid(),'{owner}','race-{{}}',now(),NULL);"
    race(args.psql,args.database,session.format('a'),session.format('b'),expected_error='23505')
    version=run(args.psql,args.database,f"SELECT data_version FROM payse.demo_users WHERE id='{owner}';")
    if not version.isascii() or not version.isdecimal():
        raise AssertionError('One existing owner with a nonnegative version is required')
    update=f"UPDATE payse.demo_users SET data_version=data_version+1 WHERE id='{owner}' AND data_version={version} RETURNING id"
    race(args.psql,args.database,update+';',f"WITH changed AS ({update}) SELECT 'changed='||count(*) FROM changed;",expected_output='changed=0')
    write=f"INSERT INTO payse.write_receipts SELECT gen_random_uuid(),user_id,'race-operation',request_digest,action,changed_refs,before_after,result_version,created_at FROM payse.write_receipts WHERE id='{receipt}';"
    race(args.psql,args.database,write,write,expected_error='23505')
    event=f"INSERT INTO payse.demo_event_receipts VALUES ('{owner}','race-event','before','after','{receipt}');"
    race(args.psql,args.database,event,event,expected_error='23505')
    print('PASS: native SQL suites and 4 two-connection races; disposable database retained for inspection')


if __name__=='__main__':
    main()
