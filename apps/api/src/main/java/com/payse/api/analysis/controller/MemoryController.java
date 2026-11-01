package com.payse.api.analysis.controller;

import com.payse.api.analysis.service.MemoryCatalog;
import com.payse.api.analysis.vo.MemoryQuery;
import com.payse.api.auth.controller.AuthHttpInput;
import com.payse.api.auth.controller.AuthHttpResponse;
import com.payse.api.auth.dto.AuthResponse;
import com.payse.api.auth.error.AuthStoreException;
import com.payse.api.finance.error.FinancialException;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.databind.node.ObjectNode;

/**
 * 사용자 소유 AI 기억의 확인·삭제용 목록을 제공한다. 분석 재사용은 별도 API에서 검증한다.
 * @created 2026-11-01
 * @usedBy Spring MVC analysis 프로필
 */
@RestController
@Profile("database & auth & finance & analysis")
public final class MemoryController {
    private final MemoryCatalog catalog;
    private final AuthHttpInput auth;

    /**
     * 상태 없는 관리 조회 서비스와 기존 Bearer 파서를 주입한다.
     * @created 2026-11-01
     * @usedBy Spring 생성자 주입
     */
    public MemoryController(MemoryCatalog catalog, AuthHttpInput auth) {
        this.catalog = catalog;
        this.auth = auth;
    }

    /**
     * 인증을 먼저 수행하며 관리 응답이 중간 캐시에 저장되지 않게 한다.
     * @created 2026-11-01
     * @usedBy GET /analysis-memories
     */
    @GetMapping("/analysis-memories")
    public ResponseEntity<ObjectNode> list(HttpServletRequest request) {
        ObjectNode body = catalog.read(auth.bearer(request), () -> query(request));
        return ResponseEntity.ok().header(HttpHeaders.CACHE_CONTROL, "no-store").body(body);
    }

    /**
     * 인증된 GET의 본문·압축 전송을 거절하고 query 필터만 해석한다.
     * @created 2026-11-01
     * @usedBy list
     */
    private MemoryQuery query(HttpServletRequest request) {
        try {
            if (request.getHeader("Content-Encoding") != null || request.getInputStream().read() != -1) {
                throw new FinancialException(422, "VALIDATION_FAILED");
            }
        } catch (IOException failure) { throw new FinancialException(400, "INVALID_JSON"); }
        return MemoryQuery.parse(request.getParameterMap());
    }

    /**
     * 인증·필터·페이지 충돌을 기존 오류 봉투로 전달한다.
     * @created 2026-11-01
     * @usedBy Spring MVC 예외 처리
     */
    @ExceptionHandler(FinancialException.class)
    public ResponseEntity<AuthResponse.Error> failure(FinancialException failure) {
        return AuthHttpResponse.error(failure.status(), failure.code(), null);
    }

    /**
     * 저장·복호화 실패를 빈 성공 목록으로 바꾸거나 내부 정보를 노출하지 않는다.
     * @created 2026-11-01
     * @usedBy Spring MVC 예외 처리
     */
    @ExceptionHandler({AuthStoreException.class, RuntimeException.class})
    public ResponseEntity<AuthResponse.Error> unavailable() {
        return AuthHttpResponse.error(503, "TEMPORARILY_UNAVAILABLE", null);
    }
}
