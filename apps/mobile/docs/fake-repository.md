# 가짜 금융 스냅샷 저장소 (FakeRepository)

- 작성: 2026-10-20 · B(hyeyeonso) · GitHub #24 · 작업 명세 `docs/tasks/PAYSE-MOBILE-DATA-20261020.json`
- 상위 기준: [앱 구조](../../../docs/app-architecture.md) §1·§3, [데이터 계약](../../../docs/data-contracts.md), [데이터 명세 초안](../../api/docs/data-model-draft.md) §8. 이 문서는 모바일 구현 경계만 적고 필드 의미를 재정의하지 않는다.

## 목적

서버 API가 준비되기 전, 화면이 A의 합성 더미 스냅샷을 읽어 동작하게 한다. 실제 API가 생기면 Repository 구현만 바꾼다. 이 경로는 서버 저장·재로그인 유지 완료가 아니다.

## 형식 검사 (원천 값을 고치지 않고 거절만 함)

- 업무 날짜(`bookingDate`·`purchaseDate`·`withdrawalDate`, 조회 범위 시작·끝): `YYYY-MM-DD`이면서 실제 달력 날짜. 시각을 붙이지 않는다.
- 시각(스냅샷·계좌 `asOf`): 시간대 오프셋이 있는 시각. 원문을 그대로 둔다.
- 금액: 원 단위 정수, 절댓값 9,000,000,000,000원 이하. 거래 금액은 0 이상(방향은 `direction`), 잔액은 음수 허용.
- 거래는 `accountId`·`cardId` 중 적어도 하나가 있어야 한다. 개수 필드는 0 이상 정수.
- 오류 문구는 필수 필드 없음 / null 불가 / 기대 형식과 실제 값 종류를 구분한다. 방향·상태 같은 코드 값 목록은 계약 확정 전이라 검사하지 않는다.
- 기준: 데이터 계약의 공통 타입 규칙과 4개 스냅샷의 실제 표현(2026-10-20 확인, 모두 통과).

## 구조

```text
PayseApp (lib/app) ── 생성자 주입 ──▶ FinancialSnapshotRepository (계약)
                                        └ FakeFinancialSnapshotRepository (lib/data)
                                            └ SnapshotSource
                                                └ AssetSnapshotSource ── assets/fixtures/*.json
```

- 화면은 `FinancialSnapshotRepository`만 사용한다. 에셋 경로를 아는 곳은 `AssetSnapshotSource` 하나다.
- 결과는 `SnapshotLoaded` / `SnapshotLoadFailed`(읽기 실패) / `SnapshotFormatInvalid`(형식 오류) 세 가지다. 실패를 빈 자료·0원으로 바꾸지 않는다.
- 모델은 원천 값을 그대로 담는다. 정수 KRW, 기준 시각 원문(오프셋 포함), dataVersion·sourceVersion·ruleVersion을 유지한다. `null`은 값 미확인, 원문에 키가 없는 묶음(예: 연결 전 계좌)은 `null`(미노출)로 두고 빈 목록과 구분한다.
- FakeRepository는 파싱만 한다. 잔액 합계·U·연간 집계는 하지 않는다(이후 `packages/payse_calculation/`).

## 스냅샷 (catalog.json 사례)

| 선택값            | 파일                     | 용도                                                   |
| ----------------- | ------------------------ | ------------------------------------------------------ |
| alphaReady (기본) | `alpha-ready.json`       | 정상: 1년 자료·선택 계좌·카드 정산·부분 정산·보호 배정 |
| alphaShock        | `alpha-shock.json`       | 준비 사건으로 잔액 하락, 기존 보호액 유지              |
| salaryWait        | `salary-wait.json`       | 급여일 미입금, 당일·연체 예정 지출 홈 반영 대기        |
| alphaUnconnected  | `alpha-unconnected.json` | 초기 복원: 연결 0, 금융 자료 미노출                    |

## 에셋 복사본과 동기화

- `apps/mobile/assets/fixtures/`의 4개 파일은 `apps/api/fixtures/generated/snapshots/` 원본을 바이트 그대로 복사한 것이다(2026-10-20 사용자 승인). 내용·구조를 고치지 않는다.
- `test/data/fixture_copy_test.dart`가 원본과 바이트 단위로 비교한다. 원본이 바뀌면 테스트가 실패하며 자동으로 덮어쓰지 않는다.
- 동기화 절차: 원본 변경 내용(A의 PR)을 확인 → 원본을 `assets/fixtures/`에 다시 복사 → 파싱 테스트 확인. 필드가 바뀌었으면 A와 계약을 먼저 확인한다.
- 복사본은 Prettier 형식인 원본과 같다. 하네스 `--format`으로 복사본을 따로 고치지 않는다.

## 앱 시작 구조 — 개발 단계 임시 (결정 기록)

| 항목          | 내용                                                                                                                                                                                                                                                                                                                |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 결정일·결정자 | 2026-10-20 · B(hyeyeonso), 작업 2 진행 중 범위 조정으로 사용자 승인                                                                                                                                                                                                                                                 |
| 결정          | 앱 시작 화면을 하단 탭 골격(홈·계좌·계획·내 정보)으로 교체하고, 개발 환경 확인용 임시 화면 `lib/app/bootstrap_screen.dart`(2026-10-19 초기화 때 생성, 사용자 화면 아님)를 삭제                                                                                                                                      |
| 성격          | 인증 구현 전 **개발 단계의 임시 구조**. 실제 사용자 진입 흐름을 확정한 것이 아니다                                                                                                                                                                                                                                  |
| 실제 흐름     | 최초 사용자는 온보딩(00-1 → 10-x → 12-x → 01-x), 기존 사용자는 PIN 확인(11-1) 후 홈. [v0.6 화면 규칙](../../../docs/v0.6-screen-rules.md)과 [화면 규칙 보완](screen-rules-update.md)에 따라 별도 작업으로 구현하며, 그때 시작 화면을 저장된 세션·PIN 상태로 정한다([앱 구조](../../../docs/app-architecture.md) §4) |
| 지금 화면     | 탭에는 "준비 중" 안내만 있고 금융 자료를 보여주지 않는다. 더미 자료는 개발 빌드의 확인 화면에서만 보인다                                                                                                                                                                                                            |

## 개발용 확인 화면

- `lib/app/dev/fixture_debug_screen.dart`: 4개 스냅샷 선택, 기준 시각·버전, 계좌·카드·거래 수 표시.
- 진입점은 내 정보 탭 아래 개발용 버튼이다. 컴파일 시점 상수 `kReleaseMode`로 갈라 두어 릴리스 빌드에서는 진입점과 확인 화면 코드가 트리 셰이킹으로 빠진다. 개발 빌드에서 진입점을 끄려면 `PayseApp(enableDevTools: false)`를 쓴다(테스트용).
- 확인 방법(2026-10-20): Flutter AOT 컴파일러(frontend_server `--aot --tfa`, `-Ddart.vm.product=true`)와 gen_snapshot으로 만든 스냅샷에서 개발용 문구·`FixtureDebugScreen`이 릴리스 0건, profile에는 존재. Android·iOS 실제 릴리스 앱 빌드는 이 Mac에 도구가 없어 미실행.

## 실제 API로 바꿀 지점

- `FinancialSnapshotRepository`를 구현하는 API Repository를 만들고 `PayseApp`의 생성 지점만 바꾼다. 세션별 수명(로그아웃 시 폐기)은 인증 구현 때 연결한다.

## 미확정

- 계좌 잔액이 null인 실패 계좌의 표시, coverage 상태 값 목록(complete 외)의 화면 해석: A의 상태 코드 확정 후.
- 스냅샷 선택은 앱 루트 메모리에만 두며 저장하지 않는다.

## 검증

- 테스트: `test/data/`(원본 일치 4, 실제 에셋 파싱 6, 읽기 실패 2, 형식 오류 6, 값 보존 2, 날짜·값 강화 검사 9), `test/app/payse_app_test.dart`(탭 골격, 진입점 끔, 확인 화면 수치·전환, 온보딩 자리, 라이선스).
- 원본 일치 테스트가 불일치를 잡는지 복사본을 일시 변경해 실패를 확인한 뒤 원본으로 되돌렸다.
- 미확인: 실제 기기 실행, Android·iOS 실제 릴리스 앱 산출물(위 AOT 스냅샷 확인으로 대체).
