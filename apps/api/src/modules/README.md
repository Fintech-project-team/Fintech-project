# 서버 모듈 경계

실제 Java 기능은 `src/main/java/com/payse/api/auth/`와 `finance/`에 두고, 기능 안에서 역할을 구분한다. 이 폴더는 안내 문서 위치이며 별도 소스 루트가 아니다. 파일 배치는 [Java 패키지 안내](../../docs/spring-bootstrap.md#java-패키지)를 따른다. 금융 수치 엔진을 서버에 복제하지 않는다.

[현행 기준](../../../../docs/app-architecture.md). 상세 문서는 해당 담당 영역의 `docs/`에 두고 공통 계약을 복제하지 않는다.
