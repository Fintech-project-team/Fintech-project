package com.payse.api.auth.error;

import com.payse.api.constants.ApiMessageConstants.Auth;

/**
 * 인증 저장 장애를 입력값·SQL·DB 원인 예외 없이 전달한다. 자격 불일치와는 다르다.
 * @created 2026-10-25
 * @usedBy AuthRepository, AuthTransactions, 미연결: 예정 HTTP 503 매핑
 */
public final class AuthStoreException extends RuntimeException {

    /**
     * 원문과 원인 체인을 보관하지 않는 고정 메시지로 장애를 전달한다.
     * @created 2026-10-25
     * @usedBy AuthRepository, AuthTransactions
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리
     */
    public AuthStoreException() {
        super(Auth.STORAGE_FAILED);
    }
}
