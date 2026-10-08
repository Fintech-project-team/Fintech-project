# 현재 MVP 순수 계산

현재 구현 전 Node 골격이다. [계산 규칙](../../docs/calculation-rules.md)의 B−F−P와 계산 내역을 앱 측 순수 계산 경계 하나로 구현한다. 미지급 지출과 모아둘 돈을 합산하고 입력을 수정하지 않는다.

Flutter에서 이 TypeScript 골격을 직접 import하지 않는다. 실제 Dart 위치·패키지는 [초기화](../../docs/harness/FLUTTER_TRANSITION.md)에서 정한다. API의 원자적 지급/잔액 보정과 순수 계산은 구분하며 화면 계산식을 서버에 중복 구현하지 않는다. LLM은 이 금액을 결정하지 않는다.
