"""Seed common institutions independently; never create users or link accounts."""
import argparse
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from reference_data.institutions import institution_rows

def export(synchronize_reviewed=False):
    """2026-10-23: Insert references or explicitly synchronize reviewed aliases under one table lock."""
    statements=['BEGIN;']
    if synchronize_reviewed:
        statements.append('LOCK TABLE payse.institutions IN SHARE ROW EXCLUSIVE MODE;')
    reviewed_aliases={'bank.kb':'국민','bank.shinhan':'신한','bank.hana':'하나','bank.ibk':'기업'}
    for row in institution_rows():
        values=','.join("'"+value.replace("'","''")+"'" for value in row.values())
        suffix=''
        if synchronize_reviewed:
            def quote(value):
                return "'"+value.replace("'","''")+"'"
            names=','.join(quote(value) for value in dict.fromkeys([row['name'],reviewed_aliases.get(row['code'],row['name'])]))
            statements.append("DO $$ BEGIN IF EXISTS(SELECT 1 FROM payse.institutions WHERE code="+quote(row['code'])+" AND (kind<>"+quote(row['kind'])+" OR name NOT IN ("+names+"))) THEN RAISE EXCEPTION 'Unreviewed institution identity; manual review required'; END IF; END $$;")
            suffix=' ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name'
        statements.append('INSERT INTO payse.institutions(code,kind,name) VALUES('+values+')'+suffix+';')
    return '\n'.join(statements+['COMMIT;'])+'\n'

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--synchronize-reviewed',action='store_true')
    args=parser.parse_args()
    with args.out.open('x',encoding='utf-8',newline='\n') as stream:
        stream.write(export(args.synchronize_reviewed))
