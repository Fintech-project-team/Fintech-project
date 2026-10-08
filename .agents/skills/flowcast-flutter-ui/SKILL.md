---
name: flowcast-flutter-ui
description: Flowcast Flutter 화면·공통 위젯을 기존 디자인 토큰과 금융 상태 표현에 맞춰 구현·검토한다. 색·폰트·컴포넌트 사용과 반응형·접근성 작업에 적용하며 브랜드나 상태 관리 라이브러리를 임의 결정하지 않는다.
---

# 디자인 시스템에 맞춘 Flutter UI

실제 명세, [서비스 구조](../../../docs/architecture.md), [Flutter 전환 상태](../../../docs/harness/FLUTTER_TRANSITION.md), 대상 화면의 계약을 읽는다. 기존 테마·토큰·공통 컴포넌트와 승인된 디자인 자료가 원본이다.

1. 현재 요청에 필요한 화면·상태·공통 요소를 식별하고 기존 구현을 재사용한다. Flutter 패키지가 없으면 초기화 작업이 먼저다. 디자인 토큰이 없으면 필요한 최소 항목을 제안하되 브랜드 값이 확정됐다고 보고하지 않는다. 시스템 구축 자체가 승인된 작업일 때만 허용 경로에 토큰을 추가한다.
2. 색·문자·컴포넌트 스타일은 기존 `ThemeData`, `ColorScheme`, `TextTheme`를 따른다. 제품 고유 의미가 필요하면 기존 확장 구조 또는 `ThemeExtension`을 검토한다. 이름·경로·fromSeed 사용 여부는 팀 결정을 따른다. 화면마다 새 팔레트·폰트·간격 체계를 만들지 않는다.
3. 금액 표시와 계산을 분리한다. [현재 MVP 화면 용어](../../../docs/mvp-scope.md)를 사용하고 급여 통장 잔액/쓸 수 있는 돈, 미리보기/저장 완료, 저장 중/실패/충돌·부족 상태를 구분한다. 03-1 이미 나갔어요와 02-3 잔액 다시 입력의 동작 차이를 보존한다. 후속 LLM 후보는 사용자 확인 전 확정 지출로 표시하지 않는다. 금융 계산식을 위젯에 복사하지 않는다.
4. 기존 기능 경계와 상태 관리 방식을 유지한다. 화면 작업 때문에 ChangeNotifier·Riverpod·BLoC·freezed·get_it 같은 의존성을 새 표준으로 지정하지 않는다. 비즈니스 로직과 API 호출을 표시 위젯에 섞지 않는다.
5. 변경과 관련된 화면 폭·긴 한글·큰 글자·키보드·빈 데이터·오류 상태를 확인한다. 색 외에 문구나 아이콘으로 상태를 전달하고 접근성 이름·포커스·조작 가능성을 살핀다. 지원하기로 한 테마와 플랫폼만 이번 완료 조건에 포함한다.
6. 관찰 가능한 UI 동작이 바뀌면 관련 위젯 테스트와 [필수 검사](../../../docs/harness/FLUTTER_TRANSITION.md)를 확인한다. 미리보기·스크린샷·Golden·기기 테스트는 각각 확인한 범위만 보고한다. 유효한 결과를 재사용하고 범위 밖 공통 테마나 컴포넌트를 일괄 수정하지 않는다.

출처: [Flutter 테마](https://docs.flutter.dev/cookbook/design/themes), [ThemeExtension](https://api.flutter.dev/flutter/material/ThemeExtension-class.html), [접근성](https://docs.flutter.dev/ui/accessibility). 이 스킬은 Flowcast 작성본이며 디자인 시스템 자체가 구현됐다는 뜻은 아니다.
