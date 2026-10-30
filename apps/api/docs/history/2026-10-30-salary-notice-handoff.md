# 2026-10-30 급여 안내 저장·계좌 상태 인계

작업: PAYSE-SALARY-NOTICE-20261030. 관련 이슈: #22 API, #28 홈 급여 안내, #29 거래 표시. 현재 계약은 [급여 안내](../salary-notices.md)와 [공통 거래 모델](../../../../docs/data-model.md)을 따른다. 이 문서는 작업 당시 인계 기록이다.

## API 반영

- GET /salary-notices/{payMonth}, PUT /salary-notices/{payMonth}/dismissal을 구현했다. 사용자+명목 급여 회차별로 최초 닫기 시각을 저장한다. 원천 없는 회차도 표시 기록만 저장한다.
- JPA 인증 트랜잭션·사용자 잠금·RLS를 재사용한다. 같은 요청을 다시 보내도 최초 기록을 유지하며 원천·입금 확인·금융 dataVersion·거래 cursor를 바꾸지 않는다.
- 009 SQL 이행 후 salary-notices 프로필을 명시적으로 켠다. 실제 개발 DB 적용·기존 서버 활성화는 이 작업에서 하지 않았다.
- account_entry는 posted/unknown만 허용한다. 카드의 approved/cancelled는 유지한다. 신규 001·기존 DB용 010·Java 원천 검증·fixture 검증이 같은 제한을 적용한다.
- 기존 데이터 모델 첫 문장의 금융 조회 HTTP 미구현 표기는 현재 v3 구현 상태로 정정했다. 금융 응답 필드나 schemaVersion은 변경하지 않았다.
- 최신 합의에 따라 신규 서버 알파 initialCase를 demo-life로 맞췄다. 기존 Snapshot·demo-ready는 보존하고 v3/v4 준비 시드·manifest만 갱신했다. 일반 초기화는 빈 설정을 유지하며, 신규 시연 서버는 init --demo-state에서 기존 선택 시나리오 적재기로 원천·연결·설정을 함께 준비한다.

## Flutter 반영 필요

- 서버 저장 키는 사용자+payMonth다. 예정일·급여일·금액·계좌 조합이 바뀌었다는 이유로 같은 회차의 큰 안내를 다시 펼치지 않는다.
- 로컬 계산에서 명목 회차를 알 수 있을 때만 안내 API를 호출한다. 서버가 날짜나 회차를 예상하지 않는다. 원천이 없다는 이유로 화면에서 가짜 receiptEvidence를 만들지 않는다.
- 안내 조회 실패와 금융 Snapshot 조회 실패를 분리한다. 늦은 응답은 요청 당시 사용자·회차와 대조한다. 저장 응답 유실은 동일 PUT 또는 GET으로 확인한다.
- 큰 안내를 접어도 작은 확인 표시·직접 확인 경로·반영 대기 지출·계산 제한 사유는 유지한다.
- 계좌 posted는 확정 기록, unknown은 처리 상태 미확인이다. 계좌 approved/cancelled 표시를 새로 만들지 않는다. 잔액 반영 여부는 reflectionReason/balanceReflected를 별도로 읽는다.

예: 계좌 출금 30,000원 + posted/reflected는 확정 출금·잔액 반영됨이다. unknown/unknown은 처리 상태·잔액 반영을 확인하지 못한 기록이다. unknown/reflected도 가능한 독립 조합이므로 unknown을 미반영으로 단정하지 않는다. 미지원 계좌 취소를 정상 출금·반대 입금으로 변환하지 않는다.

## 공동 적용 경계

최신 develop 5f4fda60628d84620657ac4806cb37b95813686e를 확인한 뒤 작업 브랜치에 fast-forward했다. 기존 미커밋 40파일은 반영 전후 SHA-256이 같았고 직접 겹치는 변경은 없었다. 최신 모바일 파일을 그대로 가져왔으며 API 담당자가 모바일·계산 코드를 편집한 것은 아니다.

현재 모바일의 날짜·설정 조합 기반 로컬 닫기 키는 서버의 사용자+payMonth 기준과 다르므로 연결 시 수정이 필요하다. 작은 표시를 눌러 직접 확인 화면을 여는 동작과 영속 닫기 기록 삭제를 분리한다. 현재 금융 API는 v3이고, 급여 안내는 독립 PAYSE-SALARY-NOTICE-1 계약이다. 최신 앱은 v3/v4를 모두 읽지만 실제 금융 HTTP repository는 아직 없고 Fake/Unavailable 경로를 사용한다. v4 청구 항목의 실제 API 공개·통합 검증과 #96 정상 급여 근거 보완은 별도 범위를 유지한다.

**B 담당 호환 보완:** 최신 Statement.dueDate는 non-null String이고 파서는 businessDate('dueDate')를 호출한다([고정 커밋의 파서](https://github.com/Fintech-project-team/Fintech-project/blob/5f4fda60628d84620657ac4806cb37b95813686e/apps/mobile/lib/data/financial_snapshot.dart#L886)). 기존 공통 모델·DB·API는 null을 허용하므로 미확보 결제일 응답이 새 앱에서 거절된다. nullable 모델/파서와 날짜 미확보 표시·v3/v4 null 반례 검사가 필요하다. 현재 생성 청구의 날짜는 모두 있어 기본 시연의 실행 실패로 보고하지 않으며, API가 임의 날짜로 보충하지 않는다.

기존 #32 분석 기반 미커밋 변경도 보존했다. 급여 안내 저장 완료를 분석 DB·공급자 연동 완료로 기록하지 않는다. 새 commit·push·PR 병합은 실행하지 않았다.

## 검증 기록

- 실제 PostgreSQL 15.13: 급여 안내 SQL 9건, 계좌 상태 SQL 8건, 초기/시연 적재·기존 SQL 회귀 9건 통과. 최소 권한·사용자 격리·동시성·롤백·취소·기존 행 보존 포함. 기존 DB 연결 0, 임시 서버 종료 확인.
- 같은 폐기 DB에 연결한 Java 전체 203건 통과, 실패·건너뜀 0. 급여 HTTP 9건에 재로그인·서버 재시작·늦은 원천·같은 날짜의 다른 회차·기존 cursor 유지 포함.
- 최신 develop와 합친 검증본에서 Java 203건·Python 168건을 통과한 뒤 신규 서버 시연 준비 검사를 보완했다. 금융 Snapshot 47개와 모바일·계산 코드의 직접 변경은 0이다. 준비 시드·manifest의 알파 기본 연결만 변경했다.
- 공통 하네스의 최종 runId와 Python 전체 결과는 작업 PR의 검증 항목에 기록한다. Flutter 실행·실기기·기존 서비스 DB 적용은 미실행이다. 단위 검사와 별도 DB 적재 검사만으로 새 개발 서버 프로세스의 실제 기동까지 완료했다고 보고하지 않는다.

## 팀원 전달 초안

API에 급여 회차별 안내 조회·닫기 저장을 추가했습니다. 같은 payMonth는 재로그인 후에도 큰 안내를 다시 표시하지 않으며, 작은 확인 표시와 계산 상태는 유지합니다. 기존 Snapshot v3는 변경하지 않았습니다. 신규 서버 알파 시연은 앱과 같은 demo-life로 맞췄고 --demo-state 준비 시 설정도 함께 적재합니다. 앱은 실제 금융 HTTP 및 사용자+payMonth 안내 API를 연결하고 저장 실패·응답 유실을 구분해 주세요. 계좌 거래는 posted/unknown이며 잔액 반영은 reflectionReason을 따릅니다. 새 청구 파서의 dueDate는 계약에 맞게 null 허용 보완이 필요합니다. 모바일 파일은 직접 편집하지 않았고 실제 앱 연동 검증은 남아 있습니다.
