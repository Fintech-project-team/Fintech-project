"""2026-11-05: 암호화한 삭제 결정으로 격리 복원본만 차단한다. 실시간 삭제 복제기는 아니다."""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
from uuid import UUID

import backup_crypto as crypto
from portable_server import database_target
from release_server import properties

FORMAT = 'PAYSE-RESTORE-GUARD-1'
SNAPSHOT = """
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL row_security=off;
SELECT json_build_object(
 'sourceSystem', (SELECT system_identifier::text FROM pg_control_system()),
 'sourceDatabase', current_database(), 'capturedAt', transaction_timestamp(),
 'revocations', COALESCE((SELECT json_agg(json_build_object('id',id,'owner',user_id,
   'deletedAt',deleted_at,'purgeAt',purge_requested_at)) FROM payse.analysis_items
   WHERE deleted_at IS NOT NULL OR purge_requested_at IS NOT NULL), '[]'::json),
 'suppressions', COALESCE((SELECT json_agg(to_jsonb(s)) FROM payse.analysis_suppressions s), '[]'::json)
)::text;
COMMIT;
"""


def run_sql(executable, settings, sql):
    """2026-11-05: 제한된 psql 표준 입력으로만 SQL을 전달하고 자격·원문 오류를 출력하지 않는다."""
    target, database, query = database_target(settings['PAYSE_JDBC_URL'])
    executable = Path(executable)
    if not executable.is_absolute() or not executable.is_file():
        raise ValueError('An explicit psql executable is required')
    environment = {k: v for k, v in os.environ.items() if not k.upper().startswith('PG')}
    environment.update(PGPASSWORD=settings['PAYSE_DB_PASSWORD'], PGCONNECT_TIMEOUT='5',
                       PGOPTIONS='-c statement_timeout=15000 -c lock_timeout=3000')
    for name, values in query.items():
        environment['PG' + name.upper()] = values[0]
    result = subprocess.run([str(executable), '-X', '-qAt', '-w', '-v', 'ON_ERROR_STOP=1',
                             '-h', target.hostname, '-p', str(target.port or 5432),
                             '-U', settings['PAYSE_DB_USER'], '-d', database],
                            input=sql, capture_output=True, text=True, encoding='utf-8', env=environment,
                            timeout=25, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    if result.returncode:
        raise ValueError('Restore policy database operation rejected; no success reported')
    return json.loads(result.stdout)


def instant(value):
    """2026-11-05: 오프셋 없는 시각을 현재 시각으로 보정하지 않는다."""
    result = datetime.fromisoformat(value)
    if result.tzinfo is None:
        raise ValueError('An explicit policy timestamp is required')
    return result


def validate(record):
    """2026-11-05: 인증된 파일도 형식·소유자·중복·시각을 다시 검사한다."""
    expected = {'format', 'sourceSystem', 'sourceDatabase', 'capturedAt', 'revocations', 'suppressions'}
    if (set(record) != expected or record['format'] != FORMAT
            or not re.fullmatch(r'[0-9]+', record['sourceSystem'])
            or not re.fullmatch(r'[A-Za-z0-9_]+', record['sourceDatabase'])):
        raise ValueError('Invalid restore policy identity')
    captured = instant(record['capturedAt'])
    for name in ('revocations', 'suppressions'):
        if not isinstance(record[name], list) or len(record[name]) > 100000:
            raise ValueError('Invalid restore policy size')
    seen = set()
    for row in record['revocations']:
        if set(row) != {'id', 'owner', 'deletedAt', 'purgeAt'}:
            raise ValueError('Invalid revocation')
        for name in ('id', 'owner'):
            if str(UUID(row[name])) != row[name]:
                raise ValueError('Noncanonical policy identity')
        if row['id'] in seen or not (row['deletedAt'] or row['purgeAt']):
            raise ValueError('Duplicate or empty revocation')
        seen.add(row['id'])
        if any(instant(value) > captured for value in (row['deletedAt'], row['purgeAt']) if value):
            raise ValueError('Future revocation')
    seen.clear()
    for row in record['suppressions']:
        if (set(row) != {'user_id', 'semantic_kind', 'memory_key', 'evidence_hash', 'blocked_at'}
                or str(UUID(row['user_id'])) != row['user_id']
                or row['semantic_kind'] not in ('transactionMeaning', 'recurringMeaning')
                or not isinstance(row['memory_key'], str) or not row['memory_key'].strip()
                or len(row['memory_key']) > 8192
                or not re.fullmatch(r'sha256:[0-9a-f]{64}', row['evidence_hash'])
                or instant(row['blocked_at']) > captured):
            raise ValueError('Invalid suppression')
        identity = tuple(row[k] for k in ('user_id', 'semantic_kind', 'memory_key', 'evidence_hash'))
        if identity in seen:
            raise ValueError('Duplicate suppression')
        seen.add(identity)
    return record


def capture(executable, settings, key_path, output, previous=None):
    """2026-11-05: 현재 삭제 결정과 이전 파일을 합쳐 새 불변 암호문으로만 보존한다."""
    crypto.private_path(output)
    key = crypto.read_key(key_path)
    record = validate({'format': FORMAT, **run_sql(executable, settings, SNAPSHOT)})
    if previous is not None:
        prior = validate(json.loads(crypto.read_encrypted(previous, key)))
        if any(prior[k] != record[k] for k in ('sourceSystem', 'sourceDatabase')):
            raise ValueError('Previous policy belongs to another source')
        if instant(prior['capturedAt']) > instant(record['capturedAt']):
            raise ValueError('Policy capture time moved backwards')
        for field, keys in (('revocations', ('id',)),
                            ('suppressions', ('user_id', 'semantic_kind', 'memory_key', 'evidence_hash'))):
            merged = {tuple(row[k] for k in keys): row for row in record[field]}
            for row in prior[field]:
                identity = tuple(row[k] for k in keys)
                if field == 'revocations' and identity in merged and merged[identity]['owner'] != row['owner']:
                    raise ValueError('Policy owner changed')
                if identity not in merged:
                    merged[identity] = row
                else:
                    names = ('deletedAt', 'purgeAt') if field == 'revocations' else ('blocked_at',)
                    for name in names:
                        prior_time, current_time = row[name], merged[identity][name]
                        if prior_time and (not current_time or instant(prior_time) < instant(current_time)):
                            merged[identity][name] = prior_time
            record[field] = list(merged.values())
    validate(record)
    body = json.dumps(record).encode('utf-8')
    crypto.encrypt_stream(io.BytesIO(body), output, key)
    if crypto.read_encrypted(output, key) != body:
        raise ValueError('Policy backup verification failed')
    return {'revocations': len(record['revocations']), 'suppressions': len(record['suppressions']),
            'liveDatabaseChanged': False, 'continuousReplication': False}


def restore_sql(record, directory):
    """2026-11-05: 현재 원본 클러스터를 거절하고 잠근 복원본에서 소유권·삭제·만료를 원자 적용한다."""
    payload = base64.b64encode(json.dumps(record).encode()).decode()
    directory = str(directory).replace('\\', '/')
    if "'" in directory or any(ord(char) < 32 for char in directory):
        raise ValueError('Unsupported restore directory')
    return f"""
BEGIN;
SET LOCAL row_security=off;
SET LOCAL standard_conforming_strings=on;
LOCK TABLE payse.analysis_items,payse.analysis_suppressions IN EXCLUSIVE MODE;
CREATE TEMP TABLE restore_policy AS SELECT convert_from(decode('{payload}','base64'),'UTF8')::jsonb AS doc;
DO $guard$
DECLARE policy jsonb;
BEGIN
 SELECT doc INTO policy FROM restore_policy;
 IF current_database() !~ '^payse_restore_[a-z0-9_]+$'
    OR (SELECT system_identifier::text FROM pg_control_system()) = policy->>'sourceSystem'
    OR replace(current_setting('data_directory'), chr(92), '/') <> '{directory}'
    OR EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid())
 THEN RAISE EXCEPTION 'Restoration target must be an isolated owned database'; END IF;
 IF EXISTS (SELECT 1 FROM payse.analysis_items i
    JOIN jsonb_to_recordset(policy->'revocations') AS r(id uuid, owner uuid) ON i.id=r.id
    WHERE i.user_id<>r.owner)
 THEN RAISE EXCEPTION 'Restore policy owner mismatch'; END IF;
END $guard$;
INSERT INTO payse.analysis_suppressions(user_id,semantic_kind,memory_key,evidence_hash,blocked_at)
 SELECT r.user_id,r.semantic_kind,r.memory_key,r.evidence_hash,r.blocked_at
 FROM restore_policy p, jsonb_to_recordset(p.doc->'suppressions') AS r(
 user_id uuid,semantic_kind text,memory_key text,evidence_hash text,blocked_at timestamptz)
 JOIN payse.users u ON u.id=r.user_id
 ON CONFLICT DO NOTHING;
WITH selected AS (
 SELECT i.id, EXISTS(SELECT 1 FROM restore_policy p,
   jsonb_to_recordset(p.doc->'revocations') AS r(id uuid,owner uuid,"deletedAt" timestamptz)
   WHERE r.id=i.id AND r.owner=i.user_id AND r."deletedAt" IS NOT NULL)
   OR EXISTS(SELECT 1 FROM payse.analysis_suppressions s WHERE s.user_id=i.user_id
   AND s.semantic_kind=i.semantic_kind AND s.memory_key=i.memory_key AND s.evidence_hash=i.evidence_hash) AS deleted
 FROM payse.analysis_items i WHERE
   i.deleted_at IS NOT NULL OR i.purge_requested_at IS NOT NULL
   OR (NOT i.important AND i.normal_expires_at<=transaction_timestamp())
   OR EXISTS(SELECT 1 FROM restore_policy p,
      jsonb_to_recordset(p.doc->'revocations') AS r(id uuid,owner uuid)
      WHERE r.id=i.id AND r.owner=i.user_id)
   OR EXISTS(SELECT 1 FROM payse.analysis_suppressions s WHERE s.user_id=i.user_id
      AND s.semantic_kind=i.semantic_kind AND s.memory_key=i.memory_key AND s.evidence_hash=i.evidence_hash)
), changed AS (
 UPDATE payse.analysis_items i SET ciphertext=NULL,crypto_meta=NULL,active=false,
   deleted_at=CASE WHEN s.deleted THEN COALESCE(i.deleted_at,transaction_timestamp()) ELSE i.deleted_at END,
   purge_requested_at=COALESCE(i.purge_requested_at,transaction_timestamp()),metadata_version=i.metadata_version+1
 FROM selected s WHERE i.id=s.id AND (i.ciphertext IS NOT NULL OR i.active)
 RETURNING i.id
)
SELECT json_build_object('purgedItems',count(*),'restorationOnly',true) FROM changed;
COMMIT;
"""


def apply(executable, settings, key_path, archive, expected_sha256, directory):
    """2026-11-05: 새 5분 이내 삭제 자료와 명시 검토 지문 없이는 복원본도 변경하지 않는다."""
    target, database, _ = database_target(settings['PAYSE_JDBC_URL'])
    if target.hostname not in ('127.0.0.1', 'localhost', '::1') or not re.fullmatch(r'payse_restore_[a-z0-9_]+', database):
        raise ValueError('Only an explicit isolated restoration database is permitted')
    path = crypto.private_path(archive, existing=True)
    if not re.fullmatch(r'[0-9a-f]{64}', expected_sha256) or hashlib.sha256(path.read_bytes()).hexdigest() != expected_sha256:
        raise ValueError('Reviewed policy hash differs')
    record = validate(json.loads(crypto.read_encrypted(path, crypto.read_key(key_path))))
    age = (datetime.now(timezone.utc) - instant(record['capturedAt'])).total_seconds()
    if not 0 <= age <= 300:
        raise ValueError('Fresh authoritative deletion policy required before exposing a restoration')
    directory = crypto.runtime.outside_git(directory).resolve(strict=True)
    if not directory.is_dir():
        raise ValueError('Explicit owned data directory required')
    return run_sql(executable, settings, restore_sql(record, directory))


def main():
    """2026-11-05: 현재 DB 캡처와 격리 복원본 재적용을 별도 명령으로 노출한다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('capture', 'apply'))
    parser.add_argument('--psql', type=Path, required=True)
    parser.add_argument('--properties', type=Path, required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--previous', type=Path)
    parser.add_argument('--expected-sha256')
    parser.add_argument('--target-data-directory', type=Path)
    args = parser.parse_args()
    try:
        settings = properties(crypto.private_path(args.properties, existing=True))
        if args.action == 'capture':
            result = capture(args.psql, settings, args.key, args.archive, args.previous)
        else:
            if not args.expected_sha256 or not args.target_data_directory:
                raise ValueError('Explicit restoration review required')
            result = apply(args.psql, settings, args.key, args.archive,
                           args.expected_sha256, args.target_data_directory)
        print(json.dumps({'status': 'VERIFIED', **result}))
        return 0
    except Exception:
        print(json.dumps({'status': 'REJECTED', 'reason': 'Restore policy validation failed; do not expose restored data'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
