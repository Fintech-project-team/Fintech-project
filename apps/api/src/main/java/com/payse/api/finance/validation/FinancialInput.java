package com.payse.api.finance.validation;

import com.payse.api.finance.error.FinancialException;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 금융 쓰기의 허용 키·타입을 검증하며 원본 요청의 null·배열 순서를 보존한다.
 * @created 2026-10-29
 * @usedBy FinancialService
 */
public final class FinancialInput {
    public static final long MAX_MONEY = 9_000_000_000_000L;
    private static final Set<String> WRITE = Set.of("expectedDataVersion", "ruleVersion", "idempotencyKey");
    private static final Pattern UUID_TEXT = Pattern.compile("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}");
    private static final Pattern GRAPHEME = Pattern.compile("\\X");
    private static final Pattern EDGE_SPACE = Pattern.compile("^[\\p{IsWhite_Space}\\uFEFF]+|[\\p{IsWhite_Space}\\uFEFF]+$");

    /**
     * 상태 없는 검증 유틸리티의 인스턴스 생성을 막는다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     */
    private FinancialInput() { }

    /**
     * W와 경로별 허용 입력을 검사한다. DELETE 호출자는 헤더 W만 가진 객체를 전달한다.
     * @created 2026-10-29
     * @usedBy FinancialService.write
     */
    public static ObjectNode validate(String method, String path, JsonNode body) {
        if (!(body instanceof ObjectNode object)) throw invalid();
        version(object.get("expectedDataVersion"));
        if (!string(object.get("ruleVersion")) || object.get("ruleVersion").asString().isEmpty()) throw invalid();
        if (!string(object.get("idempotencyKey"))
                || !object.get("idempotencyKey").asString().matches("[A-Za-z0-9._-]{1,128}")) throw invalid();
        if (method.equals("POST") && path.equals("/institution-links")) {
            fields(object, Set.of("institutionCodes"), Set.of("institutionCodes"));
            strings(object.get("institutionCodes"));
        } else if (method.equals("PATCH") && path.equals("/account-selection")) {
            fields(object, Set.of("accountIds"), Set.of("accountIds"));
            ids(object.get("accountIds"));
        } else if (method.equals("PATCH") && path.matches("/accounts/[^/]+")) {
            id(path.substring("/accounts/".length()));
            fields(object, Set.of("nickname"), Set.of("nickname"));
            if (!object.get("nickname").isNull()) label(object.get("nickname"), 12, true);
        } else if (method.equals("PATCH") && path.equals("/settings")) {
            settings(object);
        } else if (path.equals("/obligations") && method.equals("POST")) {
            obligation(object, true);
        } else if (path.equals("/reserves") && method.equals("POST")) {
            reserve(object, true);
        } else if (path.matches("/(obligations|reserves)/[^/]+(/cancel)?")) {
            String[] parts = path.split("/");
            id(parts[2]);
            if (parts.length == 4 && method.equals("POST")) detach(object);
            else if (parts.length == 3 && method.equals("DELETE")) fields(object, Set.of(), Set.of());
            else if (parts.length == 3 && method.equals("PATCH")) {
                if (parts[1].equals("obligations")) obligation(object, false);
                else reserve(object, false);
            } else throw invalid();
        } else throw invalid();
        return object;
    }

    /**
     * 급여는 명시한 필드만, 카드 계획은 명시한 카드만 변경하도록 입력을 확인한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     */
    private static void settings(ObjectNode body) {
        fields(body, Set.of("salary", "cardPlans"), Set.of());
        if (!body.has("salary") && !body.has("cardPlans")) throw invalid();
        if (body.has("salary")) {
            JsonNode salary = body.get("salary");
            nested(salary, Set.of("salaryDay", "salaryAmountKRW", "salaryAccountId"), Set.of());
            if (salary.isEmpty()) throw invalid();
            if (salary.has("salaryDay") && !salary.get("salaryDay").isNull()) day(salary.get("salaryDay"));
            if (salary.has("salaryAmountKRW") && !salary.get("salaryAmountKRW").isNull()) money(salary.get("salaryAmountKRW"), false);
            if (salary.has("salaryAccountId") && !salary.get("salaryAccountId").isNull()) id(salary.get("salaryAccountId"));
        }
        if (body.has("cardPlans")) {
            JsonNode plans = body.get("cardPlans");
            if (!plans.isArray()) throw invalid();
            Set<UUID> seen = new HashSet<>();
            for (JsonNode plan : plans) {
                nested(plan, Set.of("cardId", "plannedPaymentDay"), Set.of("cardId", "plannedPaymentDay"));
                if (!seen.add(id(plan.get("cardId")))) throw invalid();
                if (!plan.get("plannedPaymentDay").isNull()) day(plan.get("plannedPaymentDay"));
            }
        }
    }

    /**
     * 원천·정산 키를 받지 않고 단건 의무의 허용 수정값만 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     */
    private static void obligation(ObjectNode body, boolean create) {
        Set<String> keys = Set.of("label", "withdrawalAccountId", "amountKRW", "dueDate");
        fields(body, keys, create ? keys : Set.of());
        requireChange(body);
        if (body.has("label")) label(body.get("label"), 80, false);
        if (body.has("withdrawalAccountId")) id(body.get("withdrawalAccountId"));
        if (body.has("amountKRW")) money(body.get("amountKRW"), false);
        if (body.has("dueDate")) date(body.get("dueDate"));
    }

    /**
     * 보호 설정과 명시 배정 변경을 한 요청으로 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     */
    private static void reserve(ObjectNode body, boolean create) {
        Set<String> keys = Set.of("accountId", "label", "amountKRW", "allocationChanges");
        fields(body, keys, create ? keys : Set.of());
        requireChange(body);
        if (body.has("label")) label(body.get("label"), 80, false);
        if (body.has("accountId")) id(body.get("accountId"));
        if (body.has("amountKRW")) money(body.get("amountKRW"), false);
        if (body.has("allocationChanges")) allocations(body.get("allocationChanges"));
    }

    /**
     * 배정 생성·변경·제거 목록의 타입과 중복 식별자를 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.reserve
     */
    private static void allocations(JsonNode changes) {
        nested(changes, Set.of("create", "update", "remove"), Set.of("create", "update", "remove"));
        Set<UUID> obligations = new HashSet<>();
        Set<UUID> allocations = new HashSet<>();
        for (String operation : Set.of("create", "update")) {
            JsonNode entries = changes.get(operation);
            if (!entries.isArray()) throw invalid();
            String idKey = operation.equals("create") ? "obligationId" : "allocationId";
            Set<UUID> seen = operation.equals("create") ? obligations : allocations;
            for (JsonNode entry : entries) {
                nested(entry, Set.of(idKey, "amountKRW"), Set.of(idKey, "amountKRW"));
                if (!seen.add(id(entry.get(idKey)))) throw invalid();
                money(entry.get("amountKRW"), true);
            }
        }
        JsonNode removed = changes.get("remove");
        if (!removed.isArray()) throw invalid();
        for (JsonNode entry : removed) if (!allocations.add(id(entry))) throw invalid();
    }

    /**
     * 사용자 확인한 미해제 배정 ID·금액 목록의 형식을 확인한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     */
    private static void detach(ObjectNode body) {
        fields(body, Set.of("detachAllocations"), Set.of("detachAllocations"));
        JsonNode entries = body.get("detachAllocations");
        if (!entries.isArray()) throw invalid();
        Set<UUID> seen = new HashSet<>();
        for (JsonNode entry : entries) {
            nested(entry, Set.of("allocationId", "unreleasedKRW"), Set.of("allocationId", "unreleasedKRW"));
            if (!seen.add(id(entry.get("allocationId")))) throw invalid();
            money(entry.get("unreleasedKRW"), true);
        }
    }

    /**
     * W를 포함한 최상위 필드의 허용·필수 집합을 확인한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate, settings, obligation, reserve, detach
     */
    private static void fields(JsonNode node, Set<String> allowed, Set<String> required) {
        Set<String> all = new HashSet<>(allowed);
        all.addAll(WRITE);
        Set<String> needed = new HashSet<>(required);
        needed.addAll(WRITE);
        nested(node, all, needed);
    }

    /**
     * 누락·알 수 없는 중첩 키를 자동 보정하지 않고 거절한다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     */
    private static void nested(JsonNode node, Set<String> allowed, Set<String> required) {
        if (node == null || !node.isObject()) throw invalid();
        Set<String> present = Set.copyOf(node.propertyNames());
        if (!allowed.containsAll(present) || !present.containsAll(required)) throw invalid();
    }

    /**
     * PATCH가 W 외 수정 필드를 포함하는지 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.obligation, reserve
     */
    private static void requireChange(JsonNode body) {
        if (body.size() == WRITE.size()) throw invalid();
    }

    /**
     * 기관 코드를 공백 없는 비어 있지 않은 문자열 배열로 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     */
    private static void strings(JsonNode values) {
        if (values == null || !values.isArray() || values.isEmpty()) throw invalid();
        Set<String> seen = new HashSet<>();
        for (JsonNode value : values) {
            if (!string(value) || value.asString().isBlank() || !seen.add(value.asString())) throw invalid();
        }
    }

    /**
     * UUID 배열을 대소문자와 관계없이 중복 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     */
    private static void ids(JsonNode values) {
        if (values == null || !values.isArray() || values.isEmpty()) throw invalid();
        Set<UUID> seen = new HashSet<>();
        for (JsonNode value : values) if (!seen.add(id(value))) throw invalid();
    }

    /**
     * JSON 문자열 UUID를 변환하며 숫자나 축약 UUID를 받지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialInput, FinancialWrites
     */
    public static UUID id(JsonNode value) {
        if (!string(value)) throw invalid();
        return id(value.asString());
    }

    /**
     * URL·본문의 정규 UUID 표기를 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialInput, FinancialWrites
     */
    public static UUID id(String value) {
        if (value == null || !UUID_TEXT.matcher(value).matches()) throw invalid();
        return UUID.fromString(value);
    }

    /**
     * 비음수/양수 금액을 변환 없이 정수 범위로 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     */
    private static void money(JsonNode value, boolean positive) {
        if (value == null || !value.isIntegralNumber() || !value.canConvertToLong()
                || value.asLong() < (positive ? 1 : 0) || value.asLong() > MAX_MONEY) throw invalid();
    }

    /**
     * 월별 계획 일자 입력을 검사하며 실제 날짜를 계산하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialInput.settings
     */
    private static void day(JsonNode value) {
        if (!value.isIntegralNumber() || !value.canConvertToInt() || value.asInt() < 1 || value.asInt() > 31) throw invalid();
    }

    /**
     * 업무 날짜의 형식과 달력상 존재 여부만 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.obligation
     */
    private static void date(JsonNode value) {
        if (!string(value) || !value.asString().matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")
                || value.asString().startsWith("0000")) throw invalid();
        try { LocalDate.parse(value.asString()); }
        catch (DateTimeParseException failure) { throw invalid(); }
    }

    /**
     * 문자열 버전의 bigint 범위와 선행 0 금지를 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     */
    private static void version(JsonNode value) {
        if (!string(value) || !value.asString().matches("[1-9][0-9]{0,18}")) throw invalid();
        try { Long.parseLong(value.asString()); }
        catch (NumberFormatException failure) { throw invalid(); }
    }

    /**
     * 저장 전 trim 결과의 grapheme 길이와 별칭의 특수문자 전용 값 금지를 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     */
    private static void label(JsonNode value, int maximum, boolean nickname) {
        if (!string(value)) throw invalid();
        String trimmed = trimLabel(value.asString());
        long count = GRAPHEME.matcher(trimmed).results().count();
        if (count < 1 || count > maximum) throw invalid();
        if (nickname && trimmed.codePoints().noneMatch(point -> Character.isLetterOrDigit(point)
                || Character.getType(point) == Character.OTHER_SYMBOL)) throw invalid();
    }

    /**
     * null과 문자열 타입을 구별한다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     */
    private static boolean string(JsonNode value) { return value != null && value.isString(); }

    /**
     * Flutter String.trim과 같은 Unicode White_Space·BOM 경계 공백을 제거한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.label, SettingsWrites, PlanWrites
     */
    public static String trimLabel(String value) { return EDGE_SPACE.matcher(value).replaceAll(""); }

    /**
     * 원문을 포함하지 않는 입력 오류를 만든다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     */
    private static FinancialException invalid() { return new FinancialException(422, "VALIDATION_FAILED"); }
}
