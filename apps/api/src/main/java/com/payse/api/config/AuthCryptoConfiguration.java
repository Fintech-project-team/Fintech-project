package com.payse.api.config;

import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.crypto.AuthSecrets;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiMessageConstants;
import java.util.Arrays;
import java.util.Base64;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.core.env.Environment;

/**
 * auth 프로필에서만 비밀 설정을 검증한다. 인증 HTTP 경로를 개방하지 않는다.
 * @created 2026-10-22
 * @usedBy Spring 설정 탐색, AuthCryptoConfigurationTest
 */
@Configuration(proxyBeanMethods = false)
@Profile("auth")
public class AuthCryptoConfiguration {

    /**
     * 기본값 없이 환경에서 분리된 코드·제한 키와 ID를 읽고 검증한다.
     * @created 2026-10-22
     * @usedBy Spring bean 구성, AuthCryptoConfigurationTest
     * @param environment PAYSE_AUTH_CODE_KEY_ID, PAYSE_AUTH_CODE_KEY_BASE64,
     *     PAYSE_AUTH_LIMIT_KEY_BASE64 환경
     * @return 검증된 비밀 설정
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Bean
    public AuthSecrets authSecrets(Environment environment) {
        byte[] codeKey = decodeKey(environment, ApiConfigConstants.Auth.PAYSE_AUTH_CODE_KEY_BASE64);
        byte[] limitKey = null;
        try {
            limitKey = decodeKey(environment, ApiConfigConstants.Auth.PAYSE_AUTH_LIMIT_KEY_BASE64);
            return new AuthSecrets(
                environment.getProperty(ApiConfigConstants.Auth.PAYSE_AUTH_CODE_KEY_ID),
                codeKey,
                limitKey
            );
        } finally {
            Arrays.fill(codeKey, (byte) 0);
            if (limitKey != null) {
                Arrays.fill(limitKey, (byte) 0);
            }
        }
    }

    /**
     * 필수 Base64 키를 엄격히 해석하고 오류에 입력값·원래 예외를 포함하지 않는다.
     * @created 2026-10-22
     * @usedBy AuthCryptoConfiguration.authSecrets
     * @param environment 비밀 설정 환경
     * @param property 읽을 환경 키 이름
     * @return 복호화한 32바이트 키
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private static byte[] decodeKey(Environment environment, String property) {
        String encoded = environment.getProperty(property);
        byte[] decoded = null;
        try {
            if (encoded == null) {
                throw new IllegalArgumentException();
            }

            decoded = Base64.getDecoder().decode(encoded);
            if (decoded.length != 32 || !Base64.getEncoder()
                .encodeToString(decoded)
                .equals(encoded)) {
                throw new IllegalArgumentException();
            }

            return decoded;
        } catch (IllegalArgumentException failure) {
            if (decoded != null) {
                Arrays.fill(decoded, (byte) 0);
            }
            throw new IllegalArgumentException(ApiMessageConstants.Auth.INVALID_REQUIRED_KEYS);
        }
    }

    /**
     * 무상태 암호 연산 서비스를 생성자 주입으로 구성한다.
     * @created 2026-10-22
     * @usedBy Spring bean 구성, AuthService
     * @param secrets 검증된 서버 비밀 설정
     * @return 요청별 사용자 상태를 보관하지 않는 연산 서비스
     */
    @Bean
    public AuthCrypto authCrypto(AuthSecrets secrets) {
        return new AuthCrypto(secrets);
    }
}
