package com.payse.api.analysis.controller;

import com.payse.api.analysis.service.AnalysisJobs;
import com.payse.api.auth.controller.AuthHttpInput;
import com.payse.api.auth.controller.AuthHttpResponse;
import com.payse.api.auth.dto.AuthResponse;
import com.payse.api.auth.error.AuthStoreException;
import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.finance.controller.FinancialHttpInput;
import com.payse.api.finance.error.FinancialException;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.util.Collections;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.databind.node.ObjectNode;

/**
 * 금융 Snapshot과 분리된 분석 접수·관찰·복구·기억 삭제 경로다.
 * @created 2026-11-01
 * @usedBy Spring MVC analysis 프로필
 */
@RestController
@Profile("database & auth & finance & analysis")
public final class AnalysisController {

    private final AnalysisJobs jobs;
    private final AuthHttpInput auth;
    private final FinancialHttpInput input;

    /**
     * 기존 인증과 확정된 64 KiB JSON 입력 파서를 재사용한다.
     * @created 2026-11-01
     * @usedBy Spring 생성자 주입
     */
    public AnalysisController(AnalysisJobs jobs, AuthHttpInput auth, FinancialHttpInput input) {
        this.jobs = jobs;
        this.auth = auth;
        this.input = input;
    }

    /**
     * 최소 descriptor만 접수하며 성공이 모델 실행 완료를 뜻하지 않는다.
     * @created 2026-11-01
     * @usedBy POST /analysis-jobs
     */
    @PostMapping("/analysis-jobs")
    public ResponseEntity<ObjectNode> accept(HttpServletRequest request) {
        return response(jobs.accept(auth.bearer(request), () -> input.read(request)));
    }

    /**
     * 상태와 단기 입력 허용만 전달하며 모델·금융 저장을 실행하지 않는다.
     * @created 2026-11-01
     * @usedBy GET /analysis-jobs/{id}
     */
    @GetMapping("/analysis-jobs/{id}")
    public ResponseEntity<ObjectNode> status(@PathVariable String id, HttpServletRequest request) {
        return response(jobs.read(auth.bearer(request), id, () -> input.cursor(request, false)));
    }

    /**
     * 최초 입력 제출을 재검증하며 같은 키는 같은 시도를 관찰한다.
     * @created 2026-11-01
     * @usedBy POST /analysis-jobs/{id}/input
     */
    @PostMapping("/analysis-jobs/{id}/input")
    public ResponseEntity<ObjectNode> input(@PathVariable String id, HttpServletRequest request) {
        return response(jobs.submit(auth.bearer(request), id, false, () -> input.read(request)));
    }

    /**
     * 사용자 명시 재시도만 접수하고 완료 불명 요청의 중복 위험 확인을 검사한다.
     * @created 2026-11-01
     * @usedBy POST /analysis-jobs/{id}/retry
     */
    @PostMapping("/analysis-jobs/{id}/retry")
    public ResponseEntity<ObjectNode> retry(@PathVariable String id, HttpServletRequest request) {
        return response(jobs.submit(auth.bearer(request), id, true, () -> input.read(request)));
    }

    /**
     * 현재 근거를 대조한 결과 조회다. POST지만 모델 전송이나 금융 변경을 하지 않는다.
     * @created 2026-11-01
     * @usedBy POST /analysis-results/query
     */
    @PostMapping("/analysis-results/query")
    public ResponseEntity<ObjectNode> query(HttpServletRequest request) {
        return response(jobs.query(auth.bearer(request), () -> input.read(request)));
    }

    /**
     * 지정 기억의 동일 근거 사본을 차단하며 금융 원천은 삭제하지 않는다.
     * @created 2026-11-01
     * @usedBy DELETE /analysis-memories/{id}
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    @DeleteMapping("/analysis-memories/{id}")
    public ResponseEntity<Void> delete(@PathVariable String id, HttpServletRequest request) {
        jobs.deleteMemory(auth.bearer(request), id, () -> deleteKey(request));
        return ResponseEntity.noContent()
            .header(HttpHeaders.CACHE_CONTROL, ApiConfigConstants.Analysis.NO_STORE)
            .build();
    }

    /**
     * 삭제는 단일 멱등 헤더와 빈 본문만 허용하고 금융 쓰기 W 헤더를 요구하지 않는다.
     * @created 2026-11-01
     * @usedBy delete의 인증 후 지연 파서
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private String deleteKey(HttpServletRequest request) {
        try {
            if (!request.getParameterMap().isEmpty() || request.getInputStream().read() != -1
                || request.getHeader(ApiConfigConstants.Analysis.CONTENT_ENCODING) != null
                || request
                    .getHeader(ApiConfigConstants.Analysis.PAYSE_EXPECTED_DATA_VERSION) != null
                || request.getHeader(ApiConfigConstants.Analysis.PAYSE_RULE_VERSION) != null) {
                throw new FinancialException(422, ApiCodeConstants.Analysis.VALIDATION_FAILED);
            }
        } catch (IOException failure) {
            throw new FinancialException(400, ApiCodeConstants.Analysis.INVALID_JSON);
        }

        var keys = Collections
            .list(request.getHeaders(ApiConfigConstants.Analysis.IDEMPOTENCY_KEY));
        if (keys.size() != 1) {
            throw new FinancialException(422, ApiCodeConstants.Analysis.VALIDATION_FAILED);
        }

        return keys.getFirst();
    }

    /**
     * 사용자별 분석 결과가 브라우저·중간 프록시 캐시에 저장되지 않게 한다.
     * @created 2026-11-01
     * @usedBy 모든 조회·접수 경로
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private ResponseEntity<ObjectNode> response(AnalysisJobs.Reply reply) {
        return ResponseEntity.status(reply.status())
            .header(HttpHeaders.CACHE_CONTROL, ApiConfigConstants.Analysis.NO_STORE)
            .body(reply.body());
    }

    /**
     * 기존 인증·업무 검증 오류 봉투를 유지한다.
     * @created 2026-11-01
     * @usedBy Spring MVC 예외 처리
     */
    @ExceptionHandler(FinancialException.class)
    public ResponseEntity<AuthResponse.Error> failure(FinancialException failure) {
        return AuthHttpResponse.error(failure.status(), failure.code(), null);
    }

    /**
     * 저장·암호화 장애의 SQL·본문·키를 외부 응답에 넣지 않는다.
     * @created 2026-11-01
     * @usedBy Spring MVC 예외 처리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    @ExceptionHandler({ AuthStoreException.class, RuntimeException.class })
    public ResponseEntity<AuthResponse.Error> unavailable() {
        return AuthHttpResponse.error(503, ApiCodeConstants.Analysis.TEMPORARILY_UNAVAILABLE, null);
    }
}
