import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';

/// 2026-10-21: 개발용 데모 계정의 이름·전화번호·userId가 apps/api 시드 원본과 같은지 검사한다.
/// 원본이 바뀌면 실패한다. 코드 값은 원본에서 미확정이라 비교하지 않는다.
void main() {
  test('dev demo accounts match apps/api server-seeds.json', () {
    final seeds = jsonDecode(
      File('../api/fixtures/generated/server-seeds.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final users = (seeds['users'] as List).cast<Map<String, dynamic>>();

    expect(devDemoAccounts, hasLength(users.length));
    for (var i = 0; i < users.length; i++) {
      expect(devDemoAccounts[i].userId, users[i]['userId']);
      expect(devDemoAccounts[i].name, users[i]['syntheticName']);
      expect(devDemoAccounts[i].phone, users[i]['syntheticPhone']);
      expect(
        users[i]['codeVerifier'],
        startsWith('DISABLED:'),
        reason: '서버 코드가 확정되면 개발용 임시 코드를 교체해야 함',
      );
    }
  });
}
