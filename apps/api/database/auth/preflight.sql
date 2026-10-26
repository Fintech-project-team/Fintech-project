-- 기존 저장 구조·권한을 검사하고 인증 역할을 준비한다.
-- 2026-10-26: 003_auth_access.sql에서 목적별로 분리. 해당 진입점의 단일 트랜잭션에서만 실행한다.
-- 순서: 1/5. 단독 실행하거나 트랜잭션 제어 BEGIN/COMMIT을 추가하지 않는다.

-- 기존 DB를 안전한 공통 스키마로 확인한다. 충돌한 설정은 임의 수정하지 않고 적용을 중단한다.
DO $$
DECLARE
  role_name text;
  role_oid oid;
  table_name text;
  table_oid oid;
  owner_column text;
  owner_rule text;
BEGIN
  -- 공통 저장 테이블과 저장 제약 함수가 먼저 준비되어 있어야 한다.
  IF to_regclass('payse.users') IS NULL
    OR to_regprocedure('payse.assert_user_storage(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Apply the current common storage schema first' USING ERRCODE = '55000';
  END IF;
  -- 이미 적용한 인증 구조를 다시 만들거나 덮지 않는다.
  IF to_regclass('payse.auth_rate_limits') IS NOT NULL THEN
    RAISE EXCEPTION 'Auth access migration already present; do not reapply' USING ERRCODE = '55000';
  END IF;
  -- 조회 권한을 새로 부여하기 전에 21개 비공개 테이블의 기존 소유자 필터를 대조한다.
  FOREACH table_name IN ARRAY ARRAY[
    'users',
    'demo_sessions',
    'source_contexts',
    'institution_links',
    'financial_accounts',
    'financial_cards',
    'transaction_references',
    'financial_transactions',
    'card_statements',
    'statement_items',
    'transaction_relations',
    'user_attributes',
    'recurring_plans',
    'recurring_plan_revisions',
    'obligations',
    'occurrence_overrides',
    'recurring_decisions',
    'settlement_links',
    'reserves',
    'reserve_allocations',
    'write_receipts'
  ] LOOP
    -- 테이블별 소유자 열(users.id 또는 user_id)에 맞는 검토된 정책 식을 준비한다.
    table_oid := to_regclass('payse.'||table_name);
    owner_column := CASE WHEN table_name = 'users' THEN 'id' ELSE 'user_id' END;
    owner_rule := format(
      '(%I = (NULLIF(current_setting(''payse.user_id''::text, true), ''''::text))::uuid)',
      owner_column
    );
    -- RLS/FORCE·단일 own_rows·대상 역할/명령·조회/쓰기 조건이 모두 일치해야 한다.
    IF table_oid IS NULL
      OR NOT EXISTS (
        SELECT 1
        FROM pg_class
        WHERE oid = table_oid
          AND relrowsecurity
          AND relforcerowsecurity
      )
      OR (
        SELECT count(*)
        FROM pg_policy
        WHERE polrelid = table_oid
      ) <> 1
      OR NOT EXISTS (
        SELECT 1
        FROM pg_policy
        WHERE polrelid = table_oid
          AND polname = 'own_rows'
          AND polcmd = '*'
          AND polpermissive
          AND polroles = ARRAY[0::oid]
          AND regexp_replace(pg_get_expr(polqual, polrelid), '[[:space:]]', '', 'g')
             = regexp_replace(owner_rule, '[[:space:]]', '', 'g')
          AND regexp_replace(pg_get_expr(polwithcheck, polrelid), '[[:space:]]', '', 'g')
             = regexp_replace(owner_rule, '[[:space:]]', '', 'g')
      ) THEN
      RAISE EXCEPTION 'Existing owner policies require a separate permission review' USING ERRCODE = '55000';
    END IF;
  END LOOP;
  -- 역할은 클러스터 전체 객체다. 기존 역할의 권한을 낮추거나 고쳐서 조용히 재사용하지 않는다.
  FOREACH role_name IN ARRAY ARRAY['payse_runtime', 'payse_auth_owner'] LOOP
    -- 역할 존재 여부를 조회해 새 생성과 기존 안전성 검사를 구분한다.
    SELECT oid INTO role_oid
    FROM pg_roles
    WHERE rolname = role_name;
    IF role_oid IS NULL THEN
      -- 접속·관리·RLS 우회 권한이 없는 권한 역할을 만든다. 이름은 위 고정 목록만 사용한다.
      EXECUTE format(
        'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS',
        role_name
      );
    ELSE
      -- 로그인/관리 권한이나 역할 상속·전환 경로가 있으면 적용을 거절한다.
      IF EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE oid = role_oid
          AND (
            rolcanlogin
            OR rolsuper
            OR rolcreatedb
            OR rolcreaterole
            OR rolinherit
            OR rolreplication
            OR rolbypassrls
          )
      ) OR EXISTS (
        SELECT 1
        FROM pg_auth_members
        WHERE member = role_oid
          OR (role_name = 'payse_auth_owner' AND roleid = role_oid)
      ) THEN
        RAISE EXCEPTION 'Existing auth role has incompatible attributes or membership' USING ERRCODE = '55000';
      END IF;
      -- 기존 스키마·테이블·함수 소유권을 통해 새 인증 권한이 다른 코드로 확장되지 않게 한다.
      IF EXISTS (
        SELECT 1
        FROM pg_namespace
        WHERE nspname = 'payse'
          AND nspowner = role_oid
      ) OR EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'payse'
          AND c.relowner = role_oid
      ) OR EXISTS (
        SELECT 1
        FROM pg_proc
        WHERE proowner = role_oid
      ) THEN
        RAISE EXCEPTION 'Auth role must not already own storage objects' USING ERRCODE = '55000';
      END IF;
    END IF;
  END LOOP;
  -- 기존 PUBLIC·인증 역할의 테이블 권한이 추가 노출 경로를 만들지 않는지 확인한다.
  IF EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace,
      LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) acl
    WHERE n.nspname = 'payse'
      AND c.relkind IN ('r', 'p')
      AND acl.grantee IN (
        0,
        (SELECT oid FROM pg_roles WHERE rolname = 'payse_runtime'),
        (SELECT oid FROM pg_roles WHERE rolname = 'payse_auth_owner')
      )
  ) THEN
    RAISE EXCEPTION 'Existing storage grants require a separate permission review' USING ERRCODE = '55000';
  END IF;
  -- 컬럼별 권한·새 객체의 기본 권한·스키마 CREATE 권한까지 확인해 숨은 접근 경로를 거절한다.
  IF EXISTS (
    SELECT 1
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace,
      LATERAL aclexplode(a.attacl) acl
    WHERE n.nspname = 'payse'
      AND acl.grantee IN (
        0,
        (SELECT oid FROM pg_roles WHERE rolname = 'payse_runtime'),
        (SELECT oid FROM pg_roles WHERE rolname = 'payse_auth_owner')
      )
  ) OR EXISTS (
    SELECT 1
    FROM pg_default_acl d,
      LATERAL aclexplode(d.defaclacl) acl
    WHERE d.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = current_user)
      AND d.defaclnamespace IN (
        0,
        (SELECT oid FROM pg_namespace WHERE nspname = 'payse')
      )
      AND d.defaclobjtype IN ('r', 'f')
      AND acl.grantee <> d.defaclrole
      AND NOT (d.defaclobjtype = 'f' AND acl.grantee = 0)
  ) OR EXISTS (
    SELECT 1
    FROM pg_namespace n,
      LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) acl
    WHERE n.nspname = 'payse'
      AND acl.privilege_type = 'CREATE'
      AND acl.grantee <> n.nspowner
  ) THEN
    RAISE EXCEPTION 'Existing column, default or schema grants require review' USING ERRCODE = '55000';
  END IF;
END $$;
