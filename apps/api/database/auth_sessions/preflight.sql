-- 2026-10-26: 003 인증 기반·권한 경계를 확인하고 중복/오염된 적용을 거절한다.
-- 호출: 004_auth_sessions.sql의 첫 단계. 하위 파일을 단독 실행하지 않는다.

DO $$
DECLARE
  role_name text;
  role_id oid;
  function_name text;
  function_id oid;
  session_table oid;
BEGIN
  -- 003이 관리하는 함수·테이블이 없는 DB에는 세션 전이만 부분 적용하지 않는다.
  session_table := to_regclass('payse.demo_sessions');
  IF session_table IS NULL
    OR to_regclass('payse.auth_rate_limits') IS NULL
    OR to_regprocedure('payse.auth_require_transaction()') IS NULL THEN
    RAISE EXCEPTION 'Apply auth access before session transitions' USING ERRCODE = '55000';
  END IF;

  -- 기존 함수를 덮거나 이미 반영된 권한을 재해석하지 않는다.
  IF to_regprocedure('payse.auth_login_account(text,text)') IS NOT NULL
    OR to_regprocedure('payse.auth_open_session(uuid,text)') IS NOT NULL
    OR to_regprocedure('payse.auth_end_session(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Session transitions already present; do not reapply' USING ERRCODE = '55000';
  END IF;

  -- 관리/접속/상속 권한이 없는 기존 권한 역할만 사용한다. 설정을 자동으로 낮춰 고치지 않는다.
  FOREACH role_name IN ARRAY ARRAY['payse_runtime', 'payse_auth_owner'] LOOP
    SELECT oid
    INTO role_id
    FROM pg_roles
    WHERE rolname = role_name;

    IF role_id IS NULL
      OR EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE oid = role_id
          AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole
            OR rolinherit OR rolreplication OR rolbypassrls)
      )
      OR EXISTS (
        SELECT 1
        FROM pg_auth_members
        WHERE member = role_id
          OR (role_name = 'payse_auth_owner' AND roleid = role_id)
      ) THEN
      RAISE EXCEPTION 'Auth roles require a separate permission review' USING ERRCODE = '55000';
    END IF;
  END LOOP;

  -- 토큰/자격 조회의 소유 역할·고정 검색 경로·SECURITY DEFINER 속성이 유지되어야 한다.
  FOREACH function_name IN ARRAY ARRAY[
    'payse.auth_credentials(text,text)',
    'payse.auth_authorize(text)'
  ] LOOP
    function_id := to_regprocedure(function_name);
    IF function_id IS NULL
      OR NOT EXISTS (
        SELECT 1
        FROM pg_proc
        WHERE oid = function_id
          AND proowner = (SELECT oid FROM pg_roles WHERE rolname = 'payse_auth_owner')
          AND prosecdef
          AND proconfig = ARRAY['search_path=pg_catalog, payse, pg_temp']
      ) THEN
      RAISE EXCEPTION 'Auth function boundary does not match the reviewed schema' USING ERRCODE = '55000';
    END IF;
  END LOOP;

  -- 세션과 사용자 RLS 및 활성 사용자당 한 세션 UNIQUE를 유지한다.
  IF NOT EXISTS (
    SELECT 1
    FROM pg_class
    WHERE oid = session_table
      AND relrowsecurity
      AND relforcerowsecurity
      AND relowner <> (SELECT oid FROM pg_roles WHERE rolname = 'payse_auth_owner')
  )
    OR NOT EXISTS (
      SELECT 1
      FROM pg_class
      WHERE oid = to_regclass('payse.users')
        AND relrowsecurity
        AND relforcerowsecurity
    )
    OR NOT EXISTS (
      SELECT 1
      FROM pg_index
      WHERE indrelid = session_table
        AND indexrelid = to_regclass('payse.active_session_per_user')
        AND indisunique
        AND indisvalid
        AND pg_get_expr(indpred, indrelid) = '(ended_at IS NULL)'
        AND indkey::text = (
          SELECT attnum::text
          FROM pg_attribute
          WHERE attrelid = session_table
            AND attname = 'user_id'
        )
    ) THEN
    RAISE EXCEPTION 'Session isolation or uniqueness requires review' USING ERRCODE = '55000';
  END IF;

  -- runtime/PUBLIC의 세션 직접 권한이나 인증 역할의 예상 밖 쓰기 권한을 확대하지 않는다.
  IF EXISTS (
    SELECT 1
    FROM pg_class c,
      LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) acl
    WHERE c.oid = session_table
      AND (
        acl.grantee IN (0, (SELECT oid FROM pg_roles WHERE rolname = 'payse_runtime'))
        OR (acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'payse_auth_owner')
          AND acl.privilege_type <> 'SELECT')
      )
  )
    OR EXISTS (
      SELECT 1
      FROM pg_attribute a,
        LATERAL aclexplode(a.attacl) acl
      WHERE a.attrelid = session_table
        AND (
          acl.grantee IN (0, (SELECT oid FROM pg_roles WHERE rolname = 'payse_runtime'))
          OR (acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'payse_auth_owner')
            AND acl.privilege_type <> 'SELECT')
        )
    )
    OR EXISTS (
      SELECT 1
      FROM pg_default_acl d,
        LATERAL aclexplode(d.defaclacl) acl
      WHERE d.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = current_user)
        AND d.defaclnamespace IN (0, (SELECT oid FROM pg_namespace WHERE nspname = 'payse'))
        AND d.defaclobjtype = 'f'
        AND acl.grantee NOT IN (0, d.defaclrole)
    )
    OR EXISTS (
      SELECT 1
      FROM pg_namespace n,
        LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) acl
      WHERE n.nspname = 'payse'
        AND acl.privilege_type = 'CREATE'
        AND acl.grantee <> n.nspowner
    ) THEN
    RAISE EXCEPTION 'Session grants or function defaults require review' USING ERRCODE = '55000';
  END IF;
END $$;
