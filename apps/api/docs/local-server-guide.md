# Windows PC에서 PAYSE 서버 준비하기

처음에는 본인·팀원만 접속하고, 이후 외부 시연 접속을 추가할 수 있는 구조로 준비한다. **아래 개발 도구는 이 PC의 별도 loopback DB·API를 준비한다. 외부 공개·실제 기기 연결은 별도다.** 소스는 생존 확인, `database,auth` 프로필의 로그인·재확인·로그아웃, `finance` 프로필을 함께 켠 v3 금융 조회·연결·설정 저장 HTTP를 제공한다. 직접 접속 모드·DB·암호 설정은 [인증 DB·HTTP](auth-database.md), 금융 검증 범위는 [금융 인계](history/2026-10-29-financial-api-handoff.md)를 따른다. 분석 HTTP·프록시·외부 접속 구성은 별도다.

## 1. 권장 구조

```text
본인·팀원 기기 → 사설 접속망 → HTTPS 진입점 → 127.0.0.1의 Spring API
                                               ├─ 로컬 PostgreSQL
                                               ├─ 외부 LLM (서버만 호출)
                                               └─ 외부 관리형 키 서비스

외부 시연 단계 → 승인된 공개 HTTPS 진입점 → 같은 Spring API
```

초기에는 사설 접속망의 허용된 사용자/기기만 받는다. 나중에 공개 도메인·인증서·접근 제한을 갖춘 진입점을 연결해도 API·DB 구조를 바꾸지 않도록 한다. 사설망이 PAYSE 인증을 대체하지 않으며 외부 시연에서도 별도 합성 계정·단일 세션 규칙을 유지한다. 공유기 포트 개방·터널 제공업체·도메인 구매는 아직 결정/실행하지 않는다.

## 2. 도구 확인

저장소 루트에서 PowerShell을 연다. 이 PC의 설치 현황은 [확인 기록](history/2026-10-28-analysis-foundation.md)에 있다. JDK 21을 사용하고 저장소의 Spring/Gradle/의존성 잠금 버전을 유지한다.

```powershell
$payseNodeDir = Join-Path $env:LOCALAPPDATA 'PAYSE\toolchains\node-24.21.0\node-v24.21.0-win-x64'
$env:Path = "$payseNodeDir;$env:Path"
node --version
npm.cmd --version
java -version
python --version
```

Node **24.21.0**, npm **11.19.0**, Java **21**, Python **3.10 이상**인지 확인한다. 기본 Node가 다르더라도 저장소 요구 버전을 낮추지 않는다. 처음 의존성을 준비하거나 lockfile이 바뀌었을 때 `npm.cmd ci`를 실행한다. Docker/WSL은 이 구성의 필수 설치 항목이 아니다.

## 3. DB 없는 로컬 실행부터 확인

```powershell
node scripts/harness/run-api.mjs check
if ($LASTEXITCODE -ne 0) { throw 'API 검사 실패를 먼저 해결하세요.' }

$env:SPRING_PROFILES_ACTIVE = ''
$env:PAYSE_BIND_ADDRESS = '127.0.0.1'
$env:PAYSE_PORT = '8080'
node scripts/harness/run-api.mjs start
```

다른 PowerShell 창에서 실행한다.

```powershell
Invoke-RestMethod http://127.0.0.1:8080/internal/health/live
```

`status=UP`이면 프로세스 생존 확인 성공이다. 실행 창의 Ctrl+C로 종료한다. 다른 업무 경로가 차단되는 현재 구현을 로그인 완료로 오해하지 않는다. HTTP 예시는 본인 PC loopback 확인 전용이며 실제 인증·금융 통신은 HTTPS를 사용한다.

## 4. 서비스 DB와 테스트 DB 준비

1. 이미 설치된 PostgreSQL 클러스터의 자료·사용처를 먼저 확인한다. 기존 클러스터를 삭제하거나 초기 SQL을 재실행하지 않는다.
2. 서비스 DB와 폐기 가능한 테스트 DB를 분리한다. 기존 15 계열을 유지한다면 지원되는 최신 minor로 패치한 뒤 검사한다. 신규 major 도입은 별도 결정·회귀 검사 대상이다. 현재 설치 버전을 운영 버전 확정으로 간주하지 않는다.
3. 신규 빈 DB에만 [DB 테스트/준비 절차](database-tests.md)와 [인증 DB](auth-database.md)의 사전 조건을 확인한 뒤 `001_initial.sql → 002_storage_guards.sql → 003_auth_access.sql → 004_auth_sessions.sql → 007_financial_access.sql` 순서로 적용한다. 007은 금융 쓰기에 필요한 최소 권한이다. 005·006은 구 DB용 별도 이행이므로 최신 초기 DDL에 중복 적용하지 않는다. 이 문서만 보고 사용 중 DB에 실행하지 않는다.
4. SQL은 psql 진입 파일을 사용한다. `\ir`로 포함되는 하위 파일을 단독 적용하거나 기존 트랜잭션을 재포장하지 않는다. 서버 시작 시 스키마 자동 변경은 하지 않는다. JPA 엔티티도 기존 스키마를 사용하며 JPA 전환만을 위한 추가 마이그레이션은 없다.
5. 일반 users·user_attributes·금융 테이블에 승인된 합성 자료를 적재한다. 테스트 시나리오·수리비 검증 사례를 모든 사용자의 기본 설정으로 넣지 않는다. 코드 verifier가 DISABLED인 시드는 별도 활성화 준비가 필요하다.
6. 앱 접속 역할은 비관리자이며 필요한 runtime 역할만 부여한다. PostgreSQL 5432는 휴대폰·인터넷에 공개하지 않는다. DB 소유자/superuser/BYPASSRLS 자격을 API 실행 계정으로 사용하지 않는다.

PostgreSQL 공식 정책은 major별 최신 minor 사용을 권고한다. major 변경은 데이터 이행 절차가 필요하므로 이미 설치된 자료 위에 새 버전을 덮어 문제를 해결하지 않는다. [공식 버전 정책](https://www.postgresql.org/support/versioning/)

## 5. DB·인증 실행 설정

`database,auth` 프로필의 환경값은 [초기화 안내](spring-bootstrap.md#db-연결-설정)와 [인증 기반](auth-foundation.md)을 따른다. 금융 API를 제공할 때 `SPRING_PROFILES_ACTIVE=database,auth,finance`와 별도 `PAYSE_FINANCE_CURSOR_KEY_BASE64`를 지정한다. cursor 키는 무작위 32바이트의 정규 Base64 문자열이며 코드·요청 제한 키와 분리해 보관한다. 재시작에도 같은 키를 유지해야 기존 cursor를 검증할 수 있다. 키를 교체하면 기존 페이지 조회는 처음부터 다시 시작한다. 키가 없거나 잘못되면 finance 시작을 거절하며 임시 키로 대체하지 않는다.

| 설정 묶음 | 준비할 값                                                                              |
| --------- | -------------------------------------------------------------------------------------- |
| DB        | JDBC 주소, 접속 사용자/비밀번호, 최대 풀 크기, 연결 획득/검증 timeout                  |
| 인증      | 코드 키 ID, 서로 다른 무작위 32바이트 키 2개, 올바르게 준비된 합성 코드 verifier       |
| 분석      | 승인 모델/스키마/단가/기존 비용, 외부 KMS, 호출·보관·폐기 프로필. 미준비면 분석 비활성 |

비밀값은 Git·배치·채팅·PowerShell 명령 이력에 적지 않는다. 제한된 서비스 계정의 실행 환경/비밀 저장소로 주입하고 읽기 권한을 제한한다. 풀/timeout에 테스트 값을 복사해 운영 기본값으로 쓰지 않는다. DB 연결만으로 앱 연동이 끝나지 않으며 합성 자격 준비·실제 HTTP 호출과 Flutter 서버 Repository 연결을 확인한다.

## 6. 팀원 접속과 외부 시연 확장

사설망/HTTPS 제품을 정한 뒤 다음 항목을 구성한다.

- Spring은 loopback에 유지하고 HTTPS 진입점만 허용한 사설 인터페이스에서 받는다. 휴대폰은 PC의 localhost에 접속할 수 없으므로 기기에서 도달 가능한 승인 서버 주소를 사용한다.
- Windows 방화벽은 필요한 진입 포트·네트워크·원격 주소만 허용한다. 8080/5432를 전체 인터넷에 열지 않는다. [Microsoft 방화벽 규칙](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/configure)
- 프록시는 외부의 IP 전달 헤더를 제거/재작성하고 서버는 명시한 프록시만 신뢰한다. 임의 X-Forwarded-For를 신뢰하면 인증 요청 제한을 우회할 수 있다. 프록시 뒤 모든 사용자를 하나의 IP로 세는 문제도 검사한다.
- 외부 시연은 별도 도메인·유효 TLS·접근 통제·운영 로그·계정 배정·중단 방법을 준비한 뒤 공개한다. 원격 접속이 성공한 것과 API 권한 검증 완료는 별개다.
- Windows PC의 절전·재부팅·인터넷/공유기 장애 동안 서비스가 중단된다. 상시 공개 서비스의 가용성이 필요해지면 같은 실행 JAR·PostgreSQL 접속·비밀 주입 방식으로 전용 호스트에 옮길 수 있게 PC 경로를 코드에 고정하지 않는다.

## 7. 상시 실행은 검증 뒤에

수동 start는 개발 확인용이다. API 구현·DB 검증 후, 빌드한 JAR를 제한된 Windows 서비스 계정으로 실행하고 시작/종료·재시작·로그 순환·백업/복원을 점검한다. Spring 공식 문서의 Windows 서비스 방식은 WinSW이며 실제 도입/버전은 아직 미확정이다. [Spring 설치 안내](https://docs.spring.io/spring-boot/how-to/deployment/installing.html)

백업은 사용자·금융·분석 결과와 키의 복구 경로를 함께 다룬다. 일반 분석 3개월, 중요보존 예외, 사용자 삭제, 탈퇴 후 1년 규칙은 복원 뒤에도 유지해야 한다. KMS 키 회전만으로 과거 백업의 완전 폐기를 완료했다고 보고하지 않는다.

로컬 생존 확인과 격리 DB의 인증·금융 HTTP 검증은 서버 구현 범위다. DB 운용 버전·네트워크 제품·HTTPS/신뢰 프록시·비밀 주입·백업/KMS 및 Flutter 실제 서버 연결까지 확인해야 팀원/외부 시연 서버 준비 완료로 판단한다.

## 다른 PC·운영체제에 서버 설치

API 실행은 Windows 개발 DB 관리 도구에 의존하지 않는다. [서버 배포·이동 안내](../deploy/README.md)에 따라 실행 JAR·외부 설정 예시만 묶고, 대상 DB 주소·포트·사용자·키를 별도로 제공한다. 다른 환경에서 Java 21로 같은 JAR를 실행하며 소스의 PC 경로를 수정하지 않는다. 제품 설정 로더를 추가하지 않고 Spring의 외부 설정을 사용한다. 설치/재시작은 DB 초기화·키 재생성·자료 이동을 수행하지 않는다.

아래 도구는 **Windows에서 소유한 개발 DB를 관리할 때만** 사용한다. 이 도구의 DPAPI·경로 제한을 일반 배포나 다른 PC의 복구 수단으로 사용하지 않는다.

## 별도 개발 DB·API 제어

저장소 루트에서 JDK 21·Python 3.10+·PowerShell 7·PostgreSQL 도구를 사용한다. 기존 Windows PostgreSQL 서비스는 시작·정지하지 않는다. 개발 도구는 `%LOCALAPPDATA%/PAYSE/development/api-v3/` 아래 **별도 클러스터**만 관리한다. 소유 경로·클러스터 시스템 ID를 대조하며 기존 경로의 재초기화는 거절한다.

- DB: `payse_dev`, `127.0.0.1:15432`. API: `http://127.0.0.1:18080`.
- 기본 포트가 사용 중이면 중단한다. 최초 준비의 `--pg-port`·`--api-port`로 다른 미사용 포트를 명시할 수 있다.
- PostgreSQL 실행 파일 경로는 `init --pg-bin`에서 지정하며 기존 설치를 자동 변경하지 않는다. 현재 확인 환경은 15.13이며 운영 버전 확정이 아니다.
- API는 `database,auth,finance`·직접 접속 모드와 비관리자 계정을 사용한다. 초기화 관리자 비밀번호를 API에 전달하지 않는다.
- 개발 연결 풀은 최대 8개, 연결 대기 5초, 검증 대기 1초다. 이 PC의 검증 설정이며 운영 부하 기준으로 확정한 값이 아니다.
- 공개 응답은 v3다. v4 자료·Flutter·계산 패키지는 변경하지 않는다.

최초 준비는 신규 환경에서 **한 번만** 실행한다. 이미 준비된 환경에서는 다음 초기화 명령을 반복하지 않는다.

```powershell
python -B apps/api/tools/dev_server.py init --pg-bin 'C:\Program Files\PostgreSQL\15\bin'
```

초기화는 001→002→003→004→007, 은행 기준정보, 일반 사용자·금융 원천을 적재하고 기존 합성 코드의 verifier만 새 DB에서 활성화한다. 005/006 이행이나 테스트의 TRUNCATE를 사용하지 않는다. 사용자 설정은 기본 적재 규칙대로 빈 상태이며, B의 새로운 생활 흐름 사례로 자동 전환하지 않는다.

시작 전에 현재 소스의 실행 JAR를 빌드한다. `start`는 해당 JAR를 개발 폴더로 복사하며, 이미 실행 중인 서버를 조용히 교체하지 않는다.

```powershell
node scripts/harness/run-api.mjs check
python -B apps/api/tools/dev_server.py start
python -B apps/api/tools/dev_server.py status
```

```powershell
# API만 재시작한다. DB·키·활성 세션·저장값은 유지한다.
python -B apps/api/tools/dev_server.py restart

# 이 도구가 시작한 API와 전용 DB만 중지한다. 데이터 파일은 유지한다.
python -B apps/api/tools/dev_server.py stop

# 중지 후 같은 DB·키로 다시 시작한다.
python -B apps/api/tools/dev_server.py start
```

현재 Windows 사용자 전용 ACL과 DPAPI로 `secrets.dpapi`를 보호한다. DB 비밀번호·코드/제한/cursor 키는 저장소·명령 인자·평문 설정 파일에 넣지 않는다. 초기 initdb 비밀번호 파일은 준비 직후 삭제한다. API에는 필요한 자식 환경값만 전달한다. 이 보호 파일은 다른 PC/Windows 계정의 복구 수단이 아니므로 임의 복사·키 재생성을 복구 절차로 사용하지 않는다.

HTTP 예시는 **PC 내부 loopback 개발 확인 전용**이다. 모바일·팀원 기기는 이 주소로 접속할 수 없다. 원격 접속을 위해 bind 주소나 방화벽을 임의로 넓히지 않고 앞 절의 사설 접속·HTTPS를 별도로 준비한다. Windows 서비스·자동 시작은 등록하지 않는다.

### 실제 개발 서버 검증

```powershell
python -B -m unittest discover -s apps/api/tests -p test_dev_server.py
python -B apps/api/tools/dev_server.py verify
```

`verify`는 소유 표식과 DB 정체성을 확인한 뒤 실제 HTTP에서 세 계정 로그인·중복 로그인 거절·재확인·연결·100건 페이지·설정 저장·403/409·멱등·API 재시작·재로그인 보존과 DB를 함께 중지·재시작한 뒤의 원천·설정·세션·영수증 보존을 검사한다. 토큰은 메모리에만 두고 마지막에 로그아웃한다. 실행 중 해당 합성 계정을 앱에서 동시에 사용하지 않는다. 기존 활성 세션이 있으면 강제 종료하지 않고 검증을 중단한다.

검증용 지출·모아둘 돈은 API로 논리 취소하고 변경 가능한 설정을 원복한다. 최초 미연결·빈 계좌 선택은 검증 뒤 연결된 상태와 검증 계좌 선택으로 남을 수 있으며 결과에 표시한다. 영수증·버전·취소 이력은 지우지 않는다. 금융 원천 지문은 전후 같아야 한다. 테스트 계정의 검증 상태 변경을 금융 원천 변경으로 처리하지 않는다.

비민감 결과는 개발 폴더의 `verification.json`, 실행 로그는 `api.log`·`postgres.log`에 둔다. 검사 실패는 성공으로 바꾸지 않으며 기존 DB 초기화로 해결하지 않는다. 소유 경로를 확인할 수 없거나 초기 준비가 중단됐으면 도구는 재시작을 거절한다. 경로·로그를 확인한 뒤 중단된 새 환경을 보존하고 새 경로에 준비한다.
