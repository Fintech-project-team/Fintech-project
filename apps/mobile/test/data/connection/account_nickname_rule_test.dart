import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/financial_api.dart';

void main() {
  test('counts visible characters after trimming', () {
    expect(AccountNicknameRule.length('  생활비 '), 3);
    expect(AccountNicknameRule.length('👨‍👩‍👧‍👦👍🏽'), 2);
    expect(AccountNicknameRule.length(''), 0);
  });

  test('accepts 1 to 12 characters with at least one non-special', () {
    expect(AccountNicknameRule.isValid('생활비'), isTrue);
    expect(AccountNicknameRule.isValid('ㅋㅋ'), isTrue);
    expect(AccountNicknameRule.isValid('💰💰'), isTrue);
    expect(AccountNicknameRule.isValid('여행 2026!'), isTrue);
    expect(AccountNicknameRule.isValid('가나다라마바사아자차카타'), isTrue);
    expect(AccountNicknameRule.isValid('가나다라마바사아자차카타파'), isFalse);
    expect(AccountNicknameRule.isValid('   '), isFalse);
    expect(AccountNicknameRule.isValid('!!!'), isFalse);
    expect(AccountNicknameRule.isValid('! @ #'), isFalse);
  });

  test('the special set is the 32 PC keyboard symbols', () {
    expect(AccountNicknameRule.specials.length, 32);
    for (var i = 0; i < 32; i += 12) {
      final part = AccountNicknameRule.specials.substring(
        i,
        i + 12 > 32 ? 32 : i + 12,
      );
      expect(AccountNicknameRule.isValid(part), isFalse, reason: part);
    }
  });
}
