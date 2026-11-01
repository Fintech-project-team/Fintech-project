package com.payse.ai.analysis.validation;

import java.util.HashSet;
import java.util.Set;
import java.util.regex.Pattern;
import tools.jackson.databind.JsonNode;

/**
 * PAYSE가 사용하는 제한된 JSON Schema 키워드를 검사한다. 범용 스키마 엔진이 아니다.
 * @created 2026-11-01
 * @usedBy AnalysisContract, InputMapper
 */
public final class SchemaRules {
    private static final Set<String> KEYWORDS = Set.of("$schema", "title", "description", "type",
        "properties", "required", "additionalProperties", "items", "minItems", "maxItems",
        "uniqueItems", "enum", "minimum", "maximum", "minLength", "maxLength", "pattern");
    private static final Set<String> TYPES = Set.of("object", "array", "string", "integer", "boolean", "null");

    /**
     * 스키마의 모든 분기를 미리 검사하여 빈 배열·누락값 뒤의 미지원 규칙도 거절한다.
     * @created 2026-11-01
     * @usedBy AnalysisContract 생성자
     */
    public static void supported(JsonNode schema) {
        require(schema.isObject() && KEYWORDS.containsAll(schema.propertyNames()), "UNSUPPORTED_SCHEMA");
        JsonNode type = schema.path("type");
        if (type.isString()) require(TYPES.contains(type.asString()), "UNSUPPORTED_TYPE");
        else if (type.isArray()) {
            for (JsonNode kind : type) require(kind.isString() && TYPES.contains(kind.asString()), "UNSUPPORTED_TYPE");
        } else require(type.isMissingNode(), "UNSUPPORTED_TYPE");
        if (schema.has("pattern")) Pattern.compile(schema.get("pattern").asString());
        for (JsonNode child : schema.path("properties")) supported(child);
        if (schema.has("items")) supported(schema.get("items"));
    }

    /**
     * 구조·범위·유니코드 문자 수를 검사하며 원문을 오류에 넣지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisContract.input, AnalysisContract.output, InputMapper.restore
     */
    public static void check(JsonNode schema, JsonNode value) {
        require(value != null, "MISSING_VALUE");
        JsonNode type = schema.path("type");
        if (type.isString()) require(matches(type.asString(), value), "INVALID_TYPE");
        if (type.isArray()) {
            boolean matched = false;
            for (JsonNode kind : type) matched |= matches(kind.asString(), value);
            require(matched, "INVALID_TYPE");
        }
        if (schema.has("enum")) {
            boolean allowed = false;
            for (JsonNode option : schema.get("enum")) allowed |= option.equals(value);
            require(allowed, "INVALID_ENUM");
        }
        if (value.isObject()) {
            JsonNode properties = schema.path("properties");
            for (JsonNode name : schema.path("required")) require(value.has(name.asString()), "MISSING_FIELD");
            if (schema.has("additionalProperties") && !schema.get("additionalProperties").asBoolean()) {
                require(properties.propertyNames().containsAll(value.propertyNames()), "UNEXPECTED_FIELD");
            }
            for (String name : value.propertyNames()) {
                if (properties.has(name)) check(properties.get(name), value.get(name));
            }
        }
        if (value.isArray()) {
            range(value.size(), schema, "minItems", "maxItems");
            Set<JsonNode> seen = new HashSet<>();
            for (JsonNode item : value) {
                if (schema.path("uniqueItems").asBoolean()) require(seen.add(item), "DUPLICATE_VALUE");
                if (schema.has("items")) check(schema.get("items"), item);
            }
        }
        if (value.isString()) {
            String text = value.asString();
            range(text.codePointCount(0, text.length()), schema, "minLength", "maxLength");
            if (schema.has("pattern")) {
                require(Pattern.compile(schema.get("pattern").asString()).matcher(text).find(), "INVALID_PATTERN");
            }
        }
        if (value.isIntegralNumber()) {
            if (schema.has("minimum")) require(value.bigIntegerValue().compareTo(schema.get("minimum").bigIntegerValue()) >= 0, "BELOW_MINIMUM");
            if (schema.has("maximum")) require(value.bigIntegerValue().compareTo(schema.get("maximum").bigIntegerValue()) <= 0, "ABOVE_MAXIMUM");
        }
    }

    /**
     * 정수와 실수·불리언을 혼동하지 않는 JSON 타입 판정이다.
     * @created 2026-11-01
     * @usedBy check
     */
    private static boolean matches(String kind, JsonNode value) {
        return switch (kind) {
            case "object" -> value.isObject();
            case "array" -> value.isArray();
            case "string" -> value.isString();
            case "integer" -> value.isIntegralNumber();
            case "boolean" -> value.isBoolean();
            case "null" -> value.isNull();
            default -> false;
        };
    }

    /**
     * 스키마에 명시한 길이만 제한하며 임의 기본 상한을 넣지 않는다.
     * @created 2026-11-01
     * @usedBy check
     */
    private static void range(int size, JsonNode schema, String min, String max) {
        if (schema.has(min)) require(size >= schema.get(min).asInt(), "BELOW_MINIMUM");
        if (schema.has(max)) require(size <= schema.get(max).asInt(), "ABOVE_MAXIMUM");
    }

    /**
     * 검증 실패를 상수 사유로 전달한다.
     * @created 2026-11-01
     * @usedBy SchemaRules, AnalysisContract, InputMapper
     */
    public static void require(boolean condition, String reason) {
        if (!condition) throw new ContractFailure(reason);
    }
}
