package com.payse.ai.analysis;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.AiTestConstants.AnalysisFields;
import com.payse.ai.AiTestConstants;
import com.payse.ai.analysis.mapper.InputMapper;
import com.payse.ai.analysis.validation.AnalysisContract;
import com.payse.ai.analysis.validation.ContractFailure;
import com.payse.ai.analysis.validation.SchemaRules;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 기존 Python 개발 자료와 Java 규격·투영·복원 일치를 검사한다. 모델 정확도 검사가 아니다.
 * @created 2026-11-01
 * @usedBy JUnit
 * @modified 2026-11-02 - 상수 타입 명시 참조
 */
class ContractParityTest {
    private final JsonMapper json = JsonMapper.builder().build();
    private final AnalysisContract contract = new AnalysisContract();
    private final Path data = Path.of(System.getProperty(AiTestConstants.Files.TEST_DATA_PROPERTY));

    /**
     * 5,083개 개발 입력과 대조 응답을 전건 검사한다. 정답은 모델·서비스에 전달하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void matchesPythonForEveryDevelopmentCase() throws Exception {
        int count = 0;
        try (
            var reader = Files.newBufferedReader(data.resolve(AiTestConstants.Files.PARITY_FILE))) {
            String line;
            while ((line = reader.readLine()) != null) {
                JsonNode row = json.readTree(line);
                ObjectNode input = (ObjectNode) row.get(AnalysisFields.INPUT);
                InputMapper mapper = new InputMapper(input, contract);
                assertEquals(
                    row.get(AnalysisFields.PROJECTED),
                    mapper.input(),
                    row.get(AnalysisFields.CASE_ID)
                        .asString()
                );
                assertEquals(
                    row.get(AnalysisFields.SCHEMA),
                    mapper.schema(),
                    row.get(AnalysisFields.CASE_ID)
                        .asString()
                );
                contract.output(input, row.get(AnalysisFields.OUTPUT));
                assertEquals(
                    row.get(AnalysisFields.OUTPUT),
                    mapper.restore((ObjectNode) row.get(AnalysisFields.RESPONSE))
                );
                count++;
            }
        }
        assertEquals(5083, count);
    }

    /**
     * Python이 거절한 타입·날짜·범위·중복·순환 입력을 Java도 전송 전에 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조; 제어문 본문 구분
     */
    @Test
    void rejectsPythonCounterexamples() throws Exception {
        JsonNode rows = json
            .readTree(Files.readString(data.resolve(AiTestConstants.Files.INVALID_INPUTS_FILE)));
        assertEquals(11, rows.size());
        for (JsonNode input : rows) {
            assertThrows(ContractFailure.class, () -> contract.input(input));
        }
        JsonNode dates = json
            .readTree(Files.readString(data.resolve(AiTestConstants.Files.DATE_INPUTS_FILE)));
        assertEquals(5, dates.size());
        for (JsonNode precise : dates) {
            JsonNode before = precise.deepCopy();
            assertDoesNotThrow(() -> contract.input(precise));
            assertEquals(before, precise);
        }
    }

    /**
     * 유니코드 문자 수·정수 타입·빈 배열 뒤의 미지원 규칙도 검사한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesSchemaBoundaries() {
        JsonNode text = json.readTree("{\"type\":\"string\",\"minLength\":1,\"maxLength\":1}");
        assertDoesNotThrow(() -> SchemaRules.check(text, json.getNodeFactory().stringNode("🌙")));
        assertThrows(
            ContractFailure.class,
            () -> SchemaRules.check(
                text,
                json.getNodeFactory()
                    .stringNode("🌙🌙")
            )
        );
        assertThrows(
            ContractFailure.class,
            () -> SchemaRules.supported(
                json.readTree(
                    "{\"type\":\"array\",\"items\":{\"type\":\"string\",\"format\":\"uuid\"}}"
                )
            )
        );
        JsonNode integer = json.readTree("{\"type\":\"integer\",\"maximum\":9223372036854775807}");
        for (String value : new String[] {
            "true",
            "1.0",
            "9223372036854775808"
        }) {
            assertThrows(
                ContractFailure.class,
                () -> SchemaRules.check(integer, json.readTree(value))
            );
        }
    }
}
