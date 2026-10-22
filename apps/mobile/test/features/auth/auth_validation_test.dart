import 'package:flutter_test/flutter_test.dart';
import 'package:payse/features/auth/auth_validation.dart';

void main() {
  test('name: Korean syllables or English, 2-20 chars, no inner spaces', () {
    for (final ok in [
      '홍길동',
      'Kim',
      'kim',
      '데모알파',
      '가힣',
      '가' * 20,
      'abcdefghijklmnopqrst',
    ]) {
      expect(isValidName(normalizeName(ok)), isTrue, reason: ok);
    }
    for (final bad in [
      '',
      '가',
      '가' * 21,
      'ㄱㄴㄷ',
      '가',
      '홍길동1',
      '123456',
      '김-철수',
      'PAYSE 합성 alpha',
      '김 철수',
      'a  b',
      '\uabff가',
      '가\ud7a4',
    ]) {
      expect(isValidName(normalizeName(bad)), isFalse, reason: bad);
    }
    expect(normalizeName('  홍길동 '), '홍길동');
    expect(normalizeName('   '), '');
    expect(normalizeName('Kim'), 'Kim');
    expect(normalizeName('kim'), 'kim', reason: '대소문자를 접지 않음');
  });

  test('name: only U+0020 can be removed from either edge', () {
    for (final forbidden in ['\t', '\n', '\r', '\u00a0', '\u3000']) {
      for (final raw in ['$forbidden홍길동', '홍길동$forbidden', '홍$forbidden길동']) {
        expect(normalizeName(raw), raw, reason: '허용하지 않은 공백은 보존');
        expect(isValidName(normalizeName(raw)), isFalse, reason: raw);
      }
    }
    expect(normalizeName(' \t홍길동 '), '\t홍길동');
    expect(isValidName(normalizeName(' \t홍길동 ')), isFalse);
  });

  test('phone: only ASCII spaces and hyphens are removed', () {
    for (final raw in ['010-0000-0001', ' 010 0000 0001 ', '01000000001']) {
      expect(normalizePhone(raw), '01000000001');
      expect(isValidPhone(normalizePhone(raw)), isTrue);
    }
    for (final raw in [
      '010.0000.0001',
      '+8201000000001',
      '０１００００００００１',
      '010٠٠٠٠٠٠٠١',
      '010–0000–0001',
    ]) {
      expect(normalizePhone(raw), isNull, reason: raw);
    }
    for (final forbidden in ['\t', '\n', '\r', '\u00a0', '\u3000']) {
      for (final raw in [
        '${forbidden}01000000001',
        '01000000001$forbidden',
        '010${forbidden}00000001',
      ]) {
        expect(normalizePhone(raw), isNull, reason: raw);
      }
    }
    for (final bad in ['', '01100000001', '0100000000', '010000000001']) {
      expect(isValidPhone(bad), isFalse, reason: bad);
    }
    expect(isValidPhone(null), isFalse);
  });

  test('code: exactly six ASCII digits without normalization', () {
    expect(isValidCode('000001'), isTrue);
    expect(isValidCode('123456'), isTrue);
    for (final bad in [
      '',
      '00001',
      '0000001',
      '٠٠٠٠٠١',
      '０００００１',
      '12345a',
      ' 000001',
      '000001 ',
      '000001\n',
      '000001\t',
      '\u00a0000001',
      '000001\u3000',
    ]) {
      expect(isValidCode(bad), isFalse, reason: bad);
    }
    expect(
      () => isValidCode(123456 as dynamic),
      throwsA(isA<TypeError>()),
      reason: '타입 경계에서 숫자를 문자열 자격으로 자동 변환하지 않음',
    );
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
