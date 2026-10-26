# 선택 실행하는 검증 사례

`prepare.py <생성 폴더> --cases alpha-ready beta-ready gamma-month-end --out <새 SQL 파일>`은 명시 선택한 사례를 일반 테이블에 넣는 INSERT SQL만 만든다. 자동 DB 접속이나 서비스 API를 제공하지 않는다. 같은 사용자의 두 사례를 함께 선택할 수 없다.

전용 빈 테스트 DB에 현재 DDL 두 파일 → 기관 기준정보 SQL → 선택 사례 SQL 순서로 적재한다. 일반 기본 적재 SQL과 시나리오 SQL은 둘 중 하나를 사용한다. 기존 사용자 자료 위에서 사례를 전환하거나 누적 실행하지 않는다. 기본키·작업키 제약이 중복 적재를 거절한다. 반복 실행은 별도로 준비한 새 테스트 DB에서 한다.

사례는 기존 ID·금액·날짜·기대 결과를 유지하며 설정·배정·부분 정산 이력을 준비한다. write_receipts에는 import_user_state와 실제 가져온 상태 해시를 사용한다. 기존 releaseEvidence가 참조하는 영수증 ID와 시각을 보존한 가져오기 기록이며 HTTP 요청 실행 이력이 아니다. expected 결과·사건 카탈로그·시나리오 ID는 준비 도구에만 둔다.

앱 DB에는 테스트 전용 테이블/컬럼을 추가하지 않는다. 과거 demo_event_receipts는 [기존 DB 이행](../../docs/common-storage.md)에서 외부 파일로 보존한다. 사용자·금융 관계나 계산 규칙을 이 문서에서 다시 정의하지 않는다.
