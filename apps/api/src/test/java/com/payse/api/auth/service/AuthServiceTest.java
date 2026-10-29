package com.payse.api.auth.service;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.payse.api.auth.controller.AuthHttpInput;
import com.payse.api.auth.controller.AuthHttpResponse;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.crypto.AuthSecrets;
import com.payse.api.auth.dto.AuthInput;
import com.payse.api.auth.dto.AuthResult;
import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.error.AuthInputException;
import com.payse.api.auth.error.AuthStoreException;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.auth.vo.AuthCredentials;
import com.payse.api.auth.vo.IssuedToken;
import java.net.InetAddress;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Supplier;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;

/**
 * 서비스 분기·호출 순서·민감값 출력·등록 조건을 검사한다. 커밋/잠금은 SessionJdbcTest가 실제 DB에서 검사한다.
 * @created 2026-10-26
 * @usedBy Gradle JUnit
 */
class AuthServiceTest {
    private AuthRepository repository;
    private AuthTransactions transactions;
    private AuthCrypto crypto;
    private AuthService service;
    private InetAddress peer;
    private UUID userId;
    private AuthCredentials credentials;

    /**
     * 파싱 콜백에 진입하기 전에 IP 저장이 끝나고 JSON 실패를 다시 세지 않는다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void recordsIpBeforeParsing() {
        AuthResult.Failure result = assertInstanceOf(AuthResult.Failure.class, service.login(peer, () -> {
            verify(repository).recordIp(anyString());
            verify(transactions).run(any());
            throw new AuthInputException(AuthResult.Reason.INVALID_JSON);
        }));
        assertEquals(AuthResult.Reason.INVALID_JSON, result.reason());
        verify(repository).recordIp(anyString());
        verify(repository, never()).lockCode(any(), any());
    }

    /**
     * 무효 세션이면 입력 콜백을 호출하지 않으며 IP 초과는 기존 429를 유지한다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void rejectsTokenBeforeReadingBody() {
        Supplier<AuthInput> unread = () -> { throw new AssertionError("Body must not be read"); };
        assertEquals(AuthResult.Reason.SESSION_INVALID, assertInstanceOf(AuthResult.Failure.class,
            service.reverify(peer, () -> "invalid", unread)).reason());
        Instant retryAt = Instant.now().plusSeconds(60);
        when(repository.recordIp(anyString())).thenReturn(new AuthRows.IpLimit(false, retryAt));
        assertEquals(AuthResult.Reason.RATE_LIMITED, assertInstanceOf(AuthResult.Failure.class,
            service.reverify(peer, () -> "invalid", unread)).reason());
        verify(repository, times(2)).recordIp(anyString());
    }

    /**
     * Retry-After를 초 경계에서 올림하고 만료 직후에도 음수를 반환하지 않는다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void roundsRetrySeconds() {
        Instant now = Instant.parse("2026-10-28T00:00:00Z");
        var result = new AuthResult.Failure(AuthResult.Reason.RATE_LIMITED, now.plusSeconds(1).plusNanos(1));
        assertEquals("2", AuthHttpResponse.reply(result, now).getHeaders().getFirst("Retry-After"));
        assertEquals("1", AuthHttpResponse.reply(result, now.plusSeconds(5)).getHeaders().getFirst("Retry-After"));
    }

    /**
     * 직접 접속 모드 누락·프록시 자동 신뢰는 인증 시작 시 실패한다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void requiresExplicitPeerMode() {
        var environment = new org.springframework.mock.env.MockEnvironment();
        assertThrows(IllegalStateException.class, () -> new AuthHttpInput(environment));
        environment.withProperty("PAYSE_AUTH_PEER_MODE", "direct").withProperty("server.forward-headers-strategy", "native");
        assertThrows(IllegalStateException.class, () -> new AuthHttpInput(environment));
        environment.withProperty("server.forward-headers-strategy", "none");
        assertDoesNotThrow(() -> new AuthHttpInput(environment));
    }

    /**
     * 호출별 사용자와 암호 키를 새로 만들며 저장 전이만 대역으로 분리한다.
     * @created 2026-10-26
     * @usedBy JUnit BeforeEach
     */
    @BeforeEach
    void prepare() throws Exception {
        repository = mock(AuthRepository.class);
        transactions = mock(AuthTransactions.class);
        byte[] codeKey = new byte[32];
        byte[] limitKey = new byte[32];
        SecureRandom random = new SecureRandom();
        random.nextBytes(codeKey);
        random.nextBytes(limitKey);
        crypto = new AuthCrypto(new AuthSecrets("service-tests", codeKey, limitKey));
        service = new AuthService(repository, transactions, crypto);
        peer = InetAddress.getByAddress(new byte[] {127, 0, 0, 1});
        userId = UUID.randomUUID();
        credentials = new AuthCredentials("검증사용자", "01000000000", "012345");
        when(transactions.run(any())).thenAnswer(call -> ((Supplier<?>) call.getArgument(0)).get());
        when(repository.recordIp(anyString())).thenReturn(new AuthRows.IpLimit(true, null));
        when(repository.lockCode(anyString(), anyString())).thenReturn(Optional.empty());
        when(repository.findCode(anyString(), anyString())).thenReturn(Optional.empty());
        when(repository.authorize(nullable(String.class))).thenReturn(Optional.empty());
    }

    /**
     * 실제 서비스가 사용할 잠금 후 코드 자료를 명시적으로 준비한다.
     * @created 2026-10-26
     * @usedBy 로그인 분기 검사
     */
    private void allowCode() {
        when(repository.lockCode(credentials.name(), credentials.phone())).thenReturn(Optional.of(
            new AuthRows.LoginAccount(userId, credentials.name(), crypto.codeVerifier(userId, credentials.code()))));
    }

    /**
     * IP가 먼저 기록되고 저장된 이름·세션 시각과 신규 토큰만 로그인 결과로 반환되는지 검사한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void returnsStoredLogin() {
        allowCode();
        UUID sessionId = UUID.randomUUID();
        Instant issuedAt = Instant.parse("2026-10-26T01:02:03Z");
        when(repository.openSession(eq(userId), anyString())).thenReturn(Optional.of(
            new AuthRows.OpenedSession(userId, sessionId, credentials.name(), issuedAt)));
        AuthResult.Login result = assertInstanceOf(AuthResult.Login.class,
            service.login(peer, " " + credentials.name() + " ", credentials.phone(), credentials.code()));
        assertEquals(userId, result.userId());
        assertEquals(sessionId, result.sessionId());
        assertEquals(credentials.name(), result.name());
        assertEquals(issuedAt, result.issuedAt());
        verify(repository).openSession(userId, crypto.tokenDigest(result.accessToken()));
        InOrder order = inOrder(repository);
        order.verify(repository).recordIp(anyString());
        order.verify(repository).retryAt(anyString());
        order.verify(repository).lockCode(credentials.name(), credentials.phone());
        order.verify(repository).openSession(eq(userId), anyString());
        verify(repository, never()).recordFailure(anyString());
        verify(transactions, times(2)).run(any());
        assertFalse(result.toString().contains(result.accessToken()));
    }

    /**
     * 정확한 자격의 상태 거절은 코드 실패로 누적하지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void keepsStateRejectionSeparate() {
        allowCode();
        when(repository.openSession(eq(userId), anyString())).thenReturn(Optional.empty());
        assertEquals(AuthResult.Reason.AUTH_REJECTED, assertInstanceOf(AuthResult.Failure.class,
            service.login(peer, credentials.name(), credentials.phone(), credentials.code())).reason());
        verify(repository, never()).recordFailure(anyString());
    }

    /**
     * 없는 계정도 실패를 기록하고 다섯 번째 실패의 제한 시각을 반환한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void commitsFailureAsResult() {
        Instant blocked = Instant.parse("2026-10-26T01:05:00Z");
        when(repository.recordFailure(anyString())).thenReturn(blocked);
        AuthResult.Failure result = assertInstanceOf(AuthResult.Failure.class,
            service.login(peer, credentials.name(), credentials.phone(), credentials.code()));
        assertEquals(AuthResult.Reason.RATE_LIMITED, result.reason());
        assertEquals(blocked, result.retryAt());
        verify(repository).recordFailure(crypto.combinationLimitKey(credentials.name(), credentials.phone()));
        verify(repository, never()).openSession(any(), any());
    }

    /**
     * IP와 조합 차단이 겹치면 늦은 시각을 쓰고 자격을 비교하거나 실패를 추가하지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void combinesLimitsBeforeCredentials() {
        Instant ip = Instant.parse("2026-10-26T01:01:00Z");
        Instant combination = Instant.parse("2026-10-26T01:05:00Z");
        when(repository.recordIp(anyString())).thenReturn(new AuthRows.IpLimit(false, ip));
        when(repository.retryAt(anyString())).thenReturn(combination);
        assertEquals(combination, assertInstanceOf(AuthResult.Failure.class,
            service.login(peer, credentials.name(), credentials.phone(), credentials.code())).retryAt());
        verify(repository, never()).lockCode(any(), any());
        verify(repository, never()).recordFailure(anyString());
    }

    /**
     * 코드 형식만 바꿔도 유효 조합의 차단과 더 늦은 재시도 시각을 우회하지 못한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void checksBlockedCombinationBeforeCodeFormat() {
        Instant blocked = Instant.parse("2026-10-26T01:05:00Z");
        when(repository.retryAt(anyString())).thenReturn(blocked);
        for (String code : new String[] {null, "bad", "12345", "000001 "}) {
            AuthResult.Failure result = assertInstanceOf(AuthResult.Failure.class,
                service.login(peer, credentials.name(), credentials.phone(), code));
            assertEquals(AuthResult.Reason.RATE_LIMITED, result.reason());
            assertEquals(blocked, result.retryAt());
        }
        when(repository.recordIp(anyString())).thenReturn(new AuthRows.IpLimit(false, blocked.minusSeconds(200)));
        assertEquals(blocked, assertInstanceOf(AuthResult.Failure.class,
            service.login(peer, credentials.name(), credentials.phone(), "bad")).retryAt());
        verify(repository, never()).lockCode(any(), any());
        verify(repository, never()).recordFailure(anyString());
    }

    /**
     * 형식 오류는 IP에만 포함하고 조합 식별값이나 코드 실패를 만들지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void countsInvalidInput() {
        assertEquals(AuthResult.Reason.INVALID_INPUT, assertInstanceOf(AuthResult.Failure.class,
            service.login(peer, null, credentials.phone(), credentials.code())).reason());
        verify(repository).recordIp(anyString());
        verify(repository, never()).retryAt(anyString());
        verify(repository, never()).recordFailure(anyString());
        verify(transactions).run(any());
    }

    /**
     * HTTP 파싱 전용 실패 진입점도 IP 요청을 한 건 기록한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void countsMalformedRequest() {
        assertEquals(AuthResult.Reason.INVALID_INPUT, assertInstanceOf(AuthResult.Failure.class,
            service.rejectMalformed(peer)).reason());
        verify(repository).recordIp(anyString());
        verify(repository, never()).retryAt(anyString());
    }

    /**
     * IP 저장소 장애가 나면 코드 조회와 세션 발급까지 진행하지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void failsClosedOnStoreError() {
        when(repository.recordIp(anyString())).thenThrow(new AuthStoreException());
        assertThrows(AuthStoreException.class,
            () -> service.login(peer, credentials.name(), credentials.phone(), credentials.code()));
        verify(repository, never()).retryAt(anyString());
        verify(repository, never()).lockCode(any(), any());
    }

    /**
     * 형식이 틀린 토큰도 문맥 제거용 DB 경로로 전달하며 다른 자격을 비교하지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void rejectsInvalidSession() {
        assertEquals(AuthResult.Reason.SESSION_INVALID, assertInstanceOf(AuthResult.Failure.class,
            service.reverify(peer, "invalid", credentials.name(), credentials.phone(), credentials.code())).reason());
        verify(repository).authorize(null);
        verify(repository, never()).findCode(any(), any());
        verify(repository, never()).recordFailure(anyString());
    }

    /**
     * 코드가 맞아도 다른 사용자 자격이면 재확인을 거절하고 기존 세션은 유지한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void rejectsOtherOwner() {
        IssuedToken token = crypto.issueToken();
        UUID other = UUID.randomUUID();
        when(repository.authorize(token.digest())).thenReturn(Optional.of(new AuthRows.Session(userId, UUID.randomUUID())));
        when(repository.findCode(credentials.name(), credentials.phone())).thenReturn(Optional.of(
            new AuthRows.StoredCode(other, crypto.codeVerifier(other, credentials.code()))));
        assertEquals(AuthResult.Reason.AUTH_REJECTED, assertInstanceOf(AuthResult.Failure.class,
            service.reverify(peer, token.value(), credentials.name(), credentials.phone(), credentials.code())).reason());
        verify(repository).recordFailure(anyString());
        verify(repository, never()).lockCode(any(), any());
        verify(repository, never()).endSession(any());
        verify(repository, never()).openSession(any(), any());
    }

    /**
     * 세션 종료에서 인증 시도 제한을 증가시키거나 금융 자료를 조회하지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void endsOnlyCurrentSession() {
        IssuedToken token = crypto.issueToken();
        when(repository.endSession(token.digest())).thenReturn(true);
        assertEquals(AuthResult.LoggedOut.INSTANCE, service.logout(token.value()));
        verify(repository).endSession(token.digest());
        verify(repository, never()).recordIp(anyString());
        verify(transactions).run(any());
    }

    /**
     * 제한 상태와 민감 내부 값의 표현이 모순되거나 원문을 노출하지 않는지 검사한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void protectsInternalResults() {
        assertThrows(IllegalArgumentException.class, () -> new AuthResult.Failure(AuthResult.Reason.RATE_LIMITED, null));
        assertThrows(IllegalArgumentException.class,
            () -> new AuthResult.Failure(AuthResult.Reason.AUTH_REJECTED, Instant.now()));
        AuthRows.LoginAccount account = new AuthRows.LoginAccount(userId, credentials.name(), "private-verifier");
        assertFalse(account.toString().contains("private-verifier"));
        assertFalse(account.toString().contains(credentials.name()));
    }

    /**
     * 인증과 DB 프로필을 모두 명시해야 서비스가 등록되며 기본 bootstrap에는 요구하지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void requiresBothProfiles() {
        for (String[] profiles : new String[][] {{}, {"auth"}, {"database"}, {"auth", "database"}}) {
            try (AnnotationConfigApplicationContext context = new AnnotationConfigApplicationContext()) {
                context.getEnvironment().setActiveProfiles(profiles);
                context.registerBean(AuthRepository.class, () -> repository);
                context.registerBean(AuthTransactions.class, () -> transactions);
                context.registerBean(AuthCrypto.class, () -> crypto);
                context.register(AuthService.class);
                context.refresh();
                assertEquals(profiles.length == 2 ? 1 : 0, context.getBeansOfType(AuthService.class).size());
            }
        }
    }
}
