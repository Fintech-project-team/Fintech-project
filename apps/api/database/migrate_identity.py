"""Plan and explicitly apply the synthetic identity migration; never initialize a DB.

Plans preserve removed source values outside PostgreSQL. No credentials or row values
are printed. Use a migration role, not the application's runtime role.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fixtures'))
from identity_contract import IDENTITY_USERS, validate_stored_identity

FORMAT = 'PAYSE-IDENTITY-PLAN-1'
TABLES = (
    'card_statements', 'demo_event_receipts', 'demo_sessions', 'demo_users',
    'financial_accounts', 'financial_cards', 'financial_transactions',
    'institution_links', 'institutions', 'obligations', 'occurrence_overrides',
    'recurring_decisions', 'recurring_plan_revisions', 'recurring_plans',
    'reserve_allocations', 'reserves', 'settlement_links', 'source_contexts',
    'statement_items', 'transaction_references', 'transaction_relations',
    'user_settings', 'write_receipts',
)


class MigrationError(ValueError):
    """A fail-closed tool error with a value-free public message."""


def require(condition, message):
    """Reject an unexpected contract without disclosing source values."""
    if not condition:
        raise MigrationError(message)


def sql_literal(value):
    """Quote fixed contract constants; no caller-supplied SQL is accepted."""
    return "'" + str(value).replace("'", "''") + "'"


def sql_digest(expression):
    """Use PostgreSQL's built-in SHA-256; no extension installation is needed."""
    return "encode(sha256(convert_to(" + expression + ", 'UTF8')), 'hex')"


def snapshot_query():
    """Build one catalog/data snapshot over the fixed PAYSE table inventory."""
    pairs = []
    for table in TABLES:
        omitted = ['name', 'synthetic_name', 'display_name'] if table == 'demo_users' else ['installation_id'] if table == 'demo_sessions' else []
        expression = 'to_jsonb(t)'
        for column in omitted:
            expression += ' - ' + sql_literal(column)
        row = '(' + expression + ')::text'
        content = "COALESCE(string_agg(" + row + ", E'\\n' ORDER BY " + row + "), '')"
        pairs.append(sql_literal(table) + ", (SELECT jsonb_build_object('count', count(*), 'digest', " + sql_digest(content) + ') FROM payse.' + table + ' t)')
    return """SELECT jsonb_build_object(
      'database', jsonb_build_object('name',current_database(),
        'oid',(SELECT oid::text FROM pg_database WHERE datname=current_database()),
        'systemIdentifier',(SELECT system_identifier::text FROM pg_control_system()),
        'serverAddress',inet_server_addr()::text,'serverPort',inet_server_port(),
        'serverVersion',current_setting('server_version_num')),
      'tables',(SELECT jsonb_agg(c.relname ORDER BY c.relname) FROM pg_class c
        JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='payse' AND c.relkind IN ('r','p')),
      'columns',(SELECT jsonb_agg(jsonb_build_object('table',c.relname,'name',a.attname,
        'type',format_type(a.atttypid,a.atttypmod),'notNull',a.attnotnull,
        'default',pg_get_expr(d.adbin,d.adrelid),'collation',co.collname) ORDER BY c.relname,a.attnum)
        FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
        LEFT JOIN pg_attrdef d ON (d.adrelid,d.adnum)=(a.attrelid,a.attnum)
        LEFT JOIN pg_collation co ON co.oid=a.attcollation
        WHERE n.nspname='payse' AND c.relkind IN ('r','p') AND a.attnum>0 AND NOT a.attisdropped),
      'constraints',(SELECT jsonb_agg(jsonb_build_object('table',c.relname,'name',k.conname,
        'type',k.contype,'valid',k.convalidated,'definition',pg_get_constraintdef(k.oid),
        'columns',ARRAY(SELECT a.attname FROM unnest(k.conkey) WITH ORDINALITY x(num,ord)
          JOIN pg_attribute a ON a.attrelid=k.conrelid AND a.attnum=x.num ORDER BY x.ord)) ORDER BY c.relname,k.conname)
        FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='payse'),
      'indexes',(SELECT jsonb_agg(indexdef ORDER BY tablename,indexname) FROM pg_indexes WHERE schemaname='payse'),
      'indexContracts',(SELECT jsonb_agg(jsonb_build_object('table',c.relname,'name',ic.relname,
        'unique',i.indisunique,'valid',i.indisvalid,'ready',i.indisready,'live',i.indislive,
        'immediate',i.indimmediate,'keyCount',i.indnkeyatts,'attributeCount',i.indnatts,
        'keys',ARRAY(SELECT a.attname FROM unnest(i.indkey) WITH ORDINALITY x(num,ord)
          LEFT JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=x.num ORDER BY x.ord),
        'predicate',pg_get_expr(i.indpred,i.indrelid),'expressions',pg_get_expr(i.indexprs,i.indrelid),
        'constraintName',(SELECT k.conname FROM pg_constraint k WHERE k.conindid=i.indexrelid AND k.contype IN ('p','u')),
        'method',am.amname) ORDER BY c.relname,ic.relname)
        FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_class ic ON ic.oid=i.indexrelid
        JOIN pg_am am ON am.oid=ic.relam JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='payse'),
      'tableSecurity',(SELECT jsonb_agg(jsonb_build_object('table',c.relname,'rls',c.relrowsecurity,
        'forced',c.relforcerowsecurity,'owner',c.relowner::text,'acl',c.relacl) ORDER BY c.relname)
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='payse' AND c.relkind IN ('r','p')),
      'policies',(SELECT jsonb_agg(to_jsonb(p) ORDER BY tablename,policyname) FROM pg_policies p WHERE schemaname='payse'),
      'triggers',(SELECT jsonb_agg(jsonb_build_object('table',c.relname,'name',t.tgname,
        'definitionHash',encode(sha256(convert_to(pg_get_triggerdef(t.oid),'UTF8')),'hex')) ORDER BY c.relname,t.tgname)
        FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='payse' AND NOT t.tgisinternal),
      'functions',(SELECT jsonb_agg(jsonb_build_object('id',p.oid::regprocedure::text,
        'bodyHash',encode(sha256(convert_to(p.prosrc,'UTF8')),'hex'),'config',p.proconfig,'definer',p.prosecdef) ORDER BY p.oid)
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='payse'),
      'dependentViews',COALESCE((SELECT jsonb_agg(DISTINCT v.oid::regclass::text)
        FROM pg_depend d JOIN pg_rewrite r ON d.objid=r.oid AND d.classid='pg_rewrite'::regclass
        JOIN pg_class v ON v.oid=r.ev_class JOIN pg_attribute a ON (a.attrelid,a.attnum)=(d.refobjid,d.refobjsubid)
        WHERE (a.attrelid='payse.demo_users'::regclass AND a.attname IN ('synthetic_name','display_name'))
          OR (a.attrelid='payse.demo_sessions'::regclass AND a.attname='installation_id')), '[]'::jsonb),
      'legacyFunctions',COALESCE((SELECT jsonb_agg(p.oid::regprocedure::text)
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='payse' AND p.prosrc ~ '\\m(synthetic_name|display_name|installation_id)\\M'), '[]'::jsonb),
      'legacyTriggers',COALESCE((SELECT jsonb_agg(t.tgname) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='payse' AND NOT t.tgisinternal
        AND pg_get_triggerdef(t.oid) ~ '\\m(synthetic_name|display_name|installation_id)\\M'), '[]'::jsonb),
      'users',(SELECT jsonb_agg(jsonb_build_object('id',id::text,'phone',synthetic_phone,
        'names',to_jsonb(t) - ARRAY['id','synthetic_phone','code_verifier','data_version','created_at']) ORDER BY id) FROM payse.demo_users t),
      'legacyInstallations',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id::text,
        'installation_id',to_jsonb(t)->'installation_id') ORDER BY id) FILTER (WHERE to_jsonb(t) ? 'installation_id'),'[]'::jsonb) FROM payse.demo_sessions t),
      'data',jsonb_build_object(""" + ','.join(pairs) + '))'


def columns_for(snapshot, table):
    """Return the exact visible physical columns for one fixed table."""
    return {row['name']: row for row in snapshot['columns'] if row['table'] == table}


def normalized_expression(expression):
    """Compare only known catalog expressions, not caller-supplied SQL."""
    return re.sub(r'\s+|[()]|::text', '', expression or '')


def valid_unique_index(index, keys, predicate=None):
    """Require physical uniqueness with exact keys/predicate and no hidden columns."""
    return (all(index[key] for key in ('unique','valid','ready','live','immediate'))
            and index['keys'] == keys and index['keyCount'] == len(keys)
            and index['attributeCount'] == len(keys) and index['expressions'] is None
            and index['method'] == 'btree'
            and normalized_expression(index['predicate']) == normalized_expression(predicate))


def validate_removed_dependencies(snapshot, removed):
    """Do not silently discard custom same-table constraints or indexes on old columns."""
    for table, fields in removed.items():
        columns = columns_for(snapshot, table)
        require(all(columns[field]['default'] is None for field in fields), 'Legacy column default requires separate review')
        permitted_unique_names = set()
        for constraint in snapshot['constraints']:
            if constraint['table'] != table or not set(constraint['columns'] or []) & fields:
                continue
            keys = constraint['columns']
            allowed = False
            if table == 'demo_users' and constraint['type'] == 'u' and keys == ['synthetic_name','synthetic_phone']:
                allowed = constraint['valid']
                permitted_unique_names.add(constraint['name'])
            elif constraint['type'] == 'c' and len(keys) == 1 and keys[0] in fields:
                key = keys[0]
                expected = 'CHECK' + key + 'ISNULLORlengthbtrim' + key + '>0'
                allowed = constraint['valid'] and normalized_expression(constraint['definition']) == expected
            require(allowed, 'Custom legacy constraint requires separate review')
        for index in snapshot['indexContracts']:
            if index['table'] != table:
                continue
            expressions = (index['expressions'] or '') + ' ' + (index['predicate'] or '')
            mentions = bool(set(index['keys']) & fields) or any(re.search(r'\b' + re.escape(field) + r'\b', expressions) for field in fields)
            if mentions:
                require(table == 'demo_users' and index['constraintName'] in permitted_unique_names
                        and valid_unique_index(index, ['synthetic_name','synthetic_phone']), 'Custom legacy index requires separate review')


def validate_snapshot(snapshot):
    """Require the reviewed legacy or target contract, including true NOOP validity."""
    require(snapshot['tables'] == sorted(TABLES), 'Unexpected PAYSE table inventory')
    require(not snapshot['dependentViews'] and not snapshot['legacyFunctions'] and not snapshot['legacyTriggers'], 'Legacy dependency requires separate review')
    user_columns = columns_for(snapshot, 'demo_users')
    fixed = {'id', 'synthetic_phone', 'code_verifier', 'data_version', 'created_at'}
    legacy = set(user_columns) == fixed | {'synthetic_name', 'display_name'}
    target = set(user_columns) == fixed | {'name'}
    require(legacy or target, 'Unsupported or partial identity schema')
    expected_types = {'id': 'uuid', 'synthetic_phone': 'text', 'code_verifier': 'text', 'data_version': 'bigint', 'created_at': 'timestamp with time zone'}
    expected_types.update({key: 'text' for key in ('synthetic_name', 'display_name') if legacy} if legacy else {'name': 'text'})
    require(all(user_columns[key]['type'] == kind and user_columns[key]['notNull'] for key, kind in expected_types.items()), 'Unexpected identity column type or nullability')
    sessions = columns_for(snapshot, 'demo_sessions')
    required = {'id', 'user_id', 'token_digest', 'issued_at', 'ended_at'}
    require(set(sessions) in (required, required | {'installation_id'}), 'Unexpected session columns')
    if 'installation_id' in sessions:
        require(sessions['installation_id']['type'] == 'text', 'Unexpected legacy installation type')
    session_types = {'id':'uuid','user_id':'uuid','token_digest':'text','issued_at':'timestamp with time zone','ended_at':'timestamp with time zone'}
    require(all(sessions[key]['type'] == kind and sessions[key]['notNull'] == (key != 'ended_at') for key, kind in session_types.items()), 'Unexpected session column contract')
    require(all(any(row['table'] == table and row['rls'] and row['forced'] for row in snapshot['tableSecurity']) for table in ('demo_users','demo_sessions')), 'Identity RLS contract is missing')
    for table, owner_key in [('demo_users', 'id'), ('demo_sessions', 'user_id')]:
        policies = [row for row in (snapshot['policies'] or []) if row['tablename'] == table]
        require(len(policies) == 1, 'Identity row policy count differs from contract')
        policy = policies[0]
        expression = normalized_expression(owner_key + " = NULLIF(current_setting('payse.user_id', true), '')::uuid")
        require(policy['policyname'] == 'own_rows' and policy['permissive'] == 'PERMISSIVE'
                and policy['roles'] == ['public'] and policy['cmd'] == 'ALL'
                and normalized_expression(policy['qual']) == expression
                and normalized_expression(policy['with_check']) == expression, 'Identity row policy differs from contract')
    for table, kind, keys in [('demo_users','p',['id']),('demo_sessions','p',['id']),('demo_sessions','u',['user_id','id']),('demo_sessions','u',['token_digest'])]:
        require(any(row['table'] == table and row['type'] == kind and row['valid'] and row['columns'] == keys for row in snapshot['constraints']), 'Identity key constraint is missing')
    mapping = {row['user_id']: row for row in IDENTITY_USERS}
    rows = snapshot['users'] or []
    require(len(rows) == len(mapping) and {row['id'] for row in rows} == set(mapping), 'Unknown, missing or duplicate demo identity')
    for row in rows:
        known = mapping[row['id']]
        require(row['phone'] == known['phone'], 'Stored identity does not match reviewed mapping')
        wanted = {'synthetic_name': known['legacy_synthetic_name'], 'display_name': known['legacy_display_name']} if legacy else {'name': known['name']}
        require(row['names'] == wanted, 'Stored identity does not match reviewed mapping')
        validate_stored_identity(known['name'], row['phone'])
    if target:
        checks = {row['name']: row for row in snapshot['constraints'] if row['table'] == 'demo_users'}
        for name, expression in [('identity_name_format', 'nameCOLLATE"C"~\'^[가-힣A-Za-z]{2,20}$\''), ('identity_phone_format', 'synthetic_phoneCOLLATE"C"~\'^010[0-9]{8}$\'')]:
            check = checks.get(name)
            require(check is not None and check['type'] == 'c' and check['valid'], 'Target identity constraint is missing or unvalidated')
            definition = normalized_expression(check['definition']).removeprefix('CHECK')
            require(definition == expression, 'Target identity constraint differs from contract')
        require(any(row['type'] == 'u' and row['valid'] and row['columns'] == ['name', 'synthetic_phone'] for row in checks.values()), 'Target identity uniqueness is missing')
    require(any(row['table'] == 'demo_sessions' and row['name'] == 'active_session_per_user'
                and valid_unique_index(row, ['user_id'], 'ended_at IS NULL')
                for row in snapshot['indexContracts']), 'Active session invariant is missing')
    removed = {'demo_users': {'synthetic_name','display_name'} if legacy else set(),
               'demo_sessions': {'installation_id'} if 'installation_id' in sessions else set()}
    validate_removed_dependencies(snapshot, removed)
    return {'rename': legacy, 'dropInstallation': 'installation_id' in sessions}


def run_psql(psql, database, sql, timeout_seconds):
    """Run a bounded, noninteractive connection without echoing SQL or server errors."""
    require(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,62}', database) is not None, 'Database must be an explicit simple name')
    require(timeout_seconds > 0, 'A positive tool timeout is required')
    try:
        result = subprocess.run([str(psql), '-X', '--no-password', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database], input=sql, text=True, encoding='utf-8', capture_output=True, timeout=timeout_seconds)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise MigrationError('PostgreSQL tool could not complete; no success reported') from error
    require(result.returncode == 0, 'PostgreSQL rejected the operation; no success reported')
    return result.stdout.strip()


def transaction_prefix(lock_timeout_ms, read_only=False):
    """Set per-tool limits and fail rather than silently applying RLS filtering."""
    require(type(lock_timeout_ms) is int and lock_timeout_ms > 0, 'A positive lock timeout is required')
    return 'BEGIN' + (' ISOLATION LEVEL REPEATABLE READ READ ONLY' if read_only else '') + ';\nSET LOCAL row_security=off;\nSET LOCAL client_min_messages=error;\nSET LOCAL lock_timeout=' + sql_literal(str(lock_timeout_ms) + 'ms') + ';\n'


def read_state(psql, database, timeout_seconds, lock_timeout_ms):
    """Read a single consistent state; no migration or source-data writes occur."""
    sql = transaction_prefix(lock_timeout_ms, True) + snapshot_query() + ';\nCOMMIT;'
    raw = run_psql(psql, database, sql, timeout_seconds)
    try:
        snapshot = json.loads(raw)
    except (ValueError, TypeError) as error:
        raise MigrationError('Invalid PostgreSQL snapshot response') from error
    actions = validate_snapshot(snapshot)
    return raw, snapshot, actions


def create_plan(psql, database, backup, timeout_seconds, lock_timeout_ms):
    """Write a new review/backup file exclusively after a read-only preflight."""
    backup = Path(backup)
    require(not backup.exists() and not backup.is_symlink(), 'Backup must be a new regular file')
    raw, snapshot, actions = read_state(psql, database, timeout_seconds, lock_timeout_ms)
    document = {'format': FORMAT, 'sourceState': raw, 'stateDigest': hashlib.sha256(raw.encode('utf-8')).hexdigest(), 'actions': actions}
    body = (json.dumps(document, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    try:
        descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        require(backup.read_bytes() == body, 'Backup verification failed')
    except OSError as error:
        raise MigrationError('Backup could not be preserved; do not apply') from error
    return hashlib.sha256(body).hexdigest(), actions


def load_plan(backup, expected_sha256):
    """Verify the explicitly reviewed file hash before trusting any archive content."""
    path = Path(backup)
    require(path.is_file() and not path.is_symlink(), 'Plan must be a regular preserved file')
    body = path.read_bytes()
    require(re.fullmatch(r'[0-9a-f]{64}', expected_sha256) is not None and hashlib.sha256(body).hexdigest() == expected_sha256, 'Backup hash mismatch')
    try:
        plan = json.loads(body)
        require(type(plan) is dict, 'Plan must be an object')
        require(set(plan) == {'format', 'sourceState', 'stateDigest', 'actions'} and plan['format'] == FORMAT, 'Unsupported plan format')
        raw = plan['sourceState']
        require(type(raw) is str and type(plan['stateDigest']) is str, 'Invalid plan state types')
        require(re.fullmatch(r'[0-9a-f]{64}', plan['stateDigest']) is not None, 'Invalid plan state digest')
        actions = plan['actions']
        require(type(actions) is dict and set(actions) == {'rename', 'dropInstallation'}
                and all(type(value) is bool for value in actions.values()), 'Invalid plan action types')
        require(hashlib.sha256(raw.encode('utf-8')).hexdigest() == plan['stateDigest'], 'Plan state digest mismatch')
        snapshot = json.loads(raw)
        require(type(snapshot) is dict, 'Plan source state must be an object')
        require(validate_snapshot(snapshot) == plan['actions'], 'Plan actions mismatch')
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise MigrationError('Invalid plan content') from error
    return plan, snapshot


def apply_plan(psql, database, backup, expected_sha256, timeout_seconds, lock_timeout_ms):
    """Atomically apply only the reviewed state and preserve all nonidentity data."""
    plan, snapshot = load_plan(backup, expected_sha256)
    require(snapshot['database']['name'] == database, 'Plan targets a different database')
    actions = plan['actions']
    changes = []
    if actions['rename']:
        changes.append('ALTER TABLE payse.demo_users ADD COLUMN name text;')
        for identity in IDENTITY_USERS:
            changes.append('UPDATE payse.demo_users SET name=' + sql_literal(identity['name']) + ' WHERE id=' + sql_literal(identity['user_id']) + '::uuid;')
        changes += [
            'ALTER TABLE payse.demo_users ALTER COLUMN name SET NOT NULL;',
            'ALTER TABLE payse.demo_users ADD CONSTRAINT identity_name_format CHECK (name COLLATE "C" ~ \'^[가-힣A-Za-z]{2,20}$\');',
            'ALTER TABLE payse.demo_users ADD CONSTRAINT identity_phone_format CHECK (synthetic_phone COLLATE "C" ~ \'^010[0-9]{8}$\');',
            'ALTER TABLE payse.demo_users ADD UNIQUE (name, synthetic_phone);',
            'ALTER TABLE payse.demo_users DROP COLUMN synthetic_name RESTRICT;',
            'ALTER TABLE payse.demo_users DROP COLUMN display_name RESTRICT;',
            "COMMENT ON COLUMN payse.demo_users.name IS '합성 인증·허용 호칭의 단일 이름; 제출 원문 저장소가 아님';",
        ]
    if actions['dropInstallation']:
        changes.append('ALTER TABLE payse.demo_sessions DROP COLUMN installation_id RESTRICT;')
    locked = ','.join('payse.' + table for table in TABLES)
    locks = 'LOCK TABLE ' + locked + ' IN SHARE MODE;\n'
    if any(actions.values()):
        locks += 'LOCK TABLE payse.demo_users,payse.demo_sessions IN ACCESS EXCLUSIVE MODE;\n'
    query = snapshot_query().removeprefix('SELECT ')
    sql = transaction_prefix(lock_timeout_ms) + locks + '\nDO $payse_identity$\nDECLARE before_state jsonb; after_state jsonb;\nBEGIN\n'
    sql += 'SELECT ' + query + ' INTO before_state;\n'
    sql += 'IF ' + sql_digest('before_state::text') + ' <> ' + sql_literal(plan['stateDigest']) + " THEN RAISE EXCEPTION 'Reviewed database state changed'; END IF;\n"
    sql += '\n'.join(changes) + '\nSELECT ' + query + ' INTO after_state;\n'
    expected_users = [{'id': row['user_id'], 'phone': row['phone'], 'names': {'name': row['name']}} for row in sorted(IDENTITY_USERS, key=lambda value: value['user_id'])]
    sql += "IF after_state->'users' IS DISTINCT FROM " + sql_literal(json.dumps(expected_users, ensure_ascii=False)) + "::jsonb THEN RAISE EXCEPTION 'Target mapping differs'; END IF;\n"
    sql += "IF before_state->'data' IS DISTINCT FROM after_state->'data' THEN RAISE EXCEPTION 'Preserved data changed'; END IF;\nEND $payse_identity$;\nCOMMIT;\nSELECT '" + ('APPLIED' if any(actions.values()) else 'NOOP') + "';"
    require(hashlib.sha256(Path(backup).read_bytes()).hexdigest() == expected_sha256, 'Backup changed before apply')
    result = run_psql(psql, database, sql, timeout_seconds)
    require(result in ('APPLIED', 'NOOP'), 'Unexpected migration result; inspect state before retrying')
    return result


def main():
    """Expose separate plan/apply actions with required connection and time limits."""
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--plan', action='store_true')
    mode.add_argument('--apply', action='store_true')
    parser.add_argument('--psql', required=True, type=Path)
    parser.add_argument('--database', required=True)
    parser.add_argument('--backup', required=True, type=Path)
    parser.add_argument('--timeout-seconds', required=True, type=int)
    parser.add_argument('--lock-timeout-ms', required=True, type=int)
    parser.add_argument('--expected-sha256')
    args = parser.parse_args()
    try:
        if args.plan:
            require(args.expected_sha256 is None, 'Hash is only accepted with apply')
            digest, actions = create_plan(args.psql, args.database, args.backup, args.timeout_seconds, args.lock_timeout_ms)
            print(json.dumps({'status': 'PLANNED', 'sha256': digest, 'actions': actions}))
        else:
            require(args.expected_sha256 is not None, 'Apply requires the separately reviewed SHA-256')
            print(json.dumps({'status': apply_plan(args.psql, args.database, args.backup, args.expected_sha256, args.timeout_seconds, args.lock_timeout_ms)}))
    except (MigrationError, OSError, ValueError) as error:
        # Do not print SQL/stderr, raw source data, connection details or exception values.
        print(json.dumps({'status': 'REJECTED', 'reason': str(error) if isinstance(error, MigrationError) else 'Tool input or archive failure'}))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
