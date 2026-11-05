package com.payse.api.config;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

/**
 * 직접 JAR 실행의 원격 TLS 경계와 기존 loopback 호환성을 외부 연결 없이 검사한다.
 * @created 2026-11-05
 * @usedBy Gradle JUnit test
 */
class DatabaseTransportTest {
    /**
     * 기존 loopback과 인증서 검증을 명시한 원격 주소를 유지한다.
     * @created 2026-11-05
     * @usedBy JUnit test
     */
    @Test
    void acceptsExplicitLocalAndVerifiedRemote() {
        for (String url : new String[] {
            "jdbc:postgresql://127.0.0.1:15435/payse_dev",
            "jdbc:postgresql://localhost/payse",
            "jdbc:postgresql://[::1]:5432/payse?sslmode=disable",
            "jdbc:postgresql://db.example.test:5432/payse?sslmode=verify-full",
            "jdbc:postgresql://db.example.test/payse?sslrootcert=C%3A%2Fca.pem&sslmode=verify-full"
        }) {
            assertDoesNotThrow(() -> DatabaseTransport.verify(url));
        }
    }

    /**
     * 평문 원격·중복/숨은 옵션·우회 factory·자격/호스트 혼동을 시작 전에 차단한다.
     * @created 2026-11-05
     * @usedBy JUnit test
     */
    @Test
    void rejectsInsecureOrAmbiguousSettings() {
        for (String suffix : new String[] {
            "//db.example.test/payse",
            "//db.example.test/payse?sslmode=require",
            "//db.example.test/payse?sslmode=verify-ca",
            "//db.example.test/payse?sslmode=verify-full&sslmode=disable",
            "//db.example.test/payse?sslmode=verify-full&%73slmode=disable",
            "//db.example.test/payse?sslmode=verify-full&sslfactory=NonValidatingFactory",
            "//db.example.test/payse?sslmode=verify-full&sslhostnameverifier=Ignore",
            "//db.example.test/payse?sslmode=verify-full&socketFactory=Override",
            "//localhost,db.example.test/payse",
            "//localhost@db.example.test/payse?sslmode=verify-full",
            "//127.0.0.1.evil.test/payse",
            "//127.0.0.1:0/payse",
            "//localhost:65536/payse",
            "//localhost/payse#fragment",
            "//localhost/payse?sslmode=",
            "//localhost/payse?sslmode=disable&",
            "//localhost/payse?sslmode=verify-full&sslrootcert=a%0Ab",
            "//localhost/a%2Fb",
            "payse"
        }) {
            var failure = assertThrows(
                IllegalArgumentException.class,
                () -> DatabaseTransport.verify("jdbc:postgresql:" + suffix)
            );
            assertFalse(failure.getMessage().contains(suffix));
        }
        assertThrows(IllegalArgumentException.class, () -> DatabaseTransport.verify(null));
    }
}
