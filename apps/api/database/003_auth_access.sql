-- 2026-10-25: 인증 DB 권한·전용 함수·요청 제한 저장을 001/002 이후 한 번 적용한다.
-- 2026-10-26: 목적별 SQL 파일의 실행 순서와 트랜잭션을 관리하는 psql 진입점으로 분리한다.
-- 사용: DBA의 명시 psql -f 실행, Cluster.load의 격리 PostgreSQL 검사.
-- 금융 자료·HTTP 로그인·시드 활성화·파쇄는 실행하지 않는다.
\set ON_ERROR_STOP on

BEGIN;

-- 기존 저장 구조·역할·권한을 검토한다. 충돌하면 중단한다.
\ir auth/preflight.sql

-- 인증 저장 구조와 테이블 접근 정책을 준비한다.
\ir auth/storage.sql

-- 잠금·IP 요청·자격 조합 실패 제한 함수를 준비한다.
\ir auth/limits.sql

-- 자격 후보·활성 세션·사용자 문맥 확인 함수를 준비한다.
\ir auth/sessions.sql

-- 소유권을 확정하고 검토한 함수의 실행 권한만 연다.
\ir auth/permissions.sql

-- 모든 하위 파일이 성공한 경우에만 함께 확정한다.
COMMIT;
