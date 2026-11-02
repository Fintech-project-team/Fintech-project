package com.payse.api.health.controller;

import com.payse.api.constants.ApiConfigConstants.Server;
import com.payse.api.health.dto.HealthResponse;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 금융 자료 없이 프로세스 생존 여부만 반환한다.
 * @created 2026-10-20
 * @usedBy 로컬 실행 확인, 배포 생존 검사
 */
@RestController
public class HealthController {

    /**
     * 상태 없는 생존 확인 결과를 반환한다.
     * @created 2026-10-20
     * @usedBy HTTP GET /internal/health/live
     * @return DB 상태와 무관한 프로세스 생존 응답
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리
     */
    @GetMapping("/internal/health/live")
    public HealthResponse live() {
        return new HealthResponse(Server.UP);
    }
}
