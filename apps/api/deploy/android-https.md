# Android HTTPS 시연 연결 준비

이 안내는 **같은 Windows PC에서 실행하는 Caddy → native Java API → 별도 개발 DB** 구성에 적용한다. 공개 HTTPS를 사용하되 등록한 테스트폰의 클라이언트 인증서를 확인한다. API·DB는 loopback을 유지하며 신규 금융 응답은 v4이며 기존 v3 DB는 이행하지 않는다. 급여 안내 API·PAYSE 로그인 정책은 유지한다.

현재 도메인·공개 접속 경로·실제 서버 인증서·폰 CSR은 준비되지 않았다. 아래 명령은 해당 자료를 확보한 뒤 사용하는 절차다. 로컬 TLS 검증 성공은 외부 접속·실제 Android 연동 완료를 뜻하지 않는다.

## 1. 공개 전에 준비할 자료

| 자료                 | 확인할 내용                                                                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| 도메인·서버 이름     | Android가 사용할 HTTPS 이름과 서버 인증서의 SAN이 일치해야 한다.                                                                                 |
| 공개 경로            | 해당 PC로 들어오는 공인 IP·공유기/NAT·Windows 방화벽 경로를 확인한다. 공인 주소/인바운드 연결이 제공되지 않으면 먼저 접속 경로를 해결한다.       |
| 서버 인증서·개인키   | Android가 신뢰할 인증서 체인을 확보한다. 발급자·발급 방식·갱신 절차가 정해지기 전에 준비 완료로 간주하지 않는다.                                 |
| 폰 CSR               | B가 테스트폰의 Android Keystore 안에서 비반출 개인키를 생성하고 해당 공개키의 CSR을 제공한다. 폰 개인키를 PC·채팅·Git·앱 자산으로 옮기지 않는다. |
| 클라이언트 인증서·CA | 확인한 CSR에 대한 clientAuth 인증서와 이를 검증할 CA 인증서를 준비한다. 발급/보관 주체와 유효기간은 별도로 확인한다.                             |
| 허용 인증서 지문     | 등록한 클라이언트 인증서 DER 바이트의 SHA-256을 소문자 64자리 16진수로 사용한다. 개인키나 PEM 텍스트의 해시가 아니다.                            |

Caddy의 `require_and_verify`는 신뢰한 CA의 유효 인증서를 요구하고, 추가 지문 비교는 **등록한 인증서 한 개만** 허용한다. 같은 CA가 발급한 다른 인증서도 403으로 거절한다. 인증서 파일을 다른 기기에 복제 가능한 개인키와 함께 배포하면 물리 기기 제한이 되지 않으므로, 폰 비반출 키와 실제 앱의 TLS 연결을 함께 검증한다. [Caddy TLS](https://caddyserver.com/docs/caddyfile/directives/tls), [Android Keystore](https://developer.android.com/privacy-and-security/keystore)

## 2. API·Caddy 설정

[서버 설치 안내](README.md)에 따라 준비한 DB·설정·비밀 파일을 재사용한다. API 설정은 다음과 같다.

```properties
PAYSE_BIND_ADDRESS=127.0.0.1
PAYSE_AUTH_PEER_MODE=loopback-proxy
server.forward-headers-strategy=none
```

API 포트는 설치 환경값을 사용한다. 급여 안내를 제공하려면 기존 스키마와 함께 `009_salary_notices.sql` 준비 및 `salary-notices` 프로필이 필요하다. 기존 DB에 초기 SQL을 다시 실행하지 않는다.

[Caddyfile](Caddyfile)을 실행하는 프로세스에는 다음 환경변수를 모두 제공한다. 값·경로는 설치 환경에 맞게 지정하고, 키 원문을 환경변수나 명령 인자에 넣지 않는다.

| 환경변수              | 값                                                |
| --------------------- | ------------------------------------------------- |
| `PAYSE_PUBLIC_HOST`   | 스킴·경로·포트가 없는 서버 DNS 이름               |
| `PAYSE_TLS_PORT`      | Caddy의 HTTPS 수신 포트                           |
| `PAYSE_PROXY_BIND`    | 검증 전 `127.0.0.1`; 공개 전 검토한 PC 수신 주소  |
| `PAYSE_TLS_CERT`      | 서버 인증서·필요한 중간 인증서가 든 PEM 파일 경로 |
| `PAYSE_TLS_KEY`       | 서버 개인키 PEM 파일 경로                         |
| `PAYSE_CLIENT_CA`     | 테스트폰 인증서를 검증하는 CA PEM 파일 경로       |
| `PAYSE_CLIENT_SHA256` | 허용할 클라이언트 인증서 DER의 SHA-256 지문       |
| `PAYSE_API_UPSTREAM`  | 같은 PC API의 `127.0.0.1:실제_API_포트`           |

파일 경로는 절대경로를 사용하고 실행 계정만 개인키를 읽도록 제한한다. Caddyfile의 환경변수는 설정을 해석할 때 치환되므로 값을 바꾼 뒤에는 재검증·재시작해야 한다. [Caddy 환경변수](https://caddyserver.com/docs/extending-caddy/placeholders)

Caddy는 외부의 `Forwarded`, `X-Forwarded-For`, `X-Real-IP`를 제거하고 직접 연결한 상대 IP로 `X-Payse-Client-IP`를 다시 작성한다. API는 loopback 프록시 모드에서만 그 단일 숫자 IP를 읽는다. 프록시 앞에 별도 터널·로드밸런서를 추가하면 현재 상대 IP 의미가 달라지므로 그대로 적용하지 않는다. 같은 PC의 신뢰할 수 없는 로컬 프로세스까지 구분하는 인증 방식은 아니다.

## 3. 검증·실행

Caddy·OpenSSL 경로는 실제 설치 위치를 사용한다. 저장소 루트에서 아래 검사를 실행한다.

```powershell
python -B apps/api/tools/check_tls_proxy.py --caddy "C:/설치경로/caddy.exe" --openssl "C:/설치경로/openssl.exe"
```

이 도구는 폐기용 CA·인증서와 임시 loopback 포트로 허용 인증서, 같은 CA의 미등록 인증서, 인증서 없음, IP 헤더 위조를 확인한다. 실제 폰 키·실제 DB·공개 주소는 사용하지 않는다.

실제 인증서와 환경변수 준비 후 저장소 루트에서 설정을 검사하고 실행한다. 배포 묶음에서 실행하면 config 경로를 같은 폴더의 Caddyfile로 바꾼다.

```powershell
& "C:/설치경로/caddy.exe" validate --config apps/api/deploy/Caddyfile --adapter caddyfile
& "C:/설치경로/caddy.exe" run --config apps/api/deploy/Caddyfile --adapter caddyfile
```

`validate`가 실패하면 실행하지 않는다. 파일 경로·인증서·키가 유효해도 DNS·방화벽·Android 연결까지 검증한 것은 아니다. 현재 Caddyfile은 `admin off`, `auto_https off`이며 인증서 자동 발급·갱신이나 관리 API를 제공하지 않는다. [Caddy 명령](https://caddyserver.com/docs/command-line), [Caddy 전역 설정](https://caddyserver.com/docs/caddyfile/options)

공개 전에는 Caddy 포트만 검토한 경로로 열고 API·DB 포트는 외부에 열지 않는다. 공유기/NAT를 쓰면 공개 HTTPS 포트를 Caddy 수신 포트에 연결한다. 일반 인터넷과 별도 기기에서 인증서 없이 접근이 차단되고, 등록 폰에서는 서버 인증서 검증을 유지한 채 로그인·조회·저장·재로그인이 동작하는지 확인한다.

## 4. 갱신·차단

- 서버 인증서는 만료 전에 갱신된 체인·개인키를 별도 파일로 준비하여 검증한다. 현재 구성은 파일 갱신만으로 자동 반영된다고 가정하지 않는다.
- 폰 인증서가 갱신되면 새 인증서 지문도 변경된다. B의 새 인증서 적용과 서버의 단일 지문 전환 시점을 맞춘다. 두 인증서를 동시에 허용하는 정책은 이 구성에 없다.
- 변경한 설정은 `validate` 후 실행 터미널의 Ctrl+C로 Caddy를 종료하고 다시 `run`한다. `admin off`이므로 `caddy reload`·`caddy stop` 관리 API 명령에 의존하지 않는다. 전환 중 접속 중단이 있다.
- 분실·키 문제 발생 시 Caddy 공개 접속을 중단하고 재등록을 완료한 뒤 다시 연다. 인증서 폐기 사실이 자동 CRL/OCSP 확인으로 즉시 반영된다고 가정하지 않는다.
- 재시작 후 이전 인증서·미등록 인증서가 차단되고 등록 인증서만 통과하는지 확인한다. PAYSE 세션 검증은 mTLS와 별도로 유지된다.

## 5. A·B 인계

| A가 제공                                                               | B가 제공·반영                                                                   |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| 최종 HTTPS Base URL, 배포 커밋, 금융 v4·급여 안내 계약, 계정·시연 사례 | 테스트폰 Android 버전, Keystore 키 생성·CSR, 앱의 클라이언트 인증서 TLS adapter |
| 발급한 클라이언트 인증서·체인, 등록 지문, 갱신·차단 일정               | 인증서 적용 결과, 서버 이름·체인 검증 유지, 무인증/미등록 인증서 거절 결과      |
| 실제 API 로그인·조회·저장·급여 안내 검증 결과                          | 실제 HTTP 금융·급여 안내 연결, nullable 청구일 처리, 재로그인·오류 표시 결과    |

인증서 요구로 생기는 TLS 실패 또는 프록시의 403은 PAYSE 업무 JSON 응답과 다를 수 있으므로 앱의 연결 오류와 계정 오류를 구분한다. 실제 Android 연결 코드는 B가 수정하며, API 작업자가 모바일·계산 패키지를 수정하지 않는다.

## 6. Docker·KMS 경계

현재 `loopback-proxy`는 **native Java API와 Caddy가 같은 PC의 loopback을 공유하는 구성**이다. Docker bridge의 `127.0.0.1`은 호스트 loopback과 같지 않다. 이 가이드를 컨테이너에 그대로 적용하거나 API를 `0.0.0.0`로 열어 우회하지 않는다. Docker 이미지는 별도 배포 준비물이며 컨테이너 네트워크·DB 연결 검증을 구분한다. [Docker Desktop 네트워크](https://docs.docker.com/desktop/features/networking/)

Google Cloud 프로젝트가 없으므로 gcloud CLI 설치·실행 가능 여부 확인까지만 준비한다. 로그인·프로젝트/키 생성·KMS 활성화·유료 호출은 하지 않는다. KMS는 분석 암호화용 외부 서비스이며 도구 설치만으로 PAYSE 분석 저장이 활성화되지 않는다. [Google CLI 설치](https://docs.cloud.google.com/sdk/docs/downloads-versioned-archives)
