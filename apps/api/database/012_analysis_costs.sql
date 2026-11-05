-- 2026-11-03: 금융 자료와 분리된 프로젝트 비용 예약·정산 장부를 추가한다.
-- 호출: psql -X -v ON_ERROR_STOP=1 -f 이 파일. 003 런타임 역할 이후 명시 적용.
-- 운영 한도·기존 사용액·단가는 관리자가 별도로 준비한다. 자동 활성화하지 않는다.
\set ON_ERROR_STOP on

BEGIN;

\ir analysis/costs.sql

COMMIT;
