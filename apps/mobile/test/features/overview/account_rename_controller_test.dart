import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/features/overview/account_rename_controller.dart';

import '../connection/connection_test_support.dart';

void main() {
  test(
    'allowed letters: Hangul with jamo, ASCII, space, 32 specials, emoji',
    () {
      for (final g in [
        '가',
        'ㅋ',
        'ㅏ',
        'a',
        'Z',
        '7',
        ' ',
        '!',
        '~',
        '\\',
        '💰',
        '👍🏽',
        '👨‍👩‍👧‍👦',
        '🇰🇷',
        '1️⃣',
        '❤️',
      ]) {
        expect(isNicknameGrapheme(g), isTrue, reason: g);
      }
      for (final g in ['生', 'あ', '＠', '·', '€', '\n']) {
        expect(isNicknameGrapheme(g), isFalse, reason: g);
      }
    },
  );

  test(
    'formatter drops blocked letters, reports them and keeps 12 graphemes',
    () {
      final reports = <bool>[];
      final formatter = NicknameInputFormatter(onBlocked: reports.add);
      TextEditingValue run(String text) => formatter.formatEditUpdate(
        TextEditingValue.empty,
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );

      expect(run('生活비').text, '비');
      expect(reports.last, isTrue);
      expect(run('생활비').text, '생활비');
      expect(reports.last, isFalse);
      expect(run('가나다라마바사아자차카타파').text, '가나다라마바사아자차카타');
      expect(run('👨‍👩‍👧‍👦👨‍👩‍👧‍👦').text, '👨‍👩‍👧‍👦👨‍👩‍👧‍👦');
    },
  );

  test('target trims and empties to null; save needs a real change', () {
    final snapshot = betaSnapshot(
      {...betaBanks},
      mutate: (source) =>
          ((source['accounts']! as List).first as Map)['nickname'] = '생활비',
    );
    final account = snapshot.accounts!.first;
    final c = AccountRenameController(
      repository: ScriptedRepository(),
      snapshot: snapshot,
      accountId: account.accountId,
      onSessionInvalid: () {},
    );
    addTearDown(c.dispose);

    expect(c.text, '생활비');
    expect(c.canSave, isFalse);
    c.setText('  생활비 ');
    expect(c.target, '생활비');
    expect(c.canSave, isFalse, reason: '앞뒤 공백만 다르면 저장할 것이 없음');
    c.setText('   ');
    expect(c.target, isNull);
    expect(c.canSave, isTrue, reason: '이름이 있던 계좌를 비우면 원래 이름으로 되돌림');
    c.setText('!!');
    expect(c.specialsOnly, isTrue);
    expect(c.canSave, isFalse);
  });
}
