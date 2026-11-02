package com.payse.api.finance.controller;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.finance.dto.TransactionQuery;
import com.payse.api.finance.error.FinancialException;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
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
    private final JsonMapper json = JsonMapper.builder()
        .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
        .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
        .build();

    /**
     * 쓰기 본문은 64 KiB까지 읽고 DELETE의 W는 단일 헤더에서만 구성한다.
     * @created 2026-10-29
     * @usedBy FinancialController.write의 지연 입력
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 단일 제어문 본문 중괄호 명시
     */
    public JsonNode read(HttpServletRequest request) {
        if (!request.getParameterMap().isEmpty()) {
            throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
        }

        byte[] bytes = body(request);
        if ("DELETE".equals(request.getMethod())) {
            if (bytes.length != 0) {
                throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
            }

            return json.createObjectNode()
                .put(
                    ApiFieldConstants.Finance.EXPECTED_DATA_VERSION,
                    header(request, ApiConfigConstants.Finance.PAYSE_EXPECTED_DATA_VERSION)
                )
                .put(
                    ApiFieldConstants.Finance.RULE_VERSION,
                    header(request, ApiConfigConstants.Finance.PAYSE_RULE_VERSION)
                )
                .put(
                    ApiFieldConstants.Finance.IDEMPOTENCY_KEY,
                    header(request, ApiConfigConstants.Finance.IDEMPOTENCY_HEADER)
                );
        }
        var writeHeaders = Set.of(
            ApiConfigConstants.Finance.PAYSE_EXPECTED_DATA_VERSION,
            ApiConfigConstants.Finance.PAYSE_RULE_VERSION,
            ApiConfigConstants.Finance.IDEMPOTENCY_HEADER
        );
        for (String name : writeHeaders) {
            if (request.getHeader(name) != null) {
                throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
            }
        }

        try {
            MediaType type = MediaType.parseMediaType(request.getContentType());
            if (!ApiConfigConstants.Finance.APPLICATION.equalsIgnoreCase(type.getType())
                || !ApiConfigConstants.Finance.JSON.equalsIgnoreCase(type.getSubtype())
                || (type.getCharset() != null && !StandardCharsets.UTF_8.equals(type.getCharset()))
                || request.getHeader(ApiConfigConstants.Finance.CONTENT_ENCODING) != null) {
                throw new IllegalArgumentException();
            }
        } catch (IllegalArgumentException failure) {
            throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
        }

        try {
            String text = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString();
            JsonNode value = json.readTree(text);
            if (value == null || value.isMissingNode()) {
                throw new FinancialException(400, ApiCodeConstants.Finance.INVALID_JSON);
            }

            return value;
        } catch (JacksonException | IOException failure) {
            throw new FinancialException(400, ApiCodeConstants.Finance.INVALID_JSON);
        }
    }

    /**
     * 첫 조회는 쿼리가 없고 후속 조회는 cursor 하나만 받는다. 본문은 받지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialController.snapshot, page의 지연 입력
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    public String cursor(HttpServletRequest request, boolean pageOnly) {
        if (body(request).length != 0) {
            throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
        }

        var query = request.getParameterMap();
        if (!pageOnly) {
            if (!query.isEmpty()) {
                throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
            }

            return null;
        }
        if (!query.keySet().equals(Set.of(ApiFieldConstants.Finance.CURSOR))
            || query.get(ApiFieldConstants.Finance.CURSOR).length != 1) {
            throw new FinancialException(400, ApiCodeConstants.Finance.INVALID_CURSOR);
        }

        return query.get(ApiFieldConstants.Finance.CURSOR)[0];
    }

    /**
     * 기존 cursor 단독 경로 또는 날짜 쌍을 가진 첫/후속 거래 페이지를 해석한다.
     * @created 2026-11-01
     * @usedBy FinancialController.page의 인증 후 지연 입력
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    public TransactionQuery transactions(HttpServletRequest request) {
        var query = request.getParameterMap();
        if (!query.containsKey(ApiFieldConstants.Finance.START_DATE)
            && !query.containsKey(ApiFieldConstants.Finance.END_DATE)) {
            return new TransactionQuery(cursor(request, true), null, null);
        }

        if (body(request).length != 0
            || !query.keySet()
                .containsAll(
                    Set.of(
                        ApiFieldConstants.Finance.START_DATE,
                        ApiFieldConstants.Finance.END_DATE
                    )
                )
            || !Set.of(
                ApiFieldConstants.Finance.START_DATE,
                ApiFieldConstants.Finance.END_DATE,
                ApiFieldConstants.Finance.CURSOR
            ).containsAll(query.keySet())
            || query.values()
                .stream()
                .anyMatch(values -> values.length != 1)) {
            throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
        }

        String cursor = query.containsKey(ApiFieldConstants.Finance.CURSOR)
            ? query.get(ApiFieldConstants.Finance.CURSOR)[0]
            : null;
        return new TransactionQuery(
            cursor,
            date(query.get(ApiFieldConstants.Finance.START_DATE)[0]),
            date(query.get(ApiFieldConstants.Finance.END_DATE)[0])
        );
    }

    /**
     * YYYY-MM-DD의 존재하는 날짜만 읽고 시각·공백·말일 자동 보정을 허용하지 않는다.
     * @created 2026-11-01
     * @usedBy transactions
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    private LocalDate date(String value) {
        if (value == null || !value.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")
            || value.startsWith(ApiConfigConstants.Finance.INVALID_YEAR)) {
            throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
        }

        try {
            return LocalDate.parse(value);
        } catch (DateTimeParseException failure) {
            throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
        }
    }

    /**
     * Content-Length를 신뢰하지 않고 실제 바이트 상한도 검사한다.
     * @created 2026-10-29
     * @usedBy read, cursor
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private byte[] body(HttpServletRequest request) {
        if (request.getContentLengthLong() > MAX_BODY) {
            throw new FinancialException(413, ApiCodeConstants.Finance.REQUEST_TOO_LARGE);
        }

        try {
            byte[] bytes = request.getInputStream().readNBytes(MAX_BODY + 1);
            if (bytes.length > MAX_BODY) {
                throw new FinancialException(413, ApiCodeConstants.Finance.REQUEST_TOO_LARGE);
            }

            return bytes;
        } catch (IOException failure) {
            throw new FinancialException(400, ApiCodeConstants.Finance.INVALID_JSON);
        }
    }

    /**
     * 필수 DELETE W 헤더의 누락·중복을 거절한다.
     * @created 2026-10-29
     * @usedBy read
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private String header(HttpServletRequest request, String name) {
        var values = Collections.list(request.getHeaders(name));
        if (values.size() != 1) {
            throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
        }

        return values.get(0);
    }
}
