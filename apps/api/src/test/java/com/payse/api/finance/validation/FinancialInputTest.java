package com.payse.api.finance.validation;

import com.payse.api.ApiTestConstants.FinanceFields;
import com.payse.api.ApiTestConstants.FinanceHttp;
import com.payse.api.ApiTestConstants.FinancePaths;

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
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsInvalidWriteContext() {
        for (String version : new String[] {
            "0",
            "01",
            "9223372036854775808",
            "1.0",
            "-1"
        }) {
            ObjectNode body = salary();
            body.put(FinanceFields.EXPECTED_DATA_VERSION, version);
            reject(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, body);
        }
        ObjectNode number = salary().put(FinanceFields.EXPECTED_DATA_VERSION, 1);
        reject(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, number);
        ObjectNode unknown = salary().put(FinanceFields.USER_ID, UUID.randomUUID().toString());
        reject(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, unknown);
        ObjectNode key = salary().put(FinanceFields.IDEMPOTENCY_KEY, "with spaces");
        reject(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, key);
    }

    /**
     * 금액 정수 상·하한을 허용하고 문자열·실수·boolean을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void enforcesIntegerMoney() {
        for (String amount : new String[] { "0", "9000000000000" }) {
            ObjectNode body = context();
            body.set(FinanceFields.SALARY, mapper.readTree("{\"salaryAmountKRW\":" + amount + "}"));
            assertEquals(
                body,
                FinancialInput.validate(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, body)
            );
        }
        for (String amount : new String[] {
            "-1",
            "9000000000001",
            "1.0",
            "true",
            "\"100\""
        }) {
            ObjectNode body = context();
            body.set(FinanceFields.SALARY, mapper.readTree("{\"salaryAmountKRW\":" + amount + "}"));
            reject(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, body);
        }
    }

    /**
     * 급여의 생략·명시 null을 유지하고 빈 PATCH나 원천 근거 변경을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void preservesPatchMeaning() {
        ObjectNode body = context();
        body.putObject(FinanceFields.SALARY).putNull(FinanceFields.SALARY_DAY);
        JsonNode result = FinancialInput
            .validate(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, body);
        assertTrue(result.get(FinanceFields.SALARY).has(FinanceFields.SALARY_DAY));
        assertTrue(
            result.get(FinanceFields.SALARY)
                .get(FinanceFields.SALARY_DAY)
                .isNull()
        );
        assertEquals(1, result.get(FinanceFields.SALARY).size());
        reject(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, context());
        ObjectNode empty = context();
        empty.putObject(FinanceFields.SALARY);
        reject(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, empty);
        ObjectNode source = salary();
        ((ObjectNode) source.get(FinanceFields.SALARY)).putArray(FinanceFields.RECEIPT_EVIDENCE);
        reject(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, source);
    }

    /**
     * 별칭은 12 grapheme·이모지·null을 지원하고 특수문자 전용 값을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void validatesNicknameGraphemes() {
        String path = FinancePaths.ACCOUNT_PATH + UUID.randomUUID();
        ObjectNode body = context().put(FinanceFields.NICKNAME, "  " + "가".repeat(12) + "  ");
        assertEquals(body, FinancialInput.validate(FinanceHttp.PATCH, path, body));
        assertEquals(body.get(FinanceFields.NICKNAME).asString(), "  " + "가".repeat(12) + "  ");
        FinancialInput.validate(
            FinanceHttp.PATCH,
            path,
            context().put(FinanceFields.NICKNAME, "👨‍👩‍👧‍👦")
        );
        FinancialInput.validate(FinanceHttp.PATCH, path, context().putNull(FinanceFields.NICKNAME));
        reject(FinanceHttp.PATCH, path, context().put(FinanceFields.NICKNAME, "가".repeat(13)));
        reject(FinanceHttp.PATCH, path, context().put(FinanceFields.NICKNAME, "!!!"));
    }

    /**
     * 의무명 80자와 윤일은 허용하되 존재하지 않는 날짜·원천 필드는 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void validatesObligationFields() {
        ObjectNode body = obligation()
            .put(FinanceFields.LABEL, "가".repeat(80))
            .put(FinanceFields.DUE_DATE, "2028-02-29");
        FinancialInput.validate(FinanceHttp.POST, FinancePaths.OBLIGATIONS_PATH, body);
        reject(
            FinanceHttp.POST,
            FinancePaths.OBLIGATIONS_PATH,
            body.deepCopy().put(FinanceFields.LABEL, "가".repeat(81))
        );
        reject(
            FinanceHttp.POST,
            FinancePaths.OBLIGATIONS_PATH,
            body.deepCopy().put(FinanceFields.DUE_DATE, "2027-02-29")
        );
        reject(
            FinanceHttp.POST,
            FinancePaths.OBLIGATIONS_PATH,
            body.deepCopy().put(FinanceFields.DUE_DATE, "0000-01-01")
        );
        reject(
            FinanceHttp.POST,
            FinancePaths.OBLIGATIONS_PATH,
            body.deepCopy().put(FinanceFields.STATUS, "active")
        );
        reject(FinanceHttp.PATCH, FinancePaths.OBLIGATION_PATH + UUID.randomUUID(), context());
    }

    /**
     * NBSP·BOM만 있는 이름을 거절하며 Flutter와 같은 경계 공백·grapheme 처리를 확인한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void trimsUnicodeLabelSpaces() {
        reject(
            FinanceHttp.POST,
            FinancePaths.OBLIGATIONS_PATH,
            obligation().put(FinanceFields.LABEL, "\u00a0\ufeff\u202f")
        );
        assertEquals("이름", FinancialInput.trimLabel("\ufeff\u00a0이름\u3000\ufeff"));
        ObjectNode family = obligation()
            .put(FinanceFields.LABEL, "\ufeff" + "👨‍👩‍👧‍👦".repeat(80) + "\u00a0");
        FinancialInput.validate(FinanceHttp.POST, FinancePaths.OBLIGATIONS_PATH, family);
        reject(
            FinanceHttp.POST,
            FinancePaths.OBLIGATIONS_PATH,
            family.put(FinanceFields.LABEL, "👨‍👩‍👧‍👦".repeat(81))
        );
    }

    /**
     * 대소문자만 다른 UUID와 배정 update/remove 중복을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsDuplicateIds() {
        String id = UUID.randomUUID().toString();
        ObjectNode selection = context();
        selection.putArray(FinanceFields.ACCOUNT_IDS)
            .add(id)
            .add(id.toUpperCase());
        reject(FinanceHttp.PATCH, FinancePaths.ACCOUNT_SELECTION_PATH, selection);
        ObjectNode reserve = reserve();
        ObjectNode changes = (ObjectNode) reserve.get(FinanceFields.ALLOCATION_CHANGES);
        changes.withArray("update")
            .addObject()
            .put(FinanceFields.ALLOCATION_ID, id)
            .put(FinanceFields.AMOUNT_KRW, 1);
        changes.withArray("remove").add(id);
        reject(FinanceHttp.POST, FinancePaths.RESERVES_PATH, reserve);
    }

    /**
     * 배정은 양수이며 호출자가 해제 금액·근거를 수정하지 못한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void validatesAllocationChanges() {
        FinancialInput.validate(FinanceHttp.POST, FinancePaths.RESERVES_PATH, reserve());
        ObjectNode body = reserve();
        ObjectNode entry = ((ObjectNode) body.get(FinanceFields.ALLOCATION_CHANGES))
            .withArray("create")
            .addObject()
            .put(FinanceFields.OBLIGATION_ID, UUID.randomUUID().toString())
            .put(FinanceFields.AMOUNT_KRW, 0);
        reject(FinanceHttp.POST, FinancePaths.RESERVES_PATH, body);
        entry.put(FinanceFields.AMOUNT_KRW, 1).put(FinanceFields.RELEASED_KRW, 0);
        reject(FinanceHttp.POST, FinancePaths.RESERVES_PATH, body);
    }

    /**
     * cancel의 빈 확인 목록을 형식상 허용하되 null·중복·0원은 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void validatesCancelConfirmation() {
        String path = FinancePaths.RESERVE_PATH + UUID.randomUUID() + FinancePaths.CANCEL_SUFFIX;
        ObjectNode body = context();
        body.putArray(FinanceFields.DETACH_ALLOCATIONS);
        FinancialInput.validate(FinanceHttp.POST, path, body);
        reject(FinanceHttp.POST, path, context().putNull(FinanceFields.DETACH_ALLOCATIONS));
        body.withArray(FinanceFields.DETACH_ALLOCATIONS)
            .addObject()
            .put(FinanceFields.ALLOCATION_ID, UUID.randomUUID().toString())
            .put(FinanceFields.UNRELEASED_KRW, 0);
        reject(FinanceHttp.POST, path, body);
    }

    /**
     * 카드 override 해제는 null로 허용하며 중복 카드·원천 계좌 변경은 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void validatesCardOverrides() {
        String id = UUID.randomUUID().toString();
        ObjectNode body = context();
        body.putArray(FinanceFields.CARD_PLANS)
            .addObject()
            .put(FinanceFields.CARD_ID, id)
            .putNull(FinanceFields.PLANNED_PAYMENT_DAY);
        FinancialInput.validate(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, body);
        body.withArray(FinanceFields.CARD_PLANS)
            .addObject()
            .put(FinanceFields.CARD_ID, id)
            .put(FinanceFields.PLANNED_PAYMENT_DAY, 31);
        reject(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, body);
    }

    /**
     * 빈 카드 배열은 명시한 카드가 없다는 뜻이며 급여 PATCH나 기존 카드 설정을 지우지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void allowsEmptyCardPatchList() {
        ObjectNode salaryOnly = salary();
        salaryOnly.putArray(FinanceFields.CARD_PLANS);
        FinancialInput.validate(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, salaryOnly);
        ObjectNode emptyCards = context();
        emptyCards.putArray(FinanceFields.CARD_PLANS);
        FinancialInput.validate(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, emptyCards);
        reject(
            FinanceHttp.PATCH,
            FinancePaths.SETTINGS_PATH,
            context().putNull(FinanceFields.CARD_PLANS)
        );
    }

    /**
     * 동일성 검증용 원본 요청의 배열 순서와 공백을 변경하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void keepsOriginalRequest() {
        ObjectNode body = context();
        body.putArray(FinanceFields.INSTITUTION_CODES)
            .add("bank.b")
            .add("bank.a");
        String before = body.toString();
        FinancialInput.validate(FinanceHttp.POST, FinancePaths.INSTITUTION_LINKS_PATH, body);
        assertEquals(before, body.toString());
    }

    /**
     * 다른 테스트에 종속되지 않는 유효 금융 W를 만든다.
     * @created 2026-10-29
     * @usedBy FinancialInputTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode context() {
        return mapper.createObjectNode()
            .put(FinanceFields.EXPECTED_DATA_VERSION, "1")
            .put(FinanceFields.RULE_VERSION, "test-rule")
            .put(FinanceFields.IDEMPOTENCY_KEY, UUID.randomUUID().toString());
    }

    /**
     * 급여 날짜만 바꾸는 최소 요청을 만든다.
     * @created 2026-10-29
     * @usedBy FinancialInputTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode salary() {
        ObjectNode body = context();
        body.putObject(FinanceFields.SALARY).put(FinanceFields.SALARY_DAY, 25);
        return body;
    }

    /**
     * 원천 DB와 무관한 단건 의무 형식 자료를 만든다.
     * @created 2026-10-29
     * @usedBy FinancialInputTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode obligation() {
        return context()
            .put(FinanceFields.LABEL, "월세")
            .put(FinanceFields.WITHDRAWAL_ACCOUNT_ID, UUID.randomUUID().toString())
            .put(FinanceFields.AMOUNT_KRW, 300000)
            .put(FinanceFields.DUE_DATE, "2026-10-29");
    }

    /**
     * 세 배정 배열이 명시된 최소 보호 요청을 만든다.
     * @created 2026-10-29
     * @usedBy FinancialInputTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode reserve() {
        ObjectNode body = context()
            .put(FinanceFields.ACCOUNT_ID, UUID.randomUUID().toString())
            .put(FinanceFields.LABEL, "비상금")
            .put(FinanceFields.AMOUNT_KRW, 100);
        ObjectNode changes = body.putObject(FinanceFields.ALLOCATION_CHANGES);
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
