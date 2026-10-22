import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';

/// 2026-10-22: docs/api-contract.md §2 통합 name 표(userId → name).
const _designNames = {
  'f0a4be6c-01d7-53eb-ab2c-74675b22fd8c': '데모알파',
  '87f7bbf9-2355-5210-9325-f25d83a8ff35': '데모베타',
  'd04073fd-f7ab-518d-8938-f2920d593db2': '데모감마',
};

/// 2026-10-22: apps/api 서버 시드의 users 배열을 읽어 반환한다.
List<Map<String, dynamic>> _seedUsers() {
  final seeds = jsonDecode(
    File('../api/fixtures/generated/server-seeds.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  return (seeds['users'] as List).cast<Map<String, dynamic>>();
}

void main() {
  test('dev demo accounts match the single-name server seed', () {
    final users = _seedUsers();
    expect(devDemoAccounts, hasLength(users.length));
    expect(
      users.map((user) => user['userId']).toSet(),
      _designNames.keys.toSet(),
    );
    for (final user in users) {
      final userId = user['userId'] as String;
      final account = devDemoAccounts.singleWhere((a) => a.userId == userId);
      expect(user['name'], _designNames[userId], reason: userId);
      expect(account.name, user['name'], reason: userId);
      expect(account.phone, user['syntheticPhone'], reason: userId);
      expect(user.containsKey('syntheticName'), isFalse, reason: userId);
      expect(user.containsKey('displayName'), isFalse, reason: userId);
      expect(
        user['codeVerifier'],
        startsWith('DISABLED:'),
        reason: '서버 코드가 확정되면 개발용 임시 코드를 교체해야 함',
      );
    }
  });
}
