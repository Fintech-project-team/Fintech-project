# 인증 DB 접근과 요청 제한 저장

담당은 A다. [인증 설계](v0.6/auth-design.md)의 DB 부분을 [003_auth_access.sql](../database/003_auth_access.sql)로 구현한다. 외부 요청·오류·제한 수치의 단일 기준은 [HTTP 계약](../../../docs/api-contract.md)이다. Java Repository·트랜잭션 기반과 AuthService의 세션 생성·종료·재확인을 구현하고 AuthController에서 HTTP로 연결한다. 세션 전이는 [004_auth_sessions.sql](../database/004_auth_sessions.sql)을 사용한다. 금융 조회·설정 저장은 이 인증 문맥과 [007 최소 쓰기 권한](../database/007_financial_access.sql)을 재사용한다. 실행·검증은 [금융 API 인계](history/2026-10-29-financial-api-handoff.md), 탈퇴·파쇄는 별도 미구현 범위다.

## 적용과 보존

- `003_auth_access.sql`은 `auth/`의 사전 검사·저장 구조·요청 제한·세션 확인·함수 권한 파일을 호출하는 psql 진입점이다. `psql -X -v ON_ERROR_STOP=1 -f <경로>`로 실행한다. 하위 파일을 따로 실행하거나 진입점 내용을 JDBC SQL로 전송하지 않는다. 파일 구성·읽기 기준은 [SQL 작성·구성 기준](sql-style.md)에 있다.
- 현재 공통 구조의 `001_initial.sql`·`002_storage_guards.sql` 다음에 DBA가 명시적으로 한 번 적용한다. SQL 전체가 한 트랜잭션이며 재적용·기존 권한 충돌은 오류로 중단한다. 초기 SQL을 기존 DB에 다시 실행하지 않는다. 소유자 정책 식은 현재 초기 DDL의 PostgreSQL 정규 표현과 대조하므로, 의미가 같아도 표현을 변경한 별도 정책은 검토 없이 허용하지 않는다.
- 새 역할은 클러스터 전체에 적용되므로 DB와 역할의 기존 권한을 함께 검토한다. 이름 전환·공통 저장·급여 v3 이행이 필요한 구 DB에 이 파일을 바로 실행하지 않는다.
- 기존 사용자/세션/금융 행·ID·금액·날짜·버전은 변경하지 않는다. `users`에 nullable `deactivated_at`·`purge_after`만 추가한다. 두 값은 함께 null 또는 함께 유한한 시각이고 파쇄 시각이 비활성 시각보다 늦어야 한다. 서울 달력상 1년 산정·탈퇴 원자 처리·파쇄는 이 SQL의 구현 범위가 아니다.
- `auth_rate_limits`는 서버 인증 제한 상태이며 더미 전용 저장소가 아니다. 종류·HMAC 키·시각 배열·차단 종료 시각만 저장한다. 이름·전화번호·IP·코드 원문, 세션 토큰 원문은 저장하지 않는다.
- `004_auth_sessions.sql`은 003 적용을 확인한 DB에 명시적으로 한 번 적용하는 별도 진입점이다. 기존 001/002/003을 다시 실행하지 않는다. 신규 테이블·컬럼이나 기존 행 변경 없이 세션 전이 함수·최소 열 권한·정책만 추가한다. 중복 적용·사전 조건 불일치·하위 파일 실패는 전체 롤백한다.
- 배치 적용 도구는 저장소 파일만 적용한다. DB 접속·역할 생성·DDL 실행·시드 활성화·Git 변경은 수행하지 않는다.

## 역할과 신뢰 경계

`payse_runtime`은 서버용 권한 역할, `payse_auth_owner`는 함수 소유 역할이다. 둘 다 NOLOGIN·NOINHERIT이고 SUPERUSER·BYPASSRLS·역할/DB 생성·복제 권한이 없다. 배포 접속용 계정의 비밀번호는 SQL에 넣지 않으며 별도 관리자가 최소 권한 계정에서 `SET ROLE payse_runtime`을 사용하도록 구성한다. 함수 소유 역할의 멤버십은 부여하지 않는다.

runtime은 사용자 id/data_version과 소유자 RLS가 적용된 금융 자료를 조회한다. 기존 저장 트리거를 위해 data_version UPDATE와 `assert_user_storage` 실행만 추가 허용한다. 원천 금융 쓰기·세션/인증 비밀/제한 테이블 직접 접근·비활성 컬럼 수정은 허용하지 않는다. 실제 설정 쓰기 권한은 해당 저장 기능에서 필요한 컬럼·경로만 추가한다.

003의 auth_owner에는 사용자 인증 조회·사용자 행 잠금·세션 조회·제한 상태 갱신 권한을 준다. 004는 세션의 id/user_id/token_digest/issued_at INSERT와 ended_at UPDATE 및 해당 RLS 정책만 추가한다. runtime의 세션 직접 읽기·쓰기 권한은 늘리지 않는다. FORCE RLS를 유지하면서 인증 테이블에만 해당 역할 정책을 추가하며 금융 테이블의 기존 정책은 바꾸지 않는다. 신규 함수는 고정 `search_path`를 사용하고 PUBLIC 실행 권한을 회수한다. private 보조 함수는 runtime이 호출할 수 없다. 기존 소유자 정책·RLS/FORCE 상태, 역할 속성/멤버십/소유 함수, 테이블·컬럼·기본 권한, 스키마 쓰기 권한이 맞지 않으면 자동 수정하지 않고 적용을 거절한다.

runtime은 신뢰된 서버 역할이다. PostgreSQL의 사용자 설정값은 임의 SQL을 실행할 수 있는 runtime도 바꿀 수 있으므로, 기존 `payse.user_id` RLS가 탈취된 DB 자격이나 임의 SQL 실행까지 막는다고 주장하지 않는다. 앱에는 DB 자격을 배포하지 않으며 Repository는 바인딩과 아래 토큰 경로를 강제해야 한다.

## 호출 가능한 함수

모든 함수는 READ COMMITTED·읽기/쓰기 트랜잭션을 요구한다. 시각은 DB 행 잠금 뒤 DB 시계에서 얻는다. 시각을 요청 인자로 받지 않으며 저장된 마지막 사건보다 시계가 뒤로 가면 처리 오류로 거절한다. 오류 문구에 입력값을 포함하지 않는다.

| 함수                           | 결과와 책임                                                                                                                                                                    |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `auth_ip_request(digest)`      | `{allowed,retry_at}` 1행. 성공·실패와 관계없이 인증 요청 1회를 기록한다.                                                                                                       |
| `auth_limit(digest)`           | 조합 행을 잠그고 차단 종료 시각 또는 null을 반환한다. null은 미차단이며 인증 성공이 아니다.                                                                                    |
| `auth_failure(digest)`         | 잘못된 자격 대조 1회를 기록하고 차단 종료 시각 또는 null을 반환한다. 차단 중에는 이력과 종료 시각을 늘리지 않는다.                                                             |
| `auth_credentials(name,phone)` | 정규화된 조합의 `{user_id,code_verifier}` 0~1행. 서버 내부 코드 비교용이며 세션·사용자 문맥을 만들지 않는다. DISABLED도 반환될 수 있으므로 Java Crypto 검증을 생략하지 않는다. |
| `auth_authorize(token_digest)` | 유효한 활성 계정/세션이면 `{user_id,session_id}` 1행과 트랜잭션 로컬 사용자 문맥. 그 외 0행이며 이전 문맥도 비운다.                                                            |

`digest`는 제한 함수에서 소문자 64자리 HMAC hex이고, 토큰 함수에서는 기존 `sha256:<64자리 hex>`다. 코드와 토큰 원문을 함수에 넘기지 않는다. 정규화·코드 비교·제한 HMAC 생성은 기존 Java `AuthCredentials`·`AuthCrypto` 책임이다. 클라이언트가 제출한 UUID나 digest를 그대로 인증 근거로 사용하지 않는다.

## 서비스에서 지켜야 할 트랜잭션 순서

1. 인증 요청은 본문/Bearer 검증 전에 IP 함수를 한 번 호출하고 **커밋·연결 반환**한다. JSON 오류도 요청 횟수에 포함한다.
2. 다음 트랜잭션에서 정규화 가능한 조합의 `auth_limit`을 호출한다. IP 또는 조합 차단이면 자격 대조·실패 누적·세션 발급을 하지 않는다. 두 `retry_at` 중 늦은 시각으로 HTTP `Retry-After`를 산정한다.
3. 허용된 경우 자격 조회·Java 코드 비교를 수행한다. 잘못된 자격만 `auth_failure`로 기록한다. 정확한 자격의 기존 세션/비활성 거절은 조합 실패에 포함하지 않는다. 성공 대조 때문에 실패 이력을 초기화하지 않는다.
4. 실패도 정상 함수 결과로 받아 **제한 기록을 커밋한 뒤** HTTP 오류로 변환한다. 예외로 전체 롤백한 결과를 실패 누적 성공으로 보고하지 않는다. 저장 실패는 인증을 허용하지 않는다.
5. 세션 전이를 구현할 때 조합 → 사용자 → 세션 순서로 잠그고, 사용자 잠금 뒤 계정·verifier·세션을 다시 확인한다. IP 선행 연결을 반환한 뒤 실행하며 사용자 잠금을 잡은 채 추가 연결을 기다리지 않는다.
6. 금융 조회는 같은 연결·트랜잭션에서 `auth_authorize` → 소유자 제한 조회 → 커밋/롤백 순서다. 함수는 토큰으로 사용자 후보를 찾고 사용자 행을 잠근 **다음 별도 쿼리**로 계정/세션을 다시 확인한다. 앞선 HTTP 필터 검사로 이 확인을 대체하지 않는다.

각 함수는 호출자의 트랜잭션에 참여하며 내부에서 커밋하지 않는다. autocommit으로 `auth_authorize`만 실행하면 다음 SQL까지 문맥·잠금이 유지되지 않는다. SQL 예외가 나면 전체 요청 트랜잭션을 롤백한다. savepoint로 인증 예외만 되돌린 뒤 이전 사용자 문맥으로 금융 처리를 계속하지 않는다. 커밋/롤백 뒤 문맥이 제거되며 `READ ONLY`를 강제하면 사용자 행 잠금이 불가능하므로 함수가 거절한다.

## Java 호출 기반

`auth.mapper.AuthRepository`는 위 기반 함수 5개와 아래 세션 함수 3개를 JPA `EntityManager`의 native SQL·파라미터 바인딩으로 호출한다. 기존 SQL 함수·권한·실행 순서는 유지한다. `recordIp`는 허용 여부/재시도 시각, `retryAt`·`recordFailure`는 nullable 재시도 시각, `findCode`는 코드 대조용 `StoredCode` 후보, `authorize`는 현재 트랜잭션의 `Session` 소유자를 반환한다. 이 객체들은 서버 내부 자료이며 외부 JSON 응답이 아니다. `StoredCode.toString()`은 verifier와 사용자 ID를 숨긴다.

`auth.AuthTransactions.run`은 같은 EntityManagerFactory·DataSource의 `JpaTransactionManager`를 사용한다. 기존 트랜잭션·동기화·바인딩된 EntityManager/연결 안에서의 중첩 실행을 거절하고 READ COMMITTED·읽기/쓰기·`SET LOCAL ROLE payse_runtime`을 적용한다. 콜백 후 `flush`하고 같은 연결의 `SELECT 1`로 DB가 오류 상태인지 확인한다. 커밋·연결 반환까지 성공해야 결과를 돌려주며 EntityManager는 트랜잭션마다 분리한다. 요청별 상태는 콜백 지역값에 둔다. SQL/트랜잭션 장애는 원문·원인 체인이 없는 `AuthStoreException`이며 인증 불일치나 빈 결과로 바꾸지 않는다. Repository가 DB 조회/결과 해석 장애를 발견하면 실제 EntityTransaction에 rollback-only를 표시하므로 호출자가 예외를 잡아도 정상 커밋할 수 없다.

호출 예시는 `transactions.run(() -> repository.recordIp(ipKey))`를 끝낸 뒤 별도 `run`에서 조합 제한→자격 비교→실패 기록을 처리하는 순서다. 실패 대조는 결과값을 반환해 커밋하고, 이후 HTTP 오류로 변환한다. 토큰 확인 후 금융 조회는 하나의 `run` 안에서 수행한다. 콜백에서 외부 API/LLM 호출·비동기 스레드 전환·직접 COMMIT/ROLLBACK/SET ROLE·예외를 잡은 뒤 금융 작업 계속하기는 허용하지 않는다. 인증 서비스의 순서는 아래 구현 절을 따르며 HTTP 경계의 순서 집행은 격리 PostgreSQL을 사용하는 AuthHttpTest로 검증한다.

Spring의 `database` 프로필에서만 Repository·Transactions 두 bean을 등록한다. 기존 무DB 시작·생존 확인과 업무 HTTP 차단을 유지하며, 등록 자체가 로그인 API 개방이나 시드 활성화를 의미하지 않는다. `findCode`는 계정 활성/기존 세션/사용자 잠금 뒤 재검사를 완료하지 않으므로 자격 후보를 로그인 성공으로 반환하면 안 된다. 서버 저장 name을 포함한 세션 발급은 아래 004 전이와 AuthService에서 처리한다.

트랜잭션 실행 방식은 [Spring TransactionTemplate](https://docs.spring.io/spring-framework/reference/data-access/transaction/programmatic.html)과 [JpaTransactionManager](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/orm/jpa/JpaTransactionManager.html)를 따른다. 운영에서 Hibernate SQL·바인딩·추출값·DB 원문 오류 추적 로그를 켜지 않는다. `toString` 숨김만으로 임의 직렬화나 추적 로그까지 차단되는 것은 아니다.

## 검증과 미연결 부분

[DB 검사 안내](database-tests.md)의 전용 실행기는 새 격리 PostgreSQL 클러스터만 사용한다. 역할/컬럼/함수 권한, 사용자 분리, 커밋·롤백 후 동일 연결 문맥, 종료/비활성화와 조회 경합, 제한 행 최초 생성·동시 실패·IP 초과·보관 배열 경계를 검사한다. 고정 서버 시계 주입이 없으므로 실제 시각의 경계 직전·도달 이후를 검사하며 마이크로초 단위 정확한 동시각 재현으로 보고하지 않는다.

제한 행 정리·키 교체·실제 시드 verifier 활성화는 자동 실행하지 않는다. 만료 행 정리는 유효 이벤트·차단을 보존하는 별도 작업으로 추가해야 한다. DB 함수 검증은 실제 HTTP 인증, 프론트 연결, v3 모바일 동기화 완료를 뜻하지 않는다.

공식 근거: [PostgreSQL 15 RLS](https://www.postgresql.org/docs/15/ddl-rowsecurity.html), [SECURITY DEFINER와 함수 설정](https://www.postgresql.org/docs/15/sql-createfunction.html#SQL-CREATEFUNCTION-SECURITY), [행 잠금](https://www.postgresql.org/docs/15/explicit-locking.html). 제한 횟수·시간은 공식 의무값이 아니라 상위 계약의 사용자 결정이다.

## 세션 전이와 인증 서비스

| 함수                               | 결과와 책임                                                                                                                       |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `auth_login_account(name,phone)`   | 사용자 행 잠금 뒤 같은 ID·조합의 현재 이름/verifier 0~1행. 비활성·DISABLED도 코드 비교 후보로 유지하며 인증 성공을 뜻하지 않는다. |
| `auth_open_session(userId,digest)` | 활성 계정·활성 세션 부재를 재검사하고 저장된 사용자/세션/이름/발급 시각을 반환. 기존 세션은 종료하지 않는다.                      |
| `auth_end_session(digest)`         | 기존 authorize로 사용자·세션을 잠금 재확인한 후 현재 세션의 ended_at만 저장하고 사용자 문맥을 비움. 무효 토큰은 false.            |

`AuthService`와 인증 HTTP는 `database`와 `auth` 프로필이 모두 있을 때 등록된다. DB·auth 비밀 설정 외에 `PAYSE_AUTH_PEER_MODE=direct`와 `server.forward-headers-strategy=none`을 요구한다. 기본 바인딩은 127.0.0.1이며 명시한 세 인증 경로만 허용한다. Forwarded/X-Forwarded-For/X-Real-IP를 신뢰하지 않는다. 신뢰 프록시·외부 HTTPS 배포는 후속 운영 설정이다. 기존 DISABLED 시드를 자동 활성화하거나 새 사용자·금융 자료를 생성하지 않는다.

- `login`: IP 기록을 먼저 커밋·연결 반환 → 입력 검증 → 조합 잠금·차단 확인 → 사용자 잠금·현재 코드 대조 → 세션 생성. 이름과 issuedAt은 DB 저장 결과이며 토큰은 커밋이 성공한 뒤에만 반환한다.
- `reverify`: IP 기록 커밋 → 별도 트랜잭션에서 토큰 유효성 확인·잠금 반환 → 본문 검증 → 조합 제한 → 최종 토큰/계정 재검증·자격 대조 순서다. IP 제한은 429, 저장소 오류는 503으로 유지하며, IP 제한에 걸리지 않은 무효 토큰은 본문보다 우선하여 401 SESSION_INVALID로 거절한다. 사전 사용자 잠금을 보유한 채 조합 잠금을 기다리지 않는다. 최종 대조는 토큰 소유자만 잠그고 다른 사용자를 추가로 잠그지 않는다. 실패 시 기존 세션 유지, 성공 시 새 토큰·세션 없음은 그대로다.
- `logout`: 현재 세션만 명시 종료한다. 이미 무효인 토큰은 SESSION_INVALID이고 금융 자료·설정은 유지한다.
- 자격 실패는 `AuthResult.Failure`로 반환하여 제한 기록을 커밋한다. 기존 세션/비활성 때문에 거절된 정확한 자격은 실패 횟수를 늘리지 않는다. 저장·커밋 장애는 `AuthStoreException`이며 HTTP 어댑터가 503으로 변환해야 한다.
- HTTP는 `login/reverify`의 지연 입력 콜백으로 본문을 전달하여 IP 커밋 뒤 파싱한다. 기존 `rejectMalformed`와 중복 호출하지 않는다. `AuthHttpInput`은 UTF-8 application/json·중복 키·4096바이트·허용 필드/타입·단일 Bearer를 검사한다. `AuthHttpResponse`는 공개 오류 매핑·올림한 Retry-After·no-store·401 Bearer 헤더를 담당한다. 내부 AuthResult를 그대로 JSON으로 반환하지 않는다.

`AuthResult`는 HTTP DTO가 아닌 내부 결과다. Login에는 최초 성공에 필요한 토큰만, Verified에는 기존 userId/sessionId만, Failure에는 오류 종류와 제한 시각만 둔다. 토큰·코드·이름 원문을 예외나 자동 문자열 표현에 포함하지 않는다. 인증 함수에 금융 dataVersion 변경이나 급여 계산을 추가하지 않는다.

검사는 [DB 테스트](database-tests.md)의 실제 PostgreSQL 실행기를 사용한다. SQL 전이·서비스 통과와 실제 HTTP 로그인·Flutter 통합·배포 완료는 별도다.
