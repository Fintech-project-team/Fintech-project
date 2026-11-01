package com.payse.api.finance.validation;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.payse.api.finance.error.FinancialException;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 금융 쓰기 입력의 타입·정수 경계·nullable·변경 목록을 독립적으로 검사한다.
 * @created 2026-10-29
 * @usedBy Gradle test
 */
class FinancialInputTest {
    private final JsonMapper mapper = JsonMapper.builder().build();

    /**
     * 숫자 버전·선행 0·범위 초과·알 수 없는 키는 변환하지 않고 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void rejectsInvalidWriteContext() {
        for (String version : new String[] {"0", "01", "9223372036854775808", "1.0", "-1"}) {
            ObjectNode body = salary();
            body.put("expectedDataVersion", version);
            reject("PATCH", "/settings", body);
        }
        ObjectNode number = salary().put("expectedDataVersion", 1);
        reject("PATCH", "/settings", number);
        ObjectNode unknown = salary().put("userId", UUID.randomUUID().toString());
        reject("PATCH", "/settings", unknown);
        ObjectNode key = salary().put("idempotencyKey", "with spaces");
        reject("PATCH", "/settings", key);
    }

    /**
     * 금액 정수 상·하한을 허용하고 문자열·실수·boolean을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void enforcesIntegerMoney() {
        for (String amount : new String[] {"0", "9000000000000"}) {
            ObjectNode body = context();
            body.set("salary", mapper.readTree("{\"salaryAmountKRW\":" + amount + "}"));
            assertEquals(body, FinancialInput.validate("PATCH", "/settings", body));
        }
        for (String amount : new String[] {"-1", "9000000000001", "1.0", "true", "\"100\""}) {
            ObjectNode body = context();
            body.set("salary", mapper.readTree("{\"salaryAmountKRW\":" + amount + "}"));
            reject("PATCH", "/settings", body);
        }
    }

    /**
     * 급여의 생략·명시 null을 유지하고 빈 PATCH나 원천 근거 변경을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void preservesPatchMeaning() {
        ObjectNode body = context();
        body.putObject("salary").putNull("salaryDay");
        JsonNode result = FinancialInput.validate("PATCH", "/settings", body);
        assertTrue(result.get("salary").has("salaryDay"));
        assertTrue(result.get("salary").get("salaryDay").isNull());
        assertEquals(1, result.get("salary").size());
        reject("PATCH", "/settings", context());
        ObjectNode empty = context();
        empty.putObject("salary");
        reject("PATCH", "/settings", empty);
        ObjectNode source = salary();
        ((ObjectNode) source.get("salary")).putArray("receiptEvidence");
        reject("PATCH", "/settings", source);
    }

    /**
     * 별칭은 12 grapheme·이모지·null을 지원하고 특수문자 전용 값을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void validatesNicknameGraphemes() {
        String path = "/accounts/" + UUID.randomUUID();
        ObjectNode body = context().put("nickname", "  " + "가".repeat(12) + "  ");
        assertEquals(body, FinancialInput.validate("PATCH", path, body));
        assertEquals(body.get("nickname").asString(), "  " + "가".repeat(12) + "  ");
        FinancialInput.validate("PATCH", path, context().put("nickname", "👨‍👩‍👧‍👦"));
        FinancialInput.validate("PATCH", path, context().putNull("nickname"));
        reject("PATCH", path, context().put("nickname", "가".repeat(13)));
        reject("PATCH", path, context().put("nickname", "!!!"));
    }

    /**
     * 의무명 80자와 윤일은 허용하되 존재하지 않는 날짜·원천 필드는 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void validatesObligationFields() {
        ObjectNode body = obligation().put("label", "가".repeat(80)).put("dueDate", "2028-02-29");
        FinancialInput.validate("POST", "/obligations", body);
        reject("POST", "/obligations", body.deepCopy().put("label", "가".repeat(81)));
        reject("POST", "/obligations", body.deepCopy().put("dueDate", "2027-02-29"));
        reject("POST", "/obligations", body.deepCopy().put("dueDate", "0000-01-01"));
        reject("POST", "/obligations", body.deepCopy().put("status", "active"));
        reject("PATCH", "/obligations/" + UUID.randomUUID(), context());
    }

    /**
     * NBSP·BOM만 있는 이름을 거절하며 Flutter와 같은 경계 공백·grapheme 처리를 확인한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void trimsUnicodeLabelSpaces() {
        reject("POST", "/obligations", obligation().put("label", "\u00a0\ufeff\u202f"));
        assertEquals("이름", FinancialInput.trimLabel("\ufeff\u00a0이름\u3000\ufeff"));
        ObjectNode family = obligation().put("label", "\ufeff" + "👨‍👩‍👧‍👦".repeat(80) + "\u00a0");
        FinancialInput.validate("POST", "/obligations", family);
        reject("POST", "/obligations", family.put("label", "👨‍👩‍👧‍👦".repeat(81)));
    }

    /**
     * 대소문자만 다른 UUID와 배정 update/remove 중복을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void rejectsDuplicateIds() {
        String id = UUID.randomUUID().toString();
        ObjectNode selection = context();
        selection.putArray("accountIds").add(id).add(id.toUpperCase());
        reject("PATCH", "/account-selection", selection);
        ObjectNode reserve = reserve();
        ObjectNode changes = (ObjectNode) reserve.get("allocationChanges");
        changes.withArray("update").addObject().put("allocationId", id).put("amountKRW", 1);
        changes.withArray("remove").add(id);
        reject("POST", "/reserves", reserve);
    }

    /**
     * 배정은 양수이며 호출자가 해제 금액·근거를 수정하지 못한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void validatesAllocationChanges() {
        FinancialInput.validate("POST", "/reserves", reserve());
        ObjectNode body = reserve();
        ObjectNode entry = ((ObjectNode) body.get("allocationChanges")).withArray("create")
            .addObject().put("obligationId", UUID.randomUUID().toString()).put("amountKRW", 0);
        reject("POST", "/reserves", body);
        entry.put("amountKRW", 1).put("releasedKRW", 0);
        reject("POST", "/reserves", body);
    }

    /**
     * cancel의 빈 확인 목록을 형식상 허용하되 null·중복·0원은 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void validatesCancelConfirmation() {
        String path = "/reserves/" + UUID.randomUUID() + "/cancel";
        ObjectNode body = context();
        body.putArray("detachAllocations");
        FinancialInput.validate("POST", path, body);
        reject("POST", path, context().putNull("detachAllocations"));
        body.withArray("detachAllocations").addObject()
            .put("allocationId", UUID.randomUUID().toString()).put("unreleasedKRW", 0);
        reject("POST", path, body);
    }

    /**
     * 카드 override 해제는 null로 허용하며 중복 카드·원천 계좌 변경은 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void validatesCardOverrides() {
        String id = UUID.randomUUID().toString();
        ObjectNode body = context();
        body.putArray("cardPlans").addObject().put("cardId", id).putNull("plannedPaymentDay");
        FinancialInput.validate("PATCH", "/settings", body);
        body.withArray("cardPlans").addObject().put("cardId", id).put("plannedPaymentDay", 31);
        reject("PATCH", "/settings", body);
    }

    /**
     * 빈 카드 배열은 명시한 카드가 없다는 뜻이며 급여 PATCH나 기존 카드 설정을 지우지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void allowsEmptyCardPatchList() {
        ObjectNode salaryOnly = salary();
        salaryOnly.putArray("cardPlans");
        FinancialInput.validate("PATCH", "/settings", salaryOnly);
        ObjectNode emptyCards = context();
        emptyCards.putArray("cardPlans");
        FinancialInput.validate("PATCH", "/settings", emptyCards);
        reject("PATCH", "/settings", context().putNull("cardPlans"));
    }

    /**
     * 동일성 검증용 원본 요청의 배열 순서와 공백을 변경하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void keepsOriginalRequest() {
        ObjectNode body = context();
        body.putArray("institutionCodes").add("bank.b").add("bank.a");
        String before = body.toString();
        FinancialInput.validate("POST", "/institution-links", body);
        assertEquals(before, body.toString());
    }

    /**
     * 다른 테스트에 종속되지 않는 유효 금융 W를 만든다.
     * @created 2026-10-29
     * @usedBy FinancialInputTest
     */
    private ObjectNode context() {
        return mapper.createObjectNode().put("expectedDataVersion", "1").put("ruleVersion", "test-rule")
            .put("idempotencyKey", UUID.randomUUID().toString());
    }

    /**
     * 급여 날짜만 바꾸는 최소 요청을 만든다.
     * @created 2026-10-29
     * @usedBy FinancialInputTest
     */
    private ObjectNode salary() {
        ObjectNode body = context();
        body.putObject("salary").put("salaryDay", 25);
        return body;
    }

    /**
     * 원천 DB와 무관한 단건 의무 형식 자료를 만든다.
     * @created 2026-10-29
     * @usedBy FinancialInputTest
     */
    private ObjectNode obligation() {
        return context().put("label", "월세").put("withdrawalAccountId", UUID.randomUUID().toString())
            .put("amountKRW", 300000).put("dueDate", "2026-10-29");
    }

    /**
     * 세 배정 배열이 명시된 최소 보호 요청을 만든다.
     * @created 2026-10-29
     * @usedBy FinancialInputTest
     */
    private ObjectNode reserve() {
        ObjectNode body = context().put("accountId", UUID.randomUUID().toString()).put("label", "비상금").put("amountKRW", 100);
        ObjectNode changes = body.putObject("allocationChanges");
        changes.putArray("create");
        changes.putArray("update");
        changes.putArray("remove");
        return body;
    }

    /**
     * 거절 입력이 저장 작업까지 진행되지 않도록 검증 예외를 확인한다.
     * @created 2026-10-29
     * @usedBy FinancialInputTest
     */
    private void reject(String method, String path, JsonNode body) {
        assertThrows(FinancialException.class, () -> FinancialInput.validate(method, path, body));
    }
}
