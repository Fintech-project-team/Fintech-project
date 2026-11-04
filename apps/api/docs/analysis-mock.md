# 팀원용 분석 모의 공급자 서버

[공통 합의](../../../docs/analysis-protocol.md)의 HTTP 연동용이다. 실제 Spring 인증·접수·상태·계약 검증·암호화 저장·결과 조회를 사용하고, 모델과 KMS만 테스트 대역으로 교체한다. OpenAI 키·Google 결제·운영 DB가 필요 없다. 유료 공급자 호출은 0이다. 응답의 통신료 의미는 정해진 합성 결과이며 AI 추론 성능을 측정하지 않는다.

테스트 클래스는 `src/test`에만 있고 운영 bootJar 포함 여부도 검사한다. 실행기는 새 작업 폴더·전용 DB·무작위 DB 역할·임시 로그인 코드·임시 암호화 키를 만들며 `127.0.0.1`에만 열린다. 기존 API·DB·방화벽·원격 접속을 변경하지 않는다.

## 준비와 시작

저장소의 [도구 버전](../../../docs/toolchain.md)에 맞는 JDK 21, Python, PostgreSQL 바이너리와 Gradle 의존성 접근이 필요하다. 설치된 PostgreSQL 서비스가 아니라 `initdb`, `pg_ctl`, `psql` 바이너리를 사용해 별도 클러스터를 만든다. `JAVA_HOME`과 Python PATH를 설정한다. 아래 명령은 **저장소 루트**에서 실행하고 `--pg-bin`만 해당 PC의 설치 위치로 바꾼다.

```powershell
python -X utf8 -B apps/api/testing/protocol/mock_server.py --work-dir .harness/protocol-team-01 --pg-bin "C:/Program Files/PostgreSQL/15/bin" --port 43180 --scenario success
```

Linux/macOS에서도 같은 Python 진입점에 실제 PostgreSQL 바이너리 디렉터리를 전달한다. root 계정으로 PostgreSQL을 실행하지 않는다. 최초 실행은 Gradle 의존성을 받을 수 있고 운영 설정은 자식 실행 환경에서 제외된다. Java 최대 힙 256 MiB, 컴파일은 512 MiB·worker 1을 사용한다. 이미 쓰는 포트를 빼앗지 않으며 `--port 0`이면 빈 포트를 선택한다.

`READY`가 출력된 뒤 생성 파일을 사용한다. 로그인 정보는 콘솔에 출력하지 않는다.

| 작업 폴더 파일            | 용도                                                                                             |
| ------------------------- | ------------------------------------------------------------------------------------------------ |
| `connection.private.json` | 실제 baseUrl과 `/demo-sessions`용 합성 이름·전화·무작위 코드. **Git/채팅/공유 문서에 복사 금지** |
| `requests.json`           | DB와 일치하는 accept/input/query JSON 예제. input의 permit은 실제 접수 응답에서 채운다.          |
| `ready.json`              | 모의 서버 준비 상태·주소·모드                                                                    |
| `api.log`, DB 로그        | 로컬 오류 진단. 비공개 파일로 취급한다.                                                          |
| `smoke.json`              | `--smoke` 실행 때의 검증 요약                                                                    |

연결 설정을 소스에 하드코딩하지 않는다. Git에 넣는 [설정 예시](../testing/protocol/connection.example.properties)는 빈 값만 갖는다. 모의 인증은 한 데모 사용자로 재현하므로 동시에 여러 클라이언트가 로그인할 때 세션 교체에 유의한다.

## 연동 순서

1. `connection.private.json`의 login으로 `POST /demo-sessions`를 호출하고 반환 토큰을 Bearer에 설정한다. 샘플 원천은 `demo-life`의 합성 통신료 3개월 근거다.
2. `requests.json.accept`로 `/analysis-jobs`를 호출한다. 응답의 jobId를 계속 사용한다. `action=submitInput` 때 permit을 `requests.json.input`에 넣어 `/analysis-jobs/{id}/input`에 제출한다.
3. `GET /analysis-jobs/{id}`로 상태를 읽는다. 실행 중에는 `Prefer: wait=5`를 사용할 수 있다. 완료 뒤 `requests.json.query`로 `/analysis-results/query`를 호출한다.
4. 앱을 닫았다 열거나 로그인한 뒤 같은 현재 입력으로 결과를 다시 조회한다. 조회는 추가 공급자 시도를 만들지 않는다. 실행 실패 시 자동 재호출하지 말고 review 목록을 화면에 표시한다.

요청·응답의 형식은 [HTTP Schema](../contracts/analysis-http.schema.json), 동작은 [분석 API](analysis-api.md)를 따른다. 새로운 명시 요청은 새 idempotencyKey, 동일 전송의 응답 재확인은 기존 키를 유지한다. 공유 벡터의 임의 UUID는 이 서버의 DB에 없으므로 HTTP 실행 입력으로 그대로 사용하지 않는다.

예제는 반복 후보 1개이므로 기존 Q2의 **10건 또는 60초** 조건에 따라 약 60초 queued 상태를 거친다. 이것은 모델 지연이나 실패가 아니다. `--delay-ms`는 입력 허가 이후 모델 대역 지연에만 적용되며 실제 접수 정책을 바꾸지 않는다.

## 재현 모드

[공개 HTTP 예제 14개](../testing/protocol/fixtures/http-examples.json)는 DTO와 화면 상태 파서용이다. 설명용 합성 permit/ID를 실제 요청에 복사하지 않는다. 실행 시에는 새 `requests.json`과 서버가 반환한 permit을 사용한다.

| `--scenario`   | 첫 모델 시도                    | 다음 시도                         |
| -------------- | ------------------------------- | --------------------------------- |
| `success`      | 유효 반복 의미 `candidate`      | 같은 동작                         |
| `unknown`      | 유효 의미 `unknown`, value=null | 같은 동작. 실행 실패가 아님       |
| `invalid_once` | 잘못된 출력으로 서버 검증 실패  | 사용자가 `/retry`를 호출해야 성공 |
| `timeout_once` | 전송 후 결과 불명               | 중복 위험 확인한 `/retry`만 성공  |

`--delay-ms`는 0–10000 사이의 모의 응답 지연이다. 실패 횟수는 **프로세스 단위 첫 생성 호출**에 적용한다. 시나리오를 다시 시작할 때 새 작업 폴더를 사용한다. 원천이 같은 저장 결과를 재조회하면 실패를 새로 발생시키지 않는다.

다음처럼 `--smoke`를 붙이면 새 DB에서 인증→접수→입력→저장/수동 재시도→결과 복원→인증 거절을 자동 검사하고 서버·DB를 종료한다. 실패 테스트도 각기 새 폴더와 해당 scenario로 실행한다.

```powershell
python -X utf8 -B apps/api/testing/protocol/mock_server.py --work-dir .harness/protocol-smoke-01 --pg-bin "C:/Program Files/PostgreSQL/15/bin" --port 0 --scenario invalid_once --smoke
```

## 접속 범위와 종료

모바일 앱의 baseUrl은 실행 환경에 맞춰 외부 설정으로 주입한다. 같은 PC의 데스크톱 테스트는 출력된 loopback 주소를 사용한다. USB Android는 개발자가 허용한 기기에 `adb reverse tcp:43180 tcp:43180`을 설정한 뒤 기기에서 loopback으로 접속할 수 있다. 다른 PC에서는 각자 실행하거나 승인된 SSH 터널을 사용한다. 모의 서버를 공인 IP에 공개하거나 기존 운영 프록시에 연결하지 않는다. 현재 테스트폰의 운영 mTLS URL을 자동 교체하지 않는다. 개발용 HTTP 허용과 실제 기기 연결은 B가 해당 빌드에서 확인해야 한다.

실행 터미널에서 Ctrl+C 또는 다른 터미널에서 다음 명령을 사용한다. 실행기가 자신이 만든 API와 PostgreSQL만 종료한다.

```powershell
python -X utf8 -B apps/api/testing/protocol/mock_server.py --work-dir .harness/protocol-team-01 --stop
```

기본 최대 실행 시간은 8시간이며 `--max-seconds`로 줄일 수 있다. 재시작은 새 폴더·새 DB를 만드는 방식이다. 암호화 대역 키는 메모리에만 있으므로 종료한 DB의 결과 복구를 지원하지 않는다. **앱 재접속 복원**과 **모의 서버 재시작 복원**은 다르다. 재현 자료가 필요 없으면 종료·소유 폴더 경계를 확인한 후 해당 작업 폴더만 삭제한다. 광범위한 프로세스 종료나 다른 DB 삭제는 필요 없다.

## 공개 규격 검사

```powershell
python -X utf8 -B -m unittest discover -s apps/api/testing/protocol -p "test_*.py"
```

Java에서는 `apps/api`에서 `gradlew test --tests "*Protocol*Test"`로 실제 AnalysisIdentity와 공개 30개 사례를 대조한다. B는 [공통 합의](../../../docs/analysis-protocol.md)의 중간 값까지 Dart에서 대조한다. 이 검사는 모델 정확도·유료 실행 속도·모바일 제품 연동 통과를 의미하지 않는다.

`apps/api/testing/protocol/dart`에서 `dart pub get` 후 `dart run check.dart`를 실행하면 별도 Dart 참조 구현으로도 같은 30개를 검사한다. Java·Dart·Python의 기대값을 맞추려고 fixture를 수정하지 말고 다른 첫 중간값부터 원인을 확인한다.
