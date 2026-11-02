# 테스트폰 CSR·인증서 발급과 등록

기존 [Android HTTPS](android-https.md)의 Caddy mTLS와 단일 인증서 지문 정책을 사용한다. 공개 서버 인증서와 폰 인증서는 서로 다르다. 이 절차는 테스트폰 등록용이며 실제 금융기관 인증·기기 무결성 증명을 제공하지 않는다.

## B가 제공할 자료

1. Android Keystore에서 앱 전용 비반출 키를 만든다. EC P-256 또는 RSA 2048비트 이상을 사용하고 CSR은 해당 키로 서명한다. 도구는 EC P-384도 지원한다. 실제 하드웨어 보관 여부는 기기에서 확인하며 단순 키 생성만으로 보증하지 않는다.
2. PEM 형식의 단일 `CERTIFICATE REQUEST` 파일, CSR DER의 SHA-256, 키 별칭, 테스트폰 모델·앱 빌드 정보를 전달한다. 키 별칭은 개인키가 아니다. CSR subject에는 실제 이름·전화번호를 넣지 않는다.
3. 개인키·P12·PFX는 전달하지 않는다. 서버에서 대신 만든 폰 키를 앱에 넣지 않는다.

서버가 계산한 CSR 지문을 B의 값과 대조해 받은 요청을 확인한다. CSR 검증은 서명·공개키의 일치를 확인하는 절차이며 그 자체로 특정 물리 기기·앱의 소유권을 입증하지 않는다.

## A의 발급 도구

저장소 루트에서 실행한다. Python 3.10 이상과 OpenSSL 3.x를 사용한다. 실제 경로를 변수에 설정하고 기존 출력 폴더를 재사용하지 않는다. 아래 7일은 짧은 연결 시험의 예시이며 도구 기본값이 아니다. 실제 발급 시 사용할 기간을 명시한다.

```powershell
$openssl = 'C:/도구/openssl.exe'
$csr = 'C:/수신자료/test-phone.csr'
$caCert = 'C:/서버/https/pki/phone-ca.pem'
$caKey = 'C:/서버/https/pki/phone-ca.key'
$output = 'C:/전달자료/phone-enrollment-새번호'

python -B apps/api/tools/issue_phone.py --openssl $openssl --csr $csr `
  --ca-cert $caCert --ca-key $caKey --output $output --days 7
if ($LASTEXITCODE -ne 0) { throw '인증서 발급 실패: 기존 설정을 유지하세요.' }
```

- CSR은 최대 64 KiB이며 단일 PEM·유효 서명을 요구한다. RSA 2048비트 이상 또는 EC P-256/P-384만 받는다. 이는 도구 입력 보호 기준이며 금융 원천 계약과 무관하다.
- CA의 현재 유효기간·서명 용도·키 일치와 발급기간을 확인한다. CA 만료를 넘기거나 기간이 양수가 아니면 거절한다. 암호화 CA 키의 대화형 암호 입력은 지원하지 않는다.
- CSR이 요청한 확장은 복사하지 않는다. 발급 인증서는 `CA:FALSE`, `digitalSignature`, `clientAuth`로 제한한다.
- 출력은 `client.pem`(폰 공개 인증서), `chain.pem`(발급 CA 공개 인증서), `enrollment.json`(공개 지문·기간·키 정보)뿐이다. 폰 개인키를 생성하지 않는다.
- 기존 출력은 덮어쓰지 않는다. 완성된 묶음을 동일 볼륨에서 원자 게시하고 실패한 준비 파일만 정리한다. Windows 동작을 검증했으며 Linux 원자 게시 구현은 실행 검증 전이다.
- `enrollment.json`의 지문에는 `sha256:` 접두사가 있다. 기존 환경변수 Caddyfile에 직접 설정할 때는 인증서 DER의 소문자 64자리 부분만 사용한다. 설치형 생성기가 파일을 읽어 지문을 산출하면 해당 파일을 등록한다.
- 도구는 인증서를 발급할 뿐 Caddy 설정·허용 지문·공개 기동·DB를 변경하지 않는다. `registered:false`는 의도된 결과다.

## 등록·전달 순서

1. B에게 위 공개 파일 세 개를 보낸다. CA 개인키·서버 개인키·DB 자격은 보내지 않는다.
2. B는 `client.pem → chain.pem` 순서의 인증서 체인을 **CSR을 만든 기존 Keystore 키**에 연결한다. 서버 TLS는 Android의 정상 신뢰 체인과 주소 SAN 검증을 유지한다. 폰 발급 CA를 서버 인증서 검증을 우회하는 신뢰 저장소로 설치하지 않는다.
3. Caddy 설정을 변경하기 전에 해당 설치의 HTTPS 종료 절차로 프록시만 종료한다. DB·API·인증 키는 그대로 둔다.
4. 설치형 HTTPS 생성기는 인증서 파일을 HTTPS 폴더 아래 새 등록 경로에 보관하고 `allowedClientCertificate`에 상대경로를 넣는다. 환경변수 Caddyfile은 같은 인증서의 DER 지문을 사용한다. 두 구성 방식을 혼용하지 않는다.
5. 설정 검증 후 기존 단일 지문 정책으로 HTTPS를 시작한다. 인증서 발급 성공만으로 공개 연결 완료로 표시하지 않는다. 무인증·미등록·만료 인증서 거절과 등록 폰 허용을 함께 확인한다.
6. 갱신은 새 CSR·공개 인증서를 받아 앱 적용과 단일 허용 지문 전환을 맞춘다. 자동으로 두 인증서를 동시에 허용하지 않는다. 분실·키 문제는 HTTPS 접근을 중단한 뒤 재등록한다.

## 공개 경로와 실제 테스트

공인 IP 방식은 공유기 TCP 443을 Caddy 수신 주소로 전달하고 Caddy 실행 파일에 한정한 Windows 수신 규칙을 사용한다. API·DB 포트는 loopback에 유지한다. TLS-ALPN 인증서 발급도 외부 443 도달이 필요하므로 포트포워딩 전에는 발급을 반복하지 않는다. 시험 발급과 운영 발급의 저장소를 분리하며 시험 인증서를 앱에 신뢰시키지 않는다. [Let’s Encrypt 도전 방식](https://letsencrypt.org/docs/challenge-types/), [IP 인증서](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)

폰에서는 Wi-Fi를 끈 모바일 데이터로 다음 순서를 확인한다.

1. 주소·서버 인증서·mTLS 성공 및 미등록 접근 차단.
2. 합성 계정 로그인 → 금융 v4 Snapshot → 마지막 거래 페이지까지 수집.
3. 계좌 별칭 등 사용자 설정 저장 → 재조회·재로그인·앱 재실행 후 유지.
4. 급여 안내 GET/PUT 연결 및 동일 사용자·회차의 닫기 유지.
5. 저장한 설정을 소유자 기준 SQL 조회로 확인한다. 기존 금융 원천·급여 근거를 시험 목적으로 임의 변경하지 않는다.

기기 세션 토큰을 잃은 상태에서 새 로그인을 반복하면 단일 활성 세션 정책에 따라 거절될 수 있다. 실제 기기 보안 저장소를 연결하고 검증에서 만든 세션만 명시적으로 로그아웃한다. 공유 계정의 세션을 DB에서 임의 삭제하거나 정책을 우회하지 않는다. [API 계약](../../../docs/api-contract.md), [급여 안내](../docs/salary-notices.md)

공식 기준: [Android Keystore](https://developer.android.com/privacy-and-security/keystore), [Caddy TLS 클라이언트 인증](https://caddyserver.com/docs/caddyfile/directives/tls), [OpenSSL req](https://docs.openssl.org/3.2/man1/openssl-req/), [OpenSSL x509](https://docs.openssl.org/3.2/man1/openssl-x509/).
