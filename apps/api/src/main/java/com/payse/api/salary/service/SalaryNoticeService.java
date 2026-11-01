package com.payse.api.salary.service;

import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.salary.dto.SalaryNotice;
import com.payse.api.salary.mapper.SalaryNoticeRepository;
import com.payse.api.salary.vo.SalaryMonth;
import java.time.Instant;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Service;

/**
 * 현재 인증 사용자의 급여 회차별 안내 기록을 처리한다. 원천 근거·급여 날짜·가용 금액은 바꾸지 않는다.
 * @created 2026-10-30
 * @usedBy SalaryNoticeController
 */
@Service
@Profile("database & auth & finance & salary-notices")
public final class SalaryNoticeService {
    private final AuthTransactions transactions;
    private final AuthRepository auth;
    private final AuthCrypto crypto;
    private final SalaryNoticeRepository notices;

    /**
     * 기존 인증과 트랜잭션을 재사용하고 기능 활성화에 필요한 DB 준비를 확인한다.
     * @created 2026-10-30
     * @usedBy Spring 생성자 주입
     */
    public SalaryNoticeService(AuthTransactions transactions, AuthRepository auth, AuthCrypto crypto,
            SalaryNoticeRepository notices) {
        this.transactions = transactions;
        this.auth = auth;
        this.crypto = crypto;
        this.notices = notices;
        transactions.run(() -> { notices.verifySchema(); return null; });
    }

    /**
     * 세션 검증 이후 회차·HTTP 입력을 검사한다. 원천이 없어도 안내 저장 여부만 조회한다.
     * @created 2026-10-30
     * @usedBy SalaryNoticeController.read
     */
    public SalaryNotice read(String token, String payMonth, Runnable validateRequest) {
        return transactions.run(() -> {
            AuthRows.Session session = authorize(token);
            SalaryMonth month = new SalaryMonth(payMonth);
            validateRequest.run();
            return response(session.userId(), month, notices.find(session.userId(), month).orElse(null));
        });
    }

    /**
     * 한 회차의 큰 안내만 닫는다. 커밋 성공 후 반환하며 중복·응답 유실 재전송에도 같은 결과다.
     * @created 2026-10-30
     * @usedBy SalaryNoticeController.dismiss
     */
    public SalaryNotice dismiss(String token, String payMonth, Runnable validateRequest) {
        return transactions.run(() -> {
            AuthRows.Session session = authorize(token);
            SalaryMonth month = new SalaryMonth(payMonth);
            validateRequest.run();
            return response(session.userId(), month, notices.dismiss(session.userId(), month));
        });
    }

    /**
     * 무효 토큰도 기존 DB 인증 함수를 거쳐 이전 사용자 문맥을 비운 뒤 거절한다.
     * @created 2026-10-30
     * @usedBy read, dismiss
     */
    private AuthRows.Session authorize(String token) {
        String digest;
        try { digest = crypto.tokenDigest(token); }
        catch (IllegalArgumentException failure) { digest = null; }
        return auth.authorize(digest).orElseThrow(() -> new FinancialException(401, "SESSION_INVALID"));
    }

    /**
     * DB 기록 유무에서 표시 플래그만 파생한다. 별도 boolean 컬럼과 중복 저장하지 않는다.
     * @created 2026-10-30
     * @usedBy read, dismiss
     */
    private SalaryNotice response(UUID userId, SalaryMonth month, Instant dismissedAt) {
        return new SalaryNotice("PAYSE-SALARY-NOTICE-1", userId, month.value(), dismissedAt != null, dismissedAt);
    }
}

