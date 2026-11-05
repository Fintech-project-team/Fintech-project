package com.payse.api.config;

import com.payse.api.constants.ApiConfigConstants.Analysis;
import com.payse.api.constants.ApiConfigConstants.Auth;
import com.payse.api.constants.ApiConfigConstants.Finance;
import com.payse.api.constants.ApiConfigConstants.Salary;
import com.payse.api.constants.ApiConfigConstants.Server;
import com.payse.api.constants.ApiConfigConstants;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
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
     * @modified 2026-11-01 - analysis 활성 시 사용자 인증을 거치는 분석 HTTP 경로 추가
     * @param http Spring이 제공하는 보안 구성기
     * @param environment DB/인증 프로필 활성 여부
     * @return 인증의 자격 검사는 서비스에 위임하고 다른 경로는 차단하는 필터 체인
     * @throws Exception 필터 구성 실패
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리
     * @modified 2026-11-02 - 같은 보안 구성기 호출을 람다로 명시하여 null 수신자 추론 경고 해소
     * @modified 2026-11-02 - 기존 인증 경계에 AI 기억 관리 목록 GET 추가
     * @modified 2026-11-04 - 금융 서비스 인증을 거치는 반복 결정 POST 경로 추가
     */
    @Bean
    public SecurityFilterChain bootstrapSecurity(HttpSecurity http, Environment environment)
        throws Exception {
        return http
            .sessionManagement(
                session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS)
            )
            .requestCache(configurer -> configurer.disable())
            .formLogin(configurer -> configurer.disable())
            .httpBasic(configurer -> configurer.disable())
            .logout(configurer -> configurer.disable())
            // 인증은 Bearer만 사용하며 쿠키/Basic 세션을 만들지 않는다.
            .csrf(configurer -> configurer.disable())
            .authorizeHttpRequests(
                authorize -> {
                    authorize.requestMatchers(HttpMethod.GET, Server.HEALTH_PATH).permitAll();
                    if (environment.matchesProfiles(Server.AUTH_PROFILE)) {
                        authorize
                            .requestMatchers(
                                HttpMethod.POST,
                                Auth.SESSIONS_PATH,
                                Auth.REVERIFY_PATH
                            )
                            .permitAll();
                        authorize.requestMatchers(HttpMethod.DELETE, Auth.CURRENT_SESSION_PATH)
                            .permitAll();
                    }
                    if (environment.matchesProfiles(Server.FINANCE_PROFILE)) {
                        if (environment.matchesProfiles(Server.ANALYSIS)) {
                            authorize
                                .requestMatchers(
                                    HttpMethod.POST,
                                    Analysis.JOBS_PATH,
                                    Analysis.JOB_INPUT_PATH,
                                    Analysis.JOB_RETRY_PATH,
                                    Analysis.RESULT_QUERY_PATH
                                )
                                .permitAll();
                            authorize
                                .requestMatchers(
                                    HttpMethod.GET,
                                    Analysis.JOB_PATH,
                                    ApiConfigConstants.Analysis.MEMORIES_PATH
                                )
                                .permitAll();
                            authorize.requestMatchers(HttpMethod.DELETE, Analysis.MEMORY_PATH)
                                .permitAll();
                        }
                        authorize
                            .requestMatchers(
                                HttpMethod.GET,
                                Finance.SNAPSHOT_PATH,
                                Finance.TRANSACTIONS_PATH
                            )
                            .permitAll();
                        authorize
                            .requestMatchers(
                                HttpMethod.POST,
                                Finance.LINKS_PATH,
                                Finance.OBLIGATIONS_PATH,
                                Finance.RESERVES_PATH,
                                Finance.RECURRING_DECISIONS_PATH,
                                Finance.CANCEL_OBLIGATION_PATH,
                                Finance.CANCEL_RESERVE_PATH
                            )
                            .permitAll();
                        authorize
                            .requestMatchers(
                                HttpMethod.PATCH,
                                Finance.SELECTION_PATH,
                                Finance.ACCOUNT_PATH,
                                Finance.SETTINGS_PATH,
                                Finance.OBLIGATION_PATH,
                                Finance.RESERVE_PATH
                            )
                            .permitAll();
                        authorize
                            .requestMatchers(
                                HttpMethod.DELETE,
                                Finance.OBLIGATION_PATH,
                                Finance.RESERVE_PATH
                            )
                            .permitAll();
                        if (environment.matchesProfiles(Server.SALARY_NOTICES)) {
                            authorize.requestMatchers(HttpMethod.GET, Salary.SALARY_NOTICE_PATH)
                                .permitAll();
                            authorize.requestMatchers(HttpMethod.PUT, Salary.DISMISSAL_PATH)
                                .permitAll();
                        }
                    }
                    authorize.anyRequest().denyAll();
                }
            )
            .exceptionHandling(
                errors -> errors
                    .authenticationEntryPoint(
                        (request, response, failure) -> response.setStatus(401)
                    )
                    .accessDeniedHandler((request, response, failure) -> response.setStatus(403))
            )
            .build();
    }
}
