package com.payse.api.finance.error;

/**
 * 금융 경계에서 허용한 오류 코드만 전달하며 원문·SQL·숨겨진 ID를 보관하지 않는다.
 * @created 2026-10-29
 * @usedBy FinancialController, FinancialService, 금융 입력·저장·투영
 */
public final class FinancialException extends RuntimeException {
    private final int status;
    private final String code;

    /**
     * 공개 상태와 고정 코드를 저장한다. 원래 예외를 원인으로 연결하지 않는다.
     * @created 2026-10-29
     * @usedBy 금융 서비스와 입력·저장 경계
     */
    public FinancialException(int status, String code) {
        super(code);
        this.status = status;
        this.code = code;
    }

    /**
     * HTTP 오류 상태를 반환한다.
     * @created 2026-10-29
     * @usedBy FinancialController.failure
     */
    public int status() { return status; }

    /**
     * 계약의 공개 오류 코드만 반환한다.
     * @created 2026-10-29
     * @usedBy FinancialController.failure
     */
    public String code() { return code; }
}
