-- 2026-10-30: 회차별 닫기 기록에 기존 강제 RLS와 조회·최소 INSERT 권한만 적용한다.
-- 호출: 009_salary_notices.sql 마지막 단계. 원천·금융 버전·기존 인증 권한은 변경하지 않는다.

-- 인증 함수가 설정한 트랜잭션 로컬 사용자만 자기 기록을 조회·생성할 수 있다.
ALTER TABLE payse.salary_notice_dismissals ENABLE ROW LEVEL SECURITY;

ALTER TABLE payse.salary_notice_dismissals FORCE ROW LEVEL SECURITY;

CREATE POLICY own_rows
  ON payse.salary_notice_dismissals
  USING (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid)
  WITH CHECK (user_id = NULLIF(current_setting('payse.user_id', true), '')::uuid);

-- 기본 권한을 회수한 후 시각 변경·삭제·TRUNCATE 없이 필요한 열만 연다.
REVOKE ALL ON payse.salary_notice_dismissals FROM PUBLIC, payse_runtime;

GRANT SELECT ON payse.salary_notice_dismissals TO payse_runtime;

GRANT INSERT (user_id, pay_month)
  ON payse.salary_notice_dismissals TO payse_runtime;
