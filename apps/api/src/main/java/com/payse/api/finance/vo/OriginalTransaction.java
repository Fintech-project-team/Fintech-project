package com.payse.api.finance.vo;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 원거래 상세 표시에 필요한 최소 원천만 보관하며 잔액·금액을 계산하지 않는다.
 * @created 2026-10-29
 * @usedBy TransactionLink, TransactionRepository.mapLink, AuthJdbcTest
 */
public record OriginalTransaction(UUID id, UUID cardId, String recordKind, LocalDate purchaseDate,
        long amountKRW, String sourceVersion) {
    /**
     * 자동 로그·검사 출력에 원거래 금액과 식별자가 남지 않게 한다.
     * @created 2026-10-29
     * @usedBy 내부 객체 문자열 표현
     * @return 금융 원문을 포함하지 않는 고정 설명
     */
    @Override public String toString() { return "Original[REDACTED]"; }
}
