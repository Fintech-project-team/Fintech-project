-- 2026-11-01: 관리용 기억 목록의 현재 공개 권한을 확인할 최소 원천 메타를 추가한다.
-- 호출: psql -X -v ON_ERROR_STOP=1 -f 이 파일. 008 분석 저장 이후 한 번 적용한다.
-- 기존 기억 본문·최초 저장일·금융 원천·인증 키·RLS는 유지한다. 자동 폐기와 비용 장부는 추가하지 않는다.
\set ON_ERROR_STOP on

BEGIN;

\ir analysis/memory_refs.sql

COMMIT;
