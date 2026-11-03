"""2026-11-03: 준비 원천을 첫 성공 로그인에 한 번 연결하는 테스트 전용 SQL. 사용: 관리 준비·검사.

일반 DDL·서비스 시작에 포함하지 않는다. 원천 적재·기존 사용자 초기화·DB 접속은 수행하지 않는다.
"""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'fixtures'))
from export_sql import literal
from validate import validate_snapshot


def install(source, database):
    """2026-11-03: 지정 DB·소유자·원천을 검증하며 재설치와 기존 연결 덮어쓰기를 거절한다."""
    validate_snapshot(source)
    if not database or not source['institutionLinks']:
        raise ValueError('Reviewed database and prepared links are required')
    owner = literal(source['userId']) + '::uuid'
    codes = [row['institutionCode'] for row in source['institutionLinks']]
    if len(codes) != len(set(codes)):
        raise ValueError('Only one prepared connection per institution is allowed')
    links = [{'id': row['linkId'], 'user_id': source['userId'],
              'institution_code': row['institutionCode']} for row in source['institutionLinks']]
    return f"""-- TEST ONLY: explicit installation; never load as a product migration.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
DO $preflight$ BEGIN
  IF current_database() <> {literal(database)} THEN RAISE EXCEPTION 'Wrong test DB'; END IF;
  PERFORM id FROM payse.users WHERE id = {owner} AND deactivated_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Missing active prepared owner'; END IF;
  IF NOT EXISTS (SELECT 1 FROM payse.source_contexts
      WHERE user_id = {owner} AND source_version = {literal(source['sourceVersion'])})
      OR EXISTS (SELECT 1 FROM payse.institution_links WHERE user_id = {owner}) THEN
    RAISE EXCEPTION 'Prepared source or unconnected state differs';
  END IF;
END $preflight$;
CREATE SCHEMA payse_test_login;
REVOKE ALL ON SCHEMA payse_test_login FROM PUBLIC;
CREATE TABLE payse_test_login.pending (
  user_id uuid PRIMARY KEY REFERENCES payse.users(id) ON DELETE RESTRICT,
  source_version text NOT NULL,
  links jsonb NOT NULL CHECK (jsonb_typeof(links) = 'array')
);
REVOKE ALL ON payse_test_login.pending FROM PUBLIC;
INSERT INTO payse_test_login.pending VALUES (
  {owner}, {literal(source['sourceVersion'])}, {literal(links)}
);
CREATE FUNCTION payse_test_login.connect_once() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, payse_test_login, pg_temp
AS $connect$
DECLARE prepared payse_test_login.pending%ROWTYPE;
BEGIN
  IF NEW.ended_at IS NOT NULL THEN RETURN NEW; END IF;
  SELECT * INTO prepared FROM payse_test_login.pending
    WHERE user_id = NEW.user_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;
  PERFORM id FROM payse.users WHERE id = NEW.user_id AND deactivated_at IS NULL FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM payse.source_contexts
      WHERE user_id = NEW.user_id AND source_version = prepared.source_version)
      OR EXISTS (SELECT 1 FROM payse.institution_links WHERE user_id = NEW.user_id) THEN
    RAISE EXCEPTION 'First-login prepared source changed';
  END IF;
  PERFORM set_config('payse.user_id', NEW.user_id::text, true);
  INSERT INTO payse.institution_links (id, user_id, institution_code, consented_at, disconnected_at)
    SELECT row.id, NEW.user_id, row.institution_code, NEW.issued_at, NULL
    FROM jsonb_populate_recordset(NULL::payse.institution_links, prepared.links) AS row
    WHERE row.user_id = NEW.user_id;
  UPDATE payse.users SET data_version = data_version + 1 WHERE id = NEW.user_id;
  DELETE FROM payse_test_login.pending WHERE user_id = NEW.user_id;
  RETURN NEW;
END $connect$;
REVOKE ALL ON FUNCTION payse_test_login.connect_once() FROM PUBLIC;
CREATE TRIGGER payse_test_first_login AFTER INSERT ON payse.demo_sessions
FOR EACH ROW EXECUTE FUNCTION payse_test_login.connect_once();
COMMIT;
"""


def uninstall():
    """2026-11-03: 준비 기능만 제거한다. 연결·금융 자료·인증/세션은 보존한다. 사용: 운영자 정리."""
    return """BEGIN;
SET LOCAL lock_timeout = '5s';
DROP TRIGGER payse_test_first_login ON payse.demo_sessions;
DROP FUNCTION payse_test_login.connect_once();
DROP TABLE payse_test_login.pending;
DROP SCHEMA payse_test_login;
COMMIT;
"""
