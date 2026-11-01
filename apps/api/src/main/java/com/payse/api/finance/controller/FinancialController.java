package com.payse.api.finance.controller;

import com.payse.api.auth.controller.AuthHttpInput;
import com.payse.api.auth.controller.AuthHttpResponse;
import com.payse.api.auth.dto.AuthResponse;
import com.payse.api.auth.error.AuthStoreException;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.error.TransactionStoreException;
import com.payse.api.finance.service.FinancialService;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.databind.node.ObjectNode;

/**
 * 명시적으로 활성화한 v3 금융 조회·설정 경로를 공개한다. 인증·권한은 서비스에서 검사한다.
 * @created 2026-10-29
 * @usedBy Spring MVC 요청 매핑
 */
@RestController
@Profile("database & auth & finance")
public final class FinancialController {
    private final FinancialService service;
    private final FinancialHttpInput input;
    private final AuthHttpInput auth;

    /**
     * 금융 서비스와 HTTP 파서 및 기존 Bearer 파서를 주입한다.
     * @created 2026-10-29
     * @usedBy Spring 생성자 주입
     */
    public FinancialController(FinancialService service, FinancialHttpInput input, AuthHttpInput auth) {
        this.service = service;
        this.input = input;
        this.auth = auth;
    }

    /**
     * DB의 현재 공개 스냅샷과 첫 거래 페이지를 반환한다.
     * @created 2026-10-29
     * @usedBy GET /snapshot
     */
    @GetMapping("/snapshot")
    public ResponseEntity<ObjectNode> snapshot(HttpServletRequest request) {
        return ok(service.read(auth.bearer(request), () -> input.cursor(request, false), false));
    }

    /**
     * 검증된 불투명 cursor로 같은 자료 버전의 후속 페이지를 반환한다.
     * @created 2026-10-29
     * @usedBy GET /transactions
     */
    @GetMapping("/transactions")
    public ResponseEntity<ObjectNode> page(HttpServletRequest request) {
        return ok(service.read(auth.bearer(request), () -> input.cursor(request, true), true));
    }

    /**
     * 확정된 쓰기 경로만 서비스의 원자 저장으로 전달한다. 메서드별 허용 경로는 입력에서도 검사한다.
     * @created 2026-10-29
     * @usedBy 공통 HTTP 계약 §3·§4 금융 쓰기 경로
     */
    @RequestMapping(path = {"/institution-links", "/account-selection", "/accounts/{id}", "/settings",
        "/obligations", "/obligations/{id}", "/obligations/{id}/cancel",
        "/reserves", "/reserves/{id}", "/reserves/{id}/cancel"},
        method = {RequestMethod.POST, RequestMethod.PATCH, RequestMethod.DELETE})
    public ResponseEntity<ObjectNode> write(HttpServletRequest request) {
        String path = request.getRequestURI().substring(request.getContextPath().length());
        return ok(service.write(auth.bearer(request), request.getMethod(), path, () -> input.read(request)));
    }

    /**
     * 허용된 공개 오류와 캐시 금지 헤더를 반환한다.
     * @created 2026-10-29
     * @usedBy Spring MVC 금융 오류 처리
     */
    @ExceptionHandler(FinancialException.class)
    public ResponseEntity<AuthResponse.Error> failure(FinancialException failure) {
        return AuthHttpResponse.error(failure.status(), failure.code(), null);
    }

    /**
     * DB·커밋 장애는 SQL·입력값 없이 재시도 가능한 실패로 전달한다.
     * @created 2026-10-29
     * @usedBy Spring MVC 저장 예외 처리
     */
    @ExceptionHandler({AuthStoreException.class, TransactionStoreException.class, RuntimeException.class})
    public ResponseEntity<AuthResponse.Error> unavailable() {
        return AuthHttpResponse.error(503, "TEMPORARILY_UNAVAILABLE", null);
    }

    /**
     * 금융 성공 응답도 중간 캐시에 저장하지 않는다.
     * @created 2026-10-29
     * @usedBy snapshot, page, write
     */
    private ResponseEntity<ObjectNode> ok(ObjectNode body) {
        return ResponseEntity.ok().header(HttpHeaders.CACHE_CONTROL, "no-store").body(body);
    }
}
