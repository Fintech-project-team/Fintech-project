package com.payse.api.analysis.service;

import com.payse.api.ApiTestConstants.AnalysisFields;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.payse.ai.analysis.validation.AnalysisContract;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 독립 참조 구현으로 동결한 공개 30개 사례를 실제 Java 계약·지문에 대조한다.
 * @created 2026-11-04
 * @usedBy JUnit, 프론트 공동 프로토콜 인수
 */
class ProtocolVectorsTest {
    /**
     * 원본 입력·기억/근거·최종 힌트를 검증한다. DB 결합 지문을 클라이언트에 요구하지 않는다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void matchesThirtyPublicVectors() throws Exception {
        JsonNode vectors = AnalysisJson.JSON.readTree(Files.readString(
            Path.of("testing/protocol/fixtures/identity-vectors.json")
        ));
        assertEquals("PAYSE-IDENTITY-VECTORS-1", vectors.path("format").asString());
        assertEquals(30, vectors.path("cases").size());
        var ids = new HashSet<String>();
        var identity = new AnalysisIdentity();
        var contract = new AnalysisContract();
        for (JsonNode vector : vectors.path("cases")) {
            String id = vector.path(AnalysisFields.ID).asString();
            assertTrue(ids.add(id));
            ObjectNode input = (ObjectNode) vector.path(AnalysisFields.INPUT);
            JsonNode expected = vector.path("expected");
            contract.input(input);
            assertEquals(
                expected.path("canonicalInput").asString(),
                AnalysisJson.canonical(input).toString(),
                id + " canonical input"
            );
            assertEquals(
                expected.path(AnalysisFields.INPUT_HASH_HINT).asString(),
                identity.hint(input),
                id + " hint"
            );
            var actual = identity.items(input);
            assertEquals(expected.path(AnalysisFields.ITEMS).size(), actual.size(), id);
            for (var item : actual) {
                JsonNode row = null;
                for (JsonNode candidate : expected.path(AnalysisFields.ITEMS)) {
                    if (candidate.path(AnalysisFields.ITEM_KEY).asString().equals(item.itemKey())) {
                        row = candidate;
                    }
                }
                assertTrue(row != null, id);
                assertEquals(row.path("memoryKey").asString(), item.key(), id);
                assertEquals(row.path("evidenceHash").asString(), item.evidenceHash(), id);
                JsonNode evidence = AnalysisJson.JSON.readTree(
                    row.path("canonicalEvidence").asString()
                );
                assertEquals(item.evidenceHash(), AnalysisJson.digest(evidence), id);
            }
        }
    }
}
