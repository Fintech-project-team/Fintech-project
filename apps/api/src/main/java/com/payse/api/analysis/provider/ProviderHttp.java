package com.payse.api.analysis.provider;

import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.time.Duration;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Flow;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * 공급자 JSON을 제한된 크기로 한 번 전송한다. 재시도·리디렉션·본문 로그를 만들지 않는다.
 * @created 2026-10-29
 * @usedBy GoogleKms, OpenAiGateway
 */
public final class ProviderHttp {
    private final HttpClient client;
    private final Duration timeout;
    private final int responseLimit;
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 연결 제한을 설정한 클라이언트와 응답 읽기 상한을 받는다. 자동 리디렉션은 거절한다.
     * @created 2026-10-29
     * @usedBy 공급자 어댑터 설정, ProviderHttpTest
     */
    public ProviderHttp(HttpClient client, Duration timeout, int responseLimit) {
        this.client = Objects.requireNonNull(client, "client");
        if (client.followRedirects() != HttpClient.Redirect.NEVER || client.connectTimeout().isEmpty()
                || timeout == null || timeout.isNegative() || timeout.isZero() || responseLimit < 1) {
            throw new IllegalArgumentException("Bounded provider HTTP settings are required");
        }
        this.timeout = timeout;
        this.responseLimit = responseLimit;
    }

    /**
     * 승인된 어댑터의 주소에 JSON을 한 번 보낸다. 비정상 응답 본문·자격은 예외에 포함하지 않는다.
     * @created 2026-10-29
     * @usedBy GoogleKms.wrap, GoogleKms.unwrap, OpenAiGateway
     */
    public JsonNode post(URI endpoint, String bearer, JsonNode body) {
        if (bearer == null || bearer.isBlank() || bearer.indexOf('\r') >= 0 || bearer.indexOf('\n') >= 0) {
            throw new ProviderFailure("CREDENTIAL_UNAVAILABLE", false);
        }
        HttpRequest request = HttpRequest.newBuilder(endpoint).timeout(timeout)
            .header("Authorization", "Bearer " + bearer).header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(json.writeValueAsString(body))).build();
        var exchange = client.sendAsync(request, info -> new LimitedBody(responseLimit));
        try {
            // get의 제한시간은 헤더 이후 본문이 멈춘 경우까지 포함한다.
            HttpResponse<byte[]> response = exchange.get(timeout.toMillis(), TimeUnit.MILLISECONDS);
            byte[] bytes = response.body();
            try {
                if (response.statusCode() < 200 || response.statusCode() >= 300) {
                    throw new ProviderFailure("PROVIDER_HTTP_" + response.statusCode(), true);
                }
                try {
                    JsonNode result = json.readTree(bytes);
                    if (result == null || !result.isObject()) throw new ProviderFailure("INVALID_PROVIDER_JSON", true);
                    return result;
                } catch (ProviderFailure failure) {
                    throw failure;
                } catch (RuntimeException failure) {
                    throw new ProviderFailure("INVALID_PROVIDER_JSON", true);
                }
            } finally {
                Arrays.fill(bytes, (byte) 0);
            }
        } catch (InterruptedException failure) {
            exchange.cancel(true);
            Thread.currentThread().interrupt();
            throw new ProviderFailure("TRANSMISSION_UNKNOWN", true);
        } catch (TimeoutException failure) {
            exchange.cancel(true);
            throw new ProviderFailure("TRANSMISSION_UNKNOWN", true);
        } catch (ExecutionException failure) {
            if (failure.getCause() instanceof ProviderFailure known) throw known;
            throw new ProviderFailure("TRANSMISSION_UNKNOWN", true);
        }
    }

    /**
     * 고정 응답 상한을 넘기기 전에 구독을 취소한다. 전체 본문 수신 후 크기를 검사하지 않는다.
     * @created 2026-10-29
     * @usedBy post
     */
    private static final class LimitedBody implements HttpResponse.BodySubscriber<byte[]> {
        private final int limit;
        private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        private final CompletableFuture<byte[]> body = new CompletableFuture<>();
        private Flow.Subscription subscription;

        /**
         * 한 응답의 최대 바이트 수를 고정한다.
         * @created 2026-10-29
         * @usedBy post
         */
        private LimitedBody(int limit) { this.limit = limit; }

        /**
         * 전체 제한 본문의 완료 또는 실패를 HTTP 클라이언트에 전달한다.
         * @created 2026-10-29
         * @usedBy HttpClient BodySubscriber
         */
        @Override
        public CompletionStage<byte[]> getBody() { return body; }

        /**
         * 한 청크씩 받아 과도한 선행 버퍼링을 하지 않는다.
         * @created 2026-10-29
         * @usedBy HttpClient BodySubscriber
         */
        @Override
        public void onSubscribe(Flow.Subscription value) {
            if (subscription != null) { value.cancel(); return; }
            subscription = value;
            subscription.request(1);
        }

        /**
         * 허용 크기 이내 청크만 복사하고 초과하면 즉시 종료한다.
         * @created 2026-10-29
         * @usedBy HttpClient BodySubscriber
         */
        @Override
        public void onNext(List<ByteBuffer> chunks) {
            for (ByteBuffer chunk : chunks) {
                if (chunk.remaining() > limit - bytes.size()) {
                    subscription.cancel();
                    body.completeExceptionally(new ProviderFailure("RESPONSE_TOO_LARGE", true));
                    return;
                }
                byte[] part = new byte[chunk.remaining()];
                chunk.get(part);
                bytes.writeBytes(part);
                Arrays.fill(part, (byte) 0);
            }
            subscription.request(1);
        }

        /**
         * 외부 예외의 민감 본문을 이어붙이지 않고 실패만 전파한다.
         * @created 2026-10-29
         * @usedBy HttpClient BodySubscriber
         */
        @Override
        public void onError(Throwable failure) {
            body.completeExceptionally(new ProviderFailure("TRANSMISSION_UNKNOWN", true));
        }

        /**
         * 한 응답의 제한된 바이트를 완료한다.
         * @created 2026-10-29
         * @usedBy HttpClient BodySubscriber
         */
        @Override
        public void onComplete() { body.complete(bytes.toByteArray()); }
    }

    /**
     * 외부 처리 가능성과 공개 가능한 내부 오류 분류만 전달한다. 원인 예외 본문은 보존하지 않는다.
     * @created 2026-10-29
     * @usedBy 공급자 어댑터와 실행 서비스
     */
    public static final class ProviderFailure extends RuntimeException {
        private final boolean mayHaveBeenSent;

        /**
         * 전송 후 실패를 미전송·비용0으로 잘못 환원하지 않게 한다.
         * @created 2026-10-29
         * @usedBy ProviderHttp, GoogleKms, OpenAiGateway
         */
        public ProviderFailure(String reason, boolean mayHaveBeenSent) {
            super(reason);
            this.mayHaveBeenSent = mayHaveBeenSent;
        }

        /**
         * 외부 실행 가능성을 반환하며 실제 과금액을 뜻하지 않는다.
         * @created 2026-10-29
         * @usedBy 미연결: 예정 사용처 분석 시도 상태 서비스
         */
        public boolean mayHaveBeenSent() { return mayHaveBeenSent; }
    }
}
