package com.payse.api.finance.dto;

import tools.jackson.databind.node.ObjectNode;

/**
 * 공개 영수증과 권한 재검사용 내부 변경 근거를 분리한다. 직접 HTTP 반환하지 않는다.
 * @created 2026-10-29
 * @usedBy FinancialService.write
 */
public record StoredReceipt(ObjectNode receipt, ObjectNode audit) {}
