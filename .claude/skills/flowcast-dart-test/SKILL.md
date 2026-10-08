---
name: flowcast-dart-test
description: Flowcast Dart 함수·계산·변환 로직의 단위 테스트를 작성하거나 실패를 분석한다. 위젯·기기 E2E·기존 TypeScript 패키지에는 적용하지 않는다.
---

# Dart 단위 테스트

실제 작업 명세와 [계산 계약](../../../docs/calculation-rules.md), [데이터 계약](../../../docs/contracts.md)을 필요한 부분만 읽는다. 이미 확인된 작업 범위는 재확인 절차를 반복하지 않는다. [Flutter 전환 상태](../../../docs/harness/FLUTTER_TRANSITION.md)에서 실제 Dart 패키지와 검사 준비 여부를 확인한다.

1. 대상 `pubspec.yaml`과 실제 구현 언어를 확인한다. 기존 TypeScript finance-core를 Dart 테스트 대상으로 가정하거나, 테스트 추가를 이유로 패키지를 이식하지 않는다. 패키지가 없으면 초기화가 필요한 상태로 보고한다.
2. `test/` 아래 실제 대상 경로에 대응하는 `_test.dart`를 사용한다. 순수 Dart는 기존 `package:test`, Flutter 패키지는 기존 `flutter_test`와 알맞은 실행기를 사용한다. 필요한 의존성·lockfile 수정이 명세 밖이면 필요 사항을 보고한다. Mockito·코드 생성기를 자동 추가하지 않는다.
3. 계약상 관찰 가능한 결과를 검사한다. 금융 로직이면 관련된 정상·경계·중복 차감·날짜 경계·원본 불변 사례를 선택한다. 기준 시각과 합성 데이터를 고정한다. 미확정 금융 정책의 초안 숫자를 확정 기대값으로 만들지 않는다.
4. 패키지 루트에서 순수 Dart는 `dart test <실제 테스트 파일>`, Flutter는 `flutter test <실제 테스트 파일>`을 실행한다. 유효한 동일 PASS는 재사용하고 [추가 검사](../../../docs/harness/FLUTTER_TRANSITION.md)의 분석·포맷 근거도 확인한다.
5. 실패 원인을 구현·테스트·계약·환경으로 구분한다. 구현 수정도 최초 허용 경로 안에서만 한다. 통과를 위해 assertion을 삭제하거나 정책·기대값을 바꾸지 않는다. 진전 없는 동일 수정 반복은 멈추고 필요한 결정을 보고한다.

사용한 계약·대상 테스트·결과·미검증을 보고하고 [기존 작업 기록](../../../docs/harness/AGENT_REVIEW.md)에 합친다. 별도 중복 일지는 만들지 않는다.

출처: Flutter 팀의 [dart-add-unit-test](https://github.com/flutter/agent-plugins/blob/0ef3972f93e2baa4156ba1cbb1e515cd53079c68/skills/dart-add-unit-test/SKILL.md)를 참고해 Flowcast용으로 조정했다. 공식 배포본 자체가 아니다. [원본 라이선스](../../../docs/harness/skill-licenses/flutter-agent-plugins.txt).
