package com.payse.api.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;

/**
 * 생존 확인과 명시적으로 활성화된 인증·금융 경로 외의 요청을 차단한다.
 * @created 2026-10-20
 * @usedBy Spring Security HTTP 필터 구성
 * @modified 2026-10-28 - database+auth에서만 인증 HTTP 세 경로 연결
 * @modified 2026-10-29 - finance 프로필의 확정 금융 조회·설정 경로만 허용
 */
@Configuration(proxyBeanMethods = false)
public class BootstrapSecurityConfiguration {
    /**
     * 기본 계정·폼 로그인·HTTP 세션 없이 차단 정책을 구성한다.
     * @created 2026-10-20
     * @usedBy Spring Security FilterChainProxy
     * @modified 2026-10-28 - 명시한 프로필에서 세 인증 경로만 허용
     * @modified 2026-10-29 - 금융 경로는 database+auth+finance에서 서비스 권한 검사를 거쳐 제공
     * @modified 2026-10-30 - salary-notices 활성 시에만 회차별 안내 조회·닫기 경로 제공
     * @param http Spring이 제공하는 보안 구성기
     * @param environment DB/인증 프로필 활성 여부
     * @return 인증의 자격 검사는 서비스에 위임하고 다른 경로는 차단하는 필터 체인
     * @throws Exception 필터 구성 실패
     */
    @Bean
    public SecurityFilterChain bootstrapSecurity(HttpSecurity http, Environment environment) throws Exception {
        return http
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .requestCache(AbstractHttpConfigurer::disable)
            .formLogin(AbstractHttpConfigurer::disable)
            .httpBasic(AbstractHttpConfigurer::disable)
            .logout(AbstractHttpConfigurer::disable)
            // 인증은 Bearer만 사용하며 쿠키/Basic 세션을 만들지 않는다.
            .csrf(AbstractHttpConfigurer::disable)
            .authorizeHttpRequests(authorize -> {
                authorize.requestMatchers(HttpMethod.GET, "/internal/health/live").permitAll();
                if (environment.matchesProfiles("database & auth")) {
                    authorize.requestMatchers(HttpMethod.POST, "/demo-sessions", "/demo-sessions/current/reverify").permitAll();
                    authorize.requestMatchers(HttpMethod.DELETE, "/demo-sessions/current").permitAll();
                }
                if (environment.matchesProfiles("database & auth & finance")) {
                    authorize.requestMatchers(HttpMethod.GET, "/snapshot", "/transactions").permitAll();
                    authorize.requestMatchers(HttpMethod.POST, "/institution-links", "/obligations", "/reserves",
                        "/obligations/{id}/cancel", "/reserves/{id}/cancel").permitAll();
                    authorize.requestMatchers(HttpMethod.PATCH, "/account-selection", "/accounts/{id}", "/settings",
                        "/obligations/{id}", "/reserves/{id}").permitAll();
                    authorize.requestMatchers(HttpMethod.DELETE, "/obligations/{id}", "/reserves/{id}").permitAll();
                    if (environment.matchesProfiles("salary-notices")) {
                        authorize.requestMatchers(HttpMethod.GET, "/salary-notices/{payMonth}").permitAll();
                        authorize.requestMatchers(HttpMethod.PUT, "/salary-notices/{payMonth}/dismissal").permitAll();
                    }
                }
                authorize.anyRequest().denyAll();
            })
            .exceptionHandling(errors -> errors
                .authenticationEntryPoint((request, response, failure) -> response.setStatus(401))
                .accessDeniedHandler((request, response, failure) -> response.setStatus(403)))
            .build();
    }
}
