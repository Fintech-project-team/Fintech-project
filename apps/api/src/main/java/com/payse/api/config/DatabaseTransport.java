package com.payse.api.config;

import com.payse.api.constants.ApiConfigConstants.Server;
import com.payse.api.constants.ApiMessageConstants;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Locale;
import java.util.Set;

/**
 * 설치 도구를 거치지 않은 JDBC 실행에도 같은 단일 호스트·원격 TLS 경계를 적용한다.
 * @created 2026-11-05
 * @usedBy DatabaseConfiguration.poolConfig
 */
final class DatabaseTransport {
    /**
     * 상태 없는 설정 검증기의 인스턴스 생성을 막는다.
     * @created 2026-11-05
     * @usedBy 없음: 정적 검증 전용
     */
    private DatabaseTransport() {
    }

    /**
     * 명시 loopback 외에는 verify-full을 요구하고 인증 우회·모호한 URL을 거절한다.
     * @created 2026-11-05
     * @usedBy DatabaseConfiguration.poolConfig, DatabaseTransportTest
     * @param url 자격을 포함하면 거절하며 진단에 원문을 남기지 않는 JDBC URL
     * @throws IllegalArgumentException 단일 호스트·DB명·허용 TLS 옵션 경계 위반
     */
    static void verify(String url) {
        try {
            if (url == null || !url.startsWith(Server.POSTGRES_NETWORK_PREFIX)) {
                throw invalid();
            }
            URI target = URI.create(url.substring(Server.JDBC_PREFIX.length()));
            String host = target.getHost();
            if (host == null || target.getRawUserInfo() != null || target.getRawFragment() != null
                || target.getRawPath() == null || !target.getRawPath().matches("/[A-Za-z0-9_]+")
                || target.getPort() == 0 || target.getPort() > 65535) {
                throw invalid();
            }
            var options = new HashMap<String, String>();
            var allowed = Set.of(
                Server.SSL_MODE,
                Server.SSL_ROOT_CERT,
                Server.SSL_CERT,
                Server.SSL_KEY
            );
            String query = target.getRawQuery();
            if (query != null) {
                for (String field : query.split("&", -1)) {
                    String[] pair = field.split("=", -1);
                    if (pair.length != 2) {
                        throw invalid();
                    }
                    String name = pair[0];
                    String value = URLDecoder.decode(pair[1], StandardCharsets.UTF_8);
                    if (!allowed.contains(name) || value.isBlank()
                        || value.chars().anyMatch(Character::isISOControl)
                        || options.putIfAbsent(name, value) != null) {
                        throw invalid();
                    }
                }
            }
            boolean local = Set.of(Server.LOCALHOST, Server.LOOPBACK_IPV4, Server.LOOPBACK_IPV6)
                .contains(host.toLowerCase(Locale.ROOT));
            if (!local && !Server.SSL_VERIFY_FULL.equals(options.get(Server.SSL_MODE))) {
                throw invalid();
            }
        } catch (IllegalArgumentException failure) {
            throw invalid();
        }
    }

    /**
     * 연결 주소·자격·원인 예외를 노출하지 않는 오류를 만든다.
     * @created 2026-11-05
     * @usedBy DatabaseTransport.verify
     * @return 민감 설정을 포함하지 않는 검증 오류
     */
    private static IllegalArgumentException invalid() {
        return new IllegalArgumentException(ApiMessageConstants.Server.INVALID_DATABASE_TRANSPORT);
    }
}
