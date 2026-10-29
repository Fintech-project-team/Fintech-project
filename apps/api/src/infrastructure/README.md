# 서버 외부 연결

서버는 Java + Spring Boot이며 실제 소스는 `src/main/java/`에 둔다. PostgreSQL/JPA 저장 코드는 기능별 `mapper/`, 엔티티는 `finance/entity/`, 구성은 `config/`에 둔다. [Java 패키지 안내](../../docs/spring-bootstrap.md#java-패키지)를 따른다. 이 폴더는 안내 위치이며 별도 서버·빈 인터페이스·공통 관리자를 만들지 않는다. 실제 금융기관·SMS·본인인증 연동은 범위 밖이다. API 개발 전 [필수 규칙](../AGENTS.md)을 따른다.

[현행 기준](../../../../docs/data-contracts.md). 상세 문서는 해당 담당 영역의 `docs/`에 두고 공통 계약을 복제하지 않는다.
