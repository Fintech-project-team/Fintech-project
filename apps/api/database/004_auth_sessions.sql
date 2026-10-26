-- 2026-10-26: 세션 생성·종료 전용 함수를 기존 인증 DB 위에 추가한다.
-- 호출: 검토한 대상 DB에서 psql -X -v ON_ERROR_STOP=1 -f 이 파일. 001→002→003 이후 한 번 적용한다.
-- 기존 사용자·금융 원천·활성 세션은 변경하지 않으며 서비스 시작 시 자동 실행하지 않는다.
\set ON_ERROR_STOP on

BEGIN;

\ir auth_sessions/preflight.sql
\ir auth_sessions/transitions.sql
\ir auth_sessions/permissions.sql

COMMIT;
