-- 2026-10-30: 급여 안내 닫기 상태를 사용자·명목 회차별로 저장한다.
-- 호출: psql -X -v ON_ERROR_STOP=1 -f 이 파일. 001→002→003→004→007 이후 한 번 적용한다.
-- 008 분석 저장과 독립적이다. 기존 원천·금융 설정·버전·영수증을 변경하지 않는다.
\set ON_ERROR_STOP on

BEGIN;

\ir salary_notices/preflight.sql
\ir salary_notices/storage.sql
\ir salary_notices/permissions.sql

COMMIT;
