package com.payse.ai.provider;

import com.payse.ai.analysis.mapper.CompactOutput;
import com.payse.ai.analysis.validation.ContractFailure;
import com.payse.ai.constants.AiCodeConstants.Provider;
import com.payse.ai.constants.AiConfigConstants.Analysis;
import com.payse.ai.constants.AiMessageConstants;
import com.payse.ai.provider.dto.ModelReply;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import tools.jackson.databind.JsonNode;

/**
 * 공급자 중립 전송 압축 어댑터다. 계수·생성을 한 번씩 실행하고 공개 결과를 복원한다.
 * @created 2026-11-04
 * @usedBy GammaLocalConfig, CompactOutputTest
 */
public final class CompactModel implements ModelGateway {
    private static final String INSTRUCTIONS = instructions();
    private final ModelGateway delegate;
    private final CompactOutput output;

    /**
     * 현재 요청에만 적용되는 복원 규격을 보관한다.
     * @created 2026-11-04
     * @usedBy factory
     */
    private CompactModel(ModelGateway delegate, CompactOutput output) {
        this.delegate = delegate;
        this.output = output;
    }

    /**
     * 연결 설정·비용 경계는 유지하고 같은 축약 규격으로 계수와 생성을 구성한다.
     * @created 2026-11-04
     * @usedBy GammaLocalConfig.gammaRuntime, CompactOutputTest
     */
    public static ModelFactory factory(ModelFactory models) {
        return (instructions, schema) -> {
            var output = new CompactOutput(schema);
            var model = models.create(instructions + "\n" + INSTRUCTIONS, output.schema());
            return new CompactModel(model, output);
        };
    }

    /**
     * 압축 규칙·실제 Markdown 내용이 다른 결과의 캐시 재사용을 구분한다.
     * @created 2026-11-04
     * @usedBy GammaLocalConfig.gammaRuntime, CompactOutputTest
     */
    public static String version() {
        try {
            byte[] material = (Analysis.COMPACT_VERSION + "\n" + INSTRUCTIONS)
                .getBytes(StandardCharsets.UTF_8);
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(material);
            return Analysis.COMPACT_VERSION + ":" + HexFormat.of().formatHex(digest);
        } catch (Exception failure) {
            throw new IllegalStateException(AiMessageConstants.Analysis.UNAVAILABLE_RESOURCE);
        }
    }

    /**
     * 전송할 실제 축약 규격의 토큰만 계수하고 외부 실패를 그대로 전달한다.
     * @created 2026-11-04
     * @usedBy AnalysisService.generate
     */
    @Override
    public long countInput(JsonNode input) {
        return delegate.countInput(input);
    }

    /**
     * 원문·실패를 남기지 않고 결과 형식만 복원한다. 잘못된 형식을 unknown으로 바꾸지 않는다.
     * @created 2026-11-04
     * @usedBy AnalysisService.generate
     */
    @Override
    public ModelReply generate(JsonNode input) {
        ModelReply reply = delegate.generate(input);
        if (reply == null || reply.failure() != null) {
            return reply;
        }
        try {
            return new ModelReply(output.restore(reply.output()), reply.usage(), null);
        } catch (ContractFailure failure) {
            String code = failure.getMessage();
            if (code == null || !code.matches("[A-Z_]{1,80}")) {
                code = Provider.INVALID_MODEL_OUTPUT;
            }
            System.getLogger(CompactModel.class.getName()).log(
                System.Logger.Level.WARNING,
                AiMessageConstants.Analysis.VALIDATION_FAILURE,
                code
            );
            return new ModelReply(null, reply.usage(), Provider.INVALID_MODEL_OUTPUT);
        }
    }

    /**
     * 배포에 포함된 공개 지침만 읽으며 사용자 자료·정답 파일을 탐색하지 않는다.
     * @created 2026-11-04
     * @usedBy 클래스 초기화
     */
    private static String instructions() {
        try (var stream = CompactModel.class.getResourceAsStream(
            Analysis.RULES_PATH + Analysis.COMPACT_FILE
        )) {
            if (stream == null) {
                throw new IllegalStateException(AiMessageConstants.Analysis.MISSING_RESOURCE);
            }
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        } catch (java.io.IOException failure) {
            throw new IllegalStateException(AiMessageConstants.Analysis.UNAVAILABLE_RESOURCE);
        }
    }
}
