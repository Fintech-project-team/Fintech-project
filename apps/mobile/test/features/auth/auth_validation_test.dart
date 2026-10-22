import 'package:flutter_test/flutter_test.dart';
import 'package:payse/features/auth/auth_validation.dart';

void main() {
  test(
    'name: only edge U+0020 is trimmed; Korean syllables or English 2-20',
    () {
      for (final ok in ['데모알파', 'Kim', '가나', '홍길동', 'abcdefghijklmnopqrst']) {
        expect(isValidName(normalizeName(ok)), isTrue, reason: ok);
      }
      expect(normalizeName('  데모알파 '), '데모알파', reason: '앞뒤 일반 공백만 제거');
      expect(isValidName(normalizeName('  데모알파 ')), isTrue);

      for (final bad in [
        '데모 알파',
        'PAYSE 합성 alpha',
        '데모\t알파',
        '\t데모알파',
        '데모알파\n',
        ' 데모알파',
        '데모알파　',
        '데모　알파',
        '가',
        'ㄱㄴㄷ',
        '홍길동1',
        '가' * 21,
        '김-철수',
        '',
      ]) {
        expect(isValidName(normalizeName(bad)), isFalse, reason: bad);
      }
      expect(normalizeName('\t데모알파'), '\t데모알파', reason: '탭은 지우지 않음');
      expect(normalizeName(' 데모알파'), ' 데모알파', reason: 'NBSP는 지우지 않음');
    },
  );

  test('phone: only U+0020 and U+002D are removed, 010 + 8 ASCII digits', () {
    expect(normalizePhone('010-0000-0001'), '01000000001');
    expect(normalizePhone(' 010 0000 0001 '), '01000000001');
    expect(isValidPhone(normalizePhone('010-0000 0001')), isTrue);
    for (final bad in [
      '010\t0000\t0001',
      '010\n00000001',
      '010 00000001',
      '010　00000001',
      '010.0000.0001',
      '+821000000001',
      '０１０００００００１',
      '01100000001',
      '0100000000',
    ]) {
      expect(isValidPhone(normalizePhone(bad)), isFalse, reason: bad);
    }
  });

  test('code: exactly 6 ASCII digits, never normalized', () {
    expect(isValidCode('000001'), isTrue);
    for (final bad in [
      '00001',
      ' 000001',
      '000001 ',
      '٠٠٠٠٠١',
      '０００００１',
      '12345a',
    ]) {
      expect(isValidCode(bad), isFalse, reason: bad);
    }
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
