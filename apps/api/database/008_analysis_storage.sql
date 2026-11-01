-- 2026-11-01: 분석 접수·시도·개별 암호화 기억·삭제 차단을 금융 저장소와 분리한다.
-- 호출: psql -X -v ON_ERROR_STOP=1 -f 이 파일. 001→002→003→004→007 이후 한 번 적용한다.
-- 009 급여 안내와 독립적이다. 기존 금융 원천·설정·버전·인증 테이블/함수 권한은 유지한다.
-- 세션 종료 시 분석 대기 취소에 필요한 분석 테이블 열 권한만 인증 역할에 추가한다.
-- 비용 장부·유료 실행은 이 이행의 구현 범위가 아니다. 비용 0원으로 간주하지 않는다.
\set ON_ERROR_STOP on

BEGIN;

\ir analysis/preflight.sql
\ir analysis/storage.sql
\ir analysis/permissions.sql

COMMIT;
