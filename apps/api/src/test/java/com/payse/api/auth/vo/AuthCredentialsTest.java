package com.payse.api.auth.vo;

import static org.junit.jupiter.api.Assertions.*;

import java.util.Arrays;
import org.junit.jupiter.api.Test;

/**
 * Flutter와 같은 문자·정규화 경계 및 민감 입력 표현을 검사한다.
 * @created 2026-10-22
 * @usedBy Gradle test의 JUnit 실행
 */
class AuthCredentialsTest {
    /**
     * 허용 ASCII 구분자만 제거하며 영문 대소문자와 선행 코드 0을 보존한다.
     * @created 2026-10-22
     * @usedBy JUnit test
     */
    @Test
    void normalizesOnlyPermittedSeparators() {
        var credentials = new AuthCredentials("  데모알파  ", " 010-0000-0001 ", "000001");
        assertEquals("데모알파", credentials.name());
        assertEquals("01000000001", credentials.phone());
        assertEquals("000001", credentials.code());
        assertNotEquals(new AuthCredentials("Kim", "01000000001", "000001"),
            new AuthCredentials("kim", "01000000001", "000001"));
        assertEquals("Ab", new AuthCredentials("Ab", "01000000001", "000001").name());
        assertEquals("가".repeat(20), new AuthCredentials("가".repeat(20), "01000000001", "000001").name());
    }

    /**
     * 이름 경계·내부 공백·비ASCII 공백·분해 한글·숫자·보조 문자를 거절한다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void rejectsInvalidNames() {
        for (String name : Arrays.asList(null, "", " ", "가", "가".repeat(21), "김 데모", "김1",
                "\t김데모", "김데모\n", "\u00a0김데모", "김데모\u3000", "ㄱㄴ", "가", "김😀", "Ｋｉｍ")) {
            assertThrows(IllegalArgumentException.class, () -> new AuthCredentials(name, "01000000001", "000001"));
        }
    }

    /**
     * 전화의 숫자 집합·접두사·길이와 허용 구분자 경계를 검사한다.
     * @created 2026-10-22
     * @usedBy JUnit test
     */
    @Test
    void rejectsInvalidPhones() {
        for (String phone : Arrays.asList(null, "", "0100000000", "010000000011", "01100000001",
                "+821000000001", "010\t00000001", "010\n00000001", "010\u00a000000001",
                "０１００００００００１", "010–0000–0001", "0100000000a")) {
            assertThrows(IllegalArgumentException.class, () -> new AuthCredentials("데모알파", phone, "000001"));
        }
        assertEquals("01000000001", new AuthCredentials("데모알파", "0-1 0 0-0000 001", "000001").phone());
    }

    /**
     * 코드를 trim하거나 유니코드 숫자·다른 길이로 허용하지 않는다.
     * @created 2026-10-22
     * @usedBy JUnit test
     */
    @Test
    void rejectsInvalidCodes() {
        for (String code : Arrays.asList(null, "", "00001", "0000001", "000001 ", " 000001", "00000\n",
                "０００００１", "٠٠٠٠٠١", "0000a1", "000-01")) {
            assertThrows(IllegalArgumentException.class, () -> new AuthCredentials("데모알파", "01000000001", code));
        }
    }

    /**
     * 객체 표현과 형식 오류에 제출한 민감 문자열이 복제되지 않는다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void redactsSensitiveInput() {
        var credentials = new AuthCredentials("데모알파", "01000000001", "000001");
        assertEquals("AuthCredentials[REDACTED]", credentials.toString());
        String invalid = "private-name-must-not-be-repeated";
        var error = assertThrows(IllegalArgumentException.class,
            () -> new AuthCredentials(invalid, "01000000001", "000001"));
        assertFalse(error.toString().contains(invalid));
    }
}
