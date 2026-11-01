# Spring Boot 초기화 범위와 실행

서버는 Java + Spring Boot를 사용한다. Java 21, Spring Boot 4.1.1, API 전용 Gradle 9.7.1로 고정한다. Spring BOM과 gradle.lockfile로 의존성을 관리한다. 모바일 Android Gradle과 별도다.

## 구현 범위

- `GET /internal/health/live` → `{"status":"UP"}`. 프로세스 생존만 확인하며 DB 준비·로그인·금융 기능 완료를 뜻하지 않는다.
- 기본 실행은 그 외 경로를 차단한다. `database`+`auth` 및 필수 설정이 준비되면 로그인·재확인·로그아웃 세 경로만 허용한다. 인증은 Bearer와 서비스의 DB 검증을 사용하며 기본 계정·폼 로그인·쿠키/Basic 세션을 만들지 않는다. 후속 쿠키 인증 도입 시 CSRF 방어를 재설계한다.
- 인증 HTTP·AuthService·DB 전이·제한은 [인증 DB](auth-database.md)를 따른다. 금융 조회·설정 저장은 `database,auth,finance` 프로필에서 제공하며 [금융 API 인계](history/2026-10-29-financial-api-handoff.md)를 따른다. 탈퇴·LLM HTTP는 별도 후속이다. 이 PC의 단계별 준비는 [Windows 서버 가이드](local-server-guide.md)를 따르며 코드 구현을 외부 HTTPS 배포 완료로 해석하지 않는다.
- Spring Data JPA·Hibernate와 PostgreSQL 드라이버를 준비한다. 기본 실행은 DB 없이 가능하다. `database` 프로필을 명시하면 환경변수로 실제 PostgreSQL에 연결한다. JPA는 SQL 기반 인증과 복잡한 조회를 native SQL로 유지하고 사용자 설정을 엔티티로 저장한다.
- 기존 SQL/더미를 앱 기동 시 자동 적용하지 않는다. Flyway 마이그레이션 편입은 기존 BEGIN/COMMIT·역할/권한·이력 관리 검증과 함께 후속 작업으로 진행한다. 운영 스키마 자동 생성/수정은 없다.

JPA 구성은 `JpaConfiguration`이 담당한다. 자동 DDL·OSIV·2차/쿼리 캐시는 비활성화하며 공개 응답에 엔티티를 직접 반환하지 않는다. 엔티티의 원천·소유자 필드는 수정하지 않고 변경된 설정 열만 UPDATE한다. 저장·검증 사이에는 필요한 flush를 명시하며 사용자 버전은 기존 원자 SQL로 변경한다. JPA `@Version`으로 공개 dataVersion 계약을 대체하지 않는다. 상세 전환 근거는 [JPA 인계](history/2026-10-29-jpa-handoff.md)에 있다.

## 실행과 검사

JDK 21을 준비하고 `JAVA_HOME`과 PATH를 확인한다. 기존 더미 검사에는 Python 3.10+도 필요하다(`python --version`). 저장소의 Node/npm 기준과 Flutter 준비 방식은 유지한다.

저장소 루트:

```text
node scripts/harness/run-api.mjs check
node scripts/harness/run-api.mjs start
node scripts/harness/verify-change.mjs --task "docs/tasks/<작업ID>.json"
```

check는 Java 컴파일·JUnit HTTP/설정 검사·운영/테스트/개발 도구의 Javadoc 검사·실행 JAR 생성·기존 Python 더미 검사를 수행한다. 아래 테스트 DB 설정이 있으면 PostgreSQL 연결·트랜잭션 검사도 실행한다. 기존 SQL의 동시성·인증·Flutter 금융 통합을 대신하지 않는다. Gradle 첫 실행에는 공식 배포/의존성 다운로드가 필요하다.

기본 주소는 `127.0.0.1:8080`이다. 개발용 기기 연결이 필요하면 실행 환경에 PAYSE_BIND_ADDRESS/PAYSE_PORT를 지정한다. 배포 HTTPS와 네트워크 접근 제어는 배포 구성의 책임이다.

### DB 연결 설정

DB 연결 시에만 `SPRING_PROFILES_ACTIVE=database`와 아래 설정을 실행 환경에 지정한다. 프로필이 비활성이면 DB 설정을 요구하지 않는다. `database` 프로필은 아래 값을 연결 전에 검증하며 누락·빈 값·잘못된 타입·범위를 운영 기본값으로 대체하지 않는다.

| 설정                             | 형식·범위                                                                                |
| -------------------------------- | ---------------------------------------------------------------------------------------- |
| `PAYSE_JDBC_URL`                 | 비어 있지 않은 `jdbc:postgresql:` URL                                                    |
| `PAYSE_DB_USER`                  | 비어 있지 않은 DB 연결 사용자                                                            |
| `PAYSE_DB_PASSWORD`              | 비어 있지 않은 DB 비밀번호; 원문을 정규화하지 않음                                       |
| `PAYSE_DB_MAX_POOL_SIZE`         | ASCII 십진 정수, 1~2,147,483,647. 실제 운영값은 DB 연결 예산에 맞춰 지정                 |
| `PAYSE_DB_CONNECTION_TIMEOUT_MS` | 연결 획득 대기시간(ms), ASCII 십진 정수, 검증 대기시간보다 크고 2,147,483,647 이하       |
| `PAYSE_DB_VALIDATION_TIMEOUT_MS` | 연결 유효성 검사 대기시간(ms), ASCII 십진 정수, 250 이상이며 연결 획득 대기시간보다 작음 |

숫자 설정은 부호·공백·소수·비ASCII 숫자를 거절한다. 상한은 이 설정 모델의 Java `int` 표현 범위이며 권장 풀 크기나 운영 대기시간이 아니다. HikariCP 7.0.2의 250ms 하한과 `validationTimeout < connectionTimeout` 조건을 적용한다. 기존 `initializationFailTimeout=1ms`는 유지하며, 전체 시작 시간의 상한이 1ms라는 뜻은 아니다. 연결 전 직접 검증에서 발생시키는 오류에는 입력값·파싱 원인을 포함하지 않는다. JDBC URL·자격이 담긴 설정 객체를 직렬화하거나 로그에 출력하지 않는다.

비밀값은 Git·명령 이력·보고서에 저장하지 않는다. runtime DB 계정은 superuser/BYPASSRLS를 사용하지 않는다. 연결 설정만으로 인증, RLS 사용자 설정, 역할 배포가 완료되는 것은 아니다. 스키마·시드 자동 적용은 하지 않는다.

### PostgreSQL 연결·트랜잭션 검사

운영 DB와 분리한 PostgreSQL 및 `CONNECT`·`TEMPORARY` 권한이 있는 비관리자 테스트 계정을 준비한다. 테스트 실행 환경에 `PAYSE_TEST_JDBC_URL`, `PAYSE_TEST_DB_USER`, `PAYSE_TEST_DB_PASSWORD`를 제공한 뒤 저장소 루트에서 `node scripts/harness/run-api.mjs check`를 실행한다. 운영용 `PAYSE_JDBC_URL`·자격을 테스트 값으로 자동 복사하지 않는다.

- 세 설정이 모두 없으면 `PostgresTransactionTest`는 **SKIPPED**이며 실제 DB 검증 통과로 보고하지 않는다. 일부만 있거나 빈 값이면 실패한다.
- 실제 역할이 superuser 또는 BYPASSRLS이면 실패한다. DB 연결 실패도 건너뛰지 않는다.
- 테스트가 소유한 임시 테이블만 사용한다. 커밋된 행 유지·명시적 롤백 및 UNIQUE 위반으로 실패한 트랜잭션의 행 취소, 같은 `pg_backend_pid()` 연결 재사용, 커밋·롤백 뒤 transaction-local `payse.user_id` 제거를 확인한다. 임시 테이블은 연결 종료와 함께 사라진다.
- 풀 크기 1과 테스트 대기시간은 같은 물리 연결 재사용을 확인하기 위한 테스트 입력이며 운영 기본값이 아니다. 사용자 ID는 검사 준비 때 생성해 SQL 인자로 바인딩한다.
- 이는 JDBC·트랜잭션 문맥의 검사다. 토큰 인증·사용자 RLS 정책·세션 동시성·금융 API의 실제 권한 검증은 포함하지 않는다.

## 프론트 영향

API 초기화와 Flutter의 SDK·플랫폼·계산 책임을 분리한다. Flutter만 수정하는 작업은 mobile 검사만 선택하며 API용 JDK/Gradle을 요구하지 않는다. 공통 검사기/계약을 수정하는 작업은 실제 구현이 있는 소비자를 함께 검사한다.

Java DTO와 Dart 모델은 기존 JSON 이름·날짜 정밀도·금액 단위·null/누락·버전 의미를 공유한다. 새 서버에 맞춰 프론트 모델을 바꾸지 않는다. 현재 Flutter에는 인증 화면·FakeRepository·탭 골격이 있다. [모바일 구현 경계](../../mobile/docs/fake-repository.md)를 확인하며 준비된 더미를 읽는 동작을 실제 금융 API 통합 완료로 표시하지 않는다.

## 주석과 구조

공통 코드 구조·설정·주석은 [CODE_SPEC](../../../docs/harness/CODE_SPEC.md), API 적용 범위·필수 Java 주석은 [src/AGENTS.md](../src/AGENTS.md)를 따른다. 초기화 안내에서 같은 규칙을 별도로 정의하지 않는다.

객체 수명·생성자 주입·가변 전역 상태 제한은 [앱 구조](../../../docs/app-architecture.md)를 따른다. 실제 기능의 책임·입출력·권한·실패·검사는 [문서 작성 기준](../../../docs/development-notes.md)에 따라 기존 API 상세를 보완한다. bootstrap만을 위해 빈 업무 계층을 생성하지 않는다.

### Java 패키지

실제 소스는 `src/main/java/com/payse/api/`에 둔다. 기능별로 나누고 그 안에 `controller/service/mapper`를 기본으로 둔다. 클래스가 없는 계층은 빈 폴더·위임 클래스·인터페이스로 만들지 않는다. `src/test/java/com/payse/api/`도 검사 대상 패키지를 따른다.

| 경로                                                            | 책임                                                                                       |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `config/`                                                       | Spring 보안·DB·JPA·암호 설정과 bean 생성                                                   |
| `auth/controller/`, `finance/controller/`, `health/controller/` | HTTP 경로·본문/헤더 파싱·상태 코드/응답 변환                                               |
| `auth/service/`, `finance/service/`                             | 업무 실행 순서·트랜잭션 호출, 공개 응답·페이지 조립, cursor·요청 지문                      |
| `auth/mapper/`, `finance/mapper/`                               | 기존 JPA 기반 DB 조회·저장·SQL 함수 호출·권한·제약 확인                                    |
| `auth/dto/`                                                     | 미검증 입력 AuthInput, 내부 결과 AuthResult, 공개 응답 AuthResponse, 내부 DB 결과 AuthRows |
| `finance/dto/`                                                  | 계층 간 전달용 PageSlice·StoredReceipt·WriteChange. 공개 HTTP DTO와 구분                   |
| `health/dto/`                                                   | 생존 확인 응답 HealthResponse                                                              |
| `auth/vo/`                                                      | 검증된 자격 AuthCredentials, 토큰·검증값 쌍 IssuedToken                                    |
| `finance/vo/`                                                   | 원거래 값 OriginalTransaction, 거래 연결 TransactionLink와 상태 OriginalState              |
| `finance/entity/`                                               | 기존 테이블에 매핑되는 JPA 엔티티와 소유자 계약                                            |
| `auth/crypto/`                                                  | 토큰·코드 암호 연산과 비밀 키 접근                                                         |
| `finance/validation/`                                           | service와 mapper가 공유하는 금융 입력 형식·허용 필드·단위 검증                             |
| `auth/error/`, `finance/error/`                                 | 기능의 입력·저장·업무 오류                                                                 |

기본 호출 흐름은 `controller → service → mapper`다. 여기서 mapper는 기존 JPA DB 접근 계층의 폴더명이며 MyBatis·매핑 XML·새 ORM을 도입하지 않는다. 기존 Repository 클래스명과 Spring bean 이름은 유지한다. DTO/VO/entity의 이름 때문에 새 API 필드나 테이블을 추가하지 않는다.

DTO는 데이터 전달용이며 외부 응답인지 내부 전달인지 주석으로 구분한다. `AuthInput`은 미검증 상태, `AuthCredentials`는 검증된 값이므로 합치지 않는다. `AuthResult`와 공개 `AuthResponse`도 필드·역할이 달라 유지한다. `StoredReceipt`의 감사 자료와 `AuthRows`의 verifier는 HTTP에 직접 반환하지 않는다. 가변 JSON 노드를 담는 금융 DTO를 불변 VO라고 취급하지 않는다.

VO는 기존 값·검증·민감 정보의 문자열 숨김을 유지한다. JPA entity는 DB 매핑 전용이며 응답으로 직접 직렬화하지 않는다. `AuthSecrets`는 비밀 키 접근자를 공개하지 않도록 crypto에 유지한다. `FinancialService.WriteResult`·`FinancialProjection.Context`·`WriteStore.Journal`처럼 한 처리 내부의 작업 상태는 외부 DTO/VO로 만들지 않는다.

`FinancialPages`·`FinancialShape`는 service 내부, 쓰기 보조 클래스와 `WriteStore`는 mapper 내부에 둔다. 기존 EntityManager·트랜잭션·권한·DB 제약을 이중화하지 않고 내부 도우미를 일괄 public으로 바꾸지 않는다. JPA 스캔은 entity 클래스의 실제 패키지를 사용한다.

테스트 전용 공통 DB 구성은 `support/JpaTestContext`, 하위 JDBC 연결 검사는 테스트의 `persistence/`, 주석 검사기 검증은 `architecture/`에 둔다. health는 DB·업무 계층이 필요 없으므로 controller/dto만 둔다. 과거 작업 JSON의 당시 경로는 이력으로 보존하고 신규 작업 명세는 현재 경로를 사용한다. `src/modules/`·`src/infrastructure/`는 안내 문서 위치이며 Java 소스 루트가 아니다.

## 공식 근거

- [Spring Boot 요구사항](https://docs.spring.io/spring-boot/system-requirements.html): Java/Gradle 지원 범위.
- [Gradle 호환표](https://docs.gradle.org/current/userguide/compatibility.html): JDK 21 실행 지원.
- [Spring JDBC](https://docs.spring.io/spring-framework/reference/data-access/jdbc/core.html): JDBC 연결/자원 관리.
- [DB 초기화](https://docs.spring.io/spring-boot/how-to/data-initialization.html): 스키마 관리 수단 단일화.
- [HikariCP 7.0.2 설정](https://github.com/brettwooldridge/HikariCP/blob/HikariCP-7.0.2/README.md#configuration-knobs-baby): 시간 단위, 대기시간 하한·관계, 풀 크기 및 초기 연결 실패 설정.
- [PostgreSQL 설정 함수](https://www.postgresql.org/docs/15/functions-admin.html#FUNCTIONS-ADMIN-SET): `set_config`의 트랜잭션 한정 설정과 `current_setting` 조회.
- [Spring 요청 검증](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-methods/requestbody.html): 기본 400과 PAYSE 업무 검증 422의 명시적 매핑 필요.

작성·변경·검증 이력은 [API 문서 이력](history/2026-10-22-api-doc-history.md)에 보존한다.
