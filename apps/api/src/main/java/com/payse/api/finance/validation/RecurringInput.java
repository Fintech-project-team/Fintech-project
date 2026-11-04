package com.payse.api.finance.validation;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiFieldConstants.Finance;
import com.payse.api.constants.ApiFieldConstants.Recurring;
import com.payse.api.finance.error.FinancialException;
import java.time.YearMonth;
import java.time.format.DateTimeParseException;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import tools.jackson.databind.JsonNode;

/**
 * 로컬 후보의 명시 승인·제외 명령을 검증한다. 반복 수치와 예정일을 재계산하지 않는다.
 * @created 2026-11-04
 * @usedBy FinancialInput.validate
 */
public final class RecurringInput {
    /**
     * 정적 입력 검증만 제공한다.
     * @created 2026-11-04
     * @usedBy 없음: 인스턴스화 금지
     */
    private RecurringInput() {
    }

    /**
     * 쓰기 공통 필드 외의 허용 값을 확인하고 승인일 때만 계획을 요구한다.
     * @created 2026-11-04
     * @usedBy FinancialInput.validate
     */
    public static void validate(JsonNode body) {
        var fields = Set.of(
            Finance.EXPECTED_DATA_VERSION,
            Finance.RULE_VERSION,
            Finance.IDEMPOTENCY_KEY,
            Recurring.CANDIDATE_KEY,
            Recurring.SOURCE_VERSION,
            Recurring.EVIDENCE_IDS,
            Recurring.NAME,
            Recurring.DECISION,
            Recurring.PLAN
        );
        if (!body.propertyNames().equals(fields)) {
            throw invalid();
        }
        text(body.get(Recurring.CANDIDATE_KEY), 4096);
        text(body.get(Recurring.SOURCE_VERSION), 512);
        text(body.get(Recurring.NAME), 80);
        var refs = body.get(Recurring.EVIDENCE_IDS);
        if (!refs.isArray() || refs.size() < 3 || refs.size() > 60) {
            throw invalid();
        }
        Set<UUID> ids = new HashSet<>();
        for (JsonNode ref : refs) {
            if (!ids.add(FinancialInput.id(ref))) {
                throw invalid();
            }
        }
        String decision = body.get(Recurring.DECISION).asString("");
        JsonNode plan = body.get(Recurring.PLAN);
        if (ApiCodeConstants.Recurring.EXCLUDED.equals(decision)) {
            if (!plan.isNull()) {
                throw invalid();
            }
            return;
        }
        if (!ApiCodeConstants.Recurring.APPROVED.equals(decision) || !plan.isObject()) {
            throw invalid();
        }
        if (!plan.propertyNames().equals(Set.of(
            Recurring.FIRST_MONTH,
            Finance.LABEL,
            Finance.AMOUNT_KRW,
            Recurring.MONTHLY_DAY,
            Recurring.PAYMENT_TIMING,
            Recurring.SCHEDULE_BASIS,
            Finance.WITHDRAWAL_ACCOUNT_ID,
            Recurring.CARD_ID
        ))) {
            throw invalid();
        }
        text(plan.get(Finance.LABEL), 80);
        JsonNode amount = plan.get(Finance.AMOUNT_KRW);
        JsonNode day = plan.get(Recurring.MONTHLY_DAY);
        if (!amount.isIntegralNumber() || !amount.canConvertToLong()
            || amount.asLong() < 1 || amount.asLong() > 9_000_000_000_000L
            || !day.isIntegralNumber() || !day.canConvertToInt()
            || day.asInt() < 1 || day.asInt() > 31) {
            throw invalid();
        }
        month(plan.get(Recurring.FIRST_MONTH));
        FinancialInput.id(plan.get(Finance.WITHDRAWAL_ACCOUNT_ID));
        String timing = plan.get(Recurring.PAYMENT_TIMING).asString("");
        String basis = plan.get(Recurring.SCHEDULE_BASIS).asString("");
        if (ApiCodeConstants.Recurring.IMMEDIATE.equals(timing)) {
            if (!ApiCodeConstants.Recurring.WITHDRAWAL.equals(basis)
                || !plan.get(Recurring.CARD_ID).isNull()) {
                throw invalid();
            }
        } else if (ApiCodeConstants.Recurring.CARD_BILL.equals(timing)) {
            if (!Set.of(ApiCodeConstants.Recurring.PURCHASE, ApiCodeConstants.Recurring.WITHDRAWAL)
                .contains(basis)) {
                throw invalid();
            }
            FinancialInput.id(plan.get(Recurring.CARD_ID));
        } else {
            throw invalid();
        }
    }

    /**
     * 명시한 회차월만 읽고 예측 날짜를 만들지 않는다.
     * @created 2026-11-04
     * @usedBy validate, RecurringWrites
     */
    public static YearMonth month(JsonNode value) {
        if (!value.isString() || !value.asString().matches("[0-9]{4}-(0[1-9]|1[0-2])")) {
            throw invalid();
        }
        try {
            YearMonth result = YearMonth.parse(value.asString());
            if (result.getYear() < 1) {
                throw invalid();
            }
            return result;
        } catch (DateTimeParseException failure) {
            throw invalid();
        }
    }

    /**
     * 사용자 명칭·키가 비어 있거나 타입·길이가 잘못된 경우만 거절한다.
     * @created 2026-11-04
     * @usedBy validate
     */
    private static void text(JsonNode value, int maximum) {
        if (!value.isString() || value.asString().isBlank()
            || value.asString().length() > maximum) {
            throw invalid();
        }
    }

    /**
     * 입력 원문 없이 기존 오류 봉투를 재사용한다.
     * @created 2026-11-04
     * @usedBy validate, month, text
     */
    private static FinancialException invalid() {
        return new FinancialException(422, ApiCodeConstants.Finance.VALIDATION_FAILED);
    }
}
