-- 2026-10-29: 기존 공통 DB에 확인된 승인 취소일만 추가한다.
-- 사용: 배포자가 기존 스키마를 확인한 뒤 psql -X -v ON_ERROR_STOP=1 -f 로 1회 실행.
-- 신규 001에는 이미 포함된다. 신규 DB·재실행은 거절하며 원천 날짜를 역산하지 않는다.
\set ON_ERROR_STOP on

BEGIN;

-- 컬럼·제약 추가를 같은 트랜잭션에 묶어 중간 실패 시 모두 롤백한다.
ALTER TABLE payse.financial_transactions
  ADD COLUMN cancellation_date date;

ALTER TABLE payse.financial_transactions
  ADD CONSTRAINT cancellation_date_valid CHECK (
    cancellation_date IS NULL
    OR (record_kind = 'card_cancellation'
      AND isfinite(cancellation_date)
      AND (occurred_at IS NULL
        OR (occurred_at_basis = 'cancellation'
          AND (occurred_at AT TIME ZONE 'Asia/Seoul')::date = cancellation_date)))
  );

COMMENT ON COLUMN payse.financial_transactions.cancellation_date IS
  '확인된 승인 취소일; 시각 미확보 가능, 미상은 null';

COMMIT;
