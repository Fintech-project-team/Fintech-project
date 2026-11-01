package com.payse.api.finance.vo;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 현재 거래·취소일과 원거래 연결을 보관한다. 원거래 ID는 내부 자료이며,
 * UNAVAILABLE/RESTRICTED를 공개 응답에 그대로 내보내지 않는다.
 * @created 2026-10-29
 * @usedBy TransactionRepository.findLink, AuthJdbcTest
 */
public record TransactionLink(UUID id, LocalDate cancellationDate, UUID originalTransactionId,
        OriginalState originalState, OriginalTransaction original) {
    /**
     * 자동 로그·검사 출력에 금융 식별자와 날짜가 남지 않게 한다.
     * @created 2026-10-29
     * @usedBy 내부 객체 문자열 표현
     * @return 금융 원문을 포함하지 않는 고정 설명
     */
    @Override public String toString() { return "TransactionLink[REDACTED]"; }
}
