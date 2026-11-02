package com.payse.api.finance.dto;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.finance.error.FinancialException;
import java.time.LocalDate;

/**
 * 거래 목록의 선택적 조회 기간과 불투명 후속 위치를 보관한다. 원천 확보 범위를 변경하지 않는다.
 * @created 2026-11-01
 * @usedBy FinancialHttpInput.transactions, FinancialService.transactions,
 * FinancialProjection.project
 */
public record TransactionQuery(String cursor, LocalDate startDate, LocalDate endDate) {
    /**
     * 기간은 양쪽 날짜가 함께 있어야 하며 실제 달력의 오름차순 범위만 허용한다.
     * @created 2026-11-01
     * @usedBy FinancialHttpInput.transactions, FinancialService.read, FinancialProjection.project
     * @modified 2026-11-02 - 날짜 쌍 누락과 범위를 분리하고 양쪽 null을 명시 검사
     */
    public TransactionQuery {
        if ((startDate == null) != (endDate == null)) {
            throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
        }

        if (startDate != null && endDate != null
            && (startDate.getYear() < 1 || endDate.getYear() > 9999
                || startDate.isAfter(endDate))) {
            throw new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
        }
    }

    /**
     * 명시 조회 기간을 기존 coverage 기반 페이지와 구분한다.
     * @created 2026-11-01
     * @usedBy FinancialService.snapshot
     */
    public boolean hasPeriod() {
        return startDate != null;
    }
}
