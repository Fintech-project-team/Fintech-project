# PAYSE API

Java 21 + Spring Boot 4.1.1 + Spring MVC/Security/JDBC + PostgreSQL로 초기화했다. API 전용 Gradle Wrapper 9.7.1을 사용하며 Node package.json은 공통 검사 연결용이다.

서버 책임은 합성 금융 데이터·확정 설정·인증/권한·저장 제약·LLM이다. 계좌 합산·U·소비 집계·시뮬레이션은 Flutter가 계산한다. 현재 구현은 프로세스 생존 확인과 인증 전 접근 차단, 선택적 DB 연결 설정이며 금융/인증 API 구현 완료가 아니다.

개발 전 [API 필수 규칙](src/AGENTS.md)과 [초기화·검사 안내](docs/spring-bootstrap.md)를 읽는다. [데이터 계약](../../docs/data-contracts.md)·기존 데이터 모델·DDL·더미는 유지한다.
