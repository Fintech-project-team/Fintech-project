package com.payse.ai.analysis.validation;

import com.payse.ai.constants.AiCodeConstants.Analysis;
import com.payse.ai.constants.AiFieldConstants.Schema;
import java.util.HashSet;
import java.util.Set;
import java.util.regex.Pattern;
import tools.jackson.databind.JsonNode;

/**
 * PAYSE가 사용하는 제한된 JSON Schema 키워드를 검사한다. 범용 스키마 엔진이 아니다.
 * @created 2026-11-01
 * @usedBy AnalysisContract, InputMapper
 * @modified 2026-11-02 - 상수 타입 명시 참조
 */
public final class SchemaRules {
    private static final Set<String> KEYWORDS = Set.of(
        Schema.SCHEMA_URI,
        Schema.TITLE,
        Schema.DESCRIPTION,
        Schema.TYPE_KEY,
        Schema.PROPERTIES,
        Schema.REQUIRED_FIELDS,
        Schema.ADDITIONAL_PROPERTIES,
        Schema.ITEMS,
        Schema.MIN_ITEMS,
        Schema.MAX_ITEMS,
        Schema.UNIQUE_ITEMS,
        Schema.ENUM,
        Schema.MINIMUM,
        Schema.MAXIMUM,
        Schema.MIN_LENGTH,
        Schema.MAX_LENGTH,
        Schema.PATTERN
    );
    private static final Set<String> TYPES = Set.of(
        Schema.OBJECT_TYPE,
        Schema.ARRAY_TYPE,
        Schema.STRING_TYPE,
        Schema.INTEGER_TYPE,
        Schema.BOOLEAN_TYPE,
        Schema.NULL_TYPE
    );

    /**
     * 스키마의 모든 분기를 미리 검사하여 빈 배열·누락값 뒤의 미지원 규칙도 거절한다.
     * @created 2026-11-01
     * @usedBy AnalysisContract 생성자
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     */
    public static void supported(JsonNode schema) {
        require(
            schema.isObject() && KEYWORDS.containsAll(schema.propertyNames()),
            Analysis.UNSUPPORTED_SCHEMA
        );
        JsonNode type = schema.path(Schema.TYPE_KEY);
        if (type.isString()) {
            require(TYPES.contains(type.asString()), Analysis.UNSUPPORTED_TYPE);
        } else if (type.isArray()) {
            for (JsonNode kind : type) {
                require(
                    kind.isString() && TYPES.contains(kind.asString()),
                    Analysis.UNSUPPORTED_TYPE
                );
            }
        } else {
            require(type.isMissingNode(), Analysis.UNSUPPORTED_TYPE);
        }
        if (schema.has(Schema.PATTERN)) {
            Pattern.compile(schema.get(Schema.PATTERN).asString());
        }
        for (JsonNode child : schema.path(Schema.PROPERTIES)) {
            supported(child);
        }
        if (schema.has(Schema.ITEMS)) {
            supported(schema.get(Schema.ITEMS));
        }
    }

    /**
     * 구조·범위·유니코드 문자 수를 검사하며 원문을 오류에 넣지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisContract.input, AnalysisContract.output, InputMapper.restore
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조; 제어문 본문 구분
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    public static void check(JsonNode schema, JsonNode value) {
        require(value != null, Analysis.MISSING_VALUE);
        JsonNode type = schema.path(Schema.TYPE_KEY);
        if (type.isString()) {
            require(matches(type.asString(), value), Analysis.INVALID_TYPE);
        }
        if (type.isArray()) {
            boolean matched = false;
            for (JsonNode kind : type) {
                matched |= matches(kind.asString(), value);
            }
            require(matched, Analysis.INVALID_TYPE);
        }

        if (schema.has(Schema.ENUM)) {
            boolean allowed = false;
            for (JsonNode option : schema.get(Schema.ENUM)) {
                allowed |= option.equals(value);
            }
            require(allowed, Analysis.INVALID_ENUM);
        }

        if (value.isObject()) {
            JsonNode properties = schema.path(Schema.PROPERTIES);
            for (JsonNode name : schema.path(Schema.REQUIRED_FIELDS)) {
                require(value.has(name.asString()), Analysis.MISSING_FIELD);
            }
            if (schema.has(Schema.ADDITIONAL_PROPERTIES)
                && !schema.get(Schema.ADDITIONAL_PROPERTIES)
                    .asBoolean()) {
                require(
                    properties.propertyNames().containsAll(value.propertyNames()),
                    Analysis.UNEXPECTED_FIELD
                );
            }
            for (String name : value.propertyNames()) {
                if (properties.has(name)) {
                    check(properties.get(name), value.get(name));
                }
            }
        }

        if (value.isArray()) {
            range(value.size(), schema, Schema.MIN_ITEMS, Schema.MAX_ITEMS);
            Set<JsonNode> seen = new HashSet<>();
            for (JsonNode item : value) {
                if (schema.path(Schema.UNIQUE_ITEMS).asBoolean()) {
                    require(seen.add(item), Analysis.DUPLICATE_VALUE);
                }
                if (schema.has(Schema.ITEMS)) {
                    check(schema.get(Schema.ITEMS), item);
                }
            }
        }

        if (value.isString()) {
            String text = value.asString();
            range(
                text.codePointCount(0, text.length()),
                schema,
                Schema.MIN_LENGTH,
                Schema.MAX_LENGTH
            );
            if (schema.has(Schema.PATTERN)) {
                Pattern pattern = Pattern.compile(schema.get(Schema.PATTERN).asString());
                boolean matched = pattern.matcher(text).find();
                require(matched, Analysis.INVALID_PATTERN);
            }
        }
        if (value.isIntegralNumber()) {
            if (schema.has(Schema.MINIMUM)) {
                var actual = value.bigIntegerValue();
                var minimum = schema.get(Schema.MINIMUM).bigIntegerValue();
                require(actual.compareTo(minimum) >= 0, Analysis.BELOW_MINIMUM);
            }
            if (schema.has(Schema.MAXIMUM)) {
                var actual = value.bigIntegerValue();
                var maximum = schema.get(Schema.MAXIMUM).bigIntegerValue();
                require(actual.compareTo(maximum) <= 0, Analysis.ABOVE_MAXIMUM);
            }
        }
    }

    /**
     * 정수와 실수·불리언을 혼동하지 않는 JSON 타입 판정이다.
     * @created 2026-11-01
     * @usedBy check
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조
     */
    private static boolean matches(String kind, JsonNode value) {
        return switch (kind) {
        case Schema.OBJECT_TYPE -> value.isObject();
        case Schema.ARRAY_TYPE -> value.isArray();
        case Schema.STRING_TYPE -> value.isString();
        case Schema.INTEGER_TYPE -> value.isIntegralNumber();
        case Schema.BOOLEAN_TYPE -> value.isBoolean();
        case Schema.NULL_TYPE -> value.isNull();
        default -> false;
        };
    }

    /**
     * 스키마에 명시한 길이만 제한하며 임의 기본 상한을 넣지 않는다.
     * @created 2026-11-01
     * @usedBy check
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     */
    private static void range(int size, JsonNode schema, String min, String max) {
        if (schema.has(min)) {
            require(size >= schema.get(min).asInt(), Analysis.BELOW_MINIMUM);
        }
        if (schema.has(max)) {
            require(size <= schema.get(max).asInt(), Analysis.ABOVE_MAXIMUM);
        }
    }

    /**
     * 검증 실패를 상수 사유로 전달한다.
     * @created 2026-11-01
     * @usedBy SchemaRules, AnalysisContract, InputMapper
     * @modified 2026-11-02 - 제어문 본문 구분
     */
    public static void require(boolean condition, String reason) {
        if (!condition) {
            throw new ContractFailure(reason);
        }
    }
}
