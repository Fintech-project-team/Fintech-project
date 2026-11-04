package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.payse.api.ApiTestConstants.AnalysisFields;
import com.payse.api.ApiTestConstants.AnalysisColumns;
import java.time.Instant;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실패 목록의 본문 비노출·중복 위험·상세 만료를 독립된 기대값으로 검사한다.
 * @created 2026-11-04
 * @usedBy JUnit
 */
class AnalysisReviewTest {
    /**
     * 실패를 정상 해석으로 바꾸지 않고 항목 키 외 입력 자료를 반환하지 않는다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void exposesOnlyReferences() {
        ObjectNode review = AnalysisReview.describe(fixture(), "failed", Instant.EPOCH);
        assertEquals("failed", review.path(AnalysisFields.REASON).asString());
        assertTrue(review.path(AnalysisFields.REQUIRES_USER_INPUT).asBoolean());
        assertTrue(review.path(AnalysisFields.ITEMS_AVAILABLE).asBoolean());
        assertFalse(review.path(AnalysisFields.RETRY_REQUIRES_ACKNOWLEDGEMENT).asBoolean());
        var item = review.path(AnalysisFields.ITEMS).get(0);
        assertEquals(1, item.size());
        assertEquals("item-1", item.path(AnalysisFields.ITEM_KEY).asString());
        assertFalse(review.has(AnalysisFields.RESULT));
    }

    /**
     * 전송 완료 불명만 추가 비용 동의를 요구하고 취소·만료도 수동 확인으로 남긴다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void preservesUnknownRisk() {
        for (String state : new String[] {"failed", "outcomeUnknown", "cancelled", "expired"}) {
            ObjectNode review = AnalysisReview.describe(fixture(), state, Instant.EPOCH);
            assertEquals(state, review.path(AnalysisFields.REASON).asString());
            assertEquals(state.equals("outcomeUnknown"),
                review.path(AnalysisFields.RETRY_REQUIRES_ACKNOWLEDGEMENT).asBoolean());
        }
    }

    /**
     * 정확히 종료 7일이면 상세를 숨기고 목록 부재를 해결 완료로 보고하지 않는다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void expiresReferencesWithoutHidingFailure() {
        ObjectNode job = fixture().put(AnalysisColumns.FINISHED_AT, Instant.EPOCH.toString());
        Instant expiry = Instant.EPOCH.plusSeconds(604800);
        assertTrue(AnalysisReview.describe(job, "failed", expiry.minusNanos(1))
            .path(AnalysisFields.ITEMS_AVAILABLE).asBoolean());
        ObjectNode review = AnalysisReview.describe(job, "failed", expiry);
        assertFalse(review.path(AnalysisFields.ITEMS_AVAILABLE).asBoolean());
        assertTrue(review.path(AnalysisFields.REQUIRES_USER_INPUT).asBoolean());
        assertFalse(review.has(AnalysisFields.ITEMS));
        job.remove(AnalysisFields.DETAIL);
        assertFalse(AnalysisReview.describe(job, "failed", Instant.EPOCH)
            .path(AnalysisFields.ITEMS_AVAILABLE).asBoolean());
    }

    /**
     * 실행 중·정상 완료에 실패 확인을 붙여 재분석을 유도하지 않는다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void omitsReviewForActiveAndSuccessfulJobs() {
        for (String state : new String[] {"queued", "awaitingInput", "running", "succeeded"}) {
            assertNull(AnalysisReview.describe(fixture(), state, Instant.EPOCH));
        }
    }

    /**
     * 숨겨야 할 원문을 섞은 독립 합성 상태를 준비한다.
     * @created 2026-11-04
     * @usedBy AnalysisReviewTest
     */
    private ObjectNode fixture() {
        ObjectNode job = AnalysisJson.JSON.createObjectNode();
        job.putObject(AnalysisFields.DETAIL)
            .putArray(AnalysisFields.ITEMS)
            .addObject()
            .put(AnalysisFields.ITEM_KEY, "item-1")
            .put(AnalysisFields.DESCRIPTION, "synthetic-private-text");
        return job;
    }
}
