package com.payse.api.finance.service;

import com.payse.api.ApiTestConstants.FinanceCodes;
import com.payse.api.ApiTestConstants.FinanceFields;
import com.payse.api.ApiTestConstants.FinancePaths;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.payse.api.finance.error.FinancialException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 준비 원천과 실제 v3 투영의 페이지·미연결·근거 보존 계약을 검증한다.
 * @created 2026-10-29
 * @usedBy Gradle JUnit
 */
class FinancialProjectionTest {
    private final FinancialProjection projection = new FinancialProjection();
    private final JsonMapper mapper = JsonMapper.builder().build();

    /**
     * 모든 유효 v3 준비 원천의 거래를 중복·누락 없이 100건씩 전달한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     * @modified 2026-11-02 - 기존 자연 정렬을 명시적 수신자 람다로 표현
     */
    @Test
    void preparedSourcesPageWithoutChangingFacts() throws Exception {
        List<Path> files;
        try (var paths = Files.list(Path.of("fixtures/generated/snapshots"))) {
            files = paths.filter(path -> path.toString().endsWith(".json"))
                .filter(
                    path -> !Set.of("alpha-unconnected.json", "refund-unavailable-original.json")
                        .contains(path.getFileName().toString())
                )
                .toList();
        }
        assertFalse(files.isEmpty());
        for (Path path : files) {
            ObjectNode source = (ObjectNode) mapper.readTree(Files.readString(path));
            ObjectNode before = source.deepCopy();
            List<String> expected = ids(source.get(FinanceFields.TRANSACTIONS));
            expected.sort((left, right) -> left.compareTo(right));
            List<String> actual = readAll(source, codes(source));
            assertEquals(expected, actual, path.getFileName().toString());
            assertEquals(before, source);
        }
    }

    /**
     * 연결 전 열 개 키만 제공하고 원천 계좌 선택·급여·잔액을 응답에 덧붙이지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void unconnectedHasOnlyContractKeys() throws Exception {
        ObjectNode source = source("demo-ready");
        var slice = projection.project(source, Set.of(), "5", null, false);
        assertEquals(
            Set.of(
                FinanceFields.USER_ID,
                FinanceFields.SCHEMA_VERSION,
                FinanceFields.CURRENCY,
                FinanceFields.DATA_VERSION,
                FinanceFields.SOURCE_VERSION,
                FinanceFields.RULE_VERSION,
                FinanceFields.AS_OF,
                FinanceFields.INSTITUTIONS,
                FinanceFields.INSTITUTION_LINKS,
                FinanceFields.COVERAGE
            ),
            Set.copyOf(slice.body().propertyNames())
        );
        assertEquals(
            "5",
            slice.body()
                .get(FinanceFields.DATA_VERSION)
                .asString()
        );
        assertEquals(
            0,
            slice.body()
                .get(FinanceFields.INSTITUTION_LINKS)
                .size()
        );
        assertEquals(
            0,
            slice.body()
                .get(FinanceFields.COVERAGE)
                .size()
        );
        assertFalse(slice.hasMore());
    }

    /**
     * 제공된 아홉 기관의 모든 부분 연결 조합에서 원천별 거래 공개와 숨긴 ID 비노출을 검사한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     * @modified 2026-11-02 - 기존 자연 정렬을 명시적 수신자 람다로 표현
     */
    @Test
    void everyConnectionCombinationRespectsSourceAuthority() throws Exception {
        ObjectNode source = source("demo-ready");
        List<String> institutions = new ArrayList<>(codes(source));
        assertEquals(9, institutions.size());
        Map<String, String> parentInstitutions = new HashMap<>();
        for (String group : List.of(FinanceFields.ACCOUNTS, FinanceFields.CARDS)) {
            for (JsonNode row : source.get(group)) {
                parentInstitutions.put(
                    row.get(
                        group.equals(FinanceFields.ACCOUNTS) ? FinanceFields.ACCOUNT_ID
                            : FinanceFields.CARD_ID
                    ).asString(),
                    row.get(FinanceFields.INSTITUTION_CODE).asString()
                );
            }
        }
        for (int mask = 1; mask < 1 << institutions.size(); mask++) {
            Set<String> selected = new HashSet<>();
            for (int index = 0; index < institutions.size(); index++) {
                if ((mask & (1 << index)) != 0) {
                    selected.add(institutions.get(index));
                }
            }
            List<String> expected = new ArrayList<>();
            Set<String> hidden = new HashSet<>();
            for (JsonNode row : source.get(FinanceFields.TRANSACTIONS)) {
                String primary = row.get(FinanceFields.RECORD_KIND)
                    .asString()
                    .equals("account_entry") ? FinanceFields.ACCOUNT_ID : FinanceFields.CARD_ID;
                if (selected.contains(parentInstitutions.get(row.get(primary).asString()))) {
                    expected.add(row.get(FinanceFields.TRANSACTION_ID).asString());
                } else {
                    hidden.add(row.get(FinanceFields.TRANSACTION_ID).asString());
                }
            }
            expected.sort((left, right) -> left.compareTo(right));
            var first = projection.project(source, selected, "1", null, false);
            for (String hiddenId : hidden) {
                assertFalse(
                    first.body()
                        .toString()
                        .contains(hiddenId)
                );
            }
            assertEquals(expected, readAll(source, selected), "connection mask " + mask);
        }
    }

    /**
     * Java의 signed UUID 비교가 아닌 정규 UUID 문자열 순서를 페이지 경계까지 유지한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     * @modified 2026-11-02 - 기존 자연 정렬을 명시적 수신자 람다로 표현
     */
    @Test
    void uuidOrderingAndPageBoundaryMatchPostgres() throws Exception {
        ObjectNode source = source("demo-ready");
        List<String> expected = ids(source.get(FinanceFields.TRANSACTIONS));
        assertTrue(expected.stream().anyMatch(value -> value.charAt(0) >= '8'));
        assertTrue(expected.stream().anyMatch(value -> value.charAt(0) < '8'));
        expected.sort((left, right) -> left.compareTo(right));
        var first = projection.project(source, codes(source), "1", null, false);
        assertEquals(expected.subList(0, 100), ids(first.body().get(FinanceFields.TRANSACTIONS)));
        assertEquals(expected.get(99), first.lastId().toString());
        var second = projection.project(source, codes(source), "1", first.lastId(), true);
        assertEquals(
            expected.subList(100, 200),
            ids(second.body().get(FinanceFields.TRANSACTIONS))
        );
    }

    /**
     * 다음 페이지의 청구 참조는 ID를 유지하고 relatedTransactions에 전량 복제하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void referencesToNextPageRemainIds() throws Exception {
        ObjectNode source = source("demo-ready");
        var first = projection.project(source, codes(source), "1", null, false);
        Set<String> pageIds = new HashSet<>(ids(first.body().get(FinanceFields.TRANSACTIONS)));
        Set<String> related = new HashSet<>(
            ids(first.body().get(FinanceFields.RELATED_TRANSACTIONS))
        );
        int nextReferences = 0;
        for (JsonNode statement : first.body().get(FinanceFields.STATEMENTS)) {
            for (JsonNode reference : statement.get(FinanceFields.INCLUDED_TRANSACTION_REFS)) {
                if (!pageIds.contains(reference.asString())) {
                    nextReferences++;
                    assertFalse(related.contains(reference.asString()));
                }
            }
        }
        assertTrue(nextReferences > 0);
        assertEquals(
            0,
            first.body()
                .get(FinanceFields.REFERENCE_RESOLUTIONS)
                .size()
        );
    }

    /**
     * 기간 밖 환불 원결제는 관계 근거로 보존하고 일반 거래 목록에 섞지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void outsideWindowOriginalRemainsRelated() throws Exception {
        ObjectNode source = source("refund-outside-window");
        Set<String> expectedRelated = new HashSet<>(
            ids(source.get(FinanceFields.RELATED_TRANSACTIONS))
        );
        assertFalse(expectedRelated.isEmpty());
        Set<String> seenRelated = new HashSet<>();
        var slice = projection.project(source, codes(source), "1", null, false);
        while (true) {
            seenRelated.addAll(ids(slice.body().get(FinanceFields.RELATED_TRANSACTIONS)));
            for (String transactionId : ids(slice.body().get(FinanceFields.TRANSACTIONS))) {
                assertFalse(expectedRelated.contains(transactionId));
            }
            if (!slice.hasMore()) {
                break;
            }
            slice = projection.project(source, codes(source), "1", slice.lastId(), true);
        }
        assertEquals(expectedRelated, seenRelated);
    }

    /**
     * 입금 전 미래 원천은 unknown과 빈 거래 목록 그대로 응답에 남는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void unknownFutureSalaryEvidenceIsPreserved() throws Exception {
        ObjectNode source = source("salary-schedule-provided");
        var body = projection.project(source, codes(source), "1", null, false).body();
        assertEquals(
            source.at(FinancePaths.SALARY_EVIDENCE_POINTER),
            body.at(FinancePaths.SALARY_EVIDENCE_POINTER)
        );
        boolean hasUnconfirmedSchedule = FinancialProjection
            .rows(body.at(FinancePaths.SALARY_POINTER), FinanceFields.RECEIPT_EVIDENCE)
            .stream()
            .anyMatch(
                row -> row.get("confirmation")
                    .asString()
                    .equals("unknown") && row.get("transactionIds").isEmpty()
            );
        assertTrue(hasUnconfirmedSchedule);
    }

    /**
     * 숨겨진 은행의 카드 출금 참조는 null이 아닌 생략과 제한 표식으로 표현한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void hiddenWithdrawalAccountUsesOmission() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode card = unique(
            source,
            FinanceFields.CARDS,
            FinanceFields.INSTITUTION_CODE,
            "card.hyundai"
        );
        assertFalse(card.get(FinanceFields.WITHDRAWAL_ACCOUNT_ID).isNull());
        String cardId = card.get(FinanceFields.CARD_ID).asString();
        String hiddenAccount = card.get(FinanceFields.WITHDRAWAL_ACCOUNT_ID).asString();
        var body = projection
            .project(
                source,
                Set.of(card.get(FinanceFields.INSTITUTION_CODE).asString()),
                "1",
                null,
                false
            )
            .body();
        ObjectNode actualCard = FinancialProjection.rows(body, FinanceFields.CARDS)
            .stream()
            .filter(
                row -> row.get(FinanceFields.CARD_ID)
                    .asString()
                    .equals(cardId)
            )
            .findFirst()
            .orElseThrow();
        assertFalse(actualCard.has(FinanceFields.WITHDRAWAL_ACCOUNT_ID));
        assertFalse(body.toString().contains(hiddenAccount));
        boolean hasAccountRestriction = FinancialProjection
            .rows(body, FinanceFields.ACCESS_RESTRICTIONS)
            .stream()
            .anyMatch(
                mark -> mark.get(FinanceFields.OWNER_TYPE)
                    .asString()
                    .equals("card")
                    && mark.get(FinanceFields.OWNER_ID)
                        .asString()
                        .equals(cardId)
                    && mark.get(FinanceFields.FIELD)
                        .asString()
                        .equals(FinanceFields.WITHDRAWAL_ACCOUNT_ID)
            );
        assertTrue(hasAccountRestriction);
    }

    /**
     * 미확보 원결제의 기관 권한을 모를 때 빈 값이나 가짜 관계 대신 계약의 503을 반환한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void missingOriginalWithoutAuthorityFailsClosed() throws Exception {
        ObjectNode source = source("refund-unavailable-original");
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 내부 조회 결과에 다른 사용자 행이 섞이면 미연결 상태로 숨겨 통과시키지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void foreignOwnerIsRejectedBeforeProjection() throws Exception {
        ObjectNode source = source("demo-ready");
        String foreignOwner = source("beta-ready")
            .get(FinanceFields.USER_ID)
            .asString();
        unique(
            source,
            FinanceFields.ACCOUNTS,
            FinanceFields.ACCOUNT_ID,
            source.at(FinancePaths.SALARY_ACCOUNT_POINTER).asString()
        ).put(FinanceFields.USER_ID, foreignOwner);
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 같은 ID의 상충 행을 마지막 값으로 덮어쓰지 않고 조회를 실패시킨다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void conflictingDuplicateTransactionFails() throws Exception {
        ObjectNode source = source("demo-ready");
        String salaryTransaction = source.at("/settings/salary/receiptEvidence/0/transactionIds/0")
            .asString();
        assertEquals(1, source.at(FinancePaths.SALARY_EVIDENCE_POINTER).size());
        assertEquals(1, source.at("/settings/salary/receiptEvidence/0/transactionIds").size());
        ObjectNode duplicate = unique(
            source,
            FinanceFields.TRANSACTIONS,
            FinanceFields.TRANSACTION_ID,
            salaryTransaction
        ).deepCopy();
        duplicate.put(FinanceFields.DESCRIPTION, "다른 원천 설명");
        ((ArrayNode) source.get(FinanceFields.TRANSACTIONS)).add(duplicate);
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 내부 rawFragment 같은 미등록 필드를 공개 모델에 흘려보내지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void unregisteredPayloadFieldIsRejected() throws Exception {
        ObjectNode source = source("demo-ready");
        unique(
            source,
            FinanceFields.ACCOUNTS,
            FinanceFields.ACCOUNT_ID,
            source.at(FinancePaths.SALARY_ACCOUNT_POINTER).asString()
        ).put("rawFragment", "private");
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 청구 항목이 없는 v3 자료의 이름만 v4로 바꿔 정상 원천으로 통과시키지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-10-30 - v4 지원 이후에도 필수 청구 항목 없는 버전 재표시를 거절
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void v4RequiresBillingItems() throws Exception {
        ObjectNode source = source("demo-ready");
        source.put(FinanceFields.SCHEMA_VERSION, FinanceCodes.DRAFT_V4);
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 현재 원천 목록에 없는 페이지 경계는 정상 빈 페이지로 바꾸지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void cursorBoundaryMustExistInCurrentRange() throws Exception {
        ObjectNode source = source("demo-ready");
        UUID nonexistent = UUID.randomUUID();
        assertFalse(ids(source.get(FinanceFields.TRANSACTIONS)).contains(nonexistent.toString()));
        var failure = assertThrows(
            FinancialException.class,
            () -> projection.project(source, codes(source), "1", nonexistent, true)
        );
        assertEquals(400, failure.status());
        assertEquals(FinanceCodes.INVALID_CURSOR, failure.code());
    }

    /**
     * 후속 페이지는 설정·계좌·청구를 반복하거나 해당 부모 제한 표식을 단독 노출하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void nextPageHasOnlyPageContractFields() throws Exception {
        ObjectNode source = source("demo-ready");
        var first = projection.project(source, codes(source), "1", null, false);
        var page = projection.project(source, codes(source), "1", first.lastId(), true).body();
        assertEquals(
            Set.of(
                FinanceFields.USER_ID,
                FinanceFields.SCHEMA_VERSION,
                FinanceFields.CURRENCY,
                FinanceFields.DATA_VERSION,
                FinanceFields.SOURCE_VERSION,
                FinanceFields.RULE_VERSION,
                FinanceFields.AS_OF,
                FinanceFields.TRANSACTIONS,
                FinanceFields.RELATED_TRANSACTIONS,
                FinanceFields.REFERENCE_RESOLUTIONS,
                FinanceFields.TRANSACTION_RELATIONS,
                FinanceFields.OCCURRENCE_LINKS,
                FinanceFields.COVERAGE,
                FinanceFields.PAGE,
                FinanceFields.ACCESS_RESTRICTIONS
            ),
            Set.copyOf(page.propertyNames())
        );
        for (JsonNode mark : page.get(FinanceFields.ACCESS_RESTRICTIONS)) {
            assertTrue(
                Set.of(FinanceFields.RESPONSE, "transaction")
                    .contains(mark.get(FinanceFields.OWNER_TYPE).asString())
            );
        }
    }

    /**
     * 동일 회차 연결은 JSON 키 순서가 달라도 계약의 식별 튜플로 한 번만 제공한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void occurrenceTupleIgnoresObjectKeyOrder() throws Exception {
        ObjectNode source = source("demo-ready");
        ArrayNode links = (ArrayNode) source.get(FinanceFields.OCCURRENCE_LINKS);
        assertFalse(links.isEmpty());
        ObjectNode original = (ObjectNode) links.get(0);
        ObjectNode duplicate = mapper.createObjectNode();
        List<String> fields = new ArrayList<>(original.propertyNames()).reversed();
        for (String field : fields) {
            duplicate.set(field, original.get(field).deepCopy());
        }
        int count = links.size();
        links.add(duplicate);
        assertEquals(
            count,
            projection.project(source, codes(source), "1", null, false)
                .body()
                .get(FinanceFields.OCCURRENCE_LINKS)
                .size()
        );
    }

    /**
     * 기간 밖 원거래가 순환 참조해도 각 보조 거래는 한 번만 제공하고 탐색을 종료한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void cyclicOutsideReferencesTerminateOncePerId() throws Exception {
        ObjectNode source = source("refund-outside-window");
        ArrayNode related = (ArrayNode) source.get(FinanceFields.RELATED_TRANSACTIONS);
        assertEquals(1, related.size());
        ObjectNode original = (ObjectNode) related.get(0);
        String originalId = original.get(FinanceFields.TRANSACTION_ID).asString();
        ObjectNode additional = original.deepCopy();
        String newId = UUID.randomUUID().toString();
        additional.put(FinanceFields.TRANSACTION_ID, newId)
            .put(
                FinanceFields.SOURCE_REF,
                original.get(FinanceFields.SOURCE_REF).asString() + "/cycle"
            )
            .put(FinanceFields.ORIGINAL_TRANSACTION_ID, originalId);
        original.put(FinanceFields.ORIGINAL_TRANSACTION_ID, newId);
        related.add(additional);
        Set<String> seen = new HashSet<>();
        var slice = projection.project(source, codes(source), "1", null, false);
        while (true) {
            List<String> ids = ids(slice.body().get(FinanceFields.RELATED_TRANSACTIONS));
            assertEquals(new HashSet<>(ids).size(), ids.size());
            seen.addAll(ids);
            if (!slice.hasMore()) {
                break;
            }
            slice = projection.project(source, codes(source), "1", slice.lastId(), true);
        }
        assertEquals(Set.of(originalId, newId), seen);
    }

    /**
     * 저장 JSON의 문자열 슬롯에 임의 객체를 넣어 비밀 데이터를 우회 전달하지 못한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void nestedObjectInScalarSlotIsRejected() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode card = unique(
            source,
            FinanceFields.CARDS,
            FinanceFields.INSTITUTION_CODE,
            "card.hyundai"
        );
        assertFalse(card.get(FinanceFields.SCHEDULE_EVIDENCE).isEmpty());
        ObjectNode evidence = (ObjectNode) card.get(FinanceFields.SCHEDULE_EVIDENCE).get(0);
        evidence.putObject(FinanceFields.EVIDENCE_REF).put("secret", "not-a-reference");
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 테스트 원천은 파일 이름으로 명시 선택하고 사용자·참조 ID는 본문에서 확인해 전달한다.
     * @created 2026-10-29
     * @usedBy FinancialProjectionTest
     */
    private ObjectNode source(String name) throws Exception {
        return (ObjectNode) mapper
            .readTree(Files.readString(Path.of("fixtures/generated/snapshots", name + ".json")));
    }

    /**
     * 원천에 실제 제공된 기관 집합만 시험 연결 대상으로 사용한다.
     * @created 2026-10-29
     * @usedBy FinancialProjectionTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private Set<String> codes(ObjectNode source) {
        Set<String> result = new LinkedHashSet<>();
        for (JsonNode institution : source.get(FinanceFields.INSTITUTIONS)) {
            result.add(institution.get(FinanceFields.CODE).asString());
        }
        return result;
    }

    /**
     * 거래 ID만 수집하여 표시명·고정 UUID에 의존하지 않고 페이지 관계를 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialProjectionTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private List<String> ids(JsonNode transactions) {
        List<String> result = new ArrayList<>();
        for (JsonNode transaction : transactions) {
            result.add(transaction.get(FinanceFields.TRANSACTION_ID).asString());
        }
        return result;
    }

    /**
     * 명시 관계·기관 코드로 시험 대상을 정하고 단일 행임을 먼저 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialProjectionTest의 원천 변조 검증
     */
    private ObjectNode unique(ObjectNode source, String group, String field, String value) {
        List<ObjectNode> matches = FinancialProjection.rows(source, group)
            .stream()
            .filter(
                row -> row.get(field)
                    .asString()
                    .equals(value)
            )
            .toList();
        assertEquals(1, matches.size());
        return matches.getFirst();
    }

    /**
     * 응답 경계를 이어 읽고 같은 ID가 두 페이지에 나오거나 최대 크기를 넘으면 실패한다.
     * @created 2026-10-29
     * @usedBy preparedSourcesPageWithoutChangingFacts,
     * everyConnectionCombinationRespectsSourceAuthority
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private List<String> readAll(ObjectNode source, Set<String> codes) {
        List<String> actual = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        UUID after = null;
        while (true) {
            var slice = projection.project(source, codes, "1", after, after != null);
            List<String> pageIds = ids(slice.body().get(FinanceFields.TRANSACTIONS));
            assertTrue(pageIds.size() <= 100);
            for (String id : pageIds) {
                assertTrue(seen.add(id));
            }
            actual.addAll(pageIds);
            if (!slice.hasMore()) {
                break;
            }
            assertNotNull(slice.lastId());
            after = slice.lastId();
        }
        return actual;
    }

    /**
     * 처리할 수 없는 원천을 0원·빈 정상 응답 대신 공개 503으로 구분한다.
     * @created 2026-10-29
     * @usedBy FinancialProjectionTest의 실패 시나리오
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private void assertUnavailable(Runnable operation) {
        var failure = assertThrows(FinancialException.class, operation::run);
        assertEquals(503, failure.status());
        assertEquals(FinanceCodes.TEMPORARILY_UNAVAILABLE, failure.code());
    }
}
