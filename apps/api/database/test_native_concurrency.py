"""2026-10-19: Optional native multi-connection verification on an empty localhost test DB.

Requires psql, PGHOST=127.0.0.1/localhost, PGUSER/PGPORT as needed, and an existing
EMPTY database named payse_fixture_*. Never uses or edits an application DB.
Not executed by the PGlite single-connection test. Credentials stay in PG env vars.
"""
import argparse
import os
import re
import subprocess
import time
from pathlib import Path


def run(psql, database, text):
    """2026-10-19: Run fixed test SQL using environment credentials; return checked stdout."""
    result=subprocess.run([psql,'-X','-A','-t','-v','ON_ERROR_STOP=1','-d',database],input=text,text=True,encoding='utf-8',capture_output=True,timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def race(psql,database,first,second,expected_error=None,expected_output=None):
    """2026-10-19: Hold a real connection lock, then submit a competing write on a second connection."""
    command=[psql,'-X','-A','-t','-v','ON_ERROR_STOP=1','-d',database]
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
    """2026-10-19: Load new DDL/fixtures, execute SQL tests, then four real concurrent write cases."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database',required=True);parser.add_argument('--psql',default='psql');parser.add_argument('--seed',type=Path,required=True)
    args=parser.parse_args()
    if not re.fullmatch(r'payse_fixture_[a-z0-9_]+',args.database) or os.environ.get('PGHOST') not in ('127.0.0.1','localhost'):
        raise ValueError('Explicit localhost and disposable database name required')
    os.environ['PGCLIENTENCODING']='UTF8';os.environ['PGCONNECT_TIMEOUT']='5'
    count=run(args.psql,args.database,"SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname<>'information_schema' AND c.relkind IN ('r','v','m','p');")
    if count!='0':
        raise ValueError('Database must be empty')
    folder=Path(__file__).resolve().parent
    for filename in ('001_initial.sql','002_storage_guards.sql'):
        run(args.psql,args.database,(folder/filename).read_text(encoding='utf-8'))
    run(args.psql,args.database,args.seed.read_text(encoding='utf-8'))
    for filename in ('test_constraints.sql','test_extremes.sql'):
        run(args.psql,args.database,(folder/filename).read_text(encoding='utf-8'))
    owner=run(args.psql,args.database,"SELECT id FROM payse.demo_users WHERE synthetic_name='PAYSE 합성 alpha';")
    receipt=run(args.psql,args.database,f"SELECT id FROM payse.write_receipts WHERE user_id='{owner}' LIMIT 1;")
    session=f"INSERT INTO payse.demo_sessions VALUES (gen_random_uuid(),'{owner}','race-{{}}',gen_random_uuid(),now(),NULL);"
    race(args.psql,args.database,session.format('a'),session.format('b'),expected_error='23505')
    version=run(args.psql,args.database,f"SELECT data_version FROM payse.demo_users WHERE id='{owner}';")
    update=f"UPDATE payse.demo_users SET data_version=data_version+1 WHERE id='{owner}' AND data_version={version} RETURNING id"
    race(args.psql,args.database,update+';',f"WITH changed AS ({update}) SELECT 'changed='||count(*) FROM changed;",expected_output='changed=0')
    write=f"INSERT INTO payse.write_receipts SELECT gen_random_uuid(),user_id,'race-operation',request_digest,action,changed_refs,before_after,result_version,created_at FROM payse.write_receipts WHERE id='{receipt}';"
    race(args.psql,args.database,write,write,expected_error='23505')
    event=f"INSERT INTO payse.demo_event_receipts VALUES ('{owner}','race-event','before','after','{receipt}');"
    race(args.psql,args.database,event,event,expected_error='23505')
    print('PASS: native SQL suites and 4 two-connection races; disposable database retained for inspection')


if __name__=='__main__':
    main()
