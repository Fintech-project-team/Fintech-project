-- 함수 소유권을 지정하고 PUBLIC 권한을 회수한 뒤 runtime 실행 권한을 연다.
-- 2026-10-26: 003_auth_access.sql에서 목적별로 분리. 해당 진입점의 단일 트랜잭션에서만 실행한다.
-- 순서: 5/5. 단독 실행하거나 트랜잭션 제어 BEGIN/COMMIT을 추가하지 않는다.

-- auth_events_valid의 관리 소유권을 인증 역할로 통일한다. 실행 권한은 호출 역할을 따른다.
ALTER FUNCTION payse.auth_events_valid(timestamptz[], integer) OWNER TO payse_auth_owner;
-- auth_require_transaction의 관리 소유권을 인증 역할로 통일한다. 실행 권한은 호출 역할을 따른다.
ALTER FUNCTION payse.auth_require_transaction() OWNER TO payse_auth_owner;
-- auth_lock_limit의 관리 소유권을 인증 역할로 통일한다. 실행 권한은 호출 역할을 따른다.
ALTER FUNCTION payse.auth_lock_limit(text, text) OWNER TO payse_auth_owner;
-- auth_combo_state의 관리 소유권을 인증 역할로 통일한다. 실행 권한은 호출 역할을 따른다.
ALTER FUNCTION payse.auth_combo_state(text) OWNER TO payse_auth_owner;
-- auth_ip_request가 인증 역할의 제한된 권한으로 실행되도록 소유권을 지정한다.
ALTER FUNCTION payse.auth_ip_request(text) OWNER TO payse_auth_owner;
-- auth_limit가 인증 역할의 제한된 권한으로 실행되도록 소유권을 지정한다.
ALTER FUNCTION payse.auth_limit(text) OWNER TO payse_auth_owner;
-- auth_failure가 인증 역할의 제한된 권한으로 실행되도록 소유권을 지정한다.
ALTER FUNCTION payse.auth_failure(text) OWNER TO payse_auth_owner;
-- auth_credentials가 인증 역할의 제한된 권한으로 실행되도록 소유권을 지정한다.
ALTER FUNCTION payse.auth_credentials(text, text) OWNER TO payse_auth_owner;
-- auth_authorize가 인증 역할의 제한된 권한으로 실행되도록 소유권을 지정한다.
ALTER FUNCTION payse.auth_authorize(text) OWNER TO payse_auth_owner;
-- 생성한 인증 함수·보조 함수의 PUBLIC 실행 권한을 같은 적용 트랜잭션에서 회수한다.
REVOKE ALL ON FUNCTION payse.auth_events_valid(timestamptz[], integer),
  payse.auth_require_transaction(), payse.auth_lock_limit(text, text), payse.auth_combo_state(text),
  payse.auth_ip_request(text), payse.auth_limit(text), payse.auth_failure(text),
  payse.auth_credentials(text, text), payse.auth_authorize(text) FROM PUBLIC;
-- runtime에는 외부 진입 함수 5개만 공개한다. 배열/잠금/상태 정리 보조 함수는 직접 호출할 수 없다.
GRANT EXECUTE ON FUNCTION payse.auth_ip_request(text), payse.auth_limit(text), payse.auth_failure(text),
  payse.auth_credentials(text, text), payse.auth_authorize(text) TO payse_runtime;
