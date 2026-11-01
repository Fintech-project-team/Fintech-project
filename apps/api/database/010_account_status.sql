-- 2026-10-30: 기존 공통 DB의 계좌 원천 상태를 posted/unknown으로 제한한다.
-- 사용: 배포자가 기존 스키마를 확인한 뒤 psql -X -v ON_ERROR_STOP=1 -f 로 1회 실행.
-- 신규 001에는 같은 명명 제약이 있다. 신규 DB·재실행은 중복 제약 오류로 거절한다.
-- 기존 미지원 값은 변환하지 않는다. 검증 실패·중도 취소 시 제약 추가 전체를 롤백한다.
\set ON_ERROR_STOP on

BEGIN;

-- ALTER의 테이블 잠금 안에서 기존 행도 검사하여 검증과 새 쓰기 사이의 경쟁을 막는다.
ALTER TABLE payse.financial_transactions
  ADD CONSTRAINT account_entry_status_valid CHECK (
    record_kind <> 'account_entry'
    OR status IN ('posted', 'unknown')
  );

COMMIT;
