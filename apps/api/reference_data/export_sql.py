"""Seed common institutions independently; never create users or link accounts."""
import argparse
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from reference_data.institutions import institution_rows

def export(synchronize_reviewed=False):
    """2026-10-23: 기관 기준을 적재하거나 명시된 검토 별칭만 테이블 잠금 아래 동기화한다.

    2026-10-26: 생성 SQL의 열·값·조건·충돌 처리를 줄별로 구분한다.
    사용: 파일 CLI, 공통 저장 이행 및 기관 기준 검사.
    """
    statements=['BEGIN;']
    if synchronize_reviewed:
        statements.append('LOCK TABLE payse.institutions IN SHARE ROW EXCLUSIVE MODE;')
    reviewed_aliases={'bank.kb':'국민','bank.shinhan':'신한','bank.hana':'하나','bank.ibk':'기업'}
    for row in institution_rows():
        values=',\n'.join("  '"+value.replace("'","''")+"'" for value in row.values())
        suffix=''
        if synchronize_reviewed:
            def quote(value):
                """2026-10-26: 검토된 기관 문자열을 SQL 리터럴로 이스케이프한다. 사용: export."""
                return "'"+value.replace("'","''")+"'"
            names=','.join(quote(value) for value in dict.fromkeys([row['name'],reviewed_aliases.get(row['code'],row['name'])]))
            statements.append(
                "DO $$\nBEGIN\n  IF EXISTS (\n    SELECT 1\n"
                "    FROM payse.institutions\n    WHERE code = "+quote(row['code'])+"\n"
                "      AND (\n        kind <> "+quote(row['kind'])+"\n"
                "        OR name NOT IN ("+names+")\n      )\n  ) THEN\n"
                "    RAISE EXCEPTION 'Unreviewed institution identity; manual review required';\n"
                "  END IF;\nEND $$;"
            )
            suffix='\nON CONFLICT (code) DO UPDATE\nSET name = EXCLUDED.name'
        statements.append('INSERT INTO payse.institutions (\n  code,\n  kind,\n  name\n) VALUES (\n'+values+'\n)'+suffix+';')
    return '\n\n'.join(statements+['COMMIT;'])+'\n'

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--synchronize-reviewed',action='store_true')
    args=parser.parse_args()
    with args.out.open('x',encoding='utf-8',newline='\n') as stream:
        stream.write(export(args.synchronize_reviewed))
