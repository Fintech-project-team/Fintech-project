# 서비스 구조

한 저장소에 앱, 앱 API, 별도 더미 서버를 둔다.
앱은 HTTP로 api를 호출하고 api는 HTTP로 mock-bank를 호출한다. DB 저장과 AI 호출은 api에서 처리한다.
모바일 목표는 Flutter다. 앱 측 계산을 공통 순수 계산 영역으로 분리하고 JSON 데이터 계약을 공유한다. 기존 finance-core/contracts는 Node 골격이므로 Flutter에서 직접 import하지 않는다. 실제 Dart 연결은 [전환 기준](harness/FLUTTER_TRANSITION.md)의 초기화 작업에서 정한다.

아래 앱 경로는 현재 보존된 이전 골격이다. 신규 Flutter의 lib 경로와 하네스 역할은 전환 기준에 따라 함께 확정하며, 이 표를 신규 Expo 구현 지시로 사용하지 않는다.

| 경로                                | 담당 기능                                   | 제한                                                             |
| ----------------------------------- | ------------------------------------------- | ---------------------------------------------------------------- |
| apps/mobile/app                     | 화면 이동과 레이아웃                        | 금융 계산·큰 화면 구현을 넣지 않는다                             |
| apps/mobile/src/features/connection | 데모 연결·조회 상태                         | 금융사에 직접 연결하지 않는다                                    |
| apps/mobile/src/features/recurring  | 지출 후보 확인·수정                         | AI 제공자에 직접 연결하지 않는다                                 |
| apps/mobile/src/features/spending   | 사용 여유·What-if 화면                      | 계산식을 복사하지 않는다                                         |
| apps/mobile/src/features/allocation | 배분 계획·은행 이동 안내                    | 링크 실행을 이체 완료로 표시하지 않는다                          |
| apps/mobile/src/shared              | 공통 UI·API 클라이언트·저장 연결            | 기능 간 임의 참조를 만들지 않는다                                |
| apps/api/src/modules                | snapshots, recurring, allocations, analysis | mock-bank 소스를 import하지 않는다                               |
| apps/api/src/infrastructure         | DB·금융 API·AI 제공자 연결                  | 앱 화면 코드를 넣지 않는다                                       |
| apps/mock-bank                      | 합성 데이터·시연 사례                       | 실제 토큰·이체를 사용하지 않는다                                 |
| packages/contracts                  | 스키마·요청/응답·오류 형식                  | 앱·DB에 의존하지 않는다                                          |
| packages/finance-core               | 입력값으로 결과를 계산                      | 네트워크·LLM·UI 프레임워크·현재 시각 자동 조회에 의존하지 않는다 |

다른 기능의 내부 파일을 직접 import하지 않는다. 필요한 데이터와 함수를 먼저 합의하고 공개한다.
루트 설정·라우터·shared는 integration이 조정한다. 각 기여자는 작업 명세에 허용된 파일만 수정한다.

## 저장

- 사용자 확정 지출·배분 계획은 서버에 저장한다. 기기에는 마지막 스냅샷과 결과를 읽기 캐시로 둔다.
- 첫 버전은 서버 저장이 성공한 뒤 확정한다. 저장 상태를 pending/saved/failed로 구분한다.
- version이 다르면 덮어쓰지 말고 다시 조회한다. 오래된 데이터와 저장 실패를 알린다.
- DB 연결 전 메모리 저장은 재시작하면 사라진다고 표시한다.

## 분석

- analysis 모듈이 공통 입력·출력 형식을 정의한다. infrastructure/analysis에서 rules, general-llm, jev를 연결한다.
- 후보에 근거 거래 ID·금액·예정일·분석 버전·사용자 확인 상태를 포함한다.
- AI 제공자마다 다른 confidence 값을 같은 확률로 비교하지 않는다.
- 실패·시간 초과를 알리고 규칙 기반 후보 또는 확인 필요 상태로 처리한다.

현재는 폴더와 규칙만 준비됐다. 코드 추가 시 import 제한·실행 중 입력 검사·타입 검사·데이터 형식 테스트를 연결한다.
문서만으로 다른 영역의 참조나 수정이 자동 차단된다고 가정하지 않는다.
