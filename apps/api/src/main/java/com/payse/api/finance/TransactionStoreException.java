package com.payse.api.finance;

/**
 * 금융 조회 장애를 SQL·파라미터·원인 체인 없이 전달한다. 실제 빈 결과와는 구별한다.
 * @created 2026-10-29
 * @usedBy TransactionRepository, 미연결: 금융 조회 HTTP 오류 매핑
 */
public final class TransactionStoreException extends RuntimeException {
    /**
     * 금융 원문과 DB 내부 정보를 담지 않는 고정 메시지로 실패를 알린다.
     * @created 2026-10-29
     * @usedBy TransactionRepository
     */
    public TransactionStoreException() {
        super("Transaction storage failed");
    }
}
