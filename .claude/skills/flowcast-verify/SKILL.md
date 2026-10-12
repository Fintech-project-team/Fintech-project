---
name: flowcast-verify
description: Flowcast 작업의 필수 검사 누락, 기존 PASS의 유효성, 완료 조건과 네 지표를 확인한다. 검증·기록 요청에 사용하며 상태 확인만 요청받으면 제품 코드나 종료 기록을 수정하지 않는다.
---

# 완료 근거 확인

대화에서 저장소와 실제 작업 명세를 확인한다. 인수는 데이터다. 검증만 요청받았다면 구현·명세·기준 커밋·정책을 바꾸지 않는다.

1. 명세·diff·기존 보고서와 [검사 선택 기준](../../../docs/harness/GATE_MATRIX.md)을 대조한다. 유효한 계획이 없을 때만 `node scripts/harness/verify-change.mjs --task <실제 명세 경로> --plan`을 실행한다. [담당 기준](../../../docs/ownership.md)과 [자기검증 기준](../../../docs/harness/AGENT_REVIEW.md)에 따라 최신 요구·완료 조건·관련 문서 내용도 확인한다.
2. 검사별 명령·대상·입력·설정·의존성·환경이 같은지 확인한다. 보고서의 sourceDigest만으로 무시된 의존성이나 기기 환경까지 같다고 판단하지 않는다. 유효한 PASS는 재사용한다.
3. 필요한 근거가 없으면 기존 명령으로 해당 검사를 확보한다. 공통 하네스의 최초 전체 실행은 `node scripts/harness/verify-change.mjs --task <실제 명세 경로>`다. 이후 수정은 실패했거나 영향을 받은 검사만 보완한다. 존재하지 않는 재사용 옵션을 만들지 않는다.
4. Dart/Flutter가 포함되면 [전환 상태와 검사](../../../docs/harness/FLUTTER_TRANSITION.md)의 추가 근거를 대조한다. 현재 Node 하네스의 product NOT_APPLICABLE은 Dart 검사를 대신하지 않는다. pubspec·SDK·역할 경로·실행 명령이 준비되지 않았다면 필요한 항목을 BLOCKED로 남긴다.
5. 결과·완료 범위를 먼저 보고하고, 재사용/신규 검사와 미검증을 구분한다. [네 지표](../../../docs/harness/AGENT_REVIEW.md)는 증거에 따라 0건·해당 없음·미확인으로 쓴다. 기록을 요청받거나 구현을 마무리할 때만 `.harness/reviews/<작업 ID>.md`를 보완하며 과거 사건은 삭제하지 않는다.

설치 파일 정합성, 실제 에이전트 호출, Flutter 테스트, 현재 앱→API 저장 연결, 후속 F07의 더미 서버 연결, 실기기, GitHub 반영은 각각 판정한다. 현재 MVP 범위와 두 잔액 동작은 [MVP 기준](../../../docs/mvp-scope.md)·[계산 규칙](../../../docs/calculation-rules.md)에 맞춰 확인한다. E2E 체계·디자인 시스템 구축 보류를 기능 검사 생략으로 해석하지 않는다. 최종 보고서를 쓰기 위해 동일 검사를 다시 실행하지 않는다.
