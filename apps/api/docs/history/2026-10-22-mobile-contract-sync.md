# 모바일 계약 동기화 이력 · 2026-10-22

이 문서는 당시 변경 범위와 인계 기록이다. 현행 규격은 [데이터 계약](../../../../docs/data-contracts.md), [API 계약](../../../../docs/api-contract.md)을 따른다. 아래의 변경·검증 안내는 원문을 보존한 것이며, 검증 명령의 기재만으로 실행 통과를 뜻하지 않는다.

원래 위치: `apps/mobile/docs/contract-sync-20261022.md`. 상대 링크만 새 위치에 맞췄다.

---

# 2026-10-22 API 계약 동기화 인계

이 문서는 이번 변경 경로와 검증 명령만 안내한다. 데이터 의미는 [공통 계약](../../../../docs/data-contracts.md), 로그인 요청은 [API 계약](../../../../docs/api-contract.md), 합성 원본의 구조는 [데이터 모델](../../../../docs/data-model.md)을 따른다.

## 변경한 14개 파일

아래 경로는 `apps/mobile/` 기준이다. 화면 디자인·PIN·계정 매칭·사용자별 기존 세션 우선 정책은 이번 동기화에서 바꾸지 않는다.

| 경로                                            | 변경                                                                   |
| ----------------------------------------------- | ---------------------------------------------------------------------- |
| `lib/data/auth/auth_repository.dart`            | 세션 생성 계약과 Unavailable 구현에서 설치 식별값 인자 제거            |
| `lib/data/auth/fake_auth_repository.dart`       | 설치 식별값 인자와 UUID 검사 제거; 나머지 인증 동작 유지               |
| `lib/data/auth/random_id.dart`                  | 사용처 주석 수정; 가짜 세션 ID 생성 함수는 유지                        |
| `lib/features/auth/auth_services.dart`          | 설치 식별값 보관 필드·생성자 인자 제거                                 |
| `lib/features/auth/auth_view_models.dart`       | 가입 요청에서 설치 식별값 전달 제거                                    |
| `lib/app/payse_app.dart`                        | 앱 진입 시 설치 식별값 난수 생성·전용 import 제거                      |
| `test/data/auth/fake_auth_repository_test.dart` | 호출 인자와 설치 식별값 형식 검사 1개 제거; 자격·제한·세션 검사는 유지 |
| `test/features/auth/code_view_model_test.dart`  | 테스트 대역과 의존성 구성에서 설치 식별값 제거                         |
| `test/features/auth/auth_flow_test.dart`        | 테스트 대역의 세션 생성 인자·전달 제거                                 |
| `test/data/fake_repository_test.dart`           | 독립 최소 입력의 스키마 표기를 `PAYSE-DRAFT-2`로 맞춤                  |
| `assets/fixtures/alpha-ready.json`              | 동명 API 합성 원본과 바이트 동기화                                     |
| `assets/fixtures/alpha-shock.json`              | 동명 API 합성 원본과 바이트 동기화                                     |
| `assets/fixtures/salary-wait.json`              | 동명 API 합성 원본과 바이트 동기화                                     |
| `assets/fixtures/alpha-unconnected.json`        | 동명 API 합성 원본과 바이트 동기화                                     |

현재 `FinancialSnapshot` 파서는 반복 계획·버전 필드를 읽지 않으므로 계획 필드에 대한 새 파서나 계산 구현을 추가하지 않았다. 원본 경로와 이후 동기화 절차는 [FakeRepository 안내](../../../mobile/docs/fake-repository.md)를 따른다. 실제 HTTP 어댑터는 구현 전이며 이 변경으로 실서버 연동 완료를 뜻하지 않는다.

## 검증

Flutter 3.47.7·Dart 3.13.5에서 `apps/mobile`을 작업 디렉터리로 사용한다.

```sh
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
```

의존성 준비 후 lockfile을 바꾸지 않는다. 4개 에셋의 원본 일치 검사는 `test/data/fixture_copy_test.dart`, 파싱 검사는 `test/data/fake_repository_test.dart`가 담당한다. 인증 저장소·ViewModel·Flow의 기존 테스트도 함께 유지한다. 분석·자동 테스트 결과와 실제 기기 실행 결과는 구분한다.
