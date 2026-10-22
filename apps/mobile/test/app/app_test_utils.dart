import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/auth/credential_stores.dart';
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

/// 2026-10-21: 세션과 PIN이 이미 있는 기기 저장소 한 쌍을 만들어 반환한다(재실행 상황).
Future<(MemorySessionStore, MemoryLocalPinStore)> signedInStores() async {
  final sessions = MemorySessionStore();
  await sessions.save(
    const StoredSession(
      userId: 'test-user',
      sessionId: 'test-session',
      accessToken: 'test-token',
    ),
  );
  final pins = MemoryLocalPinStore();
  await pins.setPin(testPin);
  return (sessions, pins);
}

/// 2026-10-21: 키패드에서 [pin]을 한 자리씩 누르고 화면을 안정시킨다.
Future<void> enterPin(WidgetTester tester, String pin) async {
  for (final c in pin.split('')) {
    await tester.tap(find.byKey(ValueKey('pin-key-$c')));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
