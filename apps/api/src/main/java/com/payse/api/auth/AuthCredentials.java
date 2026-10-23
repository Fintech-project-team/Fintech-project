package com.payse.api.auth;

/**
 * 공유 ASCII 입력 규칙으로 검증한 합성 인증 자격이다. 자격 존재 여부는 판단하지 않는다.
 * @created 2026-10-22
 * @usedBy 미연결: 예정 AuthService 로그인·재확인 입력, AuthCredentialsTest
 */
public record AuthCredentials(String name, String phone, String code) {
    /**
     * 이름·전화번호만 허용된 구분자로 정규화하고 코드는 원문 형식을 검사한다.
     * @created 2026-10-22
     * @usedBy 미연결: 예정 AuthService, AuthCredentialsTest
     * @param name 앞뒤 U+0020 제거 전 이름
     * @param phone U+0020·U+002D 제거 전 전화번호
     * @param code 정규화하지 않는 ASCII 숫자 6자리
     * @throws IllegalArgumentException 누락 또는 허용하지 않은 문자·길이
     */
    public AuthCredentials {
        name = normalizeName(name);
        phone = normalizePhone(phone);
        requireCode(code);
    }

    /**
     * 이름 앞뒤의 ASCII 공백만 제거한 뒤 한글 완성형·영문 2~20자를 검증한다.
     * @created 2026-10-22
     * @usedBy AuthCredentials 생성자, AuthCrypto.combinationLimitKey
     * @param raw 정규화 전 이름
     * @return 검증된 이름
     */
    static String normalizeName(String raw) {
        if (raw == null) throw new IllegalArgumentException("Invalid authentication name");
        int start = 0;
        int end = raw.length();
        while (start < end && raw.charAt(start) == ' ') start++;
        while (end > start && raw.charAt(end - 1) == ' ') end--;
        String normalized = raw.substring(start, end);
        if (!normalized.matches("[가-힣A-Za-z]{2,20}")) {
            throw new IllegalArgumentException("Invalid authentication name");
        }
        return normalized;
    }

    /**
     * ASCII 공백·하이픈만 제거한 뒤 010으로 시작하는 ASCII 11자리를 검증한다.
     * @created 2026-10-22
     * @usedBy AuthCredentials 생성자, AuthCrypto.combinationLimitKey
     * @param raw 정규화 전 전화번호
     * @return 검증된 전화번호
     */
    static String normalizePhone(String raw) {
        if (raw == null || !raw.matches("[0-9 -]*")) {
            throw new IllegalArgumentException("Invalid authentication phone");
        }
        String normalized = raw.replace(" ", "").replace("-", "");
        if (!normalized.matches("010[0-9]{8}")) {
            throw new IllegalArgumentException("Invalid authentication phone");
        }
        return normalized;
    }

    /**
     * 코드에 공백 제거·숫자형 변환 없이 ASCII 숫자 6자리만 허용한다.
     * @created 2026-10-22
     * @usedBy AuthCredentials 생성자, AuthCrypto.codeVerifier
     * @param code 검증할 코드
     */
    static void requireCode(String code) {
        if (code == null || !code.matches("[0-9]{6}")) {
            throw new IllegalArgumentException("Invalid authentication code");
        }
    }

    /**
     * 자동 record 문자열 표현으로 자격 원문이 로그에 노출되는 것을 막는다.
     * @created 2026-10-22
     * @usedBy Java 문자열 변환, AuthCredentialsTest
     * @return 원문이 없는 고정 표현
     */
    @Override
    public String toString() {
        return "AuthCredentials[REDACTED]";
    }
}
