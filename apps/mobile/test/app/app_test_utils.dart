import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/credential_stores.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/fixture_scenario.dart';
import 'package:payse/data/snapshot_source.dart';

/// 2026-10-21: 테스트에서 직접 움직이는 시계. 위젯 테스트의 pump 시간과 함께 [advance]한다.
class FakeClock {
  DateTime value = DateTime(2026, 10, 21, 9);

  /// 2026-10-21: 현재 가짜 시각을 반환한다.
  DateTime now() => value;

  /// 2026-10-21: 가짜 시각을 [d]만큼 앞으로 옮긴다.
  void advance(Duration d) => value = value.add(d);
}

/// 2026-10-20: 앱 에셋 복사본을 미리 읽어 두고 즉시 돌려주는 테스트용 출처(위젯 테스트의 가짜 시계와 호환).
class PreloadedAssetSource implements SnapshotSource {
  /// 2026-10-20: 4개 스냅샷 원문을 디스크에서 동기로 읽어 둔다.
  PreloadedAssetSource()
    : _raw = {
        for (final s in FixtureScenario.values)
          s: File('assets/fixtures/${s.fileStem}.json').readAsStringSync(),
      };

  final Map<FixtureScenario, String> _raw;

  /// 2026-10-20: 미리 읽은 [scenario] 원문을 반환한다.
  @override
  Future<String> load(FixtureScenario scenario) async => _raw[scenario]!;
}

/// 2026-10-21: 테스트용 PIN. 쉬운 비밀번호 규칙에 걸리지 않는 값이다.
const String testPin = '135790';

/// 2026-10-21: 세션과 PIN이 이미 있는 기기 저장소를 만들어 반환한다(재실행 상황).
/// 2026-10-22: 세션은 개발 데모 alpha 계정으로 가짜 인증 저장소에서 실제로 발급받아, 금융 조회가 토큰을 확인할 수 있게 한다.
Future<(MemorySessionStore, MemoryLocalPinStore, FakeAuthRepository)>
signedInStores() async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final alpha = devDemoAccounts.first;
  final issued = await auth.createSession(
    DemoCredentials(name: alpha.name, phone: alpha.phone, code: alpha.code),
  );
  final session = (issued as AuthOk<DemoSession>).value;
  final sessions = MemorySessionStore();
  await sessions.save(
    StoredSession(
      userId: session.userId,
      name: session.name,
      sessionId: session.sessionId,
      accessToken: session.accessToken,
    ),
  );
  final pins = MemoryLocalPinStore();
  await pins.setPin(testPin);
  return (sessions, pins, auth);
}

/// 2026-10-22: 연결 전 사용자의 연결 자리에서 '홈으로 가기'(임시 화면 이동)를 눌러 하단 탭으로 간다.
Future<void> skipConnectionPlaceholder(WidgetTester tester) async {
  await tester.tap(find.text('홈으로 가기'));
  await tester.pumpAndSettle();
}

/// 2026-10-21: 키패드에서 [pin]을 한 자리씩 누르고 화면을 안정시킨다.
Future<void> enterPin(WidgetTester tester, String pin) async {
  for (final c in pin.split('')) {
    await tester.tap(find.byKey(ValueKey('pin-key-$c')));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
