-- 코드 비교 후보와 활성 세션·소유자 확인 함수를 정의한다.
-- 2026-10-26: 003_auth_access.sql에서 목적별로 분리. 해당 진입점의 단일 트랜잭션에서만 실행한다.
-- 순서: 4/5. 단독 실행하거나 트랜잭션 제어 BEGIN/COMMIT을 추가하지 않는다.

-- 2026-10-25: 정규화한 이름·전화번호로 서버 내부 코드 비교에 필요한 후보 0~1행을 읽는다.
-- 사용: AuthRepository.findCode. 비활성/ DISABLED 후보도 반환될 수 있으며 Java 코드 비교·세션 발급을 대신하지 않는다.
CREATE FUNCTION payse.auth_credentials(input_name text, input_phone text)
RETURNS TABLE(user_id uuid, code_verifier text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
BEGIN
  -- 내부 인증 흐름이 사용하는 트랜잭션 조건을 먼저 검사한다.
  PERFORM payse.auth_require_transaction();
  -- 이름·전화번호는 이미 계약대로 정규화된 입력이어야 하며 함수에서 임의 보정하지 않는다.
  IF input_name IS NULL
    OR input_phone IS NULL
    OR input_name COLLATE "C" !~ '^[가-힣A-Za-z]{2,20}$'
    OR input_phone COLLATE "C" !~ '^010[0-9]{8}$' THEN
    RAISE EXCEPTION 'Invalid normalized credentials' USING ERRCODE = '22023';
  END IF;
  -- 조합 UNIQUE에 따라 사용자 ID·verifier 0~1행만 반환한다. 비활성/코드 상태 판정은 후속 대조 책임이다.
  RETURN QUERY
    SELECT u.id, u.code_verifier
    FROM payse.users u
    WHERE u.name = input_name
      AND u.phone = input_phone;
END $$;

-- 2026-10-25: 토큰 digest의 활성 사용자·세션을 잠금 뒤 재확인하고 현재 트랜잭션에 소유자를 연결한다.
-- 사용: AuthRepository.authorize. 성공은 식별자 1행, 무효 토큰·종료 세션·비활성 사용자는 0행이다.
CREATE FUNCTION payse.auth_authorize(digest text)
RETURNS TABLE(user_id uuid, session_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payse, pg_temp
AS $$
DECLARE
  owner_id uuid;
BEGIN
  -- 잠금 뒤 재조회할 수 있는 트랜잭션 환경인지 먼저 검사한다.
  PERFORM payse.auth_require_transaction();
  -- 같은 연결·트랜잭션의 이전 사용자 문맥을 비워 실패 재인증으로 권한이 남지 않게 한다.
  PERFORM set_config('payse.user_id', '', true);
  -- 형식이 맞지 않는 토큰 검증값은 소유자 문맥 없이 0행으로 거절한다.
  IF digest IS NULL OR digest COLLATE "C" !~ '^sha256:[0-9a-f]{64}$' THEN
    RETURN;
  END IF;
  -- 세션에서 잠글 사용자 후보만 찾는다. 이 단계만으로 접근을 허용하지 않는다.
  SELECT s.user_id
  INTO owner_id
  FROM payse.demo_sessions s
  WHERE s.token_digest = digest;
  -- 토큰에 대응하는 세션 후보가 없으면 사용자 문맥 없이 0행을 반환한다.
  IF NOT FOUND THEN
    RETURN;
  END IF;
  -- 사용자 행을 잠가 로그아웃·비활성화·금융 처리와 실행 순서를 맞춘다.
  PERFORM u.id
  FROM payse.users u
  WHERE u.id = owner_id
  FOR UPDATE;
  -- 잠금 대기가 끝난 뒤 별도 쿼리로 계정·세션을 재확인해 먼저 커밋된 종료 상태를 반영한다.
  SELECT u.id, s.id
  INTO user_id, session_id
  FROM payse.users u
  JOIN payse.demo_sessions s ON s.user_id = u.id
  WHERE u.id = owner_id
    AND u.deactivated_at IS NULL
    AND s.token_digest = digest
    AND s.ended_at IS NULL;
  -- 해당 조회에서 후보 또는 유효한 상태가 없으면 사용자 문맥 없이 0행을 반환한다.
  IF NOT FOUND THEN
    RETURN;
  END IF;
  -- 검증된 소유자만 트랜잭션 로컬 RLS 값으로 설정한다. 커밋/롤백 뒤에는 유지되지 않는다.
  PERFORM set_config('payse.user_id', user_id::text, true);
  -- 검증된 사용자·세션 식별자를 한 행으로 반환한다. 같은 트랜잭션에서 금융 조회를 이어간다.
  RETURN NEXT;
END $$;
