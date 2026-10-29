# Windows PC에서 PAYSE 서버 준비하기

처음에는 본인·팀원만 접속하고, 이후 외부 시연 접속을 추가할 수 있는 구조로 준비한다. **이 문서는 설치 가이드이며 설치·외부 공개를 실행한 결과가 아니다.** 현재 소스는 생존 확인과 명시적으로 설정한 `database`+`auth` 프로필의 로그인·재확인·로그아웃 HTTP를 제공한다. 직접 접속 모드·DB·암호 설정은 [인증 DB·HTTP](auth-database.md)를 따른다. 금융 조회·설정·분석 HTTP와 아래 프록시/외부 접속 구성은 아직 구현·검증하지 않았다.

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
3. 신규 빈 DB에만 [DB 테스트/준비 절차](database-tests.md)와 [인증 DB](auth-database.md)의 사전 조건을 확인한 뒤 `001_initial.sql → 002_storage_guards.sql → 003_auth_access.sql → 004_auth_sessions.sql` 순서로 적용한다. 이 문서만 보고 사용 중 DB에 실행하지 않는다.
4. SQL은 psql 진입 파일을 사용한다. `\ir`로 포함되는 하위 파일을 단독 적용하거나 기존 트랜잭션을 재포장하지 않는다. 서버 시작 시 스키마 자동 변경은 하지 않는다.
5. 일반 users·user_attributes·금융 테이블에 승인된 합성 자료를 적재한다. 테스트 시나리오·수리비 검증 사례를 모든 사용자의 기본 설정으로 넣지 않는다. 코드 verifier가 DISABLED인 시드는 별도 활성화 준비가 필요하다.
6. 앱 접속 역할은 비관리자이며 필요한 runtime 역할만 부여한다. PostgreSQL 5432는 휴대폰·인터넷에 공개하지 않는다. DB 소유자/superuser/BYPASSRLS 자격을 API 실행 계정으로 사용하지 않는다.

PostgreSQL 공식 정책은 major별 최신 minor 사용을 권고한다. major 변경은 데이터 이행 절차가 필요하므로 이미 설치된 자료 위에 새 버전을 덮어 문제를 해결하지 않는다. [공식 버전 정책](https://www.postgresql.org/support/versioning/)

## 5. DB·인증 실행 설정

`database,auth` 프로필을 사용할 때 필요한 환경값은 [초기화 안내](spring-bootstrap.md#db-연결-설정)와 [인증 기반](auth-foundation.md)을 따른다.

| 설정 묶음 | 준비할 값                                                                              |
| --------- | -------------------------------------------------------------------------------------- |
| DB        | JDBC 주소, 접속 사용자/비밀번호, 최대 풀 크기, 연결 획득/검증 timeout                  |
| 인증      | 코드 키 ID, 서로 다른 무작위 32바이트 키 2개, 올바르게 준비된 합성 코드 verifier       |
| 분석      | 승인 모델/스키마/단가/기존 비용, 외부 KMS, 호출·보관·폐기 프로필. 미준비면 분석 비활성 |

비밀값은 Git·배치·채팅·PowerShell 명령 이력에 적지 않는다. 제한된 서비스 계정의 실행 환경/비밀 저장소로 주입하고 읽기 권한을 제한한다. 풀/timeout에 테스트 값을 복사해 운영 기본값으로 쓰지 않는다. 연결 설정이 성공해도 #22 HTTP 구현 전에는 앱 로그인이 되지 않는다.

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

**현재 실행 가능한 단계는 2~3의 로컬 확인이다.** DB 운용 버전·네트워크 제품·HTTPS/신뢰 프록시·비밀 주입·백업/KMS와 실제 업무 HTTP가 준비되어야 팀원/외부 시연 서버 준비 완료로 판단한다.
