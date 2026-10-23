import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/credential_stores.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/fixture_scenario.dart';
import 'package:payse/data/snapshot_source.dart';
import 'package:payse/features/connection/connection_presentation_policy.dart';

import '../features/connection/connection_test_support.dart';

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

/// 2026-10-23: 기다리지 않는 연결 표시 정책을 만드는 함수를 반환한다. 실패 연출 사용 여부는 앱의 토글 값을 따르고,
/// [draws] 순서(실수열)로 실패 추첨을 재현한다. 기본값은 실패 없음이다.
ConnectionPresentationPolicy Function(bool Function()) instantPresentation({
  List<double> draws = const [0.9],
}) =>
    (enabled) => ConnectionPresentationPolicy(
      failuresEnabled: enabled,
      random: SequenceRandom(doubles: draws),
      wait: (_) async {},
    );

/// 2026-10-23: 진입 로딩이 끝나 '다음'이 보이면 눌러 12-1로 간다. 진입 로딩이 없는 화면(01-1 재개 등)에서는 하지 않는다.
Future<void> passEntryLoading(WidgetTester tester) async {
  final next = find.byKey(const ValueKey('entry-next'));
  if (next.evaluate().isEmpty) return;
  await tester.tap(next);
  await tester.pumpAndSettle();
}

/// 2026-10-23: 12-1 목록 맨 위로 돌아가 첫 은행 하나를 골라 동의·불러오기·기본 계좌 선택·01-2 확인까지 마치고 홈으로 간다.
/// 연결 흐름 자체의 검사는 연결 테스트에 두며, 여기서는 홈이 필요한 테스트의 준비만 한다.
Future<void> connectAndChooseAccounts(WidgetTester tester) async {
  await passEntryLoading(tester);
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
  await tester.pumpAndSettle();
  await tester.tap(find.byWidgetPredicate(_isBankRow).first);
  await tester.pump();
  await tester.tap(find.text('다음'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('consent-all')));
  await tester.pump();
  await tester.tap(find.text('동의하고 불러오기'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('계속하기'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('이 계좌로 계산하기'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('확인했어요'));
  await tester.pumpAndSettle();
}

/// 2026-10-23: 12-1의 은행 행 위젯이면 true를 반환한다.
bool _isBankRow(Widget w) {
  final key = w.key;
  return key is ValueKey<String> && key.value.startsWith('institution-bank.');
}

/// 2026-10-21: 키패드에서 [pin]을 한 자리씩 누르고 화면을 안정시킨다.
Future<void> enterPin(WidgetTester tester, String pin) async {
  for (final c in pin.split('')) {
    await tester.tap(find.byKey(ValueKey('pin-key-$c')));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
