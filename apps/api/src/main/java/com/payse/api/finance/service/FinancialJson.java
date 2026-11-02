package com.payse.api.finance.service;

import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.HexFormat;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 멱등 요청의 객체 키만 정렬한다. 배열 순서·null·생략은 서로 다른 요청으로 남긴다.
 * @created 2026-10-29
 * @usedBy FinancialService, FinancialCursor
 */
final class FinancialJson {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    /**
     * 상태 없는 변환 도구의 생성을 막는다.
     * @created 2026-10-29
     * @usedBy 클래스 초기화
     */
    private FinancialJson() {
    }

    /**
     * 메서드·정규 경로·원래 허용 본문으로 요청 지문을 만든다. 키 자체는 제외한다.
     * @created 2026-10-29
     * @usedBy FinancialService.write
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    static String requestDigest(String method, String path, ObjectNode body) {
        ObjectNode copy = body.deepCopy();
        copy.remove(ApiFieldConstants.Finance.IDEMPOTENCY_KEY);
        ObjectNode request = JSON.createObjectNode()
            .put(ApiFieldConstants.Finance.METHOD, method)
            .put(ApiFieldConstants.Finance.PATH, path);
        request.set(ApiFieldConstants.Finance.BODY, copy);
        return digest(request);
    }

    /**
     * 직렬화가 결정적인 JSON의 SHA-256을 계산한다. 비밀 자격을 입력받지 않는다.
     * @created 2026-10-29
     * @usedBy requestDigest, FinancialCursor.context
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    static String digest(JsonNode node) {
        try {
            byte[] bytes = canonical(node)
                .toString()
                .getBytes(StandardCharsets.UTF_8);
            byte[] digest = MessageDigest.getInstance(ApiConfigConstants.Finance.DIGEST_ALGORITHM)
                .digest(bytes);
            return ApiConfigConstants.Finance.SHA256_PREFIX + HexFormat.of().formatHex(digest);
        } catch (GeneralSecurityException failure) {
            throw new IllegalStateException(ApiMessageConstants.Finance.DIGEST_UNAVAILABLE);
        }
    }

    /**
     * 객체 키를 재귀 정렬하되 배열과 값의 표현은 보존한다.
     * @created 2026-10-29
     * @usedBy digest
     */
    private static JsonNode canonical(JsonNode node) {
        if (node.isObject()) {
            ObjectNode result = JSON.createObjectNode();
            node.propertyNames()
                .stream()
                .sorted()
                .forEach(key -> result.set(key, canonical(node.get(key))));
            return result;
        }
        if (node.isArray()) {
            var result = JSON.createArrayNode();
            node.forEach(value -> result.add(canonical(value)));
            return result;
        }
        return node.deepCopy();
    }
}
