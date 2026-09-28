# 서비스 구조와 의존 방향

모노레포 하나에 앱, 앱 API, 별도 더미 서버를 둔다. 처음부터 기능마다 서버를 나누지 않는다.

```text
mobile ── HTTP ──> api ── HTTP ──> mock-bank
  │                 ├─ persistence (나중에 PostgreSQL)
  │                 └─ analysis (rules / general-llm / jev)
  └─ finance-core ──> contracts
mobile / api / mock-bank ──> contracts
```

## 영역

| 경로                                | 책임                                        | 하지 않는 일                        |
| ----------------------------------- | ------------------------------------------- | ----------------------------------- |
| apps/mobile/app                     | Expo Router 연결·레이아웃                   | 비즈니스 계산·대형 화면 코드        |
| apps/mobile/src/features/connection | 데모 연결·조회 상태                         | 금융사 직접 연결                    |
| apps/mobile/src/features/recurring  | 분석 후보 확인·수정                         | AI 공급자 직접 호출                 |
| apps/mobile/src/features/spending   | 가용금액·What-if UI                         | 계산식 복제                         |
| apps/mobile/src/features/allocation | 배분 계획·안내 UI                           | 이체 완료 추정                      |
| apps/mobile/src/shared              | 공통 UI·API 클라이언트·저장 어댑터          | 도메인 간 무제한 참조               |
| apps/api/src/modules                | snapshots, recurring, allocations, analysis | mock-bank 내부 소스 참조            |
| apps/api/src/infrastructure         | DB·금융 API 클라이언트·AI 제공자 어댑터     | 앱 화면 코드                        |
| apps/mock-bank                      | 합성 원천 데이터·fixture 시나리오           | 실제 기관 토큰·실제 이체            |
| packages/contracts                  | 스키마·요청/응답·공통 오류                  | 앱·DB 의존성                        |
| packages/finance-core               | 입력→결과 순수 계산                         | 네트워크·LLM·React·암묵적 현재 시각 |

기능 폴더는 자기 내부 구현을 관리한다. 다른 기능의 내부 파일을 직접 import하지 않는다. 공유가 필요하면 먼저 인터페이스를 합의한다. root 설정, router, shared는 공통 담당자가 취합한다.

## 서버와 기기 저장

서버에 사용자 확정 지출·배분 계획을 저장하고, 기기에는 마지막 스냅샷/결과 읽기 캐시를 둔다. 첫 버전은 온라인 저장 성공 후 확정한다. version 불일치면 덮어쓰기 대신 재조회 안내를 한다. pending/saved/failed 상태를 UI에 구분한다. DB 구현 전 임시 메모리 저장은 재시작 시 소실을 명시한다.

## AI 교체 지점

analysis 모듈이 공통 요청/응답을 소유하고, infrastructure/analysis 아래에 rules, general-llm, jev 어댑터를 도입한다. 후보에는 근거 거래 ID·금액·예정일·분석 버전·사용자 확인 상태가 필요하다. AI 공급자별 confidence 값을 같은 확률처럼 비교하지 않는다. 실패/timeout은 명시하고 규칙 후보 또는 확인 필요 상태로 돌아간다.

## 경계 검증의 단계

현재 구조 검사는 파일 존재와 설정 일관성만 검사한다. 소스가 생기면 TypeScript 참조/ESLint import 제한, API 런타임 스키마, 계약 테스트를 첫 기능 PR에 연결한다. 문서만으로 import 경계가 강제된다고 가정하지 않는다.
