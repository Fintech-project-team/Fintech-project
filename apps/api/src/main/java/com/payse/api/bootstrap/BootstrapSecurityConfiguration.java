package com.payse.api.bootstrap;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;

/**
 * 로그인 기능 구현 전 생존 확인 이외의 모든 요청을 차단한다.
 * @created 2026-10-20
 * @usedBy Spring Security HTTP 필터 구성
 */
@Configuration(proxyBeanMethods = false)
public class BootstrapSecurityConfiguration {
    /**
     * 기본 계정·폼 로그인·HTTP 세션 없이 차단 정책을 구성한다.
     * @created 2026-10-20
     * @usedBy Spring Security FilterChainProxy
     * @param http Spring이 제공하는 보안 구성기
     * @return 생존 확인 GET만 공개하는 필터 체인
     * @throws Exception 필터 구성 실패
     */
    @Bean
    public SecurityFilterChain bootstrapSecurity(HttpSecurity http) throws Exception {
        return http
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .requestCache(AbstractHttpConfigurer::disable)
            .formLogin(AbstractHttpConfigurer::disable)
            .httpBasic(AbstractHttpConfigurer::disable)
            .logout(AbstractHttpConfigurer::disable)
            // 쿠키/Basic 인증이 없고 모든 업무 경로를 차단한다. 쿠키 인증 도입 시 CSRF를 재설계한다.
            .csrf(AbstractHttpConfigurer::disable)
            .authorizeHttpRequests(authorize -> authorize
                .requestMatchers(HttpMethod.GET, "/internal/health/live").permitAll()
                .anyRequest().denyAll())
            .exceptionHandling(errors -> errors
                .authenticationEntryPoint((request, response, failure) -> response.setStatus(401))
                .accessDeniedHandler((request, response, failure) -> response.setStatus(403)))
            .build();
    }
}
