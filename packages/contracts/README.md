# 공통 계약

스키마 구현 전. docs/contracts.md 초안에서 요청·응답 타입과 런타임 스키마를 먼저 확정한다.

이 폴더만으로 서버나 앱이 실행되지는 않는다. 의존성과 실제 검증 명령은 초기화 PR에서 추가한다.

Flutter와 Node가 공유하는 것은 언어 독립 JSON 계약과 사례다. Dart 모델·서버 타입·실행 중 검증 연결은 [전환 기준](../../docs/harness/FLUTTER_TRANSITION.md)에 따라 초기화 때 정한다. TypeScript import를 앱 공유 방식으로 가정하지 않는다.
