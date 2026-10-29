package com.payse.api.auth.dto;

import java.time.Instant;
import java.util.UUID;

/**
 * 인증 DB 함수의 조회 결과다. HTTP에 직접 반환하지 않는다.
 * @created 2026-10-29
 * @usedBy AuthRepository, AuthService, FinancialService
 */
public final class AuthRows {
    /**
     * 중첩 전달 타입만 사용하므로 묶음 클래스의 생성을 막는다.
     * @created 2026-10-29
     * @usedBy AuthRows 클래스 초기화
     */
    private AuthRows() {}

    /**
     * IP 요청 저장 결과다. allowed=false이면 retryAt이 있으며 외부 응답 DTO로 사용하지 않는다.
     * @created 2026-10-25
     * @usedBy AuthRepository.recordIp, AuthJdbcTest
     */
    public record IpLimit(boolean allowed, Instant retryAt) {}

    /**
     * 서버 내부 코드 비교용 후보다. 계정 활성/세션 판정이나 인증 성공 결과가 아니다.
     * @created 2026-10-25
     * @usedBy AuthRepository.findCode, AuthJdbcTest
     */
    public record StoredCode(UUID userId, String verifier) {
        /**
         * verifier·사용자 식별자가 자동 문자열 표현으로 로그에 남지 않게 한다.
         * @created 2026-10-25
         * @usedBy Java 문자열 표현, AuthRepositoryTest
         * @return 원문 없는 고정 문자열
         */
        @Override
        public String toString() { return "StoredCode[redacted]"; }
    }

    /**
     * 현재 트랜잭션에서 확인된 소유자다. 토큰 원문을 보관하지 않는다.
     * @created 2026-10-25
     * @usedBy AuthRepository.authorize, AuthJdbcTest
     */
    public record Session(UUID userId, UUID sessionId) {}

    /**
     * 사용자 잠금 뒤 확보한 내부 코드 비교 자료다. 외부 응답으로 직렬화하지 않는다.
     * @created 2026-10-26
     * @usedBy AuthRepository.lockCode, AuthService.signIn
     */
    public record LoginAccount(UUID userId, String name, String verifier) {
        /**
         * 합성 자격과 verifier가 문자열 표현으로 기록되는 것을 막는다.
         * @created 2026-10-26
         * @usedBy Java 문자열 변환, AuthServiceTest
         */
        @Override
        public String toString() { return "LoginAccount[REDACTED]"; }
    }

    /**
     * 세션 INSERT의 실제 반환값이다. token 원문·digest를 담지 않는다.
     * @created 2026-10-26
     * @usedBy AuthRepository.openSession, AuthService.signIn
     */
    public record OpenedSession(UUID userId, UUID sessionId, String name, Instant issuedAt) {
        /**
         * 내부 저장 이름이 자동 문자열 표현으로 로그에 남지 않게 한다.
         * @created 2026-10-26
         * @usedBy Java 문자열 변환
         */
        @Override
        public String toString() { return "OpenedSession[REDACTED]"; }
    }
}
