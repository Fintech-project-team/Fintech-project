-- PAYSE v1.0 initial design, 2026-10-19. Empty database/schema only.

-- No DROP, no role creation, no application grants. Source/settings APIs remain separate work.

BEGIN;

CREATE SCHEMA payse;

CREATE DOMAIN payse.money AS bigint CHECK (VALUE BETWEEN -9000000000000 AND 9000000000000);

CREATE DOMAIN payse.nonnegative_money AS bigint CHECK (VALUE BETWEEN 0 AND 9000000000000);

CREATE DOMAIN payse.positive_money AS bigint CHECK (VALUE BETWEEN 1 AND 9000000000000);

CREATE TABLE payse.users (
  id uuid NOT NULL,
  name text NOT NULL,
  phone text NOT NULL,
  code_verifier text NOT NULL,
  data_version bigint NOT NULL,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (name, phone),
  CHECK (data_version >= 1),
  CHECK (created_at IS NULL OR isfinite(created_at)),
  CONSTRAINT identity_name_format CHECK (name COLLATE "C" ~ '^[가-힣A-Za-z]{2,20}$'),
  CONSTRAINT identity_phone_format CHECK (phone COLLATE "C" ~ '^010[0-9]{8}$'),

  CHECK (code_verifier IS NULL OR length(btrim(code_verifier)) > 0)
);

COMMENT ON COLUMN payse.users.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.users.name IS '인증·허용 호칭의 단일 이름; 제출 원문 저장소가 아님';

COMMENT ON COLUMN payse.users.phone IS '조회 전화번호; 단독 인증 불가';

COMMENT ON COLUMN payse.users.code_verifier IS '서버 전용 코드 검증값; 준비 시드는 DISABLED로 인증 불가';

COMMENT ON COLUMN payse.users.data_version IS '원천/확정 설정 변경마다 한 트랜잭션에서 증가';

COMMENT ON COLUMN payse.users.created_at IS '사전 사용자 생성 시각';

CREATE TABLE payse.demo_sessions (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  token_digest text NOT NULL,
  issued_at timestamptz NOT NULL,
  ended_at timestamptz,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  UNIQUE (token_digest),
  CHECK (ended_at IS NULL OR ended_at >= issued_at),
  CHECK (issued_at IS NULL OR isfinite(issued_at)),
  CHECK (ended_at IS NULL OR isfinite(ended_at)),
  CHECK (token_digest IS NULL OR length(btrim(token_digest)) > 0)
);

COMMENT ON COLUMN payse.demo_sessions.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.demo_sessions.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.demo_sessions.token_digest IS '무작위 세션 토큰 검증값; 원문/PIN 저장 금지';

COMMENT ON COLUMN payse.demo_sessions.issued_at IS '실제 발급 시각';

COMMENT ON COLUMN payse.demo_sessions.ended_at IS '명시 종료 시각; null은 활성';

CREATE TABLE payse.institutions (
  code text NOT NULL,
  kind text NOT NULL,
  name text NOT NULL,
  PRIMARY KEY (code),
  CHECK (kind IN ('bank', 'card')),
  CHECK (code IS NULL OR length(btrim(code)) > 0),
  CHECK (kind IS NULL OR length(btrim(kind)) > 0),
  CHECK (name IS NULL OR length(btrim(name)) > 0)
);

COMMENT ON COLUMN payse.institutions.code IS 'PAYSE 내부 코드; 공급자 공식 코드 아님';

COMMENT ON COLUMN payse.institutions.kind IS 'bank/card 구분';

COMMENT ON COLUMN payse.institutions.name IS '표시명';

CREATE TABLE payse.source_contexts (
  user_id uuid NOT NULL,
  source_version text NOT NULL,
  schema_version text NOT NULL,
  rule_version text NOT NULL,
  as_of timestamptz NOT NULL,
  coverage jsonb NOT NULL,
  salary_evidence jsonb NOT NULL,
  occurrence_links jsonb NOT NULL,
  PRIMARY KEY (user_id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  UNIQUE (user_id, source_version),
  CHECK (jsonb_typeof(coverage) = 'array'
    AND jsonb_typeof(salary_evidence) = 'array'
    AND jsonb_typeof(occurrence_links) = 'array'),
  CHECK (as_of IS NULL OR isfinite(as_of)),
  CHECK (source_version IS NULL OR length(btrim(source_version)) > 0),
  CHECK (schema_version IS NULL OR length(btrim(schema_version)) > 0),
  CHECK (rule_version IS NULL OR length(btrim(rule_version)) > 0)
);

COMMENT ON COLUMN payse.source_contexts.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.source_contexts.source_version IS '사용자별 현재 원천 묶음 버전';

COMMENT ON COLUMN payse.source_contexts.schema_version IS '원본 데이터 형식 버전; API 응답 표현 버전과 별도';

COMMENT ON COLUMN payse.source_contexts.rule_version IS 'Flutter 계산 규칙 버전; 서버 계산을 의미하지 않음';

COMMENT ON COLUMN payse.source_contexts.as_of IS '잔액·자료의 업무 기준시각';

COMMENT ON COLUMN payse.source_contexts.coverage IS '계좌/카드별 요청/확보/누락 구간; 참조는 loader/API 검증';

COMMENT ON COLUMN payse.source_contexts.salary_evidence IS 'payMonth 명목 회차·확인 예정일·명시 거래 ID·입금 상태; 원천 근거';

COMMENT ON COLUMN payse.source_contexts.occurrence_links IS '확인된 구매/청구/회차 연결; 참조·중복은 loader/API 검증';

CREATE TABLE payse.institution_links (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  institution_code text NOT NULL,
  consented_at timestamptz NOT NULL,
  disconnected_at timestamptz,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (institution_code) REFERENCES payse.institutions(code) ON DELETE RESTRICT,
  CHECK (disconnected_at IS NULL OR disconnected_at >= consented_at),
  CHECK (consented_at IS NULL OR isfinite(consented_at)),
  CHECK (disconnected_at IS NULL OR isfinite(disconnected_at)),
  CHECK (institution_code IS NULL OR length(btrim(institution_code)) > 0)
);

COMMENT ON COLUMN payse.institution_links.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.institution_links.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.institution_links.institution_code IS '대상 기관';

COMMENT ON COLUMN payse.institution_links.consented_at IS '확정 연결 시각';

COMMENT ON COLUMN payse.institution_links.disconnected_at IS '해제 시각; null은 현재 연결';

CREATE TABLE payse.financial_accounts (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  institution_code text NOT NULL,
  source_ref text NOT NULL,
  source_version text NOT NULL,
  product_type text NOT NULL,
  product_name text NOT NULL,
  masked_number text NOT NULL,
  balance_krw payse.money NOT NULL,
  as_of timestamptz NOT NULL,
  included boolean NOT NULL,
  nickname text,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (institution_code) REFERENCES payse.institutions(code) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, source_version) REFERENCES payse.source_contexts(user_id, source_version) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (user_id, source_ref),
  CHECK (product_type IN ('demand', 'savings', 'time_deposit', 'other')),
  CHECK (as_of IS NULL OR isfinite(as_of)),
  CHECK (institution_code IS NULL OR length(btrim(institution_code)) > 0),
  CHECK (source_ref IS NULL OR length(btrim(source_ref)) > 0),
  CHECK (source_version IS NULL OR length(btrim(source_version)) > 0),
  CHECK (product_type IS NULL OR length(btrim(product_type)) > 0),
  CHECK (product_name IS NULL OR length(btrim(product_name)) > 0),
  CHECK (masked_number IS NULL OR length(btrim(masked_number)) > 0),
  CHECK (nickname IS NULL OR length(btrim(nickname)) > 0)
);

COMMENT ON COLUMN payse.financial_accounts.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.financial_accounts.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.financial_accounts.institution_code IS '은행 내부 코드';

COMMENT ON COLUMN payse.financial_accounts.source_ref IS '객체별 이름 공간을 가진 원천 키';

COMMENT ON COLUMN payse.financial_accounts.source_version IS '같은 사용자 현재 원천 묶음에 속함';

COMMENT ON COLUMN payse.financial_accounts.product_type IS 'demand/savings/time_deposit/other';

COMMENT ON COLUMN payse.financial_accounts.product_name IS '원천 상품 표시명';

COMMENT ON COLUMN payse.financial_accounts.masked_number IS '가린 번호; 전체 번호 없음';

COMMENT ON COLUMN payse.financial_accounts.balance_krw IS '원천 잔액; 음수 허용';

COMMENT ON COLUMN payse.financial_accounts.as_of IS '잔액 기준시각';

COMMENT ON COLUMN payse.financial_accounts.included IS '사용자 홈 선택; 복원 초기값 false';

COMMENT ON COLUMN payse.financial_accounts.nickname IS '사용자 별칭; null은 해제';

CREATE TABLE payse.financial_cards (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  institution_code text NOT NULL,
  source_ref text NOT NULL,
  source_version text NOT NULL,
  product_name text,
  masked_number text,
  card_type text NOT NULL,
  withdrawal_account_id uuid,
  schedule_evidence jsonb NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (institution_code) REFERENCES payse.institutions(code) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, source_version) REFERENCES payse.source_contexts(user_id, source_version) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, withdrawal_account_id) REFERENCES payse.financial_accounts(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (user_id, source_ref),
  CHECK (card_type IN ('credit', 'debit', 'unknown')),
  CHECK (jsonb_typeof(schedule_evidence) = 'array'),
  CHECK (institution_code IS NULL OR length(btrim(institution_code)) > 0),
  CHECK (source_ref IS NULL OR length(btrim(source_ref)) > 0),
  CHECK (source_version IS NULL OR length(btrim(source_version)) > 0),
  CHECK (product_name IS NULL OR length(btrim(product_name)) > 0),
  CHECK (masked_number IS NULL OR length(btrim(masked_number)) > 0),
  CHECK (card_type IS NULL OR length(btrim(card_type)) > 0)
);

COMMENT ON COLUMN payse.financial_cards.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.financial_cards.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.financial_cards.institution_code IS '카드사 내부 코드';

COMMENT ON COLUMN payse.financial_cards.source_ref IS '객체별 이름 공간을 가진 원천 키';

COMMENT ON COLUMN payse.financial_cards.source_version IS '같은 사용자 현재 원천 묶음에 속함';

COMMENT ON COLUMN payse.financial_cards.product_name IS '확보된 원천 표시명';

COMMENT ON COLUMN payse.financial_cards.masked_number IS '가린 카드 번호';

COMMENT ON COLUMN payse.financial_cards.card_type IS 'credit/debit/unknown; 미상을 신용으로 변환 금지';

COMMENT ON COLUMN payse.financial_cards.withdrawal_account_id IS '실제 출금 계좌; 미상이면 null';

COMMENT ON COLUMN payse.financial_cards.schedule_evidence IS '확인된 기간/결제일/근거; 빈 배열은 일정 미확보';

CREATE TABLE payse.transaction_references (
  user_id uuid NOT NULL,
  transaction_id uuid NOT NULL,
  resolution text NOT NULL,
  reason text,
  PRIMARY KEY (user_id, transaction_id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  CHECK ((resolution = 'resolved'
    AND reason IS NULL)
    OR (resolution = 'unavailable'
    AND reason IS NOT NULL
    AND reason IN ('outside_retention', 'not_provided', 'not_connected'))),
  CHECK (resolution IS NULL OR length(btrim(resolution)) > 0),
  CHECK (reason IS NULL OR length(btrim(reason)) > 0)
);

COMMENT ON COLUMN payse.transaction_references.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.transaction_references.transaction_id IS '자료가 없어도 보존할 안정된 원천 거래 참조';

COMMENT ON COLUMN payse.transaction_references.resolution IS 'resolved/unavailable';

COMMENT ON COLUMN payse.transaction_references.reason IS '미확보 이유; resolved는 null';

CREATE TABLE payse.financial_transactions (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  source_ref text NOT NULL,
  source_version text NOT NULL,
  account_id uuid,
  card_id uuid,
  record_kind text NOT NULL,
  amount_krw payse.nonnegative_money NOT NULL,
  direction text NOT NULL,
  status text NOT NULL,
  merchant_name text,
  description text,
  purchase_date date,
  withdrawal_date date,
  refund_date date,
  cancellation_date date,
  booking_date date,
  occurred_at timestamptz,
  occurred_at_basis text,
  reflection_reason text NOT NULL,
  original_transaction_id uuid,
  payse_transaction_type text,
  installment_current integer,
  installment_total integer,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, source_version) REFERENCES payse.source_contexts(user_id, source_version) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, account_id) REFERENCES payse.financial_accounts(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, card_id) REFERENCES payse.financial_cards(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, id) REFERENCES payse.transaction_references(user_id, transaction_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, original_transaction_id) REFERENCES payse.transaction_references(user_id, transaction_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (user_id, source_ref),
  UNIQUE (user_id, id, card_id),
  CHECK (account_id IS NOT NULL OR card_id IS NOT NULL),
  CHECK (record_kind IN ('account_entry', 'card_purchase', 'card_refund', 'card_cancellation')),
  CHECK (direction IN ('in', 'out')),
  CHECK (status IN ('approved', 'posted', 'cancelled', 'unknown')),
  -- 2026-10-30: 계좌 내역에는 확정 기록·미확인만 허용하며 카드 상태 범위는 유지한다.
  CONSTRAINT account_entry_status_valid CHECK (
    record_kind <> 'account_entry'
    OR status IN ('posted', 'unknown')
  ),
  CHECK (reflection_reason IN ('reflected', 'not_reflected', 'not_applicable', 'unknown')),
  CHECK (account_id IS NOT NULL OR reflection_reason IN ('not_applicable', 'unknown')),
  CHECK ((occurred_at IS NULL
    AND occurred_at_basis IS NULL)
    OR (occurred_at IS NOT NULL
    AND occurred_at_basis IS NOT NULL
    AND occurred_at_basis IN ('purchase', 'booking', 'withdrawal', 'refund', 'cancellation'))),
  CHECK (original_transaction_id IS NULL OR original_transaction_id <> id),
  CHECK (payse_transaction_type IS NULL
    OR payse_transaction_type IN ('expense', 'income', 'internal_transfer', 'card_payment')),
  CHECK (installment_current IS NULL OR installment_current > 0),
  CHECK (installment_total IS NULL OR installment_total > 0),
  CHECK (installment_current IS NULL
    OR installment_total IS NULL
    OR installment_current <= installment_total),
  CHECK ((record_kind = 'account_entry'
    AND account_id IS NOT NULL)
    OR (record_kind <> 'account_entry'
    AND card_id IS NOT NULL)),
  CHECK (purchase_date IS NULL OR isfinite(purchase_date)),
  CHECK (withdrawal_date IS NULL OR isfinite(withdrawal_date)),
  CHECK (refund_date IS NULL OR isfinite(refund_date)),
  CONSTRAINT cancellation_date_valid CHECK (
    cancellation_date IS NULL
    OR (record_kind = 'card_cancellation'
      AND isfinite(cancellation_date)
      AND (occurred_at IS NULL
        OR (occurred_at_basis = 'cancellation'
          AND (occurred_at AT TIME ZONE 'Asia/Seoul')::date = cancellation_date)))
  ),
  CHECK (booking_date IS NULL OR isfinite(booking_date)),
  CHECK (occurred_at IS NULL OR isfinite(occurred_at)),
  CHECK (source_ref IS NULL OR length(btrim(source_ref)) > 0),
  CHECK (source_version IS NULL OR length(btrim(source_version)) > 0),
  CHECK (record_kind IS NULL OR length(btrim(record_kind)) > 0),
  CHECK (direction IS NULL OR length(btrim(direction)) > 0),
  CHECK (status IS NULL OR length(btrim(status)) > 0),
  CHECK (merchant_name IS NULL OR length(btrim(merchant_name)) > 0),
  CHECK (description IS NULL OR length(btrim(description)) > 0),
  CHECK (occurred_at_basis IS NULL OR length(btrim(occurred_at_basis)) > 0),
  CHECK (reflection_reason IS NULL OR length(btrim(reflection_reason)) > 0),
  CHECK (payse_transaction_type IS NULL OR length(btrim(payse_transaction_type)) > 0)
);

COMMENT ON COLUMN payse.financial_transactions.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.financial_transactions.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.financial_transactions.source_ref IS '객체별 이름 공간을 가진 원천 키';

COMMENT ON COLUMN payse.financial_transactions.source_version IS '같은 사용자 현재 원천 묶음에 속함';

COMMENT ON COLUMN payse.financial_transactions.account_id IS '기장 계좌; 카드 전용 기록은 null';

COMMENT ON COLUMN payse.financial_transactions.card_id IS '관련 카드; 계좌 전용 기록은 null';

COMMENT ON COLUMN payse.financial_transactions.record_kind IS '원천 사건 종류';

COMMENT ON COLUMN payse.financial_transactions.amount_krw IS '거래 크기; 방향과 분리';

COMMENT ON COLUMN payse.financial_transactions.direction IS 'in/out; 카드 out이 현금 출금이라는 뜻 아님';

COMMENT ON COLUMN payse.financial_transactions.status IS 'approved/posted/cancelled/unknown';

COMMENT ON COLUMN payse.financial_transactions.merchant_name IS '원천 거래처';

COMMENT ON COLUMN payse.financial_transactions.description IS '원천 설명';

COMMENT ON COLUMN payse.financial_transactions.purchase_date IS '확인된 이용일';

COMMENT ON COLUMN payse.financial_transactions.withdrawal_date IS '확인된 계좌 출금일; 입금일 전용 금지';

COMMENT ON COLUMN payse.financial_transactions.refund_date IS '확인된 환불 반영일';

COMMENT ON COLUMN payse.financial_transactions.cancellation_date IS '확인된 승인 취소일; 시각 미확보 가능, 미상은 null';

COMMENT ON COLUMN payse.financial_transactions.booking_date IS '입금도 포함한 계좌 기장일';

COMMENT ON COLUMN payse.financial_transactions.occurred_at IS '확인된 실제 시각만; 날짜만 있으면 null';

COMMENT ON COLUMN payse.financial_transactions.occurred_at_basis IS '어느 사실의 시각인지; 시각 없으면 null';

COMMENT ON COLUMN payse.financial_transactions.reflection_reason IS 'reflected/not_reflected/not_applicable/unknown; boolean은 응답에서 파생';

COMMENT ON COLUMN payse.financial_transactions.original_transaction_id IS '확인된 원거래; 참조 목록으로 미확보도 보존';

COMMENT ON COLUMN payse.financial_transactions.payse_transaction_type IS '사용자 정정 분류; 원천 재적재 시 보존';

COMMENT ON COLUMN payse.financial_transactions.installment_current IS '확인된 할부 현재 회차';

COMMENT ON COLUMN payse.financial_transactions.installment_total IS '확인된 할부 총회차';

CREATE TABLE payse.card_statements (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  source_ref text NOT NULL,
  source_version text NOT NULL,
  card_id uuid NOT NULL,
  amount_krw payse.nonnegative_money NOT NULL,
  due_date date,
  period_start date,
  period_end date,
  detail_completeness text NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, source_version) REFERENCES payse.source_contexts(user_id, source_version) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, card_id) REFERENCES payse.financial_cards(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (user_id, source_ref),
  UNIQUE (user_id, id, card_id),
  CHECK (detail_completeness IN ('complete', 'partial', 'unavailable')),
  CHECK ((period_start IS NULL
    AND period_end IS NULL)
    OR (period_start IS NOT NULL
    AND period_end IS NOT NULL
    AND period_start <= period_end)),
  CHECK (due_date IS NULL OR isfinite(due_date)),
  CHECK (period_start IS NULL OR isfinite(period_start)),
  CHECK (period_end IS NULL OR isfinite(period_end)),
  CHECK (source_ref IS NULL OR length(btrim(source_ref)) > 0),
  CHECK (source_version IS NULL OR length(btrim(source_version)) > 0),
  CHECK (detail_completeness IS NULL OR length(btrim(detail_completeness)) > 0)
);

COMMENT ON COLUMN payse.card_statements.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.card_statements.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.card_statements.source_ref IS '객체별 이름 공간을 가진 원천 키';

COMMENT ON COLUMN payse.card_statements.source_version IS '같은 사용자 현재 원천 묶음에 속함';

COMMENT ON COLUMN payse.card_statements.card_id IS '해당 카드';

COMMENT ON COLUMN payse.card_statements.amount_krw IS '확인된 청구 총액';

COMMENT ON COLUMN payse.card_statements.due_date IS '확인된 결제 예정일';

COMMENT ON COLUMN payse.card_statements.period_start IS '확인된 이용기간 시작';

COMMENT ON COLUMN payse.card_statements.period_end IS '확인된 이용기간 끝; 양 끝 포함';

COMMENT ON COLUMN payse.card_statements.detail_completeness IS 'complete/partial/unavailable';

CREATE TABLE payse.statement_items (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  source_ref text NOT NULL,
  source_version text NOT NULL,
  statement_id uuid NOT NULL,
  card_id uuid NOT NULL,
  transaction_id uuid,
  label text,
  merchant_name text,
  purchase_date date,
  original_used_amount_krw payse.nonnegative_money,
  billed_principal_krw payse.nonnegative_money,
  fee_or_adjustment_amount_krw payse.money,
  billed_amount_krw payse.money,
  installment_months integer,
  installment_round integer,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  UNIQUE (user_id, source_ref),
  FOREIGN KEY (user_id, source_version) REFERENCES payse.source_contexts(user_id, source_version) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, statement_id, card_id) REFERENCES payse.card_statements(user_id, id, card_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, transaction_id, card_id) REFERENCES payse.financial_transactions(user_id, id, card_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT statement_item_source_ref CHECK (length(btrim(source_ref)) > 0),
  CONSTRAINT statement_item_source_version CHECK (length(btrim(source_version)) > 0),
  CONSTRAINT statement_item_purchase_date CHECK (purchase_date IS NULL OR isfinite(purchase_date)),
  CONSTRAINT statement_item_installment_months CHECK (installment_months IS NULL OR installment_months > 0),
  CONSTRAINT statement_item_installment_round CHECK (installment_round IS NULL OR installment_round > 0),
  CONSTRAINT statement_item_installment_order CHECK (
    installment_months IS NULL
    OR installment_round IS NULL
    OR installment_round <= installment_months
  )
);

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

CREATE TABLE payse.transaction_relations (
  user_id uuid NOT NULL,
  kind text NOT NULL,
  from_id uuid NOT NULL,
  to_id uuid NOT NULL,
  evidence_ref text NOT NULL,
  PRIMARY KEY (user_id, kind, from_id, to_id),
  FOREIGN KEY (user_id, from_id) REFERENCES payse.financial_transactions(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, to_id) REFERENCES payse.financial_transactions(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CHECK (from_id <> to_id),
  CHECK (kind IN ('card_account_pair', 'internal_transfer')),
  CHECK (kind IS NULL OR length(btrim(kind)) > 0),
  CHECK (evidence_ref IS NULL OR length(btrim(evidence_ref)) > 0)
);

COMMENT ON COLUMN payse.transaction_relations.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.transaction_relations.kind IS 'card_account_pair/internal_transfer';

COMMENT ON COLUMN payse.transaction_relations.from_id IS '근거 있는 첫 거래';

COMMENT ON COLUMN payse.transaction_relations.to_id IS '근거 있는 둘째 거래';

COMMENT ON COLUMN payse.transaction_relations.evidence_ref IS '자동 병합을 허용하는 명시 근거';

CREATE TABLE payse.user_attributes (
  user_id uuid NOT NULL,
  salary_day smallint,
  salary_amount_krw payse.nonnegative_money,
  salary_account_id uuid,
  card_plan_overrides jsonb NOT NULL,
  PRIMARY KEY (user_id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, salary_account_id) REFERENCES payse.financial_accounts(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CHECK (salary_day IS NULL OR salary_day BETWEEN 1 AND 31),
  CHECK (jsonb_typeof(card_plan_overrides) = 'array')
);

COMMENT ON COLUMN payse.user_attributes.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.user_attributes.salary_day IS '1~31 또는 미입력 null';

COMMENT ON COLUMN payse.user_attributes.salary_amount_krw IS '확정 예상 급여; 미입력을 0으로 대체 금지';

COMMENT ON COLUMN payse.user_attributes.salary_account_id IS '급여 수령 계좌; 미입력 null';

COMMENT ON COLUMN payse.user_attributes.card_plan_overrides IS 'cardId/사용자 계획 결제일; 원천 일정과 분리';

CREATE TABLE payse.recurring_plans (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  first_occurrence_month date NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  CHECK (EXTRACT(DAY FROM first_occurrence_month) = 1),
  CHECK (first_occurrence_month IS NULL OR isfinite(first_occurrence_month))
);

COMMENT ON COLUMN payse.recurring_plans.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.recurring_plans.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.recurring_plans.first_occurrence_month IS '최초 명목 월의 1일; 과거 전체 소급 생성 금지';

CREATE TABLE payse.recurring_plan_revisions (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  plan_id uuid NOT NULL,
  effective_from_month date NOT NULL,
  label text NOT NULL,
  amount_krw payse.nonnegative_money NOT NULL,
  monthly_day smallint NOT NULL,
  payment_timing text NOT NULL,
  schedule_basis text NOT NULL,
  withdrawal_account_id uuid NOT NULL,
  card_id uuid,
  status text NOT NULL,
  schedule_overrides jsonb NOT NULL,
  is_current boolean DEFAULT true NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, plan_id) REFERENCES payse.recurring_plans(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, withdrawal_account_id) REFERENCES payse.financial_accounts(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, card_id) REFERENCES payse.financial_cards(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (user_id, id, plan_id),
  CHECK (EXTRACT(DAY FROM effective_from_month) = 1),
  CHECK (monthly_day BETWEEN 1 AND 31),
  CHECK (status IN ('active', 'cancelled')),
  CHECK ((payment_timing = 'immediate'
    AND schedule_basis = 'withdrawal'
    AND card_id IS NULL)
    OR (payment_timing = 'card_bill'
    AND schedule_basis IN ('purchase', 'withdrawal')
    AND card_id IS NOT NULL)),
  CHECK (jsonb_typeof(schedule_overrides) = 'array'),
  CHECK (effective_from_month IS NULL OR isfinite(effective_from_month)),
  CHECK (label IS NULL OR length(btrim(label)) > 0),
  CHECK (payment_timing IS NULL OR length(btrim(payment_timing)) > 0),
  CHECK (schedule_basis IS NULL OR length(btrim(schedule_basis)) > 0),
  CHECK (status IS NULL OR length(btrim(status)) > 0)
);

COMMENT ON COLUMN payse.recurring_plan_revisions.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.recurring_plan_revisions.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.recurring_plan_revisions.plan_id IS '불변 계획 ID';

COMMENT ON COLUMN payse.recurring_plan_revisions.effective_from_month IS '적용 시작 명목 월의 1일';

COMMENT ON COLUMN payse.recurring_plan_revisions.label IS '사용자 확인 명칭';

COMMENT ON COLUMN payse.recurring_plan_revisions.amount_krw IS '사용자 확인 금액';

COMMENT ON COLUMN payse.recurring_plan_revisions.monthly_day IS '원래 1~31일; 말일 보정으로 덮어쓰지 않음';

COMMENT ON COLUMN payse.recurring_plan_revisions.payment_timing IS 'immediate/card_bill';

COMMENT ON COLUMN payse.recurring_plan_revisions.schedule_basis IS 'withdrawal/purchase';

COMMENT ON COLUMN payse.recurring_plan_revisions.withdrawal_account_id IS '확정 출금 계좌';

COMMENT ON COLUMN payse.recurring_plan_revisions.card_id IS 'card_bill이면 필수';

COMMENT ON COLUMN payse.recurring_plan_revisions.status IS 'active/cancelled';

COMMENT ON COLUMN payse.recurring_plan_revisions.schedule_overrides IS '확인된 개별 일정; 명목 월별 최대 1개';

COMMENT ON COLUMN payse.recurring_plan_revisions.is_current IS '같은 적용 시작 월의 현재 권위 버전; 이전 버전은 기존 회차 참조용으로 유지';

CREATE TABLE payse.obligations (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  label text NOT NULL,
  withdrawal_account_id uuid NOT NULL,
  amount_krw payse.nonnegative_money NOT NULL,
  due_date date NOT NULL,
  status text NOT NULL,
  statement_id uuid,
  plan_id uuid,
  plan_revision_id uuid,
  occurrence_month date,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, withdrawal_account_id) REFERENCES payse.financial_accounts(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, statement_id) REFERENCES payse.card_statements(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, plan_revision_id, plan_id) REFERENCES payse.recurring_plan_revisions(user_id, id, plan_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CHECK (status IN ('active', 'cancelled')),
  CHECK ((plan_id IS NULL
    AND plan_revision_id IS NULL
    AND occurrence_month IS NULL)
    OR (plan_id IS NOT NULL
    AND plan_revision_id IS NOT NULL
    AND occurrence_month IS NOT NULL
    AND EXTRACT(DAY FROM occurrence_month) = 1)),
  CHECK (statement_id IS NULL OR plan_id IS NULL),
  UNIQUE (user_id, plan_id, occurrence_month),
  CHECK (due_date IS NULL OR isfinite(due_date)),
  CHECK (occurrence_month IS NULL OR isfinite(occurrence_month)),
  CHECK (label IS NULL OR length(btrim(label)) > 0),
  CHECK (status IS NULL OR length(btrim(status)) > 0)
);

COMMENT ON COLUMN payse.obligations.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.obligations.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.obligations.label IS '사용자 확인 예정 지출명';

COMMENT ON COLUMN payse.obligations.withdrawal_account_id IS '확정 출금 계좌';

COMMENT ON COLUMN payse.obligations.amount_krw IS '의무 전체 금액; 잔여액은 정산에서 로컬 산출';

COMMENT ON COLUMN payse.obligations.due_date IS '확정 예정일';

COMMENT ON COLUMN payse.obligations.status IS 'active/cancelled';

COMMENT ON COLUMN payse.obligations.statement_id IS '청구 대표 의무이면 해당 청구';

COMMENT ON COLUMN payse.obligations.plan_id IS '직접 현금 반복 회차의 계획';

COMMENT ON COLUMN payse.obligations.plan_revision_id IS '해당 회차 생성 근거 버전; 이후 변경에 고정';

COMMENT ON COLUMN payse.obligations.occurrence_month IS '명목 회차월 1일; 날짜 이동에도 키 불변';

CREATE TABLE payse.occurrence_overrides (
  user_id uuid NOT NULL,
  plan_id uuid NOT NULL,
  occurrence_month date NOT NULL,
  plan_revision_id uuid NOT NULL,
  amount_krw payse.nonnegative_money NOT NULL,
  due_date date NOT NULL,
  withdrawal_account_id uuid NOT NULL,
  status text NOT NULL,
  PRIMARY KEY (user_id, plan_id, occurrence_month),
  FOREIGN KEY (user_id, plan_revision_id, plan_id) REFERENCES payse.recurring_plan_revisions(user_id, id, plan_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, withdrawal_account_id) REFERENCES payse.financial_accounts(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CHECK (EXTRACT(DAY FROM occurrence_month) = 1),
  CHECK (status IN ('active', 'cancelled')),
  CHECK (occurrence_month IS NULL OR isfinite(occurrence_month)),
  CHECK (due_date IS NULL OR isfinite(due_date)),
  CHECK (status IS NULL OR length(btrim(status)) > 0)
);

COMMENT ON COLUMN payse.occurrence_overrides.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.occurrence_overrides.plan_id IS '반복 계획';

COMMENT ON COLUMN payse.occurrence_overrides.occurrence_month IS '명목 회차월 1일';

COMMENT ON COLUMN payse.occurrence_overrides.plan_revision_id IS '수정 당시 회차 근거 버전';

COMMENT ON COLUMN payse.occurrence_overrides.amount_krw IS '사용자가 확정한 해당 회차 금액';

COMMENT ON COLUMN payse.occurrence_overrides.due_date IS '확정 출금 예정일';

COMMENT ON COLUMN payse.occurrence_overrides.withdrawal_account_id IS '확정 출금 계좌';

COMMENT ON COLUMN payse.occurrence_overrides.status IS 'active/cancelled';

CREATE TABLE payse.recurring_decisions (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  candidate_key text NOT NULL,
  rule_version text NOT NULL,
  source_version text NOT NULL,
  evidence_refs jsonb NOT NULL,
  normalized_name text NOT NULL,
  decision text NOT NULL,
  plan_id uuid,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, plan_id) REFERENCES payse.recurring_plans(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (user_id, candidate_key, rule_version),
  CHECK ((decision = 'approved' AND plan_id IS NOT NULL) OR (decision = 'excluded' AND plan_id IS NULL)),
  CHECK (jsonb_typeof(evidence_refs) = 'array'),
  CHECK (candidate_key IS NULL OR length(btrim(candidate_key)) > 0),
  CHECK (rule_version IS NULL OR length(btrim(rule_version)) > 0),
  CHECK (source_version IS NULL OR length(btrim(source_version)) > 0),
  CHECK (normalized_name IS NULL OR length(btrim(normalized_name)) > 0),
  CHECK (decision IS NULL OR length(btrim(decision)) > 0)
);

COMMENT ON COLUMN payse.recurring_decisions.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.recurring_decisions.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.recurring_decisions.candidate_key IS '같은 근거 집합+규칙의 후보 키';

COMMENT ON COLUMN payse.recurring_decisions.rule_version IS '후보 계산 규칙';

COMMENT ON COLUMN payse.recurring_decisions.source_version IS '승인 당시 원천 버전; 갱신 후에도 이력 유지';

COMMENT ON COLUMN payse.recurring_decisions.evidence_refs IS '근거 거래 ID 배열; 존재·소유권은 서비스 검사';

COMMENT ON COLUMN payse.recurring_decisions.normalized_name IS '확인한 이름';

COMMENT ON COLUMN payse.recurring_decisions.decision IS 'approved/excluded';

COMMENT ON COLUMN payse.recurring_decisions.plan_id IS 'approved는 계획 필수, excluded는 null';

CREATE TABLE payse.settlement_links (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  obligation_id uuid NOT NULL,
  transaction_id uuid NOT NULL,
  allocated_krw payse.positive_money NOT NULL,
  method text NOT NULL,
  evidence jsonb NOT NULL,
  invalidated_at timestamptz,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, obligation_id) REFERENCES payse.obligations(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, transaction_id) REFERENCES payse.financial_transactions(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CHECK (method IN ('automatic', 'manual')),
  CHECK (jsonb_typeof(evidence) = 'array' AND jsonb_array_length(evidence) > 0),
  CHECK (invalidated_at IS NULL OR isfinite(invalidated_at)),
  CHECK (method IS NULL OR length(btrim(method)) > 0)
);

COMMENT ON COLUMN payse.settlement_links.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.settlement_links.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.settlement_links.obligation_id IS '정산 대상 의무';

COMMENT ON COLUMN payse.settlement_links.transaction_id IS '실제 출금 근거';

COMMENT ON COLUMN payse.settlement_links.allocated_krw IS '이 연결에 배정된 지급액';

COMMENT ON COLUMN payse.settlement_links.method IS 'automatic/manual';

COMMENT ON COLUMN payse.settlement_links.evidence IS '명시 매핑 또는 사용자 확정 근거';

COMMENT ON COLUMN payse.settlement_links.invalidated_at IS '정정으로 무효화한 시각';

CREATE TABLE payse.reserves (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  account_id uuid NOT NULL,
  label text NOT NULL,
  amount_krw payse.nonnegative_money NOT NULL,
  cancelled_at timestamptz,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, account_id) REFERENCES payse.financial_accounts(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CHECK (cancelled_at IS NULL OR isfinite(cancelled_at)),
  CHECK (label IS NULL OR length(btrim(label)) > 0)
);

COMMENT ON COLUMN payse.reserves.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.reserves.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.reserves.account_id IS '보호 금액이 속한 계좌';

COMMENT ON COLUMN payse.reserves.label IS '사용자 명칭';

COMMENT ON COLUMN payse.reserves.amount_krw IS '해제를 반영한 현재 R; 원천 잔액 하락으로 자동 축소 금지';

COMMENT ON COLUMN payse.reserves.cancelled_at IS '명시 취소 시각';

CREATE TABLE payse.reserve_allocations (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  reserve_id uuid NOT NULL,
  obligation_id uuid NOT NULL,
  amount_krw payse.positive_money NOT NULL,
  released_krw payse.nonnegative_money NOT NULL,
  release_evidence jsonb NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  FOREIGN KEY (user_id, reserve_id) REFERENCES payse.reserves(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (user_id, obligation_id) REFERENCES payse.obligations(user_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CHECK (released_krw <= amount_krw),
  CHECK (jsonb_typeof(release_evidence) = 'array')
);

COMMENT ON COLUMN payse.reserve_allocations.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.reserve_allocations.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.reserve_allocations.reserve_id IS '보호 설정';

COMMENT ON COLUMN payse.reserve_allocations.obligation_id IS '충당할 의무';

COMMENT ON COLUMN payse.reserve_allocations.amount_krw IS '지급 해제 누계를 포함한 현재 유효 총 배정액; 최초값은 변경 이력';

COMMENT ON COLUMN payse.reserve_allocations.released_krw IS '근거가 있는 해제 누계';

COMMENT ON COLUMN payse.reserve_allocations.release_evidence IS '정산 링크/해제액/정정 영수증; 참조·합계는 서비스 검증';

CREATE TABLE payse.write_receipts (
  id uuid NOT NULL,
  user_id uuid NOT NULL,
  operation_key text NOT NULL,
  request_digest text NOT NULL,
  action text NOT NULL,
  changed_refs jsonb NOT NULL,
  before_after jsonb NOT NULL,
  result_version bigint NOT NULL,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  UNIQUE (user_id, operation_key),
  CHECK (result_version >= 1),
  CHECK (jsonb_typeof(changed_refs) = 'array' AND jsonb_typeof(before_after) = 'object'),
  CHECK (created_at IS NULL OR isfinite(created_at)),
  CHECK (operation_key IS NULL OR length(btrim(operation_key)) > 0),
  CHECK (request_digest IS NULL OR length(btrim(request_digest)) > 0),
  CHECK (action IS NULL OR length(btrim(action)) > 0)
);

COMMENT ON COLUMN payse.write_receipts.id IS '안정된 내부 식별자; 원천 버전·날짜 변경에도 유지';

COMMENT ON COLUMN payse.write_receipts.user_id IS '인증 세션에서 정한 소유자; 다른 사용자 참조 차단';

COMMENT ON COLUMN payse.write_receipts.operation_key IS '사용자별 재시도 키';

COMMENT ON COLUMN payse.write_receipts.request_digest IS '허용된 설정 요청의 canonical digest; 인증 원문 제외';

COMMENT ON COLUMN payse.write_receipts.action IS '확정 쓰기 작업명';

COMMENT ON COLUMN payse.write_receipts.changed_refs IS '변경된 설정/관계 참조';

COMMENT ON COLUMN payse.write_receipts.before_after IS '정정에 필요한 변경 필드만; 가상 시뮬레이션 제외';

COMMENT ON COLUMN payse.write_receipts.result_version IS '커밋 결과 dataVersion';

COMMENT ON COLUMN payse.write_receipts.created_at IS '커밋 기록 시각';

CREATE UNIQUE INDEX current_plan_revision_per_month ON payse.recurring_plan_revisions(user_id, plan_id, effective_from_month)
WHERE is_current;

CREATE UNIQUE INDEX active_session_per_user ON payse.demo_sessions(user_id)
WHERE ended_at IS NULL;

CREATE UNIQUE INDEX active_institution_per_user ON payse.institution_links(user_id, institution_code)
WHERE disconnected_at IS NULL;

CREATE UNIQUE INDEX active_statement_obligation ON payse.obligations(user_id, statement_id)
WHERE statement_id IS NOT NULL AND status = 'active';

CREATE UNIQUE INDEX active_settlement_pair ON payse.settlement_links(user_id, obligation_id, transaction_id)
WHERE invalidated_at IS NULL;

-- 청구별 항목 조회와 원거래에서 청구 목록으로 역조회하는 경로를 지원한다.
CREATE INDEX statement_items_by_statement ON payse.statement_items(user_id, statement_id, id);

CREATE INDEX statement_items_by_transaction ON payse.statement_items(user_id, transaction_id, statement_id)
  WHERE transaction_id IS NOT NULL;

CREATE INDEX transactions_by_account_date ON payse.financial_transactions(user_id, account_id, booking_date, id);

CREATE INDEX transactions_by_card_date ON payse.financial_transactions(user_id, card_id, purchase_date, id);

CREATE INDEX obligations_by_due ON payse.obligations(user_id, due_date, id);

CREATE INDEX settlements_by_transaction ON payse.settlement_links(user_id, transaction_id)
WHERE invalidated_at IS NULL;

CREATE INDEX allocations_by_obligation ON payse.reserve_allocations(user_id, obligation_id);

CREATE INDEX reserves_by_account ON payse.reserves(user_id, account_id)
WHERE cancelled_at IS NULL;

ALTER TABLE payse.users ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.users FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.users
  USING (id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.demo_sessions ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.demo_sessions FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.demo_sessions
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.source_contexts ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.source_contexts FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.source_contexts
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.institution_links ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.institution_links FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.institution_links
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.financial_accounts ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.financial_accounts FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.financial_accounts
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.financial_cards ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.financial_cards FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.financial_cards
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.transaction_references ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.transaction_references FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.transaction_references
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.financial_transactions ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.financial_transactions FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.financial_transactions
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.card_statements ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.card_statements FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.card_statements
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.statement_items ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.statement_items FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.statement_items
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.transaction_relations ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.transaction_relations FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.transaction_relations
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.user_attributes ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.user_attributes FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.user_attributes
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.recurring_plans ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.recurring_plans FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.recurring_plans
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.recurring_plan_revisions ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.recurring_plan_revisions FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.recurring_plan_revisions
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.obligations ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.obligations FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.obligations
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.occurrence_overrides ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.occurrence_overrides FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.occurrence_overrides
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.recurring_decisions ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.recurring_decisions FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.recurring_decisions
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.settlement_links ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.settlement_links FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.settlement_links
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.reserves ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.reserves FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.reserves
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.reserve_allocations ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.reserve_allocations FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.reserve_allocations
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

ALTER TABLE payse.write_receipts ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.write_receipts FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.write_receipts
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);




COMMIT;
