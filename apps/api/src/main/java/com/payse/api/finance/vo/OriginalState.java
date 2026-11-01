package com.payse.api.finance.vo;

/**
 * 원거래 참조 없음·공개 가능한 확보 자료·미확보·기관 미연결을 분리한다.
 * @created 2026-10-29
 * @usedBy TransactionLink, TransactionRepository.mapLink
 */
public enum OriginalState { ABSENT, AVAILABLE, UNAVAILABLE, RESTRICTED }
