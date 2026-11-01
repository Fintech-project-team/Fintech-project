-- 2026-10-30: 원천 근거 유무와 독립적인 회차별 안내 닫기 기록을 만든다.
-- 호출: 009_salary_notices.sql에서 사전 검사 뒤 실행한다. 급여 계산·입금 확인을 수행하지 않는다.

-- 행의 존재 자체가 닫기 상태다. 재요청은 같은 PK에 DO NOTHING하여 최초 시각을 보존한다.
CREATE TABLE payse.salary_notice_dismissals (
  user_id uuid NOT NULL,
  pay_month text NOT NULL,
  dismissed_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  PRIMARY KEY (user_id, pay_month),
  FOREIGN KEY (user_id) REFERENCES payse.users(id) ON DELETE RESTRICT,
  CHECK (
    pay_month COLLATE "C" ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'
    AND left(pay_month, 4) <> '0000'
  ),
  CHECK (isfinite(dismissed_at))
);

COMMENT ON TABLE payse.salary_notice_dismissals IS '사용자별 명목 급여 회차의 안내 닫기 기록; 원천·입금 상태와 독립';

COMMENT ON COLUMN payse.salary_notice_dismissals.user_id IS '인증 세션에서 확인한 사용자; 사용자 전역 안내 플래그가 아님';

COMMENT ON COLUMN payse.salary_notice_dismissals.pay_month IS 'YYYY-MM 명목 급여 회차; 원천 근거 없는 회차도 저장 가능';

COMMENT ON COLUMN payse.salary_notice_dismissals.dismissed_at IS '최초 닫기 트랜잭션 시각; 재요청으로 변경하지 않음';
