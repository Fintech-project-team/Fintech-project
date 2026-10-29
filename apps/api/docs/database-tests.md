# 데이터베이스 테스트 준비와 실행

저장 계약은 [DB 사전](../../../docs/database-schema.md), 코드 규칙은 [API 필수 규칙](../src/AGENTS.md)이 기준이다. 이 문서는 테스트 대상 선택과 실행만 정의하며 제품 필드·계산 규칙을 추가하지 않는다.

SQL 파일의 책임·줄바꿈·분리 기준은 [SQL 작성·구성 기준](sql-style.md)을 따른다. 인증 테스트의 파일 적재는 `psql -f`를 사용해 진입 파일 기준의 상대 포함을 유지한다. 현재 작업 디렉터리와 다른 공백 포함 경로에서도 실행하고, 하위 파일 누락·SQL 오류가 앞선 변경까지 롤백하는지 검사한다.

## 준비 자료와 대상 선택

### 실제 금융 HTTP·설정 저장 검사

`test_financial_service.py`는 새 폐기용 PostgreSQL에 001~004와 007을 적용하고, 명시된 시나리오를 일반 사용자·금융 테이블에 적재한다. 기존 DB 주소를 입력받지 않는다. Java는 실제 HTTP로 조회·저장·취소·재로그인·권한·멱등·동시성·롤백을 검증하고, 기존 인증 검사 DB와 금융 원천의 전후 동일성도 확인한다.

```powershell
python -B apps/api/database/test_financial_service.py --pg-bin 'C:\Program Files\PostgreSQL\15\bin' --work-dir '<존재하지 않는 새 검사 폴더>'
```

JDK 21과 테스트용 Python을 먼저 준비한다. 결과는 새 검사 폴더의 `result.json`·`java-tests.log`, 합성 공개 응답은 `public-responses/`다. 임시 자격은 하위 프로세스 환경으로만 전달한다. 이 검사는 기존 DB 마이그레이션이나 외부 HTTPS 배포를 실행하지 않는다. 실제 API 활성화에는 [서버 가이드](local-server-guide.md)의 `finance` 프로필·별도 cursor 키가 필요하다.

`database/test_context.py`는 검증된 `fixtures/generated`의 catalog에서 `alpha-ready`, `beta-ready`, `gamma-month-end` 사례를 읽는다. 사용자·계좌·지출·정산·배정·반복 버전·영수증은 실제 참조 관계로 찾는다. 표시명·고정 UUID·배열 첫 항목으로 대체하지 않는다. 같은 역할이 없거나 여러 개면 자료 준비 오류다. 여러 건이 필요한 카드 구매 근거는 집합 전체를 검사한다.

`test_context.sql`의 임시 함수는 같은 연결에서 DB의 ID·소유자·관계·자료 버전과 검사에 필요한 사전 상태를 다시 대조한다. 준비 오류는 기대 SQLSTATE를 포착하는 본 검사 밖에서 발생해야 한다. 행이 없는 UPDATE가 성공했다는 이유로 제약 검사를 통과시키지 않는다. 생성한 context를 DB·파일에 영구 저장하거나 서비스의 공통 모델로 사용하지 않는다.

준비 모듈은 주소와 사전 상태만 제공한다. 원화 상한·bigint 넘침·부분 정산의 1원 초과·날짜 경계·기대 SQLSTATE는 각 검사에 명시된 독립 벡터다. 현재 테스트가 전제하는 정산 금액과 반복 회차가 달라지면 전제를 검토해야 하며, DB 구현에서 한도나 정답을 읽어 검사를 자동 변경하지 않는다.

## SQL 검사

별도로 준비한 **로컬 전용 폐기 가능 DB**만 사용한다. `PGHOST`는 `127.0.0.1` 또는 `localhost`, DB명은 `payse_fixture_` 뒤에 소문자·숫자·밑줄이 붙는 이름이어야 한다. 이름 규칙만으로 안전한 DB가 되는 것은 아니므로 테스트 담당자가 데이터와 용도를 확인한다. 연결 자격은 환경 변수/별도 비밀번호 파일에 두고 Git에 저장하지 않는다.

빈 테스트 DB에는 `001_initial.sql`, `002_storage_guards.sql`, 기관 기준 INSERT, 같은 fixture 디렉터리의 선택한 시나리오 INSERT를 순서대로 적재한다. 아래 exporter는 파일만 만들고 DB에 접속하지 않는다. 명시 선택한 세 사례는 테스트 전제이며 앱의 최초 연결 상태를 바꾸는 설정이 아니다.

```powershell
python -B apps/api/reference_data/export_sql.py --out "검증용-새-reference.sql"
python -B apps/api/testing/scenarios/prepare.py apps/api/fixtures/generated `
  --cases alpha-ready beta-ready gamma-month-end --out "검증용-새-seed.sql"

python -B apps/api/database/run_sql_tests.py `
  --psql "검증한-psql-경로" --database payse_fixture_sql_review `
  --fixtures apps/api/fixtures/generated
```

두 번째 명령은 스키마·시드를 생성하거나 기존 DB를 초기화하지 않는다. 준비된 DB에서 제약·극한값·원천/설정 관계·인증 저장의 네 SQL을 실행한다. 각 SQL은 준비 함수와 같은 연결에서 실행되고 ROLLBACK한다. SQL 파일만 단독 실행하면 준비 함수가 없으므로 실패한다. 애플리케이션 서버·HTTP API의 실행은 필요하지 않다.

## 두 연결 경합과 기존 DB 이행

```powershell
python -B apps/api/database/test_native_concurrency.py `
  --psql "검증한-psql-경로" --database payse_fixture_race_review `
  --seed "검증용-새-seed.sql" --fixtures apps/api/fixtures/generated
```

이 명령은 **빈 DB만** 허용하며 초기 DDL·기관 기준·입력 시드를 적재한 뒤 네 SQL과 두 연결 경합을 실행한다. 입력 시드는 기관 기준 SQL 다음에 시나리오 SQL을 연결한 파일이어야 하며, 테스트 담당자가 검토한 로컬 생성 SQL만 사용한다. 활성 세션·버전 비교 갱신·작업 키의 세 경합은 실제 커밋을 수행하므로 전용 DB를 사용한다. 완료 후 DB는 검사 목적으로 남고 자동 삭제하지 않는다. 시드와 fixture가 다르면 준비 검사가 실패한다.

단일 이름 이행은 [별도 이행 회귀 검사](identity-migration.md#회귀-검증)를 따른다. 승인된 세 계정의 과거→현재 매핑은 `fixtures/identity_contract.py`가 기준이다. 그 매핑을 임의 사용자 추정 로직으로 바꾸지 않으며, 검사에서 동일 UUID·표시명을 복사해 조회하지 않는다.

## 검증 범위

`python -B -m unittest discover -s apps/api/tests`는 fixture와 context 준비의 정상·누락·모호성·관계 오류를 검사한다. 실제 PostgreSQL의 SQL·RLS·잠금·경합은 위 별도 명령으로 검증한다. 단위 검사나 JUnit 통과를 실제 DB 검사 완료로 대체하지 않는다. 실행한 PostgreSQL 버전과 미실행 환경을 결과에 기록한다. 팀 목표 버전은 [도구 기준](../../../docs/toolchain.md)을 유지한다.

## 공통 구조 이행 검사

`test_common_storage_migration.py --database payse_fixture_common_review --psql <경로> --temp <검사 임시 폴더>`는 전용 DB의 payse 스키마를 재생성한다. 기존 서비스 DB에서 실행하지 않는다. 임의 추가 사용자, 활성 세션, 남아 있는 시나리오 기록의 외부 보존, 변경된 원천/해시/스키마/함수/권한, 중복 실행 거절을 검사한다. 기존 identity 회귀 검사는 과거 DDL만 사용한다.

## 급여 회차 검사

`test_salary_receipts.sql`은 필수 payMonth·잘못된 형식·동일 회차 중복 거절과 월 경계 이동·서로 다른 회차의 같은 예정일 보존을 검사한다. 원천 보존 뒤 구간 정보 부족 판정은 Flutter 담당이다. SQL의 사용자·거래 ID는 준비 context에서 받으며 명목 회차 프로브는 독립된 테스트 전제다. 입금 거래일에서 월을 추정하는 서비스 규칙으로 사용하지 않는다.

`python -B -m unittest discover -s apps/api/tests`는 기존 검사와 test_salary_receipts.py를 포함한다. 별도 급여 이행 테스트는 검토 매핑·버전 FK·이력 보존·변경 감지·롤백을 실제 폐기용 PostgreSQL에서 검사한다. 실행 인자는 `python -B apps/api/database/test_salary_evidence_migration.py --help`에서 확인한다. 일반 DB에 테스트를 실행하지 않는다.

## 인증 DB 역할·요청 제한 검사

[인증 DB 접근](auth-database.md)의 `003_auth_access.sql`은 별도 검사한다. 다음 실행기는 **새 작업 디렉터리에 새 PostgreSQL 클러스터**를 만들고 종료하며, 기존 서버·DB를 재사용하지 않는다. 역할은 클러스터 전체 객체이므로 일반 개발 DB에서 역할 테스트를 실행하지 않는다. 작업 디렉터리가 이미 있으면 다른 새 경로를 사용한다.

```powershell
python -B apps/api/database/test_auth_access.py `
  --pg-bin "C:\Program Files\PostgreSQL\15\bin" `
  --work-dir "$env:TEMP\payse-auth-check-$([guid]::NewGuid().ToString('N'))"
```

`--pg-bin`은 실제 설치한 PostgreSQL 도구 경로다. 결과와 테스트 DB는 검사 폴더에 남으며 비밀번호 파일을 공유하지 않는다. 현재 공통 API CI는 이 별도 클러스터 검사를 자동 실행하지 않으므로 실행 결과를 PR에 구분해서 기록한다.

## Java 인증 DB 연결 검사

`AuthRepositoryTest`는 단일 행·0~1행·정상 null·오류 결과, 파라미터 바인딩, 트랜잭션 조건과 Spring 등록을 검사한다. 실제 SQL·권한·잠금 확인은 `AuthJdbcTest`가 담당한다. 다음 실행기는 새 폐기용 PostgreSQL에 기존 001/002/003과 검사용 사용자 관계를 준비하고, 생성한 최소 권한 자격을 하위 Gradle 환경에만 전달한다. JDK 21과 기존 Gradle 도구가 필요하다.

```powershell
python -B apps/api/database/test_auth_jdbc.py `
  --pg-bin "C:\Program Files\PostgreSQL\15\bin" `
  --work-dir "$env:TEMP\payse-auth-jdbc-$([guid]::NewGuid().ToString('N'))"
```

기존 서버 주소·운영 DB 자격을 입력받지 않는다. 전체 Java 검사와 Java 주석 검사를 실행하며 DB 접속/관계 입력은 파일·명령 인자에 저장하지 않는다. 결과 JSON·JUnit 요약으로 실패·건너뜀을 구분하고 인증 제한 행을 제외한 공통 테이블이 그대로인지 대조한다. 종료 시 새 클러스터와 임시 접속 자격을 정리한다.

실제 검증 범위는 최소 권한 함수 호출, 같은 연결의 역할/소유자 문맥 제거, 풀 크기 1의 IP 선행 커밋→후속 롤백, 실패 5회·IP 60회 경계, 동시 호출, SQL 오류를 잡은 콜백의 거짓 성공 방지다. 기본 Gradle 검사에서 전용 `PAYSE_AUTH_TEST_*` 환경이 없으면 실제 DB 검사는 SKIPPED다. 이 실행기의 실제 PostgreSQL 결과를 함께 기록해야 하며 HTTP 로그인·세션 발급·모바일 검증 완료로 보고하지 않는다.

## 세션 전이·인증 서비스 검사

신규 세션 함수·권한·경합은 `test_auth_sessions.py`, 서비스의 JPA 트랜잭션·실제 PostgreSQL 연결은 `test_session_service.py`로 검사한다. 두 실행기 모두 새 폐기용 PostgreSQL 클러스터만 사용하고 기존 서버 주소·서비스 DB 자격을 받지 않는다. 관리자 관측·자료 준비용 JdbcTemplate은 제품 저장 계층과 구분하여 유지한다.

```powershell
python -B apps/api/database/test_auth_sessions.py --pg-bin "C:\Program Files\PostgreSQL\15\bin" --work-dir "$env:TEMP\payse-session-sql-$([guid]::NewGuid().ToString('N'))"
python -B apps/api/database/test_session_service.py --pg-bin "C:\Program Files\PostgreSQL\15\bin" --work-dir "$env:TEMP\payse-session-service-$([guid]::NewGuid().ToString('N'))"
```

검증은 세션 한 개만 생성되는 동시 로그인, 기존 세션 우선, 동일 세션 재확인, 다른 사용자 자격 거절, 로그아웃·조회 경합, IP 선행 커밋·실패 누적과 전체 롤백, 권한·원천 보존을 구분한다. 테스트 준비는 새 UUID와 검증된 관계를 사용하며 제품 더미의 표시명이나 첫 행에 의존하지 않는다.

일반 Gradle 검사에서 전용 DB 환경이 없으면 실제 PostgreSQL 검사는 SKIPPED다. 전용 실행기의 결과를 함께 확인하며 이 서비스 검사만으로 HTTP API·모바일 통합이 통과한 것으로 기록하지 않는다. `AuthJdbcTest`·`SessionJdbcTest`는 기존 클래스명을 유지하지만 제품 호출은 JPA 트랜잭션을 사용한다. 운영 시드의 인증 코드를 자동 활성화하지 않는다.

## 취소 날짜와 원거래 JOIN

`python -B apps/api/database/test_cancellation_date.py --pg-bin <PostgreSQL bin> --work-dir <새 폴더>`는 새 소유 클러스터에서 신규 001·기존 DB용 005의 동일 제약, 기존 행 보존, 재실행 거절, 중간 실패 롤백을 검사한다. 실제 DB 주소를 받지 않는다. 과거 구조/급여 이행 검사는 frozen 001_common_storage.v2.sql 및 테스트 전용 legacy_seed.py의 175컬럼 입력을 사용한다. legacy_seed는 운영 적재 경로가 아니다.

기존 test_session_service.py는 원거래 LEFT JOIN의 JPA native SQL 검사도 함께 실행한다. prepare_links.py는 동적 UUID·소유자·카드 관계를 확인해 새 테스트 자료만 준비한다. 원거래 없음/미확보/기관 제한·타 사용자·트랜잭션 문맥을 구분하며 금융 원천의 사용자별 불변도 확인한다. 이 내부 조회 검사를 금융 조회 HTTP 구현 완료로 기록하지 않는다.

## 청구 항목 저장과 기존 연결 이행

`python -B apps/api/database/test_statement_storage.py --pg-bin <PostgreSQL bin> --work-dir <새 폴더>`는 소유한 새 임시 클러스터에서 신규 001·기존 공통 DB용 006을 검사한다. 기존 서비스 DB에 접속하지 않는다. 검사 범위는 signed 조정/청구액·nullable 거래, 기존 비음수 금액 규칙, 소유자/카드/원천 버전 FK·RLS, 동일 구매의 여러 항목, 구 행·관계 보존, 재실행 거절, 실패 시 전체 롤백이다.

신규 001에는 취소 날짜와 청구 항목 구조가 함께 포함된다. 기존 DB의 명시적 전환 순서는 공통 구조/급여 회차 이행 → 005 취소 날짜 → 006 청구 항목이다. 새 001에 005/006을 다시 실행하지 않는다. 006은 사용자·거래·청구 관계만 새 항목 ID로 옮기고 새 금액/표시/회차는 null로 유지한다. 원천 버전과 schemaVersion을 자동 변경하지 않는다. 실제 서비스 DB 이행은 별도 작업이다.

`export_sql.py`는 v3 참조를 동일한 식별 매핑으로 명시 변환하거나 v4 항목을 그대로 저장한다. 과거 175컬럼 회귀에 쓰는 `legacy_seed.py`는 v3 자료만 허용하고 당시 네 청구 연결 컬럼을 투영한다. 신규 구조의 필드를 과거 이행 입력에 섞지 않는다.

원천 검증·생성 재현·공개 제한/다음 페이지/구버전 반례는 `python -B -m unittest discover -s apps/api/tests`에 포함된다. 이는 Flutter 실행이나 금융 조회 HTTP 제공 완료를 뜻하지 않는다. 실제 v4 공동 전환은 [인계 기록](history/2026-10-29-statement-items-handoff.md)을 따른다.
