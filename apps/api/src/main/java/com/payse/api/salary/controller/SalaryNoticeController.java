package com.payse.api.salary.controller;

import com.payse.api.auth.controller.AuthHttpInput;
import com.payse.api.auth.controller.AuthHttpResponse;
import com.payse.api.auth.dto.AuthResponse;
import com.payse.api.auth.error.AuthStoreException;
import com.payse.api.finance.controller.FinancialHttpInput;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.salary.dto.SalaryNotice;
import com.payse.api.salary.service.SalaryNoticeService;
import jakarta.servlet.http.HttpServletRequest;
import java.util.Set;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 기존 Snapshot 형식을 유지하면서 급여 건별 안내 상태만 독립적으로 공개한다.
 * @created 2026-10-30
 * @usedBy Spring MVC 요청 매핑
 */
@RestController
@Profile("database & auth & finance & salary-notices")
public final class SalaryNoticeController {
    private final SalaryNoticeService service;
    private final AuthHttpInput auth;
    private final FinancialHttpInput input;

    /**
     * 세션 파서·본문 없는 금융 입력 검사와 급여 안내 서비스를 주입한다.
     * @created 2026-10-30
     * @usedBy Spring 생성자 주입
     */
    public SalaryNoticeController(SalaryNoticeService service, AuthHttpInput auth, FinancialHttpInput input) {
        this.service = service;
        this.auth = auth;
        this.input = input;
    }

    /**
     * 지정된 명목 회차의 표시 상태를 반환한다. 다른 사용자의 ID는 입력으로 받지 않는다.
     * @created 2026-10-30
     * @usedBy GET /salary-notices/{payMonth}
     */
    @GetMapping("/salary-notices/{payMonth}")
    public ResponseEntity<SalaryNotice> read(@PathVariable String payMonth, HttpServletRequest request) {
        return ok(service.read(auth.bearer(request), payMonth, () -> requireEmpty(request)));
    }

    /**
     * 고정된 회차별 닫기 자원을 멱등 저장한다. 원천 confirmation을 수정하는 API가 아니다.
     * @created 2026-10-30
     * @usedBy PUT /salary-notices/{payMonth}/dismissal
     */
    @PutMapping("/salary-notices/{payMonth}/dismissal")
    public ResponseEntity<SalaryNotice> dismiss(@PathVariable String payMonth, HttpServletRequest request) {
        return ok(service.dismiss(auth.bearer(request), payMonth, () -> requireEmpty(request)));
    }

    /**
     * 사용자 ID·시각·입금 상태·금융 버전 등을 본문/쿼리로 주입하는 요청을 거절한다.
     * @created 2026-10-30
     * @usedBy read, dismiss의 인증 이후 지연 검사
     */
    private void requireEmpty(HttpServletRequest request) {
        input.cursor(request, false);
        for (String header : Set.of("Content-Encoding", "Payse-Expected-Data-Version",
                "Payse-Rule-Version", "Idempotency-Key")) {
            if (request.getHeader(header) != null) throw new FinancialException(422, "VALIDATION_FAILED");
        }
    }

    /**
     * 표시 상태도 인증 사용자 전용이므로 중간 캐시 저장을 금지한다.
     * @created 2026-10-30
     * @usedBy read, dismiss
     */
    private ResponseEntity<SalaryNotice> ok(SalaryNotice result) {
        return ResponseEntity.ok().header(HttpHeaders.CACHE_CONTROL, "no-store").body(result);
    }

    /**
     * 기존 인증·검증 오류 봉투를 유지한다.
     * @created 2026-10-30
     * @usedBy Spring MVC 오류 처리
     */
    @ExceptionHandler(FinancialException.class)
    public ResponseEntity<AuthResponse.Error> failure(FinancialException failure) {
        return AuthHttpResponse.error(failure.status(), failure.code(), null);
    }

    /**
     * DB 장애나 미완료 저장은 성공으로 바꾸지 않고 내부 SQL 없이 알린다.
     * @created 2026-10-30
     * @usedBy Spring MVC 저장 오류 처리
     */
    @ExceptionHandler({AuthStoreException.class, RuntimeException.class})
    public ResponseEntity<AuthResponse.Error> unavailable() {
        return AuthHttpResponse.error(503, "TEMPORARILY_UNAVAILABLE", null);
    }
}

