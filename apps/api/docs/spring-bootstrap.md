# Spring Boot 초기화 범위와 실행

2026-10-20 사용자 결정: Java + Spring Boot. Java 21, Spring Boot 4.1.1, API 전용 Gradle 9.7.1로 고정한다. Spring BOM과 gradle.lockfile로 의존성을 관리한다. 모바일 Android Gradle과 별도다.

## 구현 범위

- `GET /internal/health/live` → `{"status":"UP"}`. 프로세스 생존만 확인하며 DB 준비·로그인·금융 기능 완료를 뜻하지 않는다.
- 그 외 경로는 401로 차단한다. 가짜 토큰·기본 계정·폼 로그인·서블릿 로그인 세션으로 우회할 수 없다. 쿠키/Basic 인증이 없고 업무 경로를 모두 차단하는 초기화에서는 CSRF 토큰 세션을 만들지 않는다. 후속 인증을 쿠키 방식으로 바꾸는 경우 CSRF 방어를 재설계해야 한다.
- 업무 API의 성공/오류 응답, 단일 데모 세션, 재확인, 조회/저장, LLM 호출은 후속 구현이다. 기존 401/403/409/422 계약은 변경하지 않는다.
- Spring JDBC와 PostgreSQL 드라이버를 준비한다. 기본 실행은 DB 없이 가능하다. `database` 프로필을 명시하면 환경변수로 실제 PostgreSQL에 연결한다.
- 기존 SQL/더미를 앱 기동 시 자동 적용하지 않는다. Flyway 마이그레이션 편입은 기존 BEGIN/COMMIT·역할/권한·이력 관리 검증과 함께 후속 작업으로 진행한다. 운영 스키마 자동 생성/수정은 없다.

## 실행과 검사

JDK 21을 준비하고 `JAVA_HOME`과 PATH를 확인한다. 기존 더미 검사에는 Python 3.10+도 필요하다(`python --version`). 저장소의 Node/npm 기준과 Flutter 준비 방식은 유지한다.

저장소 루트:

```text
node scripts/harness/run-api.mjs check
node scripts/harness/run-api.mjs start
node scripts/harness/verify-change.mjs --task docs/tasks/PAYSE-SPRING-20261020.json
```

check는 Java 컴파일·JUnit HTTP/설정 검사·운영/테스트/개발 도구의 Javadoc 검사·실행 JAR 생성·기존 Python 더미 검사를 수행한다. 실제 PostgreSQL 연결·기존 SQL의 동시성·Flutter 금융 통합을 대신하지 않는다. Gradle 첫 실행에는 공식 배포/의존성 다운로드가 필요하다.

기본 주소는 `127.0.0.1:8080`이다. 개발용 기기 연결이 필요하면 실행 환경에 PAYSE_BIND_ADDRESS/PAYSE_PORT를 지정한다. 배포 HTTPS와 네트워크 접근 제어는 배포 구성의 책임이다.

DB 연결 시에만 SPRING_PROFILES_ACTIVE=database와 PAYSE_JDBC_URL, PAYSE_DB_USER, PAYSE_DB_PASSWORD를 실행 환경에 지정한다. 비밀값은 Git에 저장하지 않는다. runtime DB 계정은 superuser/BYPASSRLS를 사용하지 않는다. 현재 연결 설정만으로 RLS 사용자 설정/역할 배포까지 완료된 것은 아니다.

## 프론트 영향

Flutter 소스·pubspec·SDK·Android/iOS·금융 계약·계산 규칙·DDL·fixture는 이 초기화에서 변경하지 않는다. Flutter만 수정하는 작업은 mobile 검사만 선택하며 API용 JDK/Gradle을 요구하지 않는다. 공통 검사기/계약을 수정하는 작업은 실제 구현이 있는 소비자를 함께 검사한다.

Java DTO와 Dart 모델은 기존 JSON 이름·날짜 정밀도·금액 단위·null/누락·버전 의미를 공유한다. 새 서버에 맞춰 프론트 모델을 바꾸지 않는다. 현재 저장소의 Flutter는 bootstrap UI이므로 실제 금융 API 호출부의 통합 완료는 아직 검증할 수 없다.

## 주석과 구조

[src/AGENTS.md](../src/AGENTS.md)는 apps/api 전체의 필수 개발 규칙이다. Java 주석 의무·자동 검사는 src/main/java·src/test/java·tools의 직접 작성한 Java 코드에 적용한다. 이름 있는 타입·메서드의 생성일·목적·사용처와 기존 메서드/DTO의 수정일·목적을 기록한다. 자동 검사는 형식 검사이며 실제 호출 관계·unknown의 허용 근거·수정 누락은 diff 리뷰 대상이다.

Spring singleton bean은 상태 없는 서비스·DB pool 등 자원 수명에만 사용한다. 계정·세션·잔액·트랜잭션을 전역 필드에 보관하지 않는다. API 업무 패키지는 실제 기능 구현 시 만들며 초기화만을 위해 빈 계층을 늘리지 않는다.

## 공식 근거

- [Spring Boot 요구사항](https://docs.spring.io/spring-boot/system-requirements.html): Java/Gradle 지원 범위.
- [Gradle 호환표](https://docs.gradle.org/current/userguide/compatibility.html): JDK 21 실행 지원.
- [Spring JDBC](https://docs.spring.io/spring-framework/reference/data-access/jdbc/core.html): JDBC 연결/자원 관리.
- [DB 초기화](https://docs.spring.io/spring-boot/how-to/data-initialization.html): 스키마 관리 수단 단일화.
- [Spring 요청 검증](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-methods/requestbody.html): 기본 400과 PAYSE 업무 검증 422의 명시적 매핑 필요.
