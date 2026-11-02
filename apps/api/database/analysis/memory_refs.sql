-- 2026-11-01: 기존 기억은 미확인으로 남기고 신규 기억의 불변 참조·원천 지문을 저장한다.
-- 호출: 011_analysis_memory_refs.sql의 단일 트랜잭션 안에서 실행한다. 단독 실행하지 않는다.

-- 현재 분석 저장과 강제 사용자 RLS가 설치된 DB에서만 추가 이행을 허용한다.
DO $$
BEGIN
  IF to_regclass('payse.analysis_items') IS NULL
    OR to_regprocedure('payse.analysis_item_guard()') IS NULL
    OR to_regprocedure('payse.auth_authorize(text)') IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM pg_class relation
      JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
      JOIN pg_policy policy ON policy.polrelid = relation.oid
      WHERE namespace.nspname = 'payse'
        AND relation.relname = 'analysis_items'
        AND relation.relrowsecurity
        AND relation.relforcerowsecurity
        AND policy.polname = 'own_rows'
        AND policy.polcmd = '*'
        AND policy.polroles = ARRAY['payse_runtime'::regrole::oid]
    )
  THEN
    RAISE EXCEPTION 'Reviewed analysis storage and owner isolation are required'
      USING ERRCODE = '55000';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'payse.analysis_items'::regclass
      AND attname IN ('source_refs', 'source_hash')
      AND NOT attisdropped
  )
    OR to_regclass('payse.analysis_items_period') IS NOT NULL
    OR to_regprocedure('payse.analysis_source_guard()') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Analysis memory references already exist; do not reapply'
      USING ERRCODE = '55000';
  END IF;
END $$;

-- 과거 행에는 근거를 추정해 채우지 않는다. 거래명·금액·설명·로컬 계산 입력을 이 열에 복제하지 않는다.
ALTER TABLE payse.analysis_items
  ADD COLUMN source_refs uuid[],
  ADD COLUMN source_hash text,
  ADD CONSTRAINT analysis_items_source_pair CHECK (
    (source_refs IS NULL AND source_hash IS NULL)
    OR (
      source_refs IS NOT NULL
      AND source_hash IS NOT NULL
      AND cardinality(source_refs) > 0
      AND array_ndims(source_refs) = 1
      AND array_lower(source_refs, 1) = 1
      AND array_position(source_refs, NULL) IS NULL
      AND source_hash COLLATE "C" ~ '^sha256:[0-9a-f]{64}$'
    )
  );

-- 기간 조회는 해당 사용자·저장기간의 메타만 읽으며 본문을 전체 스캔하지 않는다.
CREATE INDEX analysis_items_period
  ON payse.analysis_items (user_id, stored_at, id);

-- 2026-11-01: 이미 저장한 원천 메타는 관리자 갱신에서도 교체하지 못하게 한다.
-- 사용: analysis_items BEFORE UPDATE OF source_refs, source_hash 트리거.
CREATE FUNCTION payse.analysis_source_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, payse, pg_temp
AS $$
BEGIN
  IF NEW.source_refs IS DISTINCT FROM OLD.source_refs
    OR NEW.source_hash IS DISTINCT FROM OLD.source_hash
  THEN
    RAISE EXCEPTION 'Stored analysis source references are immutable'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER analysis_source_guard
  BEFORE UPDATE OF source_refs, source_hash ON payse.analysis_items
  FOR EACH ROW EXECUTE FUNCTION payse.analysis_source_guard();

REVOKE ALL ON FUNCTION payse.analysis_source_guard()
  FROM PUBLIC, payse_runtime;

-- 런타임은 검증한 신규 기억에만 메타를 넣는다. 이미 저장한 근거를 덮어쓰는 UPDATE는 허용하지 않는다.
GRANT INSERT (source_refs, source_hash)
  ON payse.analysis_items TO payse_runtime;

REVOKE UPDATE (source_refs, source_hash)
  ON payse.analysis_items FROM PUBLIC, payse_runtime;

COMMENT ON COLUMN payse.analysis_items.source_refs IS
  '서버가 검증한 대상·근거·원거래·명시 관계의 전체 거래 ID 집합; NULL은 기존 기억의 미확보 메타';

COMMENT ON COLUMN payse.analysis_items.source_hash IS
  'source_refs의 관련 금융 원천·관계 지문; 현재 적용 가능 판정이나 로컬 features 저장을 대신하지 않음';
