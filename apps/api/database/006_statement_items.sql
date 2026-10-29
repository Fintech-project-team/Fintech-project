-- 2026-10-29: 기존 청구-거래 관계를 독립 청구 항목 구조로 전환한다.
-- 사용: 기존 공통 구조와 005 적용 후 배포자가 psql -X -v ON_ERROR_STOP=1 -f 로 1회 실행.
-- 신규 001·재실행은 중복 컬럼으로 거절한다. 소유자/이행 권한이 필요하며 실제 금융 값을 추정하지 않는다.
\set ON_ERROR_STOP on

BEGIN;

-- 승인 취소일 이행까지 준비된 공통 스키마에서만 다음 단계를 적용한다.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'payse'
      AND table_name = 'financial_transactions'
      AND column_name = 'cancellation_date'
  ) THEN
    RAISE EXCEPTION 'Apply cancellation date migration before statement items'
      USING ERRCODE = '55000';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'payse'
      AND table_name = 'statement_items'
      AND column_name = 'id'
  ) THEN
    RAISE EXCEPTION 'Statement item identity already exists'
      USING ERRCODE = '42701';
  END IF;
END $$;

-- 열·키·원천 관계를 한 트랜잭션으로 전환하여 중간 실패를 전부 롤백한다.
ALTER TABLE payse.statement_items
  ADD COLUMN migration_id uuid,
  ADD COLUMN source_ref text,
  ADD COLUMN source_version text,
  ADD COLUMN label text,
  ADD COLUMN merchant_name text,
  ADD COLUMN purchase_date date,
  ADD COLUMN original_used_amount_krw payse.nonnegative_money,
  ADD COLUMN billed_principal_krw payse.nonnegative_money,
  ADD COLUMN fee_or_adjustment_amount_krw payse.money,
  ADD COLUMN billed_amount_krw payse.money,
  ADD COLUMN installment_months integer,
  ADD COLUMN installment_round integer;

-- 기존 ID 불변 트리거를 해제하지 않고 임시 열에 식별 매핑을 준비한다.
-- 구 복합키로 안정된 새 식별자만 생성한다. 금액·일자·회차·표시 정보는 null을 유지한다.
-- md5는 인증/암호화가 아니라 과거 관계의 결정적 식별 매핑이며 충돌은 UNIQUE로 거절한다.
UPDATE payse.statement_items item
SET migration_id = md5('payse:statement-item:' || item.user_id::text || ':' ||
             item.statement_id::text || ':' || item.transaction_id::text)::uuid,
    source_ref = 'legacy-statement-item/' ||
      (md5('payse:statement-item:' || item.user_id::text || ':' ||
           item.statement_id::text || ':' || item.transaction_id::text)::uuid)::text,
    source_version = statement.source_version
FROM payse.card_statements statement
WHERE statement.user_id = item.user_id
  AND statement.id = item.statement_id
  AND statement.card_id = item.card_id;

-- UPDATE가 쌓은 지연 저장 검사를 먼저 처리한 뒤 같은 테이블의 키를 변경한다.
SET CONSTRAINTS ALL IMMEDIATE;

-- 기존 행에 id가 없던 준비 단계를 끝내고 같은 트랜잭션 안에서 최종 열 이름을 확정한다.
ALTER TABLE payse.statement_items
  RENAME COLUMN migration_id TO id;

ALTER TABLE payse.statement_items
  DROP CONSTRAINT statement_items_pkey,
  ALTER COLUMN transaction_id DROP NOT NULL,
  ALTER COLUMN id SET NOT NULL,
  ALTER COLUMN source_ref SET NOT NULL,
  ALTER COLUMN source_version SET NOT NULL,
  ADD PRIMARY KEY (id),
  ADD UNIQUE (user_id, id),
  ADD UNIQUE (user_id, source_ref),
  ADD FOREIGN KEY (user_id, source_version) REFERENCES payse.source_contexts(user_id, source_version)
    ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  ADD CONSTRAINT statement_item_source_ref CHECK (length(btrim(source_ref)) > 0),
  ADD CONSTRAINT statement_item_source_version CHECK (length(btrim(source_version)) > 0),
  ADD CONSTRAINT statement_item_purchase_date CHECK (purchase_date IS NULL OR isfinite(purchase_date)),
  ADD CONSTRAINT statement_item_installment_months CHECK (installment_months IS NULL OR installment_months > 0),
  ADD CONSTRAINT statement_item_installment_round CHECK (installment_round IS NULL OR installment_round > 0),
  ADD CONSTRAINT statement_item_installment_order CHECK (
    installment_months IS NULL
    OR installment_round IS NULL
    OR installment_round <= installment_months
  );

-- 청구별 항목 조회와 원거래에서 청구 목록으로 역조회하는 경로를 지원한다.
CREATE INDEX statement_items_by_statement ON payse.statement_items(user_id, statement_id, id);

CREATE INDEX statement_items_by_transaction ON payse.statement_items(user_id, transaction_id, statement_id)
  WHERE transaction_id IS NOT NULL;

COMMENT ON COLUMN payse.statement_items.id IS '청구 항목의 안정된 내부 식별자; 한 구매의 여러 청구 항목을 구별';

COMMENT ON COLUMN payse.statement_items.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.statement_items.source_ref IS '기관·청구·원천 항목을 구분하는 안정된 키; 표시명이나 배열 순서로 생성 금지';

COMMENT ON COLUMN payse.statement_items.source_version IS '사용자 현재 원천 묶음 버전; 청구 항목을 별도 권위로 복사하지 않음';

COMMENT ON COLUMN payse.statement_items.statement_id IS '소유 청구서 참조; 같은 구매를 서로 다른 청구서에 연결 가능';

COMMENT ON COLUMN payse.statement_items.card_id IS '청구서·연결 거래의 같은 카드 관계를 복합 FK로 검증';

COMMENT ON COLUMN payse.statement_items.transaction_id IS '확보한 원거래 참조; 독립 청구 항목은 null, 가짜 거래 생성 금지';

COMMENT ON COLUMN payse.statement_items.label IS '청구 원천의 항목 표시명; 미상은 null';

COMMENT ON COLUMN payse.statement_items.merchant_name IS '청구 원천의 가맹점 표시명; 거래 원문을 덮어쓰지 않음';

COMMENT ON COLUMN payse.statement_items.purchase_date IS '청구 원천이 확인한 이용일; 결제일이나 회차로 역산 금지';

COMMENT ON COLUMN payse.statement_items.original_used_amount_krw IS '청구 원천이 확인한 최초 이용금액; 원거래 금액의 자동 복사 아님';

COMMENT ON COLUMN payse.statement_items.billed_principal_krw IS '해당 청구 항목의 확인된 원금; 미상은 null';

COMMENT ON COLUMN payse.statement_items.fee_or_adjustment_amount_krw IS '해당 항목의 확인된 가산 또는 음수 감산; 미상은 null';

COMMENT ON COLUMN payse.statement_items.billed_amount_krw IS '해당 항목의 확인된 최종 청구액; 환급 등 음수 허용, 합계 자동 산출 아님';

COMMENT ON COLUMN payse.statement_items.installment_months IS '해당 청구 원천에 명시된 전체 할부 개월; 미상은 null';

COMMENT ON COLUMN payse.statement_items.installment_round IS '해당 청구 원천에 명시된 회차; 거래의 현재 회차를 복사하지 않음';

COMMIT;
