# Flutter 모바일 앱

현재 Must는 월급일·급여 통장 잔액·예정 지출·모아둘 돈의 수동 입력, 쓸 수 있는 돈 홈·계산 내역이다. [현재 MVP](../../docs/mvp-scope.md)의 F 기능·화면 용어와 [두 잔액 변경 규칙](../../docs/calculation-rules.md)을 따른다.

현재는 이전 app/src와 Node workspace 골격이며 pubspec·Dart 앱이 없다. [전환 기준](../../docs/harness/FLUTTER_TRANSITION.md)에 따라 실제 Flutter 경로·역할·검사·계산 위치를 초기화한다. 기존 경로에 새 Expo 코드를 쓰지 않는다.

서버에는 확정 입력을 저장하고 기기는 읽기 캐시를 사용한다. MVP 다음에는 예정 지출 입력·분류 LLM 후보를 사용자 확인 후 기존 저장에 연결한다. mock-bank·별도 배분·What-if·E2E/디자인 시스템 구축을 현재 선행 조건으로 추가하지 않는다.
