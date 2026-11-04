package com.payse.ai.analysis.service;

import com.payse.ai.analysis.validation.StorageContract;
import com.payse.ai.constants.AiConfigConstants.Analysis;
import com.payse.ai.constants.AiFieldConstants;
import com.payse.ai.constants.AiFieldConstants.Guide;
import com.payse.ai.constants.AiMessageConstants;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.Set;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 공개 교육 자료를 원천 구조로 선택한다. 사용자 기억·평가 정답·공급자에 의존하지 않는다.
 * @created 2026-11-04
 * @usedBy AnalysisService
 */
public final class PromptGuide {
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private final String base;
    private final ObjectNode guide;
    private final String version;

    /**
     * 배포된 자료만 읽고 내용 지문을 만든다. 요청 데이터나 통신은 사용하지 않는다.
     * @created 2026-11-04
     * @usedBy AnalysisService 생성자
     */
    public PromptGuide(String criteria) {
        String source = resource();
        guide = (ObjectNode) JSON.readTree(source);
        validate();
        base = criteria + "\n" + JSON.writeValueAsString(guide.get(Guide.RULES));
        String material = Analysis.PROMPT_RENDERER + "\n" + JSON.writeValueAsString(guide)
            + "\n" + criteria
            + "\n" + StorageContract.instructions()
            + "\n" + AiMessageConstants.Analysis.SOURCE_FACTS_INSTRUCTIONS;
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest(material.getBytes(StandardCharsets.UTF_8));
            version = Analysis.PROMPT_RENDERER + ":" + HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException failure) {
            throw new IllegalStateException(AiMessageConstants.Analysis.UNAVAILABLE_RESOURCE);
        }
    }

    /**
     * 조립 규칙과 공통 기준·교육 자료·저장 지침의 변경을 캐시 자격에 반영한다.
     * @created 2026-11-04
     * @usedBy AnalysisService.promptVersion
     */
    public String version() {
        return version;
    }

    /**
     * 고정 지침을 앞에 두고 원천 종류·방향·업무만으로 관련 예시를 결정한다.
     * @created 2026-11-04
     * @usedBy AnalysisService.analyze, AnalysisService.analyzeForStorage
     */
    public String instructions(ObjectNode input, boolean storage) {
        StringBuilder text = new StringBuilder(base);
        if (storage) {
            text.append('\n').append(StorageContract.instructions());
        }
        if (input.has(AiFieldConstants.Analysis.AS_OF)) {
            text.append('\n').append(AiMessageConstants.Analysis.SOURCE_FACTS_INSTRUCTIONS);
        }
        var selected = JSON.createArrayNode();
        for (JsonNode section : guide.get(Guide.SECTIONS)) {
            if (matches(section, input)) {
                ObjectNode row = selected.addObject();
                row.set(Guide.ID, section.get(Guide.ID));
                row.set(Guide.RULE, section.get(Guide.RULE));
                row.set(Guide.EXAMPLES, section.get(Guide.EXAMPLES));
            }
        }
        return text.append('\n').append(JSON.writeValueAsString(selected)).toString();
    }

    /**
     * 자유 적요·정답·사용자 이름으로 검색하지 않아 예시 선택의 지시 삽입을 막는다.
     * @created 2026-11-04
     * @usedBy instructions
     */
    private boolean matches(JsonNode section, ObjectNode input) {
        JsonNode task = input.get(AiFieldConstants.Analysis.SEMANTIC_TASK_KIND);
        if (!contains(section.get(Guide.TASKS), task)) {
            return false;
        }
        if (section.get(Guide.RECORD_KINDS).isEmpty()) {
            return true;
        }
        for (JsonNode transaction : input.get(AiFieldConstants.Analysis.TRANSACTIONS)) {
            JsonNode kind = transaction.get(AiFieldConstants.Analysis.RECORD_KIND);
            JsonNode direction = transaction.get(AiFieldConstants.Analysis.DIRECTION);
            if (contains(section.get(Guide.RECORD_KINDS), kind)
                && contains(section.get(Guide.DIRECTIONS), direction)) {
                return true;
            }
        }
        return false;
    }

    /**
     * JSON 스칼라의 완전 일치만 사용한다.
     * @created 2026-11-04
     * @usedBy matches
     */
    private boolean contains(JsonNode values, JsonNode sought) {
        for (JsonNode value : values) {
            if (value.equals(sought)) {
                return true;
            }
        }
        return false;
    }

    /**
     * 손상·누락·중복 자료를 시작 시 거절한다. 내용의 계약 합치는 별도 검사한다.
     * @created 2026-11-04
     * @usedBy PromptGuide 생성자
     */
    private void validate() {
        if (!guide.propertyNames().equals(Set.of(Guide.VERSION, Guide.RULES, Guide.SECTIONS))
            || !guide.path(Guide.VERSION).isString()
            || !guide.path(Guide.RULES).isArray() || guide.path(Guide.RULES).isEmpty()
            || !guide.path(Guide.SECTIONS).isArray() || guide.path(Guide.SECTIONS).isEmpty()) {
            throw new IllegalStateException(AiMessageConstants.Analysis.UNAVAILABLE_RESOURCE);
        }
        Set<String> ids = new HashSet<>();
        for (JsonNode section : guide.get(Guide.SECTIONS)) {
            if (!section.propertyNames().equals(Set.of(
                Guide.ID,
                Guide.TASKS,
                Guide.RECORD_KINDS,
                Guide.DIRECTIONS,
                Guide.RULE,
                Guide.EXAMPLES
            )) || !section.path(Guide.ID).isString()
                || !ids.add(section.get(Guide.ID).asString())
                || !section.path(Guide.RULE).isString()
                || !section.path(Guide.TASKS).isArray()
                || !section.path(Guide.RECORD_KINDS).isArray()
                || !section.path(Guide.DIRECTIONS).isArray()
                || !section.path(Guide.EXAMPLES).isArray()
                || section.path(Guide.EXAMPLES).size() > 2) {
                throw new IllegalStateException(AiMessageConstants.Analysis.UNAVAILABLE_RESOURCE);
            }
        }
    }

    /**
     * 정해진 공개 리소스만 읽으며 로컬 파일·평가 디렉터리를 탐색하지 않는다.
     * @created 2026-11-04
     * @usedBy PromptGuide 생성자
     */
    private String resource() {
        try (var stream = PromptGuide.class.getResourceAsStream(
            Analysis.RULES_PATH + Analysis.GUIDE_FILE
        )) {
            if (stream == null) {
                throw new IllegalStateException(AiMessageConstants.Analysis.MISSING_RESOURCE);
            }
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException failure) {
            throw new IllegalStateException(AiMessageConstants.Analysis.UNAVAILABLE_RESOURCE);
        }
    }
}
