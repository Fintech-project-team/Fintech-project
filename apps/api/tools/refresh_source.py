"""2026-11-02: 검증된 합성 원천 갱신 SQL을 생성한다. DB에 접속하거나 현재 시각을 쓰지 않는다.

사용: 관리 CLI, test_fixtures, database/test_source_refresh. 준비 자료 adapter이며 API 의존이 아니다.
이전/신규 전체 원천과 현재 사용자 버전을 검토하고 psql로 실행한다. 기본 SQL은 ROLLBACK한다.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

API = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API / 'fixtures'))
sys.path.insert(0, str(API))
from fixtures.export_sql import financial_rows, literal
from fixtures.validate import instant, require, validate_snapshot

KEYS = {
    'source_contexts': ('user_id',),
    'financial_accounts': ('id',),
    'financial_cards': ('id',),
    'transaction_references': ('user_id', 'transaction_id'),
    'financial_transactions': ('id',),
    'card_statements': ('id',),
    'statement_items': ('id',),
    'transaction_relations': ('user_id', 'kind', 'from_id', 'to_id'),
}
PRESERVED = {
    'source_contexts': {'occurrence_links'},
    'financial_accounts': {'included', 'nickname'},
    'financial_transactions': {'payse_transaction_type'},
}


def source_rows(snapshot):
    """2026-11-02: 기존 적재 매핑의 원천 열만 선택하며 새 계좌/거래의 사용자 설정은 비운다."""
    unused_identity = dict.fromkeys(('name', 'phone', 'codeVerifier', 'createdAt'))
    tables = {table: [] for table in KEYS}
    for table, mapped in financial_rows(snapshot, unused_identity):
        if table not in tables:
            continue
        row = dict(mapped)
        if table == 'financial_accounts':
            row.update(included=False, nickname=None)
        if table == 'financial_transactions':
            row['payse_transaction_type'] = None
        tables[table].append(row)
    return tables


def prepare(before, after):
    """2026-11-02: 원천 계약·소유자·버전·시간·기존 식별자 보존을 검사하고 두 행 묶음을 반환한다."""
    validate_snapshot(before)
    validate_snapshot(after)
    for key in ('userId', 'schemaVersion', 'ruleVersion', 'currency'):
        require(before[key] == after[key], 'refresh cannot change owner or contract')
    require('accounts' in before and 'accounts' in after, 'complete source bundles required')
    require(before['sourceVersion'] != after['sourceVersion'], 'new sourceVersion required')
    require(instant(after['asOf']) >= instant(before['asOf']), 'source time cannot go backwards')
    require(before['institutions'] == after['institutions'], 'institution changes need separate review')
    for group in ('institutionLinks', 'obligations', 'reserves', 'allocations', 'settlements',
                  'recurringPlans', 'recurringPlanRevisions', 'recurringDecisions',
                  'occurrenceOverrides', 'occurrenceLinks'):
        require(before[group] == after[group], 'source refresh cannot edit user settings or links')
    for key in ('salaryDay', 'salaryAmountKRW', 'salaryAccountId'):
        require(before['settings']['salary'][key] == after['settings']['salary'][key],
                'source refresh cannot edit salary settings')
    require(before['settings']['cardPlans'] == after['settings']['cardPlans'],
            'source refresh cannot edit card plans')
    for groups, identity, fields in (
        (('accounts',), 'accountId', ('included', 'nickname')),
        (('transactions', 'relatedTransactions'), 'transactionId', ('payseTransactionType',)),
    ):
        existing = {row[identity]: row for group in groups for row in before[group]}
        for group in groups:
            for row in after[group]:
                old = existing.get(row[identity])
                if old is not None:
                    require(all(old[field] == row[field] for field in fields),
                            'source refresh cannot edit selection, nickname or classification')
    previous, updated = source_rows(before), source_rows(after)
    for table, keys in KEYS.items():
        old = {tuple(row[key] for key in keys): row for row in previous[table]}
        new = {tuple(row[key] for key in keys): row for row in updated[table]}
        require(len(old) == len(previous[table]) and len(new) == len(updated[table]),
                'duplicate source identity')
        require(old.keys() <= new.keys(), 'refresh cannot remove existing source identities')
        for identity, row in old.items():
            if 'source_ref' in row:
                require(row['source_ref'] == new[identity]['source_ref'],
                        'existing source identity cannot be reassigned')
    return previous, updated


def column_names(table, records):
    """2026-11-02: 기존 고정 mapper의 열에서 사용자 편집값과 연결 근거를 제외한다."""
    return [key for key in records[0] if key not in PRESERVED.get(table, set())]


def recordset(table, records):
    """2026-11-02: 고정 테이블 타입으로 JSON 값을 변환해 SQL 문자열/날짜/소수의 의미를 보존한다."""
    return f'jsonb_populate_recordset(NULL::payse.{table}, {literal(records)})'


def comparison(table, records, owner, columns):
    """2026-11-02: 현재 원천과 검토 묶음의 모든 행·열을 양방향으로 비교한다."""
    fields = ', '.join(columns)
    current = f'SELECT {fields}\n      FROM payse.{table}\n      WHERE user_id = {owner}'
    expected = f'SELECT {fields}\n      FROM {recordset(table, records)}'
    return f'''EXISTS (
    ({current}
      EXCEPT
      {expected})
    UNION ALL
    ({expected}
      EXCEPT
      {current})
  )'''


def render(before, after, expected_version, database, *, apply=False):
    """2026-11-02: 재시도·낙관적 버전·사용자 잠금·설정 보존을 갖춘 단일 갱신 SQL을 만든다.

    실제 DB 이름과 현재 dataVersion은 운영자가 제공한다. 입력의 fixture 초기 버전을 재사용하지 않는다.
    """
    require(type(expected_version) is int and 1 <= expected_version < 9223372036854775807,
            'current expected dataVersion must leave room for one increment')
    require(isinstance(database, str) and bool(database.strip()) and '\x00' not in database,
            'target database name required')
    previous, updated = prepare(before, after)
    owner = literal(before['userId']) + '::uuid'
    checks = {}
    for table in KEYS:
        records = updated[table] or previous[table]
        if records:
            columns = column_names(table, records)
        else:
            # 두 묶음 모두 비어도 DB에 숨은 기존 행이 있으면 교체하지 않는다.
            columns = list(dict.fromkeys(('user_id',) + KEYS[table]))
        checks[table] = columns
    replay_checks = '\n    OR '.join(
        comparison(table, updated[table], owner, columns)
        for table, columns in checks.items()
    )
    preflight = '\n    OR '.join(
        comparison(table, previous[table], owner, columns)
        for table, columns in checks.items()
    )
    statements = []
    for table, records in updated.items():
        if not records:
            continue
        fields = list(records[0])
        changed = [key for key in checks[table] if key not in KEYS[table] and key != 'user_id']
        assignments = ',\n      '.join(f'{key} = EXCLUDED.{key}' for key in changed)
        conflict = (f'DO UPDATE SET\n      {assignments}\n'
                    f'    WHERE stored.user_id = {owner}') if changed else 'DO NOTHING'
        field_lines = ',\n    '.join(fields)
        statements.append(f'''  INSERT INTO payse.{table} AS stored (
    {field_lines}
  )
    SELECT
      {', '.join(fields)}
    FROM {recordset(table, records)}
    ON CONFLICT ({', '.join(KEYS[table])}) {conflict};''')
    # sourceVersion을 재사용한 다른 내용이나 외부 사용자 ID 충돌도 최종 대조에서 롤백한다.
    body = f'''DECLARE
  current_version bigint;
  current_source text;
BEGIN
  IF current_database() <> {literal(database)} THEN
    RAISE EXCEPTION 'Source refresh target database mismatch';
  END IF;

  SELECT data_version
  INTO STRICT current_version
  FROM payse.users
  WHERE id = {owner}
  FOR UPDATE;

  IF EXISTS (
    SELECT 1
    FROM payse.users
    WHERE id = {owner}
      AND deactivated_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Inactive source owner';
  END IF;

  PERFORM set_config('payse.user_id', {literal(before['userId'])}, true);
  SELECT source_version
  INTO STRICT current_source
  FROM payse.source_contexts
  WHERE user_id = {owner};

  IF current_source = {literal(after['sourceVersion'])} THEN
    IF current_version <= {expected_version} THEN
      RAISE EXCEPTION 'Source refresh version increment is missing';
    END IF;
    IF {replay_checks} THEN
      RAISE EXCEPTION 'Source version already exists with different facts';
    END IF;
    RAISE NOTICE 'Source refresh already applied; dataVersion unchanged';
    RETURN;
  END IF;
  IF current_version <> {expected_version} THEN
    RAISE EXCEPTION 'Source refresh dataVersion changed';
  END IF;
  IF {preflight} THEN
    RAISE EXCEPTION 'Source refresh baseline changed';
  END IF;

{chr(10).join(statements)}

  IF {replay_checks} THEN
    RAISE EXCEPTION 'Source refresh did not preserve the complete owner bundle';
  END IF;
  UPDATE payse.users
  SET data_version = data_version + 1
  WHERE id = {owner};

  SET CONSTRAINTS ALL IMMEDIATE;
  RAISE NOTICE 'Source refresh validated; dataVersion incremented once';
END'''
    # 자료 속 임의 $tag$나 역슬래시도 코드 경계를 바꾸지 못한다.
    tag = '$payse_source_refresh$'
    while tag in body:
        tag = tag[:-1] + '_$'
    return f'''-- PAYSE source refresh. Private generated data; do not commit this file.
-- Mode: {'APPLY' if apply else 'CHECK ONLY (ROLLBACK)'}.
BEGIN;
SET LOCAL standard_conforming_strings = on;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
SET CONSTRAINTS ALL DEFERRED;
DO {tag}
{body}
{tag};
{'COMMIT' if apply else 'ROLLBACK'};
'''


def main():
    """2026-11-02: 검토 가능한 비공개 SQL을 새 파일로만 쓰고 내용 대신 해시·실행 모드를 알린다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--expected-data-version', type=int, required=True)
    parser.add_argument('--database', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--apply', action='store_true', help='COMMIT SQL 생성; 자동 DB 실행 없음')
    args = parser.parse_args()
    try:
        destination = args.out.resolve()
        require(not destination.is_relative_to(API.parents[1]),
                'generated financial SQL must be outside the repository')
        before = json.loads(args.before.read_text(encoding='utf-8'))
        after = json.loads(args.after.read_text(encoding='utf-8'))
        sql = render(before, after, args.expected_data_version, args.database, apply=args.apply)
        with destination.open('x', encoding='utf-8', newline='\n') as output:
            output.write(sql)
        print(json.dumps({'mode': 'apply' if args.apply else 'check-only',
                          'sha256': hashlib.sha256(sql.encode('utf-8')).hexdigest(),
                          'executed': False}))
    except (ValueError, KeyError, TypeError, OSError):
        parser.exit(1, 'Source refresh preparation failed; verify the input contract and private output path.\n')


if __name__ == '__main__':
    main()
