package com.payse.api.finance.validation;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants;
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
    private static final Set<String> WRITE = Set.of(
        "expectedDataVersion",
        "ruleVersion",
        "idempotencyKey"
    );
    private static final Pattern UUID_TEXT = Pattern
        .compile("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}");
    private static final Pattern GRAPHEME = Pattern.compile("\\X");
    private static final Pattern EDGE_SPACE = Pattern
        .compile("^[\\p{IsWhite_Space}\\uFEFF]+|[\\p{IsWhite_Space}\\uFEFF]+$");

    /**
     * 상태 없는 검증 유틸리티의 인스턴스 생성을 막는다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     */
    private FinancialInput() {
    }

    /**
     * W와 경로별 허용 입력을 검사한다. DELETE 호출자는 헤더 W만 가진 객체를 전달한다.
     * @created 2026-10-29
     * @usedBy FinancialService.write
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    public static ObjectNode validate(String method, String path, JsonNode body) {
        if (!(body instanceof ObjectNode object)) {
            throw invalid();
        }

        version(object.get(ApiFieldConstants.Finance.EXPECTED_DATA_VERSION));
        if (!string(object.get(ApiFieldConstants.Finance.RULE_VERSION))
            || object.get(ApiFieldConstants.Finance.RULE_VERSION)
                .asString()
                .isEmpty()) {
            throw invalid();
        }
        if (!string(object.get(ApiFieldConstants.Finance.IDEMPOTENCY_KEY))
            || !object.get(ApiFieldConstants.Finance.IDEMPOTENCY_KEY)
                .asString()
                .matches("[A-Za-z0-9._-]{1,128}")) {
            throw invalid();
        }

        if (method.equals(ApiCodeConstants.Finance.POST)
            && path.equals(ApiConfigConstants.Finance.LINKS_PATH)) {
            fields(
                object,
                Set.of(ApiFieldConstants.Finance.INSTITUTION_CODES),
                Set.of(ApiFieldConstants.Finance.INSTITUTION_CODES)
            );
            strings(object.get(ApiFieldConstants.Finance.INSTITUTION_CODES));
        } else if (method.equals(ApiCodeConstants.Finance.PATCH)
            && path.equals(ApiConfigConstants.Finance.SELECTION_PATH)) {
            fields(
                object,
                Set.of(ApiFieldConstants.Finance.ACCOUNT_IDS),
                Set.of(ApiFieldConstants.Finance.ACCOUNT_IDS)
            );
            ids(object.get(ApiFieldConstants.Finance.ACCOUNT_IDS));
        } else if (method.equals(ApiCodeConstants.Finance.PATCH)
            && path.matches("/accounts/[^/]+")) {
            id(path.substring(ApiConfigConstants.Finance.ACCOUNT_PATH_PREFIX.length()));
            fields(
                object,
                Set.of(ApiFieldConstants.Finance.NICKNAME),
                Set.of(ApiFieldConstants.Finance.NICKNAME)
            );
            if (!object.get(ApiFieldConstants.Finance.NICKNAME).isNull()) {
                label(object.get(ApiFieldConstants.Finance.NICKNAME), 12, true);
            }
        } else if (method.equals(ApiCodeConstants.Finance.PATCH)
            && path.equals(ApiConfigConstants.Finance.SETTINGS_PATH)) {
            settings(object);
        } else if (path.equals(ApiConfigConstants.Finance.OBLIGATIONS_PATH)
            && method.equals(ApiCodeConstants.Finance.POST)) {
            obligation(object, true);
        } else if (path.equals(ApiConfigConstants.Finance.RESERVES_PATH)
            && method.equals(ApiCodeConstants.Finance.POST)) {
            reserve(object, true);
        } else if (path.matches("/(obligations|reserves)/[^/]+(/cancel)?")) {
            String[] parts = path.split("/");
            id(parts[2]);
            if (parts.length == 4 && method.equals(ApiCodeConstants.Finance.POST)) {
                detach(object);
            } else if (parts.length == 3 && method.equals("DELETE")) {
                fields(object, Set.of(), Set.of());
            } else if (parts.length == 3 && method.equals(ApiCodeConstants.Finance.PATCH)) {
                if (parts[1].equals(ApiFieldConstants.Finance.OBLIGATIONS)) {
                    obligation(object, false);
                } else {
                    reserve(object, false);
                }
            } else {
                throw invalid();
            }
        } else {
            throw invalid();
        }
        return object;
    }

    /**
     * 급여는 명시한 필드만, 카드 계획은 명시한 카드만 변경하도록 입력을 확인한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private static void settings(ObjectNode body) {
        fields(
            body,
            Set.of(ApiFieldConstants.Finance.SALARY, ApiFieldConstants.Finance.CARD_PLANS),
            Set.of()
        );
        if (!body.has(ApiFieldConstants.Finance.SALARY)
            && !body.has(ApiFieldConstants.Finance.CARD_PLANS)) {
            throw invalid();
        }

        if (body.has(ApiFieldConstants.Finance.SALARY)) {
            JsonNode salary = body.get(ApiFieldConstants.Finance.SALARY);
            nested(
                salary,
                Set.of(
                    ApiFieldConstants.Finance.SALARY_DAY,
                    ApiFieldConstants.Finance.SALARY_AMOUNT_KRW,
                    ApiFieldConstants.Finance.SALARY_ACCOUNT_ID
                ),
                Set.of()
            );
            if (salary.isEmpty()) {
                throw invalid();
            }

            if (salary.has(ApiFieldConstants.Finance.SALARY_DAY)
                && !salary.get(ApiFieldConstants.Finance.SALARY_DAY).isNull()) {
                day(salary.get(ApiFieldConstants.Finance.SALARY_DAY));
            }
            if (salary.has(ApiFieldConstants.Finance.SALARY_AMOUNT_KRW)
                && !salary.get(ApiFieldConstants.Finance.SALARY_AMOUNT_KRW).isNull()) {
                money(salary.get(ApiFieldConstants.Finance.SALARY_AMOUNT_KRW), false);
            }
            if (salary.has(ApiFieldConstants.Finance.SALARY_ACCOUNT_ID)
                && !salary.get(ApiFieldConstants.Finance.SALARY_ACCOUNT_ID).isNull()) {
                id(salary.get(ApiFieldConstants.Finance.SALARY_ACCOUNT_ID));
            }
        }
        if (body.has(ApiFieldConstants.Finance.CARD_PLANS)) {
            JsonNode plans = body.get(ApiFieldConstants.Finance.CARD_PLANS);
            if (!plans.isArray()) {
                throw invalid();
            }

            Set<UUID> seen = new HashSet<>();
            for (JsonNode plan : plans) {
                nested(
                    plan,
                    Set.of(
                        ApiFieldConstants.Finance.CARD_ID,
                        ApiFieldConstants.Finance.PLANNED_PAYMENT_DAY
                    ),
                    Set.of(
                        ApiFieldConstants.Finance.CARD_ID,
                        ApiFieldConstants.Finance.PLANNED_PAYMENT_DAY
                    )
                );
                if (!seen.add(id(plan.get(ApiFieldConstants.Finance.CARD_ID)))) {
                    throw invalid();
                }

                if (!plan.get(ApiFieldConstants.Finance.PLANNED_PAYMENT_DAY).isNull()) {
                    day(plan.get(ApiFieldConstants.Finance.PLANNED_PAYMENT_DAY));
                }
            }
        }
    }

    /**
     * 원천·정산 키를 받지 않고 단건 의무의 허용 수정값만 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private static void obligation(ObjectNode body, boolean create) {
        Set<String> keys = Set.of(
            ApiFieldConstants.Finance.LABEL,
            ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID,
            ApiFieldConstants.Finance.AMOUNT_KRW,
            ApiFieldConstants.Finance.DUE_DATE
        );
        fields(body, keys, create ? keys : Set.of());
        requireChange(body);
        if (body.has(ApiFieldConstants.Finance.LABEL)) {
            label(body.get(ApiFieldConstants.Finance.LABEL), 80, false);
        }
        if (body.has(ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID)) {
            id(body.get(ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID));
        }
        if (body.has(ApiFieldConstants.Finance.AMOUNT_KRW)) {
            money(body.get(ApiFieldConstants.Finance.AMOUNT_KRW), false);
        }
        if (body.has(ApiFieldConstants.Finance.DUE_DATE)) {
            date(body.get(ApiFieldConstants.Finance.DUE_DATE));
        }
    }

    /**
     * 보호 설정과 명시 배정 변경을 한 요청으로 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private static void reserve(ObjectNode body, boolean create) {
        Set<String> keys = Set.of(
            ApiFieldConstants.Finance.ACCOUNT_ID,
            ApiFieldConstants.Finance.LABEL,
            ApiFieldConstants.Finance.AMOUNT_KRW,
            ApiFieldConstants.Finance.ALLOCATION_CHANGES
        );
        fields(body, keys, create ? keys : Set.of());
        requireChange(body);
        if (body.has(ApiFieldConstants.Finance.LABEL)) {
            label(body.get(ApiFieldConstants.Finance.LABEL), 80, false);
        }
        if (body.has(ApiFieldConstants.Finance.ACCOUNT_ID)) {
            id(body.get(ApiFieldConstants.Finance.ACCOUNT_ID));
        }
        if (body.has(ApiFieldConstants.Finance.AMOUNT_KRW)) {
            money(body.get(ApiFieldConstants.Finance.AMOUNT_KRW), false);
        }
        if (body.has(ApiFieldConstants.Finance.ALLOCATION_CHANGES)) {
            allocations(body.get(ApiFieldConstants.Finance.ALLOCATION_CHANGES));
        }
    }

    /**
     * 배정 생성·변경·제거 목록의 타입과 중복 식별자를 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.reserve
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private static void allocations(JsonNode changes) {
        nested(
            changes,
            Set.of(
                ApiFieldConstants.Finance.CREATE,
                ApiFieldConstants.Finance.UPDATE,
                ApiFieldConstants.Finance.REMOVE
            ),
            Set.of(
                ApiFieldConstants.Finance.CREATE,
                ApiFieldConstants.Finance.UPDATE,
                ApiFieldConstants.Finance.REMOVE
            )
        );
        Set<UUID> obligations = new HashSet<>();
        Set<UUID> allocations = new HashSet<>();
        for (String operation : Set
            .of(ApiFieldConstants.Finance.CREATE, ApiFieldConstants.Finance.UPDATE)) {
            JsonNode entries = changes.get(operation);
            if (!entries.isArray()) {
                throw invalid();
            }

            String idKey = operation.equals(ApiFieldConstants.Finance.CREATE)
                ? ApiFieldConstants.Finance.OBLIGATION_ID
                : ApiFieldConstants.Finance.ALLOCATION_ID;
            Set<UUID> seen = operation.equals(ApiFieldConstants.Finance.CREATE) ? obligations
                : allocations;
            for (JsonNode entry : entries) {
                nested(
                    entry,
                    Set.of(idKey, ApiFieldConstants.Finance.AMOUNT_KRW),
                    Set.of(idKey, ApiFieldConstants.Finance.AMOUNT_KRW)
                );
                if (!seen.add(id(entry.get(idKey)))) {
                    throw invalid();
                }

                money(entry.get(ApiFieldConstants.Finance.AMOUNT_KRW), true);
            }
        }

        JsonNode removed = changes.get(ApiFieldConstants.Finance.REMOVE);
        if (!removed.isArray()) {
            throw invalid();
        }

        for (JsonNode entry : removed) {
            if (!allocations.add(id(entry))) {
                throw invalid();
            }
        }
    }

    /**
     * 사용자 확인한 미해제 배정 ID·금액 목록의 형식을 확인한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private static void detach(ObjectNode body) {
        fields(
            body,
            Set.of(ApiFieldConstants.Finance.DETACH_ALLOCATIONS),
            Set.of(ApiFieldConstants.Finance.DETACH_ALLOCATIONS)
        );
        JsonNode entries = body.get(ApiFieldConstants.Finance.DETACH_ALLOCATIONS);
        if (!entries.isArray()) {
            throw invalid();
        }

        Set<UUID> seen = new HashSet<>();
        for (JsonNode entry : entries) {
            nested(
                entry,
                Set.of(
                    ApiFieldConstants.Finance.ALLOCATION_ID,
                    ApiFieldConstants.Finance.UNRELEASED_KRW
                ),
                Set.of(
                    ApiFieldConstants.Finance.ALLOCATION_ID,
                    ApiFieldConstants.Finance.UNRELEASED_KRW
                )
            );
            if (!seen.add(id(entry.get(ApiFieldConstants.Finance.ALLOCATION_ID)))) {
                throw invalid();
            }

            money(entry.get(ApiFieldConstants.Finance.UNRELEASED_KRW), true);
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
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void nested(JsonNode node, Set<String> allowed, Set<String> required) {
        if (node == null || !node.isObject()) {
            throw invalid();
        }

        Set<String> present = Set.copyOf(node.propertyNames());
        if (!allowed.containsAll(present) || !present.containsAll(required)) {
            throw invalid();
        }
    }

    /**
     * PATCH가 W 외 수정 필드를 포함하는지 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.obligation, reserve
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void requireChange(JsonNode body) {
        if (body.size() == WRITE.size()) {
            throw invalid();
        }
    }

    /**
     * 기관 코드를 공백 없는 비어 있지 않은 문자열 배열로 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void strings(JsonNode values) {
        if (values == null || !values.isArray() || values.isEmpty()) {
            throw invalid();
        }

        Set<String> seen = new HashSet<>();
        for (JsonNode value : values) {
            if (!string(value) || value.asString().isBlank() || !seen.add(value.asString())) {
                throw invalid();
            }
        }
    }

    /**
     * UUID 배열을 대소문자와 관계없이 중복 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void ids(JsonNode values) {
        if (values == null || !values.isArray() || values.isEmpty()) {
            throw invalid();
        }

        Set<UUID> seen = new HashSet<>();
        for (JsonNode value : values) {
            if (!seen.add(id(value))) {
                throw invalid();
            }
        }
    }

    /**
     * JSON 문자열 UUID를 변환하며 숫자나 축약 UUID를 받지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialInput, FinancialWrites
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    public static UUID id(JsonNode value) {
        if (!string(value)) {
            throw invalid();
        }

        return id(value.asString());
    }

    /**
     * URL·본문의 정규 UUID 표기를 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialInput, FinancialWrites
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    public static UUID id(String value) {
        if (value == null || !UUID_TEXT.matcher(value).matches()) {
            throw invalid();
        }

        return UUID.fromString(value);
    }

    /**
     * 비음수/양수 금액을 변환 없이 정수 범위로 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void money(JsonNode value, boolean positive) {
        if (value == null || !value.isIntegralNumber() || !value.canConvertToLong()
            || value.asLong() < (positive ? 1 : 0) || value.asLong() > MAX_MONEY) {
            throw invalid();
        }
    }

    /**
     * 월별 계획 일자 입력을 검사하며 실제 날짜를 계산하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialInput.settings
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void day(JsonNode value) {
        if (!value.isIntegralNumber() || !value.canConvertToInt() || value.asInt() < 1
            || value.asInt() > 31) {
            throw invalid();
        }
    }

    /**
     * 업무 날짜의 형식과 달력상 존재 여부만 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.obligation
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private static void date(JsonNode value) {
        if (!string(value) || !value.asString().matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")
            || value.asString().startsWith(ApiConfigConstants.Finance.INVALID_YEAR)) {
            throw invalid();
        }

        try {
            LocalDate.parse(value.asString());
        } catch (DateTimeParseException failure) {
            throw invalid();
        }
    }

    /**
     * 문자열 버전의 bigint 범위와 선행 0 금지를 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.validate
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void version(JsonNode value) {
        if (!string(value) || !value.asString().matches("[1-9][0-9]{0,18}")) {
            throw invalid();
        }

        try {
            Long.parseLong(value.asString());
        } catch (NumberFormatException failure) {
            throw invalid();
        }
    }

    /**
     * 저장 전 trim 결과의 grapheme 길이와 별칭의 특수문자 전용 값 금지를 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void label(JsonNode value, int maximum, boolean nickname) {
        if (!string(value)) {
            throw invalid();
        }

        String trimmed = trimLabel(value.asString());
        long count = GRAPHEME.matcher(trimmed)
            .results()
            .count();
        if (count < 1 || count > maximum) {
            throw invalid();
        }
        if (nickname && trimmed.codePoints()
            .noneMatch(
                point -> Character.isLetterOrDigit(point)
                    || Character.getType(point) == Character.OTHER_SYMBOL
            )) {
            throw invalid();
        }
    }

    /**
     * null과 문자열 타입을 구별한다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     */
    private static boolean string(JsonNode value) {
        return value != null && value.isString();
    }

    /**
     * Flutter String.trim과 같은 Unicode White_Space·BOM 경계 공백을 제거한다.
     * @created 2026-10-29
     * @usedBy FinancialInput.label, SettingsWrites, PlanWrites
     */
    public static String trimLabel(String value) {
        return EDGE_SPACE.matcher(value).replaceAll("");
    }

    /**
     * 원문을 포함하지 않는 입력 오류를 만든다.
     * @created 2026-10-29
     * @usedBy FinancialInput
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private static FinancialException invalid() {
        return new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
    }
}
