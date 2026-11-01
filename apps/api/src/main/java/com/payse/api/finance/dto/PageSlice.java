package com.payse.api.finance.dto;

import java.util.UUID;
import tools.jackson.databind.node.ObjectNode;

/**
 * 응답 본문과 서명 cursor 생성에 필요한 공개 페이지 경계를 보관한다.
 * @created 2026-10-29
 * @usedBy FinancialProjection.project, FinancialService
 */
public record PageSlice(ObjectNode body, UUID lastId, boolean hasMore) {}
