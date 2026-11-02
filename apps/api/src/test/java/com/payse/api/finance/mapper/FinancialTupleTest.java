package com.payse.api.finance.mapper;

import com.payse.api.ApiTestConstants.FinanceFields;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.payse.api.finance.error.FinancialException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.Tuple;
import jakarta.persistence.TupleElement;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * JDBC에서 JPA Tuple로 바뀌어도 금융 응답의 JSON 타입·UTC 시각·정수·null을 유지하는지 검사한다.
 * @created 2026-10-29
 * @usedBy Gradle JUnit
 */
class FinancialTupleTest {
    /**
     * 청구 항목의 UUID·부호 있는 금액·할부 정수·null은 SQL 원천 타입대로 옮긴다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 순회 대상 지역변수 분리
     */
    @Test
    void statementItemTypesPreserveUnknownAndSignedValues() throws Exception {
        UUID item = UUID.randomUUID();
        Map<String, Object> values = new LinkedHashMap<>();
        values.put(FinanceFields.ITEM_ID, item);
        values.put(FinanceFields.TRANSACTION_ID, null);
        values.put(FinanceFields.ORIGINAL_USED_AMOUNT_KRW, 600000L);
        values.put(FinanceFields.BILLED_PRINCIPAL_KRW, null);
        values.put(FinanceFields.FEE_OR_ADJUSTMENT_AMOUNT_KRW, -5000L);
        values.put(FinanceFields.BILLED_AMOUNT_KRW, -10000L);
        values.put(FinanceFields.INSTALLMENT_MONTHS, 6);
        values.put(FinanceFields.INSTALLMENT_ROUND, 2);
        ObjectNode result = map(values);
        assertEquals(item.toString(), result.path(FinanceFields.ITEM_ID).asString());
        assertTrue(result.path(FinanceFields.TRANSACTION_ID).isNull());
        assertTrue(result.path(FinanceFields.BILLED_PRINCIPAL_KRW).isNull());
        assertEquals(-5000L, result.path(FinanceFields.FEE_OR_ADJUSTMENT_AMOUNT_KRW).asLong());
        assertEquals(-10000L, result.path(FinanceFields.BILLED_AMOUNT_KRW).asLong());
        assertEquals(600000L, result.path(FinanceFields.ORIGINAL_USED_AMOUNT_KRW).asLong());
        assertEquals(6, result.path(FinanceFields.INSTALLMENT_MONTHS).asInt());
        assertEquals(2, result.path(FinanceFields.INSTALLMENT_ROUND).asInt());
        var optionalNumericFields = List.of(
            FinanceFields.ORIGINAL_USED_AMOUNT_KRW,
            FinanceFields.BILLED_PRINCIPAL_KRW,
            FinanceFields.FEE_OR_ADJUSTMENT_AMOUNT_KRW,
            FinanceFields.BILLED_AMOUNT_KRW,
            FinanceFields.INSTALLMENT_MONTHS,
            FinanceFields.INSTALLMENT_ROUND
        );
        for (String key : optionalNumericFields) {
            assertThrows(RuntimeException.class, () -> map(Map.of(key, "100")));
            assertThrows(RuntimeException.class, () -> map(Map.of(key, new BigDecimal("1.5"))));
        }
        assertThrows(
            RuntimeException.class,
            () -> map(Map.of(FinanceFields.ITEM_ID, "not-a-uuid"))
        );
    }

    /**
     * 동일 JSONB 배열의 문자열·JsonNode·PostgreSQL PGobject 반환을 같은 공개 값으로 옮긴다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void jsonRepresentationsHaveIdenticalMeaning() throws Exception {
        String json = "[{\"targetKind\":\"account\",\"requestedStart\":\"2025-10-20\"}]";
        var expected = JsonMapper.builder()
            .build()
            .readTree(json);
        assertEquals(
            expected,
            map(Map.of(FinanceFields.COVERAGE, json)).get(FinanceFields.COVERAGE)
        );
        assertEquals(
            expected,
            map(Map.of(FinanceFields.COVERAGE, expected)).get(FinanceFields.COVERAGE)
        );
        assertEquals(
            expected,
            map(Map.of(FinanceFields.COVERAGE, pgJson(json))).get(FinanceFields.COVERAGE)
        );
    }

    /**
     * DB date를 날짜로 보존하고 한국 오프셋·Instant·Timestamp는 동일 UTC 순간으로 응답한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void datesAndInstantsKeepTheirSeparateTypes() throws Exception {
        LocalDate date = LocalDate.of(2026, 10, 29);
        OffsetDateTime offset = OffsetDateTime.parse("2026-10-29T12:34:56.123456+09:00");
        String expected = "2026-10-29T03:34:56.123456Z";
        assertEquals(
            "2026-10-29",
            map(Map.of(FinanceFields.BOOKING_DATE, date))
                .get(FinanceFields.BOOKING_DATE)
                .asString()
        );
        assertEquals(
            "2026-10-29",
            map(Map.of(FinanceFields.BOOKING_DATE, java.sql.Date.valueOf(date)))
                .get(FinanceFields.BOOKING_DATE)
                .asString()
        );
        for (Object value : List.of(
            offset,
            offset.toInstant(),
            Timestamp.from(offset.toInstant())
        )) {
            assertEquals(
                expected,
                map(Map.of(FinanceFields.AS_OF, value))
                    .get(FinanceFields.AS_OF)
                    .asString()
            );
        }
    }

    /**
     * UUID·null·boolean·문자 버전은 원래 공개 타입을 보존한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void uuidNullBooleanAndVersionArePreserved() throws Exception {
        UUID owner = UUID.randomUUID();
        Map<String, Object> row = new LinkedHashMap<>();
        row.put(FinanceFields.USER_ID, owner);
        row.put(FinanceFields.WITHDRAWAL_ACCOUNT_ID, null);
        row.put(FinanceFields.BALANCE_REFLECTED, false);
        row.put(FinanceFields.DATA_VERSION, "9223372036854775807");
        ObjectNode result = map(row);
        assertEquals(owner.toString(), result.get(FinanceFields.USER_ID).asString());
        assertTrue(result.get(FinanceFields.WITHDRAWAL_ACCOUNT_ID).isNull());
        assertTrue(result.get(FinanceFields.BALANCE_REFLECTED).isBoolean());
        assertEquals(false, result.get(FinanceFields.BALANCE_REFLECTED).asBoolean());
        assertEquals("9223372036854775807", result.get(FinanceFields.DATA_VERSION).asString());
        assertEquals(
            owner.toString(),
            map(Map.of(FinanceFields.USER_ID, owner.toString()))
                .get(FinanceFields.USER_ID)
                .asString()
        );
    }

    /**
     * 정수로 정확히 표현되는 JDBC 숫자만 JSON 정수로 반환한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void integerAdaptersDoNotLosePrecision() throws Exception {
        for (Number value : List.of(
            (byte) 9,
            (short) 9,
            9,
            9L,
            BigInteger.valueOf(9),
            new BigDecimal("9.000")
        )) {
            assertEquals(
                9L,
                map(Map.of(FinanceFields.AMOUNT_KRW, value))
                    .get(FinanceFields.AMOUNT_KRW)
                    .asLong()
            );
        }
        assertEquals(
            Long.MAX_VALUE,
            map(Map.of("accountCount", BigInteger.valueOf(Long.MAX_VALUE)))
                .get("accountCount")
                .asLong()
        );
    }

    /**
     * 분수·부동소수점·숫자 문자열·long 초과를 절삭하거나 묵시 형 변환하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void invalidIntegersAreRejected() {
        for (Object value : List.of(
            new BigDecimal("1.5"),
            BigInteger.valueOf(Long.MAX_VALUE).add(BigInteger.ONE),
            1.0,
            Double.NaN,
            Float.POSITIVE_INFINITY,
            "3000",
            true
        )) {
            assertThrows(
                RuntimeException.class,
                () -> map(Map.of(FinanceFields.AMOUNT_KRW, value))
            );
        }
    }

    /**
     * 시간대 없는 시각이나 날짜 자리에 시각을 넣는 공급자 타입 오류를 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void missingTimeZoneIsNotAssumed() {
        assertThrows(
            FinancialException.class,
            () -> map(Map.of(FinanceFields.AS_OF, LocalDateTime.of(2026, 10, 29, 12, 0)))
        );
        assertThrows(
            FinancialException.class,
            () -> map(
                Map.of(
                    FinanceFields.BOOKING_DATE,
                    Timestamp.from(Instant.parse("2026-10-29T00:00:00Z"))
                )
            )
        );
        assertThrows(
            FinancialException.class,
            () -> map(Map.of(FinanceFields.AS_OF, "2026-10-29T12:00:00+09:00"))
        );
    }

    /**
     * JSONB의 배열 계약 밖 값과 boolean·버전의 잘못된 타입을 조용히 전달하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void unexpectedNativeTypesAreRejected() {
        for (Object value : List.of(
            "null",
            "{}",
            "true",
            "",
            List.of("untyped")
        )) {
            assertThrows(RuntimeException.class, () -> map(Map.of(FinanceFields.COVERAGE, value)));
        }
        assertThrows(FinancialException.class, () -> map(Map.of(FinanceFields.INCLUDED, "true")));
        assertThrows(FinancialException.class, () -> map(Map.of(FinanceFields.DATA_VERSION, 7L)));
    }

    /**
     * 단위 테스트는 공개 SQL의 별칭·Tuple 값을 구성하고 private 변환 경계만 호출한다.
     * 실제 트랜잭션·RLS·네이티브 드라이버 타입 검증은 PostgreSQL 통합 검사가 담당한다.
     * @created 2026-10-29
     * @usedBy FinancialTupleTest
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode map(Map<String, Object> values) throws Exception {
        EntityManager entityManager = mock(EntityManager.class);
        when(entityManager.getEntityManagerFactory()).thenReturn(mock(EntityManagerFactory.class));
        FinancialRepository repository = new FinancialRepository(entityManager);
        Tuple tuple = mock(Tuple.class);
        List<TupleElement<?>> elements = new ArrayList<>();
        for (Map.Entry<String, Object> entry : values.entrySet()) {
            TupleElement<?> element = mock(TupleElement.class);
            when(element.getAlias()).thenReturn(entry.getKey());
            when(tuple.get(entry.getKey())).thenReturn(entry.getValue());
            elements.add(element);
        }
        when(tuple.getElements()).thenReturn(elements);
        Method method = FinancialRepository.class.getDeclaredMethod("mapRow", Tuple.class);
        method.setAccessible(true);
        try {
            return (ObjectNode) method.invoke(repository, tuple);
        } catch (InvocationTargetException failure) {
            if (failure.getCause() instanceof RuntimeException cause) {
                throw cause;
            }
            throw failure;
        }
    }

    /**
     * runtimeOnly 드라이버의 실제 PGobject를 테스트 런타임에서 생성한다.
     * @created 2026-10-29
     * @usedBy jsonRepresentationsHaveIdenticalMeaning
     */
    private Object pgJson(String json) throws Exception {
        Class<?> type = Class.forName("org.postgresql.util.PGobject");
        Object value = type.getConstructor().newInstance();
        type.getMethod("setType", String.class).invoke(value, "jsonb");
        type.getMethod("setValue", String.class).invoke(value, json);
        return value;
    }
}
