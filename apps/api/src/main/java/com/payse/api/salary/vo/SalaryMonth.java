package com.payse.api.salary.vo;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.finance.error.FinancialException;

/**
 * 안내가 속하는 명목 급여 회차만 검증한다. 예정일이나 다음 급여 회차를 계산하지 않는다.
 * @created 2026-10-30
 * @usedBy SalaryNoticeService, SalaryMonthTest
 */
public record SalaryMonth(String value) {

    /**
     * 기존 payMonth와 같은 0001~9999년의 YYYY-MM 형식을 요구한다.
     * @created 2026-10-30
     * @usedBy SalaryNoticeService, SalaryMonthTest
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    public SalaryMonth {
        if (value == null || !value.matches("[0-9]{4}-(0[1-9]|1[0-2])")
            || value.startsWith(ApiConfigConstants.Salary.INVALID_YEAR)) {
            throw new FinancialException(422, ApiCodeConstants.Salary.VALIDATION_FAILED);
        }
    }
}
