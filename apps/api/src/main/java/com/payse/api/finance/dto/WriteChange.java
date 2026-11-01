package com.payse.api.finance.dto;

import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 공개 요약 후보와 내부 변경 근거를 분리해 영수증 저장으로 전달한다.
 * @created 2026-10-29
 * @usedBy FinancialService, FinancialReceipts
 * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
 */
public record WriteChange(ArrayNode changedRefs, ObjectNode beforeAfter) { }
