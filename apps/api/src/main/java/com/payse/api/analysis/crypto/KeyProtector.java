package com.payse.api.analysis.crypto;

/**
 * 외부 관리형 키 서비스로 기억별 데이터 키만 감싸고 푼다. 평문 분석 본문은 받지 않는다.
 * @created 2026-10-29
 * @usedBy EnvelopeCipher
 */
public interface KeyProtector {
    /**
     * 사용자·기억 문맥에 바인딩하여 데이터 키를 보호한다. 입력 키를 보관하지 않는다.
     * @created 2026-10-29
     * @usedBy EnvelopeCipher.encrypt
     */
    WrappedKey wrap(byte[] key, byte[] context);

    /**
     * 승인된 키 참조·같은 문맥을 확인하고 독립 평문 키 배열을 반환한다. 호출자가 지운다.
     * @created 2026-10-29
     * @usedBy EnvelopeCipher.decrypt
     */
    byte[] unwrap(WrappedKey wrapped, byte[] context);
}
