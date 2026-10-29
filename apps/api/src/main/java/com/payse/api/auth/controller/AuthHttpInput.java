package com.payse.api.auth.controller;

import com.payse.api.auth.dto.AuthInput;
import com.payse.api.auth.dto.AuthResult;
import com.payse.api.auth.error.AuthInputException;
import com.payse.api.auth.error.AuthStoreException;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.Set;
import org.springframework.context.annotation.Profile;
import org.springframework.core.env.Environment;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import tools.jackson.core.JacksonException;
import tools.jackson.core.StreamReadFeature;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * 인증 HTTP 입력만 제한하여 해석한다. 클라이언트 전달 헤더로 접속 IP를 바꾸지 않는다.
 * @created 2026-10-28
 * @usedBy AuthController
 */
@Component
@Profile("database & auth")
public final class AuthHttpInput {
    private static final int MAX_BODY_BYTES = 4096;
    private static final Set<String> FIELDS = Set.of("name", "phone", "code");
    private final JsonMapper mapper = JsonMapper.builder()
        .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
        .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS).build();

    /**
     * 직접 연결 배포 모드와 전달 헤더 미적용을 명시적으로 요구한다.
     * @created 2026-10-28
     * @usedBy Spring 생성자 주입
     */
    public AuthHttpInput(Environment environment) {
        if (!"direct".equals(environment.getProperty("PAYSE_AUTH_PEER_MODE"))
                || !"none".equals(environment.getProperty("server.forward-headers-strategy"))) {
            throw new IllegalStateException("Authentication requires explicit direct peer mode and forwarding disabled");
        }
    }

    /**
     * 서블릿 연결의 숫자 IP만 읽는다. hostname 및 X-Forwarded-For/Forwarded는 사용하지 않는다.
     * @created 2026-10-28
     * @usedBy AuthController.login, reverify
     */
    public InetAddress peer(HttpServletRequest request) {
        String address = request.getRemoteAddr();
        boolean ipv6 = address != null && address.contains(":") && address.matches("[0-9A-Fa-f:]+(%[0-9]+)?");
        boolean ipv4 = address != null && address.matches("[0-9]{1,3}(\\.[0-9]{1,3}){3}");
        if (ipv4) {
            for (String part : address.split("\\.")) {
                if (Integer.parseInt(part) > 255) ipv4 = false;
            }
        }
        if (!ipv4 && !ipv6) throw new AuthStoreException();
        try {
            return InetAddress.getByName(address);
        } catch (UnknownHostException failure) {
            throw new AuthStoreException();
        }
    }

    /**
     * IP 기록 이후 최대 4097바이트만 읽고 UTF-8·JSON·세 문자열 키를 검사한다.
     * @created 2026-10-28
     * @usedBy AuthController의 지연 입력 콜백
     */
    public AuthInput read(HttpServletRequest request) {
        if (request.getContentLengthLong() > MAX_BODY_BYTES) {
            throw new AuthInputException(AuthResult.Reason.REQUEST_TOO_LARGE);
        }
        byte[] body;
        try {
            body = request.getInputStream().readNBytes(MAX_BODY_BYTES + 1);
        } catch (IOException failure) {
            throw new AuthInputException(AuthResult.Reason.INVALID_JSON);
        }
        if (body.length > MAX_BODY_BYTES) throw new AuthInputException(AuthResult.Reason.REQUEST_TOO_LARGE);
        requireJson(request);
        JsonNode node;
        try {
            String text = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(body)).toString();
            node = mapper.readTree(text);
        } catch (JacksonException | IOException failure) {
            throw new AuthInputException(AuthResult.Reason.INVALID_JSON);
        }
        if (node == null || node.isMissingNode()) throw new AuthInputException(AuthResult.Reason.INVALID_JSON);
        if (!node.isObject() || !Set.copyOf(node.propertyNames()).equals(FIELDS)) {
            throw new AuthInputException(AuthResult.Reason.INVALID_INPUT);
        }
        for (String field : Set.of("name", "phone")) {
            if (!node.get(field).isString()) throw new AuthInputException(AuthResult.Reason.INVALID_INPUT);
        }
        // 잘못된 코드 타입도 조합의 기존 차단을 먼저 확인한 뒤 422로 거절한다. 문자열 변환은 하지 않는다.
        String code = node.get("code").isString() ? node.get("code").asString() : null;
        return new AuthInput(node.get("name").asString(), node.get("phone").asString(), code);
    }

    /**
     * 인증 계약의 UTF-8 JSON 외 형식과 압축 본문을 자동 변환하지 않는다.
     * @created 2026-10-28
     * @usedBy AuthHttpInput.read
     */
    private void requireJson(HttpServletRequest request) {
        try {
            MediaType type = MediaType.parseMediaType(request.getContentType());
            if (!"application".equalsIgnoreCase(type.getType()) || !"json".equalsIgnoreCase(type.getSubtype())
                    || (type.getCharset() != null && !StandardCharsets.UTF_8.equals(type.getCharset()))
                    || request.getHeader("Content-Encoding") != null) {
                throw new IllegalArgumentException();
            }
        } catch (IllegalArgumentException failure) {
            throw new AuthInputException(AuthResult.Reason.INVALID_INPUT);
        }
    }

    /**
     * 단일 Bearer 헤더만 전달한다. 누락·중복·다른 인증 방식은 무효 토큰으로 처리한다.
     * @created 2026-10-28
     * @usedBy AuthController.reverify, logout
     */
    public String bearer(HttpServletRequest request) {
        var headers = Collections.list(request.getHeaders("Authorization"));
        if (headers.size() != 1) return null;
        String value = headers.get(0);
        if (value.length() <= 7 || !value.regionMatches(true, 0, "Bearer ", 0, 7)) return null;
        return value.substring(7);
    }

    /**
     * 본문이 없는 로그아웃 계약을 검사하고 입력값을 오류에 보관하지 않는다.
     * @created 2026-10-28
     * @usedBy AuthController.logout
     */
    public void requireEmpty(HttpServletRequest request) {
        try {
            if (request.getContentLengthLong() > MAX_BODY_BYTES) {
                throw new AuthInputException(AuthResult.Reason.REQUEST_TOO_LARGE);
            }
            int size = request.getInputStream().readNBytes(MAX_BODY_BYTES + 1).length;
            if (size > MAX_BODY_BYTES) throw new AuthInputException(AuthResult.Reason.REQUEST_TOO_LARGE);
            if (size != 0) throw new AuthInputException(AuthResult.Reason.INVALID_INPUT);
        } catch (IOException failure) {
            throw new AuthInputException(AuthResult.Reason.INVALID_JSON);
        }
    }
}
