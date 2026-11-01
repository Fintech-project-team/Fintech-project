package com.payse.api.auth.service;

import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.dto.AuthInput;
import com.payse.api.auth.dto.AuthResult;
import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.error.AuthInputException;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.auth.vo.AuthCredentials;
import com.payse.api.auth.vo.IssuedToken;
import java.net.InetAddress;
import java.time.Instant;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Function;
import java.util.function.Supplier;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Service;

/**
 * 인증 요청의 제한·코드 대조·세션 전이를 순서대로 커밋한다. 요청 상태를 필드에 보관하지 않는다.
 * HTTP 입력은 IP 기록 커밋 이후 지연 해석하며 금융 원천과 로컬 PIN을 변경하지 않는다.
 * @created 2026-10-26
 * @usedBy AuthController, AuthServiceTest, SessionJdbcTest
 * @modified 2026-10-28 - HTTP 입력 지연 해석·재확인 토큰 우선 처리 연결
 */
@Service
@Profile("database & auth")
public final class AuthService {
    private final AuthRepository repository;
    private final AuthTransactions transactions;
    private final AuthCrypto crypto;

    /**
     * 같은 DB의 저장·트랜잭션 기반과 서버 암호 연산을 주입한다.
     * @created 2026-10-26
     * @usedBy Spring 생성자 주입, AuthServiceTest, SessionJdbcTest
     */
    public AuthService(AuthRepository repository, AuthTransactions transactions, AuthCrypto crypto) {
        this.repository = Objects.requireNonNull(repository);
        this.transactions = Objects.requireNonNull(transactions);
        this.crypto = Objects.requireNonNull(crypto);
    }

    /**
     * IP 기록을 먼저 커밋하고 검증된 조합으로 세션을 생성한다. 원문은 이 요청에서만 사용한다.
     * @created 2026-10-26
     * @usedBy AuthServiceTest, SessionJdbcTest
     * @modified 2026-10-28 - 공통 지연 입력 경로에 위임
     * @param peer 서버 연결 또는 신뢰 프록시 어댑터가 확인한 IP; 임의 헤더/DNS 입력 아님
     * @return 커밋된 최초 로그인 또는 원문 없는 실패 결과
     */
    public AuthResult login(InetAddress peer, String name, String phone, String code) {
        return login(peer, () -> new AuthInput(name, phone, code));
    }

    /**
     * IP 기록을 커밋한 뒤 요청을 읽는다. 파싱 실패도 정확히 한 번 집계한다.
     * @created 2026-10-28
     * @usedBy AuthController.login, AuthService.login
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    public AuthResult login(InetAddress peer, Supplier<AuthInput> input) {
        AuthRows.IpLimit ip = recordIp(peer);
        return read(ip, input, this::signIn);
    }

    /**
     * 같은 세션의 소유자 자격만 재확인한다. 새 세션·토큰 발급이나 실패 시 기존 세션 종료는 없다.
     * @created 2026-10-26
     * @usedBy SessionJdbcTest
     * @modified 2026-10-28 - 지연 입력·토큰 우선 처리 경로에 위임
     * @param token 현재 클라이언트 토큰 원문; 로그/DB에 저장하지 않음
     * @return 동일 세션 재확인 또는 기존 오류 의미의 실패
     */
    public AuthResult reverify(InetAddress peer, String token, String name, String phone, String code) {
        return reverify(peer, () -> token, () -> new AuthInput(name, phone, code));
    }

    /**
     * IP 커밋 후 토큰부터 확인한다. 최종 자격 대조 트랜잭션에서도 세션을 다시 검증한다.
     * 사전 사용자 잠금은 별도 트랜잭션에서 끝내 조합→사용자 잠금 순서를 뒤집지 않는다.
     * @created 2026-10-28
     * @usedBy AuthController.reverify, AuthService.reverify
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    public AuthResult reverify(InetAddress peer, Supplier<String> tokenInput, Supplier<AuthInput> input) {
        AuthRows.IpLimit ip = recordIp(peer);
        String token = tokenInput.get();
        boolean active = transactions.run(() -> repository.authorize(digest(token)).isPresent());
        if (!active) return ip.allowed() ? failure(AuthResult.Reason.SESSION_INVALID) : limited(ip.retryAt());
        return read(ip, input, credentials -> confirm(token, credentials));
    }

    /**
     * 제한 기록 이후 파싱하며 파서 오류 원문은 외부로 전파하지 않는다.
     * @created 2026-10-28
     * @usedBy AuthService.login, reverify
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    private AuthResult read(AuthRows.IpLimit ip, Supplier<AuthInput> source,
            Function<AuthCredentials, AuthResult> action) {
        AuthInput input;
        try {
            input = source.get();
        } catch (AuthInputException invalid) {
            return ip.allowed() ? failure(invalid.reason()) : limited(ip.retryAt());
        }
        return attempt(ip, input.name(), input.phone(), input.code(), action);
    }

    /**
     * 현재 토큰의 세션만 종료한다. 이미 무효인 토큰을 종료 성공으로 표시하지 않는다.
     * @created 2026-10-26
     * @usedBy AuthController.logout, SessionJdbcTest
     * @return 종료 커밋 결과 또는 SESSION_INVALID
     */
    public AuthResult logout(String token) {
        return transactions.run(() -> repository.endSession(digest(token))
            ? AuthResult.LoggedOut.INSTANCE : failure(AuthResult.Reason.SESSION_INVALID));
    }

    /**
     * 본문을 해석할 수 없는 요청도 IP 한 건으로 저장한다. HTTP 어댑터는 login/reverify와 중복 호출하지 않는다.
     * @created 2026-10-26
     * @usedBy AuthServiceTest, 미연결: 예정 인증 JSON 파싱 실패 처리
     * @return 형식 실패 또는 IP 제한 결과; 실제 HTTP 필터를 구현한 것은 아님
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    public AuthResult rejectMalformed(InetAddress peer) {
        AuthRows.IpLimit ip = recordIp(peer);
        return ip.allowed() ? failure(AuthResult.Reason.INVALID_INPUT) : limited(ip.retryAt());
    }

    /**
     * 선행 IP 커밋 뒤 입력을 검사하고 조합 잠금부터 시작하는 별도 트랜잭션을 실행한다.
     * @created 2026-10-26
     * @usedBy AuthService.login, reverify
     * @modified 2026-10-28 - 이미 커밋한 IP 결과를 받아 중복 집계를 방지
     * @return 제한 기록과 업무 처리가 커밋된 결과; DB 장애는 성공으로 바꾸지 않음
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    private AuthResult attempt(AuthRows.IpLimit ip, String name, String phone, String code,
            Function<AuthCredentials, AuthResult> action) {
        String normalizedName;
        String normalizedPhone;
        try {
            normalizedName = AuthCredentials.normalizeName(name);
            normalizedPhone = AuthCredentials.normalizePhone(phone);
        } catch (IllegalArgumentException invalid) {
            return ip.allowed() ? failure(AuthResult.Reason.INVALID_INPUT) : limited(ip.retryAt());
        }
        String key = crypto.combinationLimitKey(normalizedName, normalizedPhone);
        return transactions.run(() -> {
            Instant blockedUntil = repository.retryAt(key);
            Instant retryAt = later(ip.retryAt(), blockedUntil);
            if (retryAt != null) return limited(retryAt);
            AuthCredentials credentials;
            try {
                credentials = new AuthCredentials(normalizedName, normalizedPhone, code);
            } catch (IllegalArgumentException invalid) {
                // 코드 형식을 바꿔도 이름·전화번호 조합의 기존 차단을 우회하지 못한다.
                return failure(AuthResult.Reason.INVALID_INPUT);
            }
            return action.apply(credentials);
        });
    }

    /**
     * 사용자 행 잠금 뒤 읽은 현재 verifier를 대조하고 활성 세션이 없을 때만 발급한다.
     * @created 2026-10-26
     * @usedBy AuthService.login의 조합 트랜잭션
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    private AuthResult signIn(AuthCredentials credentials) {
        Optional<AuthRows.LoginAccount> account = repository.lockCode(credentials.name(), credentials.phone());
        if (account.isEmpty()) {
            compareMissing(credentials.code());
            return rejectCredentials(credentials);
        }
        AuthRows.LoginAccount stored = account.get();
        if (!crypto.verifyCode(stored.userId(), credentials.code(), stored.verifier())) {
            return rejectCredentials(credentials);
        }
        IssuedToken token = crypto.issueToken();
        Optional<AuthRows.OpenedSession> opened = repository.openSession(stored.userId(), token.digest());
        if (opened.isEmpty()) return failure(AuthResult.Reason.AUTH_REJECTED);
        AuthRows.OpenedSession session = opened.get();
        return new AuthResult.Login(session.userId(), session.name(), session.sessionId(), token.value(), session.issuedAt());
    }

    /**
     * 토큰 소유자만 잠근 후 입력 조합의 소유권과 코드를 대조해 교차 사용자 잠금 순환을 피한다.
     * @created 2026-10-26
     * @usedBy AuthService.reverify의 조합 트랜잭션
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    private AuthResult confirm(String token, AuthCredentials credentials) {
        Optional<AuthRows.Session> current = repository.authorize(digest(token));
        if (current.isEmpty()) return failure(AuthResult.Reason.SESSION_INVALID);
        Optional<AuthRows.StoredCode> account = repository.findCode(credentials.name(), credentials.phone());
        if (account.isEmpty()) {
            compareMissing(credentials.code());
            return rejectCredentials(credentials);
        }
        AuthRows.StoredCode stored = account.get();
        boolean matches = crypto.verifyCode(stored.userId(), credentials.code(), stored.verifier());
        if (!matches || !stored.userId().equals(current.get().userId())) return rejectCredentials(credentials);
        return new AuthResult.Verified(current.get().userId(), current.get().sessionId());
    }

    /**
     * 실제 자격 대조 실패만 저장하고 제한 기록이 롤백되지 않도록 정상 결과로 반환한다.
     * @created 2026-10-26
     * @usedBy AuthService.signIn, confirm
     */
    private AuthResult rejectCredentials(AuthCredentials credentials) {
        String key = crypto.combinationLimitKey(credentials.name(), credentials.phone());
        Instant retryAt = repository.recordFailure(key);
        return retryAt == null ? failure(AuthResult.Reason.AUTH_REJECTED) : limited(retryAt);
    }

    /**
     * 존재하지 않는 계정에도 코드 비교에 대응하는 HMAC 연산을 수행한다. 일정 응답 시간을 보장하지 않는다.
     * @created 2026-10-26
     * @usedBy AuthService.signIn, confirm
     */
    private void compareMissing(String code) { crypto.codeVerifier(UUID.randomUUID(), code); }

    /**
     * 토큰 형식 오류도 DB authorize의 문맥 제거 경로로 전달한다.
     * @created 2026-10-26
     * @usedBy AuthService.logout, confirm
     */
    private String digest(String token) {
        try {
            return crypto.tokenDigest(token);
        } catch (IllegalArgumentException invalid) {
            return null;
        }
    }

    /**
     * 제한 HMAC만 저장하며 IP 트랜잭션의 연결을 반환한 후 자격 처리로 진행한다.
     * @created 2026-10-26
     * @usedBy AuthService.attempt, rejectMalformed
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    private AuthRows.IpLimit recordIp(InetAddress peer) {
        String key = crypto.ipLimitKey(peer);
        return transactions.run(() -> repository.recordIp(key));
    }

    /**
     * 두 제한의 해제 시각 중 늦은 값을 선택하며 금융 날짜 계산과는 무관하다.
     * @created 2026-10-26
     * @usedBy AuthService.attempt
     */
    private static Instant later(Instant first, Instant second) {
        if (first == null) return second;
        return second == null || first.isAfter(second) ? first : second;
    }

    /**
     * 재시도 시각이 필요 없는 업무 실패를 만든다.
     * @created 2026-10-26
     * @usedBy AuthService 인증 거절 처리
     */
    private static AuthResult.Failure failure(AuthResult.Reason reason) { return new AuthResult.Failure(reason, null); }

    /**
     * DB 제한 시각을 보존한다. HTTP Retry-After 초 변환은 응답 어댑터의 책임이다.
     * @created 2026-10-26
     * @usedBy AuthService.attempt, rejectCredentials, rejectMalformed
     */
    private static AuthResult.Failure limited(Instant retryAt) { return new AuthResult.Failure(AuthResult.Reason.RATE_LIMITED, retryAt); }
}
