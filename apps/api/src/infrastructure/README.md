# 서버 외부 연결

data 역할. PostgreSQL 저장, 준비 더미 provider, LLM adapter를 인터페이스 뒤에 둔다. 실제 금융기관·SMS·본인인증 연동은 범위 밖이다. 서버는 Java + Spring Boot이며 실제 소스는 `src/main/java/`에 둔다. 이 안내 폴더에 별도 Node 서버를 만들지 않는다. API 개발 전 [필수 규칙](../AGENTS.md)을 따른다.

[현행 기준](../../../../docs/data-contracts.md). 상세 문서는 해당 담당 영역의 `docs/`에 두고 공통 계약을 복제하지 않는다.
