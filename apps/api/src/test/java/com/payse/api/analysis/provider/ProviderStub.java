package com.payse.api.analysis.provider;

import com.payse.ai.transport.ProviderHttp;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * 외부망 없이 합성 공급자 응답과 실제 전송 횟수를 검사하는 로컬 서버다.
 * @created 2026-11-01
 * @usedBy ProviderHttpTest, OpenAiGatewayTest, GoogleKmsTest
 */
final class ProviderStub implements AutoCloseable {
    private final HttpServer server;
    private final ExecutorService executor = Executors.newCachedThreadPool();
    private final List<Request> requests = new CopyOnWriteArrayList<>();
    private final JsonMapper json = JsonMapper.builder().build();
    private volatile String response = "{}";
    private volatile int status = 200;
    private volatile long delay;

    /**
     * 운영 주소와 분리된 loopback 임시 포트에서 응답한다.
     * @created 2026-11-01
     * @usedBy 공급자 테스트
     */
    ProviderStub() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setExecutor(executor);
        server.createContext("/", this::handle);
        server.start();
    }

    /**
     * 테스트 기본 시간·크기 제한의 실제 HTTP 클라이언트를 만든다.
     * @created 2026-11-01
     * @usedBy 공급자 테스트
     */
    ProviderHttp http() { return http(Duration.ofSeconds(2), 65536); }

    /**
     * 경계 테스트가 응답 시간·크기 상한을 지정한다.
     * @created 2026-11-01
     * @usedBy ProviderHttpTest
     */
    ProviderHttp http(Duration timeout, int limit) {
        return new ProviderHttp(HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(1))
            .followRedirects(HttpClient.Redirect.NEVER).build(), timeout, limit);
    }

    /**
     * 모의 공급자 전용 주소를 반환한다.
     * @created 2026-11-01
     * @usedBy 공급자 테스트
     */
    URI endpoint() { return URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/v1/"); }

    /**
     * 다음 응답의 코드·합성 본문을 지정한다.
     * @created 2026-11-01
     * @usedBy 공급자 테스트
     */
    void reply(int code, String body) { status = code; response = body; delay = 0; }

    /**
     * 헤더 전송 뒤 본문 지연을 만들어 전체 응답 timeout을 검사한다.
     * @created 2026-11-01
     * @usedBy ProviderHttpTest
     */
    void delayBody(long milliseconds) { delay = milliseconds; }

    /**
     * 합성 요청의 읽기용 스냅샷을 반환한다.
     * @created 2026-11-01
     * @usedBy 공급자 테스트
     */
    List<Request> requests() { return List.copyOf(requests); }

    /**
     * 요청을 기록하고 지정된 응답만 전달한다. 외부 서비스에 전달하지 않는다.
     * @created 2026-11-01
     * @usedBy HttpServer
     */
    private void handle(HttpExchange exchange) throws IOException {
        try (exchange) {
            requests.add(new Request(exchange.getRequestURI().getPath(), exchange.getRequestHeaders().getFirst("Authorization"),
                json.readTree(exchange.getRequestBody().readAllBytes())));
            byte[] body = response.getBytes(StandardCharsets.UTF_8);
            if (status >= 300 && status < 400) exchange.getResponseHeaders().add("Location", endpoint().resolve("redirected").toString());
            exchange.sendResponseHeaders(status, body.length);
            try { if (delay > 0) Thread.sleep(delay); }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            exchange.getResponseBody().write(body);
        }
    }

    /**
     * 테스트가 소유한 서버·스레드만 종료한다.
     * @created 2026-11-01
     * @usedBy try-with-resources
     */
    @Override
    public void close() { server.stop(0); executor.shutdownNow(); }

    /**
     * 운영 키·금융 데이터가 없는 모의 요청이다.
     * @created 2026-11-01
     * @usedBy 공급자 테스트 assertion
     */
    record Request(String path, String authorization, JsonNode body) {}
}
