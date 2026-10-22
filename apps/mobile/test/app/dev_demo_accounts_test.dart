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

/// 2026-10-22: 서버 시드가 아직 이행 전일 때의 이름(userId → syntheticName).
const _legacySeedNames = {
  'f0a4be6c-01d7-53eb-ab2c-74675b22fd8c': 'PAYSE 합성 alpha',
  '87f7bbf9-2355-5210-9325-f25d83a8ff35': 'PAYSE 합성 beta',
  'd04073fd-f7ab-518d-8938-f2920d593db2': 'PAYSE 합성 gamma',
};

const _migrationHint = '서버 이름 이행을 확인하고 시드 대조 기준을 갱신하세요';

/// 2026-10-22: apps/api 서버 시드의 users 배열을 읽어 반환한다.
List<Map<String, dynamic>> _seedUsers() {
  final seeds = jsonDecode(
    File('../api/fixtures/generated/server-seeds.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  return (seeds['users'] as List).cast<Map<String, dynamic>>();
}

void main() {
  test('dev demo accounts keep seed userId·phone and use the design names', () {
    final users = _seedUsers();
    expect(devDemoAccounts, hasLength(users.length));
    for (var i = 0; i < users.length; i++) {
      final account = devDemoAccounts[i];
      expect(account.userId, users[i]['userId']);
      expect(account.phone, users[i]['syntheticPhone']);
      expect(account.name, _designNames[account.userId]);
      expect(
        users[i]['codeVerifier'],
        startsWith('DISABLED:'),
        reason: '서버 코드가 확정되면 개발용 임시 코드를 교체해야 함',
      );
    }
  });

  test(
    'server seed names are still pre-migration (detects the name migration)',
    () {
      for (final user in _seedUsers()) {
        final userId = user['userId'] as String;
        expect(
          user.containsKey('name'),
          isFalse,
          reason: '$userId: 시드에 name 필드가 생겼습니다. $_migrationHint',
        );
        expect(
          user.containsKey('syntheticName') && user.containsKey('displayName'),
          isTrue,
          reason: '$userId: 시드 이름 필드 구조가 바뀌었습니다. $_migrationHint',
        );
        expect(
          user['syntheticName'],
          _legacySeedNames[userId],
          reason: '$userId: 시드 이름이 바뀌었습니다. $_migrationHint',
        );
      }
    },
  );
}
