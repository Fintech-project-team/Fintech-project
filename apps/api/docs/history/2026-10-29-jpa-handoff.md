# 2026-10-29 JPA 전환 인계

관련 이슈: [#22](https://github.com/Fintech-project-team/Fintech-project/issues/22), [#23](https://github.com/Fintech-project-team/Fintech-project/issues/23). 작업 브랜치는 `feat/api/financial-read-write-22-23`이며 기존 미커밋 금융 API를 포함한다.

## 변경과 보존

- Spring Boot의 의존성 관리 아래 Spring Data JPA·Hibernate를 사용한다. `JpaConfiguration`은 같은 DataSource·EntityManagerFactory의 `JpaTransactionManager`를 등록한다. 일반 사용자 설정은 7개 엔티티의 persist·변경 감지·remove로 저장하며 응답에 엔티티를 직접 노출하지 않는다.
- 인증 함수·복잡한 금융 조회·원거래 JOIN·사용자 버전 갱신은 기존 SQL을 EntityManager의 native SQL과 바인딩으로 실행한다. 이를 단순 엔티티 CRUD로 바꿔 기존 권한·잠금 순서를 잃지 않는다.
- READ COMMITTED, 트랜잭션 단위 역할·소유자 문맥, 사용자 잠금, 버전·멱등 영수증, IP 기록의 선행 커밋과 후속 실패 롤백을 유지한다. 저장 검증 전에 flush하며 SQL 취소·지연 제약·커밋 실패도 성공으로 반환하지 않는다.
- EntityManager는 트랜잭션마다 분리한다. 자동 DDL·OSIV·2차/쿼리 캐시·SQL 바인딩 로그를 끄고 소유자·원천 필드는 수정하지 않는다. 공개 dataVersion을 JPA `@Version`으로 대체하지 않는다.
- SQL 스키마·함수·권한 파일과 원천 ID·금액·날짜는 JPA 전환 전과 같다. 금융 API용 007 SQL은 기존 미커밋 변경이며 JPA 추가 이행 파일은 없다. 기존 서비스 DB에 SQL을 실행하지 않았다.
- v3 API 형식·오류·페이지·부분 연결·설정 계약을 유지한다. 모바일·계산 패키지·fixture는 수정하지 않았고 기본 계산은 Flutter에 남는다.

## 검증

- 새 폐기용 PostgreSQL 15.13에서 전체 Java 175개 통과, 실패·오류·건너뜀 0개. 금융 HTTP 18개와 조회 자료형 7개가 포함된다. 기존 서버 연결·서비스 변경 0건이며 새 클러스터는 종료했다.
- 실제 DB에서 권한·소유권·동시 요청·멱등·SQL 취소·지연 제약·원천 보존을 확인했다. JPA 추가 검사는 트랜잭션별 영속성 문맥 분리, 타 사용자 엔티티 조회 차단, flush 후 예외 발생 시 설정·버전 롤백을 포함한다.
- 전환 전후 전체 Snapshot·거래 페이지·연결 전·설정 저장 후 응답 4종이 무작위 cursor를 제외하고 동일했다. 실제 응답 5종은 변경하지 않은 Flutter `FinancialSnapshot.fromJson`으로 파싱했다.
- 최초 실행에서 저장소 예외 변환과 EntityManager 후보 중복으로 검사 2개가 실패했다. 기존 사전조건 예외 계약을 명시하고 공유 EntityManager 주입 대상을 지정한 뒤 전체 실제 DB 검사를 통과했다. 연결 유지 모드는 Spring의 명시 격리 수준 요구에 맞춰 트랜잭션 종료까지 유지한다.
- 재실행 절차는 [DB 검사 안내](../database-tests.md)를 따른다. 일반 Gradle의 DB 없는 실행에서 SKIPPED된 결과를 실제 PostgreSQL 통과로 대체하지 않는다.

## 남은 범위와 전달

- 앱 실제 HTTP 어댑터·기기 검증, v4 공동 공개, 외부 배포·서비스 DB 이행은 미실행이다. [최초 인계의 원천 권한/날짜 부족 시 503 제한](2026-10-29-financial-api-handoff.md#제한미실행)을 유지한다.
- Flutter 담당자는 기존 v3 HTTP 연동 작업을 이어가면 된다. JPA 전환에 따른 신규 요청 필드·응답 필드·계산 변경은 없다.

## 역할별 패키지 정리

- Java 67개 파일 중 66개를 이동했다. `PayseApiApplication`은 최상위 진입점으로 유지하며, 현재 배치는 [Java 패키지 안내](../spring-bootstrap.md#java-패키지)를 따른다. 테스트도 검사 대상과 같은 패키지로 이동했다.
- 기존 실행문과 대조한 차이는 공통 검증 함수 4개의 패키지 간 접근 허용과 JPA 스캔 대상의 타입 기반 지정이다. SQL·엔티티 매핑·검증 조건·처리 순서·HTTP/JSON은 유지한다. 내부 쓰기 도우미와 비밀 키 접근자는 공개하지 않았다.
- 현재 소스 경로 링크를 갱신하고 과거 작업 명세의 당시 경로는 이력으로 보존했다. Git의 기존 경로 삭제/새 경로 추가 표시는 파일 이동이며, 클래스나 기능 제거를 뜻하지 않는다.
- 이동 후 새 PostgreSQL 15.13 클러스터에서 Java 175개를 다시 통과했다(실패·오류·건너뜀 0개). 이동 전후 응답 4종은 임의 cursor를 제외하고 동일하며 변경하지 않은 Flutter 모델의 응답 5종 파싱도 통과했다. 패키지 의존 순환과 미해결 내부 import는 없다. 실제 기기·배포 검증을 뜻하지 않는다.

## controller/service/mapper와 DTO·VO 최종 배치

- 사용자가 지정한 기능별 controller/service/mapper 구조로 맞췄다. mapper는 기존 JPA DB 접근이고 MyBatis 도입이 아니다. entity는 `finance/entity/`에 별도로 둔다. 현행 배치와 책임은 [Java 패키지 안내](../spring-bootstrap.md#java-패키지)가 기준이다.
- 인증 공개 응답은 AuthResponse, 내부 DB 조회 결과는 AuthRows로 분리했다. 금융의 PageSlice·StoredReceipt·WriteChange는 dto, TransactionLink·OriginalTransaction·OriginalState는 vo로 옮겼다. AuthInput과 AuthResult는 dto, AuthCredentials와 IssuedToken은 vo, HealthResponse는 health/dto에 둔다. 원래 중첩 타입의 필드·검증·문자열 숨김을 보존했다.
- 기존 Java 파일 45개를 이동하고 중첩 전달 타입을 8개 파일로 추출했다. 현재 Java는 테스트 포함 75개이며 기존 구현 파일 누락은 없다. AuthSecrets와 내부 WriteResult·Context·Journal은 책임과 접근 범위를 유지한다. 남은 빈 옛 패키지 폴더도 제거했다.
- 최종 배치에서 새 PostgreSQL 15.13 클러스터의 Java 175개를 통과했다(실패·오류·건너뜀 0개). 응답 4종은 임의 cursor를 제외하고 동일하고, 변경하지 않은 Flutter 모델로 응답 5종 파싱을 통과했다. SQL·공통 계약·모바일·계산 코드는 보존했으며 기존 서비스 DB 접속과 변경은 0건이다.
