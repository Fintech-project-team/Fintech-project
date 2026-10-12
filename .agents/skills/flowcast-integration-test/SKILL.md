---
name: flowcast-integration-test
description: Flowcast Flutter 앱의 실제 사용자 흐름과 앱·API·합성 데이터 서버 연동 테스트를 설계·작성한다. integration_test 기반 기기 검증에 사용하며 환경이 없으면 계획과 차단 원인을 보고한다.
---

# Flutter 통합 테스트

실제 명세·[현재 MVP](../../../docs/mvp-scope.md)와 [Flutter 전환 상태](../../../docs/harness/FLUTTER_TRANSITION.md), [API 계약](../../../docs/contracts.md), [시연 기록](../../../docs/demo/README.md)을 확인한다. 요청된 검증에 필요한 앱·기기·서버·합성 데이터 초기화 중 빠진 전제는 BLOCKED로 기록한다. E2E 체계 구축은 현재 보류이며 이 스킬이 선행 구축을 요구하지 않는다.

1. 먼저 검사 경계를 적는다. 가짜 API를 쓰는 앱 검사와 실제 앱→api 저장 흐름을 구분한다. mock-bank는 후속 F07을 검증할 때만 연결한다. 실제 금융기관·실데이터를 사용하지 않는다.
2. 명세에 허용된 `integration_test/<흐름>_test.dart`와 기존 테스트 진입점을 사용한다. `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`를 사용하는 표준 integration_test가 기본이다. MCP나 Flutter Driver 확장을 필수로 추가하지 않고, 테스트를 위해 제품 `main.dart`에 디버그 확장을 넣지 않는다.
3. 시나리오 ID·기준 시각·합성 사용자·서버 주소·초기화와 종료 방법을 고정한다. 변경된 흐름에 맞춰 수동 입력·예정 지출/모아둘 돈 변경·저장 실패·버전 충돌·재조회를 선택한다. 03-1 지급 처리의 한 번 차감과 02-3 잔액 보정의 재차 차감 금지를 구분한다. 실제 은행 이체나 현재 Must 밖 What-if·배분을 검사 범위에 추가하지 않는다.
4. 기기의 실제 연결과 서버 도달 가능성을 확인한다. 휴대폰 localhost를 개발 PC로 가정하지 않는다. 재설정은 지정된 합성 테스트 환경에만 적용한다. 외부 앱·권한창 같은 네이티브 경계는 별도 시나리오로 남기고 필요가 확인될 때 도구를 추가한다.
5. 지원되는 Android/iOS/데스크톱 기기에서 앱 루트의 `flutter test integration_test/<실제 파일> -d <실제 기기 ID>`를 사용한다. 웹은 같은 명령을 그대로 적용하지 말고 팀에서 정한 지원 실행 절차를 확인한다. 성공 로그·시나리오·기기·앱/API 버전·실패 증거를 남긴다. 같은 환경과 입력의 PASS는 재사용한다.

실패는 최초 범위 안에서 수정한다. 서버·데이터 초기화·위젯 Key·lockfile이 범위 밖이면 필요한 경로를 보고한다. 설치·테스트 파일 작성·실행·시스템 E2E 통과를 구분하고 [네 지표](../../../docs/harness/AGENT_REVIEW.md)를 기존 기록에 합친다.

출처: [공식 integration_test 안내](https://docs.flutter.dev/testing/integration-tests), Flutter 팀의 [통합 테스트 스킬](https://github.com/flutter/agent-plugins/blob/0ef3972f93e2baa4156ba1cbb1e515cd53079c68/skills/flutter-add-integration-test/SKILL.md). 원본의 MCP/Driver 필수 절차를 채택하지 않은 Flowcast 조정본이다. [원본 라이선스](../../../docs/harness/skill-licenses/flutter-agent-plugins.txt).
