package com.payse.api.architecture;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

/**
 * 생성/수정 주석 검사기가 누락·잘못된 날짜·연결되지 않은 주석을 거절하는지 검사한다.
 * @created 2026-10-20
 * @usedBy Gradle test의 JUnit 실행
 * @modified 2026-10-20 - 생성일 불명·빈 수정 태그·익명 선언의 검사 경계 검증 추가
 */
class ApiDocRulesTest {
    private static final String DOC = "/** 목적 설명.\n * @created 2026-10-20\n * @usedBy JUnit test\n */\n";

    /**
     * record 자동 메서드에 중복 주석을 요구하지 않고 명시적 메서드는 확인한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void acceptsDocumentedMembers() throws Exception {
        assertEquals(0, check(DOC + "record Example(int value) { " + DOC + "int next() { return value; } }"));
    }

    /**
     * 클래스 주석을 메서드 주석으로 잘못 인정하지 않는지 검사한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void rejectsMissingDocs() throws Exception {
        assertEquals(1, check(DOC + "class Example { int next() { return 1; } }"));
        assertEquals(1, check(DOC.replace(" * @usedBy JUnit test\n", "") + "class Example {}"));
    }

    /**
     * 형식만 날짜처럼 보이는 값과 생성 전 수정 날짜를 거절한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void rejectsInvalidDates() throws Exception {
        assertEquals(1, check(DOC.replace("2026-10-20", "2026-02-30") + "class Example {}"));
        assertEquals(1, check(DOC.replace(" */", " * @modified 2026-10-19 - 과거 수정\n */") + "class Example {}"));
        assertEquals(1, check(DOC.replace(" */", " * @modified 2026-10-21\n */") + "class Example {}"));
    }

    /**
     * 유효한 수정일과 목적을 가진 주석을 수용한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void acceptsModificationReason() throws Exception {
        assertEquals(0, check(DOC.replace(" */", " * @modified 2026-10-21 - 검증 조건 보완\n */") + "class Example {}"));
    }

    /**
     * 사유가 있는 생성일 불명 표기를 허용하고 날짜를 추측하도록 강제하지 않는다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void requiresUnknownDateReason() throws Exception {
        assertEquals(0, check(DOC.replace("2026-10-20", "unknown - 이전 저장소 이력 확인 불가") + "class Example {}"));
        assertEquals(1, check(DOC.replace("2026-10-20", "unknown") + "class Example {}"));
        assertEquals(1, check(DOC.replace("2026-10-20", "unknown -   ") + "class Example {}"));
        assertEquals(0, check(DOC.replace("2026-10-20", "unknown - 이력 확인 불가")
            .replace(" */", " * @modified 2026-10-20 - 현재 수정 목적\n */") + "class Example {}"));
    }

    /**
     * 중간 또는 마지막 위치의 빈 수정 태그도 검사에서 빠지지 않도록 확인한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void rejectsEmptyModificationTags() throws Exception {
        assertEquals(1, check(DOC.replace(" * @usedBy", " * @modified\n * @usedBy") + "class Example {}"));
        assertEquals(1, check(DOC.replace(" */", " * @modified\n */") + "class Example {}"));
        assertEquals(1, check(DOC.replace(" */", " * @modified   \n *    \n */") + "class Example {}"));
    }

    /**
     * 수정 태그가 여러 개면 모두 유효해야 하며 하나라도 빈 값이면 거절한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void checksEveryModificationTag() throws Exception {
        String first = " * @modified 2026-10-20 - 첫 목적\n";
        assertEquals(0, check(DOC.replace(" */", first + " * @modified 2026-10-21 - 다음 목적\n */") + "class Example {}"));
        assertEquals(1, check(DOC.replace(" */", first + " * @modified\n */") + "class Example {}"));
        assertEquals(1, check(DOC.replace(" */", " * @modified\n" + first + " */") + "class Example {}"));
    }

    /**
     * 람다와 자동 생성 메서드는 제외하되 익명 클래스의 직접 작성한 메서드는 검사한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void checksAnonymousMethodDocs() throws Exception {
        assertEquals(0, check(DOC + "class Example { Runnable action = () -> {}; }"));
        assertEquals(1, check(DOC + "class Example { Runnable action = new Runnable() { public void run() {} }; }"));
        assertEquals(0, check(DOC + "class Example { Runnable action = new Runnable() { "
            + DOC + "@Override public void run() {} }; }"));
    }

    /**
     * 직접 선언한 생성자는 필수 주석을 요구하고 암시적 생성자는 추가 요구하지 않는다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void requiresConstructorDocs() throws Exception {
        assertEquals(0, check(DOC + "class Example {}"));
        assertEquals(1, check(DOC + "class Example { Example() {} }"));
        assertEquals(0, check(DOC + "class Example { " + DOC + "Example() {} }"));
    }

    /**
     * DTO 여부와 관계없이 인터페이스·enum·annotation 같은 이름 있는 타입도 확인한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void checksNamedTypes() throws Exception {
        assertEquals(1, check("interface Example {}"));
        assertEquals(1, check("enum Example { A }"));
        assertEquals(1, check("@interface Example {}"));
        assertEquals(0, check(DOC + "interface Example {}"));
        assertEquals(0, check(DOC + "enum Example { A }"));
        assertEquals(0, check(DOC + "@interface Example {}"));
    }

    /**
     * 날짜 태그만 있고 목적이 없거나 생성일을 중복 기재한 주석을 거절한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void rejectsInvalidRequiredTags() throws Exception {
        assertEquals(1, check(DOC.replace("목적 설명.", "") + "class Example {}"));
        assertEquals(1, check(DOC.replace(" */", " * @created 2026-10-20\n */") + "class Example {}"));
        assertEquals(1, check(DOC.replace(" * @usedBy JUnit test", " * @usedBy   ") + "class Example {}"));
    }

    /**
     * 격리한 예제에 실제 JDK 구문 검사기를 실행한다.
     * @created 2026-10-20
     * @usedBy 이 클래스의 주석 계약 테스트 메서드
     * @param source 검사할 예제 Java 소스
     * @return 검사기의 종료 코드
     */
    private int check(String source) throws Exception {
        Path parent = Files.createDirectories(Path.of("build", "doc-rule-tests"));
        Path directory = Files.createTempDirectory(parent, "case-");
        Process process = null;
        try {
            Files.writeString(directory.resolve("Example.java"), source, StandardCharsets.UTF_8);
            String java = Path.of(System.getProperty("java.home"), "bin",
                System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java").toString();
            process = new ProcessBuilder(java, "tools/VerifyApiDocs.java", directory.toString())
                .redirectErrorStream(true).redirectOutput(directory.resolve("output.txt").toFile()).start();
            assertTrue(process.waitFor(30, TimeUnit.SECONDS), "documentation checker timeout");
            return process.exitValue();
        } finally {
            if (process != null && process.isAlive()) process.destroyForcibly().waitFor();
            try (var paths = Files.walk(directory)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path);
            }
        }
    }
}
