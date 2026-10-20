package com.payse.api;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * PAYSE API의 의존성과 HTTP 서버를 시작한다. 금융 계산을 수행하지 않는다.
 * @created 2026-10-20
 * @usedBy Gradle bootRun, 배포 JAR의 시작 진입점
 */
@SpringBootApplication
public class PayseApiApplication {
    /**
     * 실행 인자를 Spring Boot에 전달한다.
     * @created 2026-10-20
     * @usedBy JVM 애플리케이션 시작
     * @param args 서버 실행 인자. 비밀값은 명령행 대신 환경변수로 전달한다.
     */
    public static void main(String[] args) {
        SpringApplication.run(PayseApiApplication.class, args);
    }
}
