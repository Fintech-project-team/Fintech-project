"""Review explicit nominal salary months before migrating common storage from v2 to v3.

Never infer payMonth from dates, create a DB, add a receipt, or run automatically
from an installer. Keep a full database backup in addition to the review archive.
Mapping format: PAYSE-SALARY-MAPPING-1, users: [{userId, expectedSourceVersion,
newSourceVersion, evidence: [{proofSha256, payMonth}]}]. proofSha256 uses sorted,
compact UTF-8 JSON (ensure_ascii=False) of the complete original proof object.
Every source_contexts owner, including an owner with [], requires an entry.
"""
from __future__ import annotations

import argparse
import copy
from datetime import date
import hashlib
import json
import os
from pathlib import Path
import re
from uuid import UUID

import migrate_common_storage as common
from migrate_identity import MigrationError, require, run_psql, sql_literal, sql_digest, transaction_prefix

HERE = Path(__file__).resolve().parent
FORMAT = 'PAYSE-SALARY-EVIDENCE-PLAN-1'
MAPPING_FORMAT = 'PAYSE-SALARY-MAPPING-1'
SOURCE_SCHEMA = 'PAYSE-DRAFT-2'
TARGET_SCHEMA = 'PAYSE-DRAFT-3'
CURRENT_TABLES = ('financial_accounts', 'financial_cards', 'financial_transactions', 'card_statements')
MANAGED_FUNCTIONS = ('lock_storage_owner', 'assert_user_storage', 'check_storage_owner')


def canonical_digest(value):
    """2026-10-23: Identify the entire original proof, independent of its array position."""
    body = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
    return hashlib.sha256(body.encode('utf-8')).hexdigest()


def strict_json(raw):
    """2026-10-23: Reject duplicate JSON keys and non-JSON numeric constants before review."""
    def pairs(items):
        """2026-10-23: Preserve one explicitly supplied value for each key."""
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    def invalid_constant(value):
        """2026-10-23: Reject NaN and Infinity in mapping and archive input."""
        raise MigrationError('Unsupported JSON constant')
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid_constant)


def read_regular(path):
    """2026-10-23: Read explicit local input without following a symbolic link."""
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'A regular input file is required')
    return path.read_bytes()


def snapshot_query():
    """2026-10-23: Hash all rows and preserve only the approved salary/version differences.

    2026-10-29: Keep the pre-cancellation-date table contract for this historical transition.
    """
    pairs = []
    for table in sorted(common.table_contract(common.FROZEN_COMMON)):
        expression = 'to_jsonb(t)'
        if table == 'source_contexts':
            expression = "(to_jsonb(t)-'source_version'-'schema_version'-'salary_evidence')||jsonb_build_object('salary_evidence',COALESCE((SELECT jsonb_agg(e.value-'payMonth' ORDER BY e.n) FROM jsonb_array_elements(t.salary_evidence) WITH ORDINALITY e(value,n)),'[]'::jsonb))"
        elif table in CURRENT_TABLES:
            expression += "-'source_version'"
        row = '(' + expression + ')::text'
        joined = "COALESCE(string_agg(" + row + ",E'\\n' ORDER BY " + row + "),'')"
        pairs.append(sql_literal(table) + ",(SELECT jsonb_build_object('count',count(*),'sha256'," + sql_digest(joined) + ') FROM payse.' + table + ' t)')
    return 'SELECT (' + common.snapshot_query(False)[7:] + """ ) || jsonb_build_object(
      'server',jsonb_build_object('address',inet_server_addr()::text,'port',inet_server_port(),'version',current_setting('server_version_num')),
      'sourceRows',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY user_id) FROM payse.source_contexts c),'[]'::jsonb),
      'triggers',(SELECT jsonb_agg(jsonb_build_object('table',c.relname,'name',t.tgname,'definition',pg_get_triggerdef(t.oid)) ORDER BY c.relname,t.tgname) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='payse' AND NOT t.tgisinternal),
      'indexes',(SELECT jsonb_agg(indexdef ORDER BY tablename,indexname) FROM pg_indexes WHERE schemaname='payse'),
      'functionContracts',(SELECT jsonb_agg(jsonb_build_object('id',p.oid,'name',p.proname,'owner',p.proowner,'acl',p.proacl,'definer',p.prosecdef,'config',p.proconfig) ORDER BY p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='payse'),
      'unmanagedFunctions',(SELECT jsonb_agg(jsonb_build_object('id',p.oid,'definition',pg_get_functiondef(p.oid)) ORDER BY p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='payse' AND p.proname NOT IN ('lock_storage_owner','assert_user_storage','check_storage_owner')),
      'invariantData',jsonb_build_object(""" + ','.join(pairs) + '))'


def transformed_sources(state, mapping):
    """2026-10-23: Apply only reviewed month assignments to exact v2 source proof objects."""
    require(isinstance(mapping, dict) and set(mapping) == {'format', 'users'} and mapping['format'] == MAPPING_FORMAT, 'Unsupported explicit mapping')
    require(isinstance(mapping['users'], list), 'Mapping users must be an array')
    sources = {row['user_id']: row for row in state['sourceRows']}
    require(len(sources) == len(state['sourceRows']), 'Duplicate source owner')
    changes = {}
    for item in mapping['users']:
        require(isinstance(item, dict) and set(item) == {'userId', 'expectedSourceVersion', 'newSourceVersion', 'evidence'}, 'Mapping keys differ')
        owner = item['userId']
        require(isinstance(owner, str) and str(UUID(owner)) == owner and owner in sources and owner not in changes, 'Invalid or duplicate mapping owner')
        source = sources[owner]
        require(source['schema_version'] == SOURCE_SCHEMA and source['source_version'] == item['expectedSourceVersion'], 'Reviewed source version differs')
        new_version = item['newSourceVersion']
        require(isinstance(new_version, str) and new_version.strip() and new_version != source['source_version'] and '\x00' not in new_version, 'A distinct explicit source version is required')
        require(isinstance(source['salary_evidence'], list) and isinstance(item['evidence'], list), 'Salary evidence must be an array')
        original = {}
        for proof in source['salary_evidence']:
            require(isinstance(proof, dict) and set(proof) == {'expectedPayDate', 'confirmation', 'transactionIds'}, 'Source proof differs from reviewed v2 contract')
            require(isinstance(proof['expectedPayDate'], str) and re.fullmatch('[0-9]{4}-[0-9]{2}-[0-9]{2}', proof['expectedPayDate']), 'Invalid original scheduled date')
            date.fromisoformat(proof['expectedPayDate'])
            require(proof['confirmation'] in ('unknown', 'partial', 'confirmed') and isinstance(proof['transactionIds'], list), 'Invalid original proof state')
            require(proof['confirmation'] == 'unknown' or bool(proof['transactionIds']), 'Original confirmed/partial proof has no transactions')
            for transaction_id in proof['transactionIds']:
                require(isinstance(transaction_id, str) and str(UUID(transaction_id)) == transaction_id, 'Invalid original transaction reference')
            digest = canonical_digest(proof)
            require(digest not in original, 'Identical original proofs need a separate source review')
            original[digest] = proof
        mapped = {}
        months = set()
        for assignment in item['evidence']:
            require(isinstance(assignment, dict) and set(assignment) == {'proofSha256', 'payMonth'}, 'Evidence mapping keys differ')
            digest = assignment['proofSha256']
            require(isinstance(digest, str) and digest in original and digest not in mapped, 'Missing, duplicate or changed proof mapping')
            month = assignment['payMonth']
            require(isinstance(month, str) and re.fullmatch('[0-9]{4}-(0[1-9]|1[0-2])', month), 'Nominal month must use YYYY-MM')
            date.fromisoformat(month + '-01')
            require(month not in months, 'Duplicate nominal salary cycle')
            months.add(month)
            mapped[digest] = month
        require(set(mapped) == set(original), 'Every original proof requires an explicit nominal month')
        updated = copy.deepcopy(source)
        updated.update(schema_version=TARGET_SCHEMA, source_version=new_version)
        updated['salary_evidence'] = [{**proof, 'payMonth': mapped[canonical_digest(proof)]} for proof in source['salary_evidence']]
        changes[owner] = updated
    require(set(changes) == set(sources), 'Every source owner requires an explicit version mapping')
    return [changes[owner] for owner in sorted(changes)]


def target_guards():
    """2026-10-23: Read the exact reviewed v3 storage functions, never caller-supplied SQL."""
    raw = (HERE / '002_storage_guards.sql').read_bytes()
    text = raw.decode('utf-8')
    functions = re.findall(r'CREATE FUNCTION payse\.[\s\S]*?END \$\$;', text)
    names = [re.search(r'CREATE FUNCTION payse\.(\w+)\(', function).group(1) for function in functions]
    require(tuple(names) == MANAGED_FUNCTIONS and 'payMonth' in text, 'Expected v3 storage functions missing')
    return hashlib.sha256(raw).hexdigest(), [function.replace('CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION', 1) for function in functions]


def create_plan(psql, database, mapping_path, backup, timeout_seconds, lock_timeout_ms):
    """2026-10-23: Archive source hashes and reviewed complete mappings without modifying the DB."""
    path = Path(backup)
    require(not path.exists() and not path.is_symlink(), 'Archive must be a new regular file')
    mapping = strict_json(read_regular(mapping_path))
    guard_digest, _ = target_guards()
    sql = transaction_prefix(lock_timeout_ms, True) + "SET LOCAL client_encoding='UTF8';\n" + snapshot_query() + ';COMMIT;'
    raw = run_psql(psql, database, sql, timeout_seconds)
    state = strict_json(raw)
    common.validate(state, False)
    transformed_sources(state, mapping)
    archive = {'format': FORMAT, 'sourceState': raw, 'stateDigest': hashlib.sha256(raw.encode('utf-8')).hexdigest(), 'mapping': mapping, 'targetGuardSha256': guard_digest}
    body = (json.dumps(archive, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(body)
        stream.flush()
        os.fsync(stream.fileno())
    require(path.read_bytes() == body, 'Archive verification failed')
    return hashlib.sha256(body).hexdigest()


def apply_plan(psql, database, backup, expected_sha256, timeout_seconds, lock_timeout_ms):
    """2026-10-23: Lock and recheck all reviewed state; change only month/schema/source versions."""
    body = read_regular(backup)
    require(re.fullmatch('[0-9a-f]{64}', expected_sha256 or '') is not None and hashlib.sha256(body).hexdigest() == expected_sha256, 'Archive hash mismatch')
    archive = strict_json(body)
    require(isinstance(archive, dict) and set(archive) == {'format', 'sourceState', 'stateDigest', 'mapping', 'targetGuardSha256'} and archive['format'] == FORMAT, 'Unsupported archive')
    require(isinstance(archive['sourceState'], str) and hashlib.sha256(archive['sourceState'].encode('utf-8')).hexdigest() == archive['stateDigest'], 'Source digest mismatch')
    state = strict_json(archive['sourceState'])
    common.validate(state, False)
    require(state['database']['name'] == database, 'Archive targets another database')
    updated = transformed_sources(state, archive['mapping'])
    guard_digest, guards = target_guards()
    require(guard_digest == archive['targetGuardSha256'], 'Reviewed target functions changed')
    tables = common.table_contract(common.FROZEN_COMMON)
    locks = 'LOCK TABLE ' + ','.join('payse.' + table for table in sorted(tables)) + ' IN ACCESS EXCLUSIVE MODE;'
    prefix = transaction_prefix(lock_timeout_ms) + "SET LOCAL client_encoding='UTF8';\nSET LOCAL standard_conforming_strings=on;\n" + locks + '\nSET CONSTRAINTS ALL DEFERRED;\n'
    sql = 'DECLARE original jsonb; result jsonb; BEGIN\n'
    sql += snapshot_query() + ' INTO original;\n'
    sql += 'IF ' + sql_digest('original::text') + '<>' + sql_literal(archive['stateDigest']) + " THEN RAISE EXCEPTION 'Reviewed database state changed'; END IF;\n"
    sql += '\n'.join(guards) + '\n'
    for source in updated:
        owner, version = sql_literal(source['user_id']) + '::uuid', sql_literal(source['source_version'])
        evidence = sql_literal(json.dumps(source['salary_evidence'], ensure_ascii=False)) + '::jsonb'
        sql += 'UPDATE payse.source_contexts SET schema_version=' + sql_literal(TARGET_SCHEMA) + ',source_version=' + version + ',salary_evidence=' + evidence + ' WHERE user_id=' + owner + ';\n'
        for table in CURRENT_TABLES:
            sql += 'UPDATE payse.' + table + ' SET source_version=' + version + ' WHERE user_id=' + owner + ';\n'
    sql += 'SET CONSTRAINTS ALL IMMEDIATE;\nPERFORM payse.assert_user_storage(id) FROM payse.users;\n'
    sql += snapshot_query() + ' INTO result;\n'
    sql += "IF (original-'data'-'sourceRows'-'functions') IS DISTINCT FROM (result-'data'-'sourceRows'-'functions') THEN RAISE EXCEPTION 'Unapproved database state changed'; END IF;\n"
    sql += "IF result->'sourceRows' IS DISTINCT FROM " + sql_literal(json.dumps(updated, ensure_ascii=False)) + "::jsonb THEN RAISE EXCEPTION 'Salary source transition differs'; END IF;\n"
    sql += 'END;'
    sql = prefix + 'DO ' + sql_literal(sql) + ";\nCOMMIT;SELECT 'APPLIED';"
    require(read_regular(backup) == body, 'Archive changed before application')
    result = run_psql(psql, database, sql, timeout_seconds)
    require(result == 'APPLIED', 'Unexpected result; inspect DB before retrying')
    return result


def main():
    """2026-10-23: Require explicit target, reviewed mapping, separate archive hash and application."""
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--plan', action='store_true')
    mode.add_argument('--apply', action='store_true')
    parser.add_argument('--mapping', type=Path)
    parser.add_argument('--database', required=True)
    parser.add_argument('--psql', required=True)
    parser.add_argument('--backup', type=Path, required=True)
    parser.add_argument('--timeout-seconds', type=int, required=True)
    parser.add_argument('--lock-timeout-ms', type=int, required=True)
    parser.add_argument('--expected-sha256')
    args = parser.parse_args()
    try:
        if args.plan:
            require(args.mapping is not None and args.expected_sha256 is None, 'Plan requires a mapping and no apply hash')
            result = {'status': 'PLANNED', 'sha256': create_plan(args.psql, args.database, args.mapping, args.backup, args.timeout_seconds, args.lock_timeout_ms)}
        else:
            require(args.mapping is None, 'Apply reads only the reviewed archive mapping')
            result = {'status': apply_plan(args.psql, args.database, args.backup, args.expected_sha256, args.timeout_seconds, args.lock_timeout_ms)}
        print(json.dumps(result))
        return 0
    except (ValueError, KeyError, TypeError, OSError):
        print(json.dumps({'status': 'REJECTED', 'reason': 'Schema/state/mapping/archive validation failed; no success reported'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
