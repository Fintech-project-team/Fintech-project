package com.payse.api.finance.controller;

import com.payse.api.finance.error.FinancialException;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.Set;
import org.springframework.context.annotation.Profile;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import tools.jackson.core.JacksonException;
import tools.jackson.core.StreamReadFeature;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * 금융 HTTP의 본문·헤더·조회 입력을 엄격히 해석한다. 허용 필드 검증은 FinancialInput에 위임한다.
 * @created 2026-10-29
 * @usedBy FinancialController
 */
@Component
@Profile("database & auth & finance")
public final class FinancialHttpInput {
    private static final int MAX_BODY = 65536;
    private final JsonMapper json = JsonMapper.builder().enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
        .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS).build();

    /**
     * 쓰기 본문은 64 KiB까지 읽고 DELETE의 W는 단일 헤더에서만 구성한다.
     * @created 2026-10-29
     * @usedBy FinancialController.write의 지연 입력
     */
    public JsonNode read(HttpServletRequest request) {
        if (!request.getParameterMap().isEmpty()) throw new FinancialException(422, "VALIDATION_FAILED");
        byte[] bytes = body(request);
        if ("DELETE".equals(request.getMethod())) {
            if (bytes.length != 0) throw new FinancialException(422, "VALIDATION_FAILED");
            return json.createObjectNode()
                .put("expectedDataVersion", header(request, "Payse-Expected-Data-Version"))
                .put("ruleVersion", header(request, "Payse-Rule-Version"))
                .put("idempotencyKey", header(request, "Idempotency-Key"));
        }
        for (String name : Set.of("Payse-Expected-Data-Version", "Payse-Rule-Version", "Idempotency-Key")) {
            if (request.getHeader(name) != null) throw new FinancialException(422, "VALIDATION_FAILED");
        }
        try {
            MediaType type = MediaType.parseMediaType(request.getContentType());
            if (!"application".equalsIgnoreCase(type.getType()) || !"json".equalsIgnoreCase(type.getSubtype())
                    || (type.getCharset() != null && !StandardCharsets.UTF_8.equals(type.getCharset()))
                    || request.getHeader("Content-Encoding") != null) throw new IllegalArgumentException();
        } catch (IllegalArgumentException failure) {
            throw new FinancialException(422, "VALIDATION_FAILED");
        }
        try {
            String text = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
            JsonNode value = json.readTree(text);
            if (value == null || value.isMissingNode()) throw new FinancialException(400, "INVALID_JSON");
            return value;
        } catch (JacksonException | IOException failure) {
            throw new FinancialException(400, "INVALID_JSON");
        }
    }

    /**
     * 첫 조회는 쿼리가 없고 후속 조회는 cursor 하나만 받는다. 본문은 받지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialController.snapshot, page의 지연 입력
     */
    public String cursor(HttpServletRequest request, boolean pageOnly) {
        if (body(request).length != 0) throw new FinancialException(422, "VALIDATION_FAILED");
        var query = request.getParameterMap();
        if (!pageOnly) {
            if (!query.isEmpty()) throw new FinancialException(422, "VALIDATION_FAILED");
            return null;
        }
        if (!query.keySet().equals(Set.of("cursor")) || query.get("cursor").length != 1) {
            throw new FinancialException(400, "INVALID_CURSOR");
        }
        return query.get("cursor")[0];
    }

    /**
     * Content-Length를 신뢰하지 않고 실제 바이트 상한도 검사한다.
     * @created 2026-10-29
     * @usedBy read, cursor
     */
    private byte[] body(HttpServletRequest request) {
        if (request.getContentLengthLong() > MAX_BODY) throw new FinancialException(413, "REQUEST_TOO_LARGE");
        try {
            byte[] bytes = request.getInputStream().readNBytes(MAX_BODY + 1);
            if (bytes.length > MAX_BODY) throw new FinancialException(413, "REQUEST_TOO_LARGE");
            return bytes;
        } catch (IOException failure) {
            throw new FinancialException(400, "INVALID_JSON");
        }
    }

    /**
     * 필수 DELETE W 헤더의 누락·중복을 거절한다.
     * @created 2026-10-29
     * @usedBy read
     */
    private String header(HttpServletRequest request, String name) {
        var values = Collections.list(request.getHeaders(name));
        if (values.size() != 1) throw new FinancialException(422, "VALIDATION_FAILED");
        return values.get(0);
    }
}
