package com.payse.api.analysis.service;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 분석 식별에 사용하는 JSON 객체 키를 정렬하고 UTF-8 지문을 만든다.
 * @created 2026-11-01
 * @usedBy AnalysisIdentity, AnalysisJobs, AnalysisRepository
 */
public final class AnalysisJson {
    public static final JsonMapper JSON = JsonMapper.builder().build();

    /**
     * 상태 없는 변환 도구의 생성을 막는다.
     * @created 2026-11-01
     * @usedBy 클래스 초기화
     */
    private AnalysisJson() {}

    /**
     * 값·배열 순서는 유지하고 객체 키만 재귀 정렬한다. 집합 정렬은 업무 호출부가 수행한다.
     * @created 2026-11-01
     * @usedBy digest, canonical
     */
    public static JsonNode canonical(JsonNode value) {
        if (value.isObject()) {
            ObjectNode sorted = JSON.createObjectNode();
            value.propertyNames().stream().sorted().forEach(key -> sorted.set(key, canonical(value.get(key))));
            return sorted;
        }
        if (value.isArray()) {
            var ordered = JSON.createArrayNode();
            value.forEach(item -> ordered.add(canonical(item)));
            return ordered;
        }
        return value.deepCopy();
    }

    /**
     * 정수·문자열·null의 구분을 보존한 정규 JSON을 SHA-256으로 식별한다.
     * @created 2026-11-01
     * @usedBy AnalysisIdentity, AnalysisJobs
     */
    public static String digest(JsonNode value) {
        try {
            byte[] bytes = canonical(value).toString().getBytes(StandardCharsets.UTF_8);
            return "sha256:" + HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException failure) {
            throw new IllegalStateException("Required digest unavailable");
        }
    }
}
