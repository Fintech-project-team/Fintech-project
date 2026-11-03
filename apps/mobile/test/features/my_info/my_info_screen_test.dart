import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/app/logout_action.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/my_info/my_info_screen.dart';
import 'package:payse/features/overview/accounts_screen.dart';
import 'package:payse/features/overview/home_screen.dart' show asOfLabel;
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/connection/connection_test_utils.dart';
import '../connection/connection_test_support.dart';

/// 2026-11-03: 데모알파(demo-ready)를 모두 연결하고 입출금 4개를 계산에 포함한 가짜 서버 세션을 만든다.
Future<(FakeUserFinancialRepository, FinancialSnapshot)> _connected() async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (userId) async => readSource('demo-ready'),
  );
  final a = devDemoAccounts.first;
  final session = await auth.createSession(
    DemoCredentials(name: a.name, phone: a.phone, code: a.code),
  );
  final token = (session as AuthOk<DemoSession>).value.accessToken;
  final repo = FakeUserFinancialRepository(server: server, accessToken: token);
  WriteContext w(String v, String k) => WriteContext(
    expectedDataVersion: v,
    ruleVersion: 'PAYSE-CALC-1',
    idempotencyKey: k,
  );
  await repo.linkInstitutions([
    'bank.kb',
    'bank.shinhan',
    'bank.hana',
    'bank.ibk',
    'bank.kakao',
    'card.hyundai',
  ], w('1', 'l'));
  final saved = await repo.selectAccounts([
    '6069b37a-abf5-56fc-8bf0-153f5301fd1c',
    '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc',
    '4021635f-1b2c-534d-b5b6-9680b3c8d5f2',
    '1ce9128d-d667-5bfc-bed0-949a571c78f5',
  ], w('2', 's'));
  final json = (saved as FinancialOk<WriteSuccess>).value.snapshot;
  return (repo, FinancialSnapshot.fromJson(json));
}

/// 2026-11-03: 버전 읽기 [version], 저장 연결 [repository], 이름 [userName]으로 내 정보 화면을 띄운다.
Future<int Function()> _pump(
  WidgetTester tester,
  FinancialSnapshot snapshot, {
  UserFinancialRepository? repository,
  String? userName = '데모알파',
  AppVersionReader? version,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var salaryOpened = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: MyInfoScreen(
          snapshot: snapshot,
          userName: userName,
          writer: repository == null
              ? null
              : (
                  repository: repository,
                  policy: instantPolicy(),
                  onSessionInvalid: () {},
                  onSnapshot: (_) {},
                ),
          onEditSalary: () => salaryOpened++,
          footer: LogoutAction(onLogout: () async => null),
          version: version,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return () => salaryOpened;
}

/// 2026-11-03: 고정 버전 0.1.0+1을 돌려준다.
Future<AppVersion?> _v010() async => (version: '0.1.0', buildNumber: '1');

/// 2026-11-03: 찾은 위젯의 화면 위쪽 좌표를 반환한다.
double _top(WidgetTester tester, Finder finder) => tester.getTopLeft(finder).dy;

void main() {
  late FakeUserFinancialRepository repo;
  late FinancialSnapshot snapshot;

  setUp(() async {
    (repo, snapshot) = await _connected();
  });

  group('my info tab', () {
    testWidgets('name, as-of above the list, two rows, logout, version', (
      tester,
    ) async {
      await _pump(tester, snapshot, repository: repo, version: _v010);

      final name = find.text('데모알파님');
      final asOf = find.text(asOfLabel(snapshot.asOf));
      final salary = find.byKey(const ValueKey('my-info-salary'));
      final accounts = find.byKey(const ValueKey('my-info-accounts'));
      final logout = find.byKey(const ValueKey('logout-button'));
      final version = find.text('PAYSE 0.1.0 (1)');
      for (final f in [name, asOf, salary, accounts, logout, version]) {
        expect(f, findsOneWidget);
      }
      final tops = [
        for (final f in [name, asOf, salary, accounts, logout, version])
          _top(tester, f),
      ];
      expect(tops, [...tops]..sort(), reason: '위에서부터 시안 순서');

      expect(
        find.descendant(
          of: salary,
          matching: find.text(
            salarySummary(snapshot, snapshot.settings!.salary),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: accounts, matching: find.text('계좌 4개 포함')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
      expect(find.textContaining('결제일'), findsNothing, reason: '카드 줄 없음');
      expect(find.textContaining('준비 중'), findsNothing);
    });

    testWidgets('월급 정보 opens the salary editor callback', (tester) async {
      final opened = await _pump(tester, snapshot, repository: repo);
      await tester.tap(find.byKey(const ValueKey('my-info-salary')));
      expect(opened(), 1);
    });

    testWidgets('계산에 포함할 계좌 opens the same selection screen', (tester) async {
      await _pump(tester, snapshot, repository: repo);
      await tester.tap(find.byKey(const ValueKey('my-info-accounts')));
      await tester.pumpAndSettle();
      expect(find.byType(AccountSelectionPage), findsOneWidget);
    });

    testWidgets('without a save connection the rows open nothing', (
      tester,
    ) async {
      final opened = await _pump(tester, snapshot);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      await tester.tap(find.byKey(const ValueKey('my-info-salary')));
      await tester.tap(find.byKey(const ValueKey('my-info-accounts')));
      await tester.pumpAndSettle();
      expect(opened(), 0);
      expect(find.byType(AccountSelectionPage), findsNothing);
    });

    final failures = <String, AppVersionReader>{
      'throws': () async => throw StateError('no platform'),
      'returns null': () async => null,
      'has an empty build number': () async =>
          (version: '0.1.0', buildNumber: ''),
    };
    for (final MapEntry(key: label, value: reader) in failures.entries) {
      testWidgets('a version read that $label hides only the version line', (
        tester,
      ) async {
        await _pump(tester, snapshot, repository: repo, version: reader);
        expect(find.byKey(const ValueKey('my-info-version')), findsNothing);
        expect(find.text('데모알파님'), findsOneWidget);
        expect(find.byKey(const ValueKey('my-info-accounts')), findsOneWidget);
        expect(find.byKey(const ValueKey('logout-button')), findsOneWidget);
      });
    }

    testWidgets('no name means no name line', (tester) async {
      await _pump(tester, snapshot, userName: null, version: _v010);
      expect(find.byKey(const ValueKey('my-info-name')), findsNothing);
      expect(find.text(asOfLabel(snapshot.asOf)), findsOneWidget);
    });

    testWidgets('320dp with 1.3x text and a long name has no overflow', (
      tester,
    ) async {
      await _pump(
        tester,
        snapshot,
        repository: repo,
        userName: '아주아주긴이름을가진데모사용자입니다아주아주긴이름',
        version: _v010,
        size: const Size(320, 640),
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('PAYSE 0.1.0 (1)'), 200);
      expect(find.text('PAYSE 0.1.0 (1)'), findsOneWidget);
    });
  });
}
