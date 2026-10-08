# 금융 계산

계산 구현 전. docs/calculation-rules.md의 정책 상태를 확인한다. network/DB/UI 프레임워크/LLM 없는 순수 계산과 테스트만 둔다.

이 폴더만으로 서버나 앱이 실행되지는 않는다. 의존성과 실제 검증 명령은 초기화 PR에서 추가한다.

Flutter 전환 시 이 Node 골격을 앱에서 직접 import하지 않는다. [전환 기준](../../docs/harness/FLUTTER_TRANSITION.md)에 따라 앱 측 순수 계산의 Dart 패키지 연결을 먼저 정한다. 임의로 서버 계산으로 옮기거나 두 언어에 중복 구현하지 않는다.
