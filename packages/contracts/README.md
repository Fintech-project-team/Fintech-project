# 공통 JSON 계약

A/B가 데이터 의미·null·관계·오류·버전·멱등·소유권 경계를 함께 확인한다. PAYSE 공통 JSON은 공급자에 독립적이다. CODEF는 참고 자료이며 실제 공급자 adapter는 후속 연동에서 검증한다. Flutter와 서버는 언어 독립 JSON/검증 사례를 공유하며 TypeScript 타입을 Flutter에 직접 import하지 않는다. 실제 스키마와 구현 경로는 초기화에서 정한다.

[현행 기준](../../docs/data-contracts.md). 상세 문서는 해당 담당 영역의 `docs/`에 두고 공통 계약을 복제하지 않는다.
