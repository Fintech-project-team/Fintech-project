-- 2026-10-26: 세션 전이의 최소 테이블 권한·RLS와 세 함수 실행 권한을 함께 확정한다.
-- 호출: 004_auth_sessions.sql의 마지막 단계. PUBLIC 회수까지 같은 트랜잭션에 포함한다.

-- 인증 함수 소유 역할만 세션을 생성하고 종료 시각을 기록할 수 있다.
CREATE POLICY auth_owner_insert
  ON payse.demo_sessions FOR INSERT TO payse_auth_owner
  WITH CHECK (true);

CREATE POLICY auth_owner_end
  ON payse.demo_sessions FOR UPDATE TO payse_auth_owner
  USING (true)
  WITH CHECK (true);

GRANT INSERT (id, user_id, token_digest, issued_at)
  ON payse.demo_sessions TO payse_auth_owner;

GRANT UPDATE (ended_at)
  ON payse.demo_sessions TO payse_auth_owner;

-- 함수는 NOLOGIN·NOBYPASSRLS 역할의 제한된 권한으로 실행한다.
ALTER FUNCTION payse.auth_login_account(text, text) OWNER TO payse_auth_owner;
ALTER FUNCTION payse.auth_open_session(uuid, text) OWNER TO payse_auth_owner;
ALTER FUNCTION payse.auth_end_session(text) OWNER TO payse_auth_owner;

-- runtime에 테이블 권한을 주지 않고 검증된 진입 함수만 공개한다.
REVOKE ALL ON FUNCTION
  payse.auth_login_account(text, text),
  payse.auth_open_session(uuid, text),
  payse.auth_end_session(text)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  payse.auth_login_account(text, text),
  payse.auth_open_session(uuid, text),
  payse.auth_end_session(text)
  TO payse_runtime;
