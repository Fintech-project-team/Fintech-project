# PAYSE 서버 설치·이동

동일한 실행 JAR를 유지하고 설치 환경값만 바꾼다. API 응답·원천·계산 계약을 바꾸지 않는다. Windows 전용 개발 DB 관리 도구와 독립적이며, 실행에는 Java 21과 준비된 PostgreSQL이 필요하다. Node·Gradle·Python·Flutter는 배포 서버의 실행 의존성이 아니다. Java가 지원하는 Windows·Linux·macOS에 같은 실행 명령을 사용하며, 실제 검증한 OS는 작업 보고에서 구분한다.

## 1. 배포 묶음 만들기

소스 저장소에서 기존 API 검사를 통과한 JAR로 묶는다. 출력 위치는 변경할 수 있고 기존 폴더는 덮어쓰지 않는다.

```text
node scripts/harness/run-api.mjs check
python -B apps/api/tools/package_server.py --output dist/payse-server
```

다른 빌드 산출물을 선택할 때는 `--jar <실행-JAR-경로>`를 지정한다. 묶음은 `server.jar`, `server.properties.example`, 이 안내, Dockerfile·.dockerignore·Caddyfile·android-https.md, 파일별 SHA-256을 담은 `manifest.json`만 포함한다. 키·DB·로그·원천 JSON·현재 PC의 설치 경로를 복사하지 않는다. 생성 실패로 일부 파일만 남았다면 새 출력 폴더를 지정하며 기존 자료를 자동 삭제하지 않는다.

## 2. 설치 환경값 준비

묶음을 원하는 폴더에 복사하고 그 폴더에서 작업한다. `server.properties.example`을 `server.properties`로 복사한 뒤 다음 값을 수정한다.

| 바꿀 값                            | 의미                                                                      |
| ---------------------------------- | ------------------------------------------------------------------------- |
| `PAYSE_BIND_ADDRESS`, `PAYSE_PORT` | API 수신 주소·포트. 예시의 loopback은 같은 PC에서만 접근 가능             |
| `PAYSE_JDBC_URL`                   | 대상 DB의 호스트·포트·DB 이름. 원격 DB의 TLS 옵션은 해당 DB 정책대로 지정 |
| `PAYSE_DB_USER`                    | `payse_runtime` 역할을 사용할 비관리자 접속 사용자                        |
| DB 풀·timeout 3개                  | 대상 DB 연결 예산·대기시간. 예시 숫자는 운영 권고값이 아님                |
| `PAYSE_AUTH_CODE_KEY_ID`           | DB에 저장된 합성 코드 verifier와 일치하는 키 ID                           |
| `spring.config.import`             | 비밀 파일 디렉터리. 예시는 실행 폴더의 `secrets/`                         |

설정 경로도 바꿀 수 있다. 상대 경로는 **Java를 실행한 작업 폴더** 기준이다. 절대 경로는 `/` 구분자를 사용하고 `configtree:` 경로 끝의 `/`를 유지한다. 환경변수·Java 시스템 속성·명령 인자는 파일보다 우선하므로 이전 설치의 `PAYSE_*`, `SPRING_*`, Java 옵션을 무심코 상속하지 않는다.

설치 시 DB를 자동 생성·초기화하거나 자료를 적재하지 않는다. 새 DB 준비는 저장소의 `apps/api/docs/database-tests.md`, `auth-database.md`에 있는 초기 스키마·권한·합성 계정 준비 절차를 별도로 따른다. 기존 DB에는 초기 SQL을 재실행하지 않는다. DB 역할 이름·API 필드·v3/v4 계약은 설치 환경값이 아니므로 바꾸지 않는다.

## 3. 비밀번호·키 준비

`secrets/`에 아래 **이름의 파일**을 만들고 각 파일에는 해당 값 하나만 넣는다. 끝 줄바꿈 없이 UTF-8로 기록한다. DB 비밀번호를 임의 trim하거나 변환하지 않는다.

```text
secrets/
  PAYSE_DB_PASSWORD
  PAYSE_AUTH_CODE_KEY_BASE64
  PAYSE_AUTH_LIMIT_KEY_BASE64
  PAYSE_FINANCE_CURSOR_KEY_BASE64
```

파일 생성 전에 설치 폴더·비밀 폴더를 실행 사용자만 읽도록 제한한다. Windows는 해당 실행 계정의 ACL을, Linux/macOS는 디렉터리 `700`·파일 `600` 등 실행 사용자 전용 권한을 사용한다. 비밀 파일은 Git·배포 묶음·채팅에 넣지 않는다. 조직의 비밀 관리 도구가 같은 파일을 마운트하거나 환경변수로 전달해도 기존 설정 키를 사용할 수 있다.

기존 DB로 서버를 옮길 때는 **현재 유효한 키와 ID를 별도 보호 경로로 이관**한다. 설치·재시작마다 키를 생성하지 않는다. 코드 키가 바뀌면 기존 verifier가 맞지 않고, 제한·cursor 키가 바뀌면 기존 식별·페이지 검증이 달라진다. Windows 개발 도구의 `secrets.dpapi`는 다른 PC/사용자에서 직접 사용하는 파일이 아니다. 새 DB의 최초 키 준비와 기존 DB의 키 이관을 구분한다.

필수 비밀 디렉터리·키·DB 설정이 빠지면 시작을 실패시킨다. 편의를 위해 `optional:`이나 임시 키를 추가하지 않는다. 외부 파일 방식은 저장 매체 자체의 암호화를 대신하지 않으므로 필요하면 암호화 볼륨·비밀 마운트를 사용한다.

## 4. 실행·이동·중지

설치 폴더로 이동하고 Java 21인지 확인한 뒤 실행한다.

```text
java -version
java -jar server.jar --spring.config.additional-location=file:./server.properties
```

JAR 경로나 설정 파일 경로를 바꾸려면 두 인자를 변경하면 된다. 경로에 공백이 있으면 해당 인자 전체를 따옴표로 감싼다. 명령 인자에는 비밀번호·키를 쓰지 않는다. Windows는 `java.exe`, Linux/macOS는 `java`가 있는 PATH 또는 해당 실행 파일의 절대 경로를 사용한다. 중지는 실행 터미널의 Ctrl+C이며 DB는 중지·삭제하지 않는다. 재시작은 같은 설정·키·DB로 같은 명령을 실행한다.

`GET /internal/health/live`의 `200 {"status":"UP"}`은 프로세스 생존만 뜻한다. 설정한 주소·포트로 합성 로그인·조회·저장·재로그인 유지도 확인해야 서버 기능 검증이 된다. API는 웹 UI를 제공하지 않으며 Flutter 연결은 별도다.

다른 컴퓨터로 옮겨도 동일 DB를 유지하면 기존 설정을 조회한다. DB 자체도 옮기려면 PostgreSQL 백업·복원과 역할·키 이관을 별도로 검증해야 하며 이 묶음은 DB 이행을 수행하지 않는다. API 업데이트는 실행 프로세스를 종료하고 새 JAR로 교체하되 현지 설정·비밀·DB는 보존한다.

## 외부 접속의 경계

기본값은 loopback이고 방화벽·자동 시작·서비스 계정·TLS·CORS 설정을 자동 변경하지 않는다. 기존 `direct`는 전달 헤더를 무시한다. 동일 호스트 프록시는 `loopback-proxy`를 명시하고 [Android HTTPS](android-https.md)의 바인딩·헤더 재작성·인증서 조건을 모두 지킨다. 임의 전달 헤더 신뢰, 전체 인터넷 공개, 모바일의 인증서 검증 해제는 설치 편의에 포함하지 않는다. 외부/팀원 접속 방식과 프록시 신뢰는 별도 검증 후 구성한다.

설정 파일·환경변수·config tree는 Spring Boot의 기존 외부 설정 기능을 이용한다. 설정 로더를 제품 코드에 중복 구현하지 않는다. [Spring Boot 공식 외부 설정](https://docs.spring.io/spring-boot/reference/features/external-config.html)

## Docker 및 KMS 준비

배포 묶음의 Dockerfile은 검증한 Java 21 이미지 digest를 고정하고 JAR만 복사하여 비관리자 UID 10001로 실행한다. `.dockerignore`로 비밀·DB·로그를 빌드 문맥에서 제외한다. 묶음 폴더에서 `docker build -t payse-api:local .`을 실행한다. 실제 DB 연결은 외부 설정·비밀 파일을 읽기 전용 마운트하여 별도로 준비한다. 호스트 loopback DB는 Docker bridge에서 자동 접근 가능하다고 가정하지 않는다. 이미지 빌드·생존 확인은 컨테이너 DB 연결 완료가 아니다.

Google Cloud KMS는 로컬 프로그램이 아니라 클라우드 키 서비스다. 설치된 gcloud CLI는 프로젝트·리전·키링·키·실행 주체가 정해진 뒤 사용한다. 프로젝트 미준비 상태에서는 로그인·서비스 활성화·키 생성·권한 부여·유료 호출을 하지 않는다. 실제 활성화 때에는 해당 키에만 암복호화 권한을 주고 갱신 가능한 인증 공급자를 기존 GoogleKms 어댑터에 연결한다. CLI 설치나 JAR 포함만으로 암호화 저장이 활성화되지 않는다.

공식 근거: [Docker 비밀 분리](https://docs.docker.com/build/building/secrets/), [Google CLI 설치](https://docs.cloud.google.com/sdk/docs/downloads-versioned-archives), [KMS 최소 권한](https://docs.cloud.google.com/kms/docs/iam).
