# 공통 JSON 계약

현재는 스키마 구현 전 Node 골격이다. [수동 MVP 계약](../../docs/contracts.md)에 맞춰 상태·예정 지출·모아둘 돈·지급/잔액 보정 사례를 먼저 확정한다. 기존 수집/배분 API 초안을 현행 필수로 사용하지 않는다.

Flutter와 Node는 언어 독립 JSON과 검증 사례를 공유한다. TypeScript 타입을 앱에서 직접 import하지 않는다. Dart/서버 스키마 연결은 [초기화 기준](../../docs/harness/FLUTTER_TRANSITION.md)을 따른다. 직후 LLM의 후보는 확정 항목과 분리한다.
