# 단일 이름과 설치 식별 컬럼의 DB 이행

공통 이름 계약은 [API 계약](../../../docs/api-contract.md#인증-입력과-단일-이름), 현재 물리 구조는 [DB 사전](../../../docs/database-schema.md)이 기준이다. 이 문서는 기존 합성 개발 DB를 전환하는 전용 도구의 실행 조건을 정의한다. 실제 사용자 DB를 자동 탐색하거나 앱 기동 때 이행하지 않는다.

## 초기 생성과 기존 DB 전환

- 빈 DB는 `database/001_initial.sql`과 `002_storage_guards.sql`, 검증된 초기 INSERT 시드를 사용한다. 기존 payse 스키마에 초기 SQL을 재실행하지 않는다.
- 기존 DB는 `database/migrate_identity.py`의 `--plan`과 `--apply`를 분리한다. Python 표준 라이브러리와 PostgreSQL `psql`을 사용하며 별도 패키지나 DB 확장을 설치하지 않는다.
- 이 도구는 준비된 23테이블의 합성 개발 DB와 세 지정 UUID의 검토된 이름/전화번호를 대상으로 한다. 계정 수를 제품의 영구 한도로 정하지 않는다. 다른 사용자·부분 스키마·추가 업무 테이블이 있는 DB는 확장 검토 없이 변환하지 않는다.
- UUID/name/전화/구 이름의 단일 매핑은 `fixtures/identity_contract.py`다. migration 전용 JSON 매핑을 새 권위로 만들거나 이름을 trim·추측·fallback으로 생성하지 않는다.

## 보존과 변경

`demo_users.name` 하나가 인증 조회와 허용 호칭의 값이다. 이름은 한글 완성형·ASCII 영문 2~20자이며, 전화번호는 기존 `synthetic_phone` 열과 값에 `010[0-9]{8}`을 적용한다. 두 형식 CHECK는 `COLLATE "C"`로 검사하고 `(name, synthetic_phone)`에 UNIQUE를 둔다. 금융 상품명·메모·별칭의 공백 규칙을 변경하지 않는다.

구 `synthetic_name`·`display_name`과 남아 있는 `demo_sessions.installation_id` 원문은 **DB 밖의 새 검토/백업 JSON**에 보존한다. name 두 개나 설치 ID를 서비스의 중복 열·새 영구 이력 테이블로 남기지 않는다. 백업에는 원문 이름·전화번호·세션 ID·구 설치 값 및 검증 메타데이터가 있으므로 접근 권한이 제한된 보관 폴더를 지정하고 Git·공유 채팅·일반 로그에 넣지 않는다. 이 파일은 암호화 파일이 아니며 Windows 폴더 ACL을 도구가 구성하지 않는다. POSIX에서는 신규 파일 모드 0600을 요청한다.

사용자 UUID·전화·생성 시각·data_version·code_verifier, 세션 ID/소유자/token_digest/발급·종료 시각, 금융 원천·설정·정산·버전은 유지한다. code_verifier 활성화·로그인 발급·세션 종료·금융 금액 계산은 이 도구가 수행하지 않는다. 준비 시드의 DISABLED 표식도 유지한다.

## 사전 조건

1. 실제 적용 대상과 운영 중단/검토 범위를 담당자가 확인한다. 앱 런타임 역할이 아닌 DDL·전체 행 읽기·`pg_control_system()` 조회 권한이 있는 명시 migration 연결을 사용한다. runtime에 이 권한을 부여하지 않는다.
2. `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSFILE` 등 libpq 연결 설정을 별도로 준비한다. 도구에는 URI/비밀번호가 아닌 단순 DB 이름을 전달한다. `--no-password`이므로 비대화식 연결이 준비되지 않았으면 실패한다.
3. `--timeout-seconds`와 `--lock-timeout-ms`를 명시한다. 이는 도구 실행·잠금 대기의 한도이며 서버 운영 기본값이 아니다. 시간 초과·권한 부족·RLS로 전체 행을 읽지 못하면 완료로 표시하지 않는다.
4. `--backup`의 부모 폴더는 미리 존재하고 접근 권한이 적절해야 한다. 기존 파일과 심볼릭 링크를 덮지 않는다. 백업 원문 보존 없이 열을 제거하지 않는다.

## 실행 순서

저장소 루트에서 사용한다. 아래 DB명·파일명·시간 한도는 입력 예시이며 실제 검토 대상과 한도로 교체한다. 백업 파일 경로는 Git 밖의 보관 위치를 사용한다.

예시의 PostgreSQL 15 경로는 검증 환경의 실행 파일 위치다. [팀 도구 기준](../../../docs/toolchain.md)의 PostgreSQL 18 목표를 변경하지 않으며 15.13에서의 검증 범위와 구분한다. `--psql`은 적용 대상 환경에서 검토한 설치 버전의 경로로 교체한다.

```powershell
python apps/api/database/migrate_identity.py --plan `
  --psql "C:/Program Files/PostgreSQL/15/bin/psql.exe" `
  --database payse_fixture_identity_review `
  --backup "C:/secure-payse-review/identity-plan.json" `
  --timeout-seconds 60 --lock-timeout-ms 3000
```

`--plan`은 `REPEATABLE READ READ ONLY`에서 현재 DB를 읽고 새 백업만 생성한다. 출력은 `PLANNED`, 백업 전체 SHA-256, 두 변경 여부뿐이다. DB 행·원문 이름·설치 ID·비밀값·SQL 오류 본문은 출력하지 않는다. 백업을 검토한 뒤 출력 SHA-256을 별도로 보존한다. 파일 안의 자체 해시만 신뢰하지 않는다.

```powershell
python apps/api/database/migrate_identity.py --apply `
  --psql "C:/Program Files/PostgreSQL/15/bin/psql.exe" `
  --database payse_fixture_identity_review `
  --backup "C:/secure-payse-review/identity-plan.json" `
  --expected-sha256 "검토한-백업의-64자리-SHA256" `
  --timeout-seconds 60 --lock-timeout-ms 3000
```

`--apply`는 백업 전체 해시와 내부 계획을 검증한 뒤 DB에 접속한다. 클러스터 system identifier·DB OID/이름·서버 주소/포트/버전, 열·제약·인덱스·보안·함수·트리거, 23테이블의 행 수/내용 지문이 검토 상태와 같아야 한다. 다른 DB, 계획 후 변경, 백업 변조는 거절한다.

동시 변경 방지를 위해 고정 테이블 목록에 SHARE 잠금을 얻고 변경할 사용자/세션 구조에는 ACCESS EXCLUSIVE 잠금을 추가한다. `row_security=off`는 행 보안 우회 권한을 부여하지 않으며, 부분 행만 읽는 실행을 실패시키기 위한 설정이다. 원문 보존을 확인한 상태에서만 열을 전환하고 `DROP ... RESTRICT`를 사용한다. 의존 view·검출된 구 필드 사용 함수/트리거, 제거 열에 연결된 기존 초기 규격 밖 CHECK/index는 별도 검토 대상으로 중단한다. 같은 테이블의 CHECK/index도 열 제거 때 자동 소멸할 수 있으므로 RESTRICT만으로 보존됐다고 판단하지 않는다. `DROP CASCADE`나 임의 SQL 입력은 제공하지 않는다.

같은 트랜잭션에서 새 지정 이름과 불변 데이터 지문을 검사한 뒤 COMMIT한다. 그 전에 실패하면 부분 DDL/UPDATE가 남지 않는다. PostgreSQL 거절·도구 오류는 `REJECTED`이며 SQL·서버 오류 원문은 출력하지 않는다. 연결/응답 유실로 커밋 여부가 불명확하면 성공이나 완전 롤백으로 추정하지 말고 현재 DB를 다시 `--plan`으로 확인한다.

정상 적용은 `APPLIED`다. 이미 이행된 DB를 새로 계획했을 때 지정 이름·물리 CHECK·UNIQUE·단일 활성 세션·RLS까지 맞으면 `NOOP`다. 단일 세션 인덱스는 이름 문자열만이 아니라 실제 키·정확 조건식·유효/준비/유일 상태를 검사한다. 사용자·세션 표는 RLS 활성화·강제 적용과 함께 `own_rows` 정책의 개수·역할·명령·허용 방식·조회/쓰기 조건까지 검사한다. **적용 전의 옛 계획을 다시 보내면 상태 변경으로 거절**하며 자동으로 새 상태를 승인하지 않는다. DB/백업의 어떤 값도 명령을 실행하기 위해 자동 수정하지 않는다.

## 회귀 검증

`test_identity_storage.sql`은 이름·전화·조합 UNIQUE·구 컬럼 부재와 금융 문자열 보존을 실제 PostgreSQL에서 검사하고 ROLLBACK한다. [DB 테스트 실행기](database-tests.md#sql-검사)가 준비 자료의 ID·관계를 검증해 같은 연결에 전달하며 이 SQL을 단독 실행하지 않는다. `test_identity_migration.py`도 준비 context로 대상 행을 확인한다. 이행 도구의 승인된 과거 매핑은 유지한다. 이 검사는 **로컬 전용 `payse_fixture_identity_` 접두사 DB의 payse 스키마를 테스트마다 재생성**하므로 기존 사용자 DB에서 실행하지 않는다.

```powershell
python apps/api/database/test_identity_migration.py `
  --psql "C:/Program Files/PostgreSQL/15/bin/psql.exe" `
  --database payse_fixture_identity_review `
  --timeout-seconds 60 --lock-timeout-ms 3000 `
  --temp "C:/secure-payse-review/test-temp"
```

검사는 정상 이행·설치 컬럼 유무·현재 계약 NOOP·옛 계획 재실행 거절·잘못된 매핑/전화/UUID·부분 스키마·위조 CHECK/인덱스·사용자 정의 구 컬럼 제약/인덱스·의존 view·백업 변조/덮어쓰기/잘못된 타입·DB 상태/지문 변경·중간 실패 롤백·RLS 정책 누락/완화/추가·RLS 부분 조회 거절·잠금 시간 초과를 다룬다. 사용자·세션·verifier·금융·설정 지문 보존도 비교한다. 테스트 백업은 테스트 소유 임시 폴더만 정리한다.

이 도구와 검증은 기존 DB 이행에 관한 것이다. 실제 인증 API·코드 verifier 발급·Flutter HTTP 연결·파쇄 운영의 완료 근거로 사용하지 않는다. 실행 날짜·DB 버전·결과는 [API 이력](history/README.md)에 연결하는 작업별 기록으로 남긴다.

## PostgreSQL 참조

- [ALTER TABLE](https://www.postgresql.org/docs/18/sql-altertable.html): 열 변경·삭제와 의존성 처리. RESTRICT만으로 같은 표의 모든 부수 구조가 보존된다고 가정하지 않고 제거 열의 제약·인덱스를 별도로 검토한다.
- [명시적 잠금](https://www.postgresql.org/docs/18/explicit-locking.html): SHARE·ACCESS EXCLUSIVE의 충돌 범위. 적용 도구의 잠금과 시간 한도는 일반 요청 처리 설정과 구분한다.
- [행 보안](https://www.postgresql.org/docs/18/ddl-rowsecurity.html): RLS·FORCE·우회 역할·row_security 설정의 의미. DB 전환 역할을 앱 실행 역할에 재사용하지 않는다.
