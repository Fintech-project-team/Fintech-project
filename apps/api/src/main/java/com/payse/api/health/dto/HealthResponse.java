package com.payse.api.health.dto;

/**
 * 프로세스 생존 확인 응답이다. DB 준비·로그인·금융 기능 완료를 뜻하지 않는다.
 * @created 2026-10-20
 * @usedBy HealthController.live
 * @param status 프로세스 응답 가능 상태 UP
 */
public record HealthResponse(String status) {}
