package com.payse.api.analysis.service;

import com.payse.api.constants.ApiCodeConstants.Analysis;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiFieldConstants.AnalysisDb;
import java.time.Instant;
import java.util.Set;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실행 실패의 사용자 확인 목록을 해석 결과와 분리하고 상세 보관 기한을 지킨다.
 * @created 2026-11-04
 * @usedBy AnalysisJobs.status
 */
final class AnalysisReview {
    /**
     * 현재 상태와 보관된 항목 키만 제공한다. 금융 본문·공급자 오류는 노출하지 않는다.
     * @created 2026-11-04
     * @usedBy AnalysisJobs.status, AnalysisReviewTest
     */
    static ObjectNode describe(ObjectNode job, String state, Instant now) {
        if (!Set.of(Analysis.FAILED, Analysis.OUTCOME_UNKNOWN, Analysis.CANCELLED,
            Analysis.EXPIRED).contains(state)) {
            return null;
        }
        JsonNode items = job.path(ApiFieldConstants.Analysis.DETAIL)
            .path(ApiFieldConstants.Analysis.ITEMS);
        boolean available = items.isArray() && !items.isEmpty();
        if (job.path(AnalysisDb.FINISHED_AT).isString()) {
            Instant expires = Instant.parse(job.path(AnalysisDb.FINISHED_AT).asString())
                .plusSeconds(7L * 86400);
            available = available && now.isBefore(expires);
        }
        ObjectNode review = AnalysisJson.JSON.createObjectNode()
            .put(ApiFieldConstants.Analysis.REASON, state)
            .put(ApiFieldConstants.Analysis.REQUIRES_USER_INPUT, true)
            .put(ApiFieldConstants.Analysis.ITEMS_AVAILABLE, available)
            .put(ApiFieldConstants.Analysis.RETRY_REQUIRES_ACKNOWLEDGEMENT,
                state.equals(Analysis.OUTCOME_UNKNOWN));
        if (available) {
            var references = review.putArray(ApiFieldConstants.Analysis.ITEMS);
            for (JsonNode item : items) {
                references.addObject().set(ApiFieldConstants.Analysis.ITEM_KEY,
                    item.get(ApiFieldConstants.Analysis.ITEM_KEY));
            }
        }
        return review;
    }
}
