import 'package:flutter_test/flutter_test.dart';
import 'package:payse/features/auth/auth_validation.dart';

void main() {
  test(
    'name: Korean syllables or English, 2-20 chars, inner single spaces',
    () {
      for (final ok in ['홍길동', 'Kim', 'PAYSE 합성 alpha', '가나']) {
        expect(isValidName(normalizeName(ok)), isTrue, reason: ok);
      }
      for (final bad in ['가', 'ㄱㄴㄷ', '홍길동1', 'a  b', '가' * 21, '김-철수', '']) {
        expect(isValidName(normalizeName(bad)), isFalse, reason: bad);
      }
      expect(normalizeName('  홍길동 '), '홍길동', reason: '앞뒤 공백만 정규화');
    },
  );

  test('phone: only spaces and hyphens are removed, 010 + 8 digits', () {
    expect(normalizePhone('010-0000-0001'), '01000000001');
    expect(normalizePhone(' 010 0000 0001 '), '01000000001');
    expect(
      normalizePhone('010.0000.0001'),
      isNull,
      reason: '허용하지 않은 구분자는 지우지 않음',
    );
    expect(isValidPhone('01000000001'), isTrue);
    expect(isValidPhone('01100000001'), isFalse);
    expect(isValidPhone('0100000000'), isFalse);
    expect(isValidPhone(null), isFalse);
  });

  test('code: exactly 6 ASCII digits', () {
    expect(isValidCode('000001'), isTrue);
    expect(isValidCode('00001'), isFalse);
    expect(isValidCode('٠٠٠٠٠١'), isFalse, reason: 'ASCII 숫자만');
    expect(isValidCode('12345a'), isFalse);
  });

  test('weak PIN: same digit x6 or step +1/-1', () {
    for (final weak in [
      '000000',
      '111111',
      '012345',
      '123456',
      '456789',
      '987654',
      '543210',
    ]) {
      expect(isWeakPin(weak), isTrue, reason: weak);
    }
    for (final ok in ['135790', '123457', '890123', '112233']) {
      expect(isWeakPin(ok), isFalse, reason: ok);
    }
  });
}
