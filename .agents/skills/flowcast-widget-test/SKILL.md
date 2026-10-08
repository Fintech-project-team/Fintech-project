---
name: flowcast-widget-test
description: Flowcast Flutter 위젯의 표시·입력·오류·저장 상태와 접근성을 테스트한다. 화면 또는 컴포넌트 동작 검증에 사용하며 서버 연동 E2E나 디자인 승인과 구분한다.
---

# Flutter 위젯 테스트

실제 작업 명세, [Flutter 전환 상태](../../../docs/harness/FLUTTER_TRANSITION.md), 변경 화면의 계약과 테마를 확인한다. pubspec·flutter_test·대상 위젯이 없으면 필요한 초기화를 보고한다.

1. `test/` 아래 `_test.dart`에 `testWidgets`와 `WidgetTester`를 사용한다. 실제 앱의 테마·지역화·필요한 주입 경계를 재사용한다. 위젯 하나의 테스트 때문에 앱의 상태 관리나 라우터를 교체하지 않는다.
2. 변경과 관련된 정상·로딩·빈 데이터·오류·부족·오래된 데이터·저장 실패 상태를 선택한다. 합성 데이터와 제어 가능한 가짜 서비스를 사용한다. API를 가짜로 바꾼 결과는 서버 연동 E2E로 보고하지 않는다.
3. 화면에 보이는 값, 탭·입력 결과, 상태 문구와 의미 정보를 검사한다. 색상만으로 금융 상태를 구분하지 않는지, 큰 글자에서 핵심 정보가 잘리지 않는지 확인한다. 구현 내부 호출 횟수를 의미 없이 고정하지 않는다.
4. 애니메이션·비동기는 조건이 명확한 `pump` 또는 제한된 대기로 처리한다. 무한 로딩 위젯에 무조건 `pumpAndSettle`을 반복하지 않는다. 실패를 감추려고 대기 시간을 계속 늘리지 않는다.
5. Flutter 패키지 루트에서 `flutter test <실제 테스트 파일>`을 실행하고 유효한 PASS를 재사용한다. 분석·포맷 등 필수 근거는 [검사 기준](../../../docs/harness/FLUTTER_TRANSITION.md)으로 대조한다. Golden은 승인된 기준 이미지와 고정된 SDK·폰트·화면 조건이 있을 때만 추가하고 자동으로 기대 이미지를 덮어쓰지 않는다.

실패 수정은 최초 목적·허용 경로 안에서만 한다. 범위 밖 구현·계약·테마 변경이 필요하면 원인과 경로를 보고한다. 사건은 [기존 작업 기록](../../../docs/harness/AGENT_REVIEW.md)에 남긴다.

출처: Flutter 팀의 [flutter-add-widget-test](https://github.com/flutter/agent-plugins/blob/0ef3972f93e2baa4156ba1cbb1e515cd53079c68/skills/flutter-add-widget-test/SKILL.md)를 조정했다. 공식 배포본 자체가 아니다. [원본 라이선스](../../../docs/harness/skill-licenses/flutter-agent-plugins.txt).
