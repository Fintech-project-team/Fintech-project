package com.payse.api.salary.dto;

import java.time.Instant;
import java.util.UUID;

/**
 * 한 급여 회차의 큰 안내를 접은 상태만 전달한다. 급여 확인·계산 상태가 아니다.
 * @created 2026-10-30
 * @usedBy SalaryNoticeService, SalaryNoticeController
 */
public record SalaryNotice(String contractVersion, UUID userId, String payMonth,
        boolean dismissed, Instant dismissedAt) {}

