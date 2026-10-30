package com.payse.api.salary.vo;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.finance.error.FinancialException;
import org.junit.jupiter.api.Test;

/**
 * 원천과 같은 회차 형식을 유지하고 날짜·공백·미확인을 임의 보충하지 않는지 검사한다.
 * @created 2026-10-30
 * @usedBy Gradle JUnit
 */
class SalaryMonthTest {
    /**
     * 회차 문자열을 그대로 보존하며 입금월·현재 월로 다시 해석하지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void preservesNominalMonth() {
        for (String value : new String[]{"0001-01", "2026-10", "2026-11", "9999-12"}) {
            assertEquals(value, new SalaryMonth(value).value());
        }
    }

    /**
     * 회차가 불명확하거나 잘못된 입력은 동일한 검증 오류로 거절한다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void rejectsMissingAndMalformedMonth() {
        for (String value : new String[]{null, "", "2026-1", "0000-01", "2026-00", "2026-13",
                " 2026-10", "2026-10 ", "2026-10-25", "2026-10\n", "２０２６-１０", "10000-01"}) {
            FinancialException failure = assertThrows(FinancialException.class, () -> new SalaryMonth(value));
            assertEquals(422, failure.status());
            assertEquals("VALIDATION_FAILED", failure.code());
        }
    }
}

