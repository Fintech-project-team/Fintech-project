import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/main_entry.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../features/connection/connection_test_support.dart';

const _selectHeading = '어느 금융사의 정보를\n불러올까요?';
const _accountsHeading = '쓸 수 있는 돈을 계산할\n계좌를 골라주세요';
const _offline = ValueKey('load-error-offline');
const _unavailable = ValueKey('load-error-unavailable');

/// 2026-10-23: 조회 실패 화면(인터넷 연결·서비스 불가 중 하나)을 찾는다.
Finder _loadFailed() =>
    find.byWidgetPredicate((w) => w.key == _offline || w.key == _unavailable);

/// 2026-10-22: [repository]로 MainEntry를 띄운다. 세션 무효 콜백 호출 수를 [onSessionInvalid]로 센다.
/// 2026-10-23: 세션 금융 저장소와 기다리지 않는 표시 정책으로 띄운다.
Future<void> pumpEntry(
  WidgetTester tester,
  UserFinancialRepository repository, {
  VoidCallback? onSessionInvalid,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: MainEntry(
        financial: repository,
        policy: instantPolicy(),
        reloadKey: 0,
        devEntryBuilder: (_) => null,
        onSessionInvalid: onSessionInvalid ?? () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 2026-10-23: 조회 결과 [results]를 차례로 돌려주는 저장소를 만든다.
ScriptedRepository _loads(
  List<FinancialOutcome<Map<String, Object?>>> results,
) => ScriptedRepository()..loadResults.addAll(results);

/// 2026-10-22: 조회 Future를 예외로 끝내는 저장소.
class _ThrowingRepository extends ScriptedRepository {
  /// 2026-10-22: 항상 예외를 던진다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() async =>
      throw StateError('boom');
}

void main() {
  testWidgets('a load that throws shows retry instead of loading forever', (
    tester,
  ) async {
    await pumpEntry(tester, _ThrowingRepository());

    expect(tester.takeException(), isA<StateError>());
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(_unavailable), findsOneWidget);
    expect(find.text('지금은 금융사 정보를\n받을 수 없어요'), findsOneWidget);
  });

  group('three entry conditions', () {
    testWidgets('not connected starts the connection flow at 12-1', (
      tester,
    ) async {
      await pumpEntry(tester, _loads([FinancialOk(betaJson(const {}))]));

      expect(find.text('연결할 수 있는 금융사\n9곳을 찾았어요'), findsOneWidget);
      expect(find.text(_selectHeading), findsNothing, reason: '자동으로 넘어가지 않음');
      await tester.tap(find.byKey(const ValueKey('entry-next')));
      await tester.pumpAndSettle();
      expect(find.text(_selectHeading), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('connected without chosen accounts resumes at 01-1', (
      tester,
    ) async {
      await pumpEntry(
        tester,
        _loads([
          FinancialOk(betaJson({...betaBanks})),
        ]),
      );

      expect(find.text(_accountsHeading), findsOneWidget);
      expect(find.text(_selectHeading), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('chosen accounts open the home shell', (tester) async {
      final kb = betaSnapshot({...betaBanks}).accounts!.first.accountId;
      await pumpEntry(
        tester,
        _loads([
          FinancialOk(betaJson({...betaBanks}, selected: {kb})),
        ]),
      );

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text(_accountsHeading), findsNothing);
    });
  });

  group('failures are never treated as zero accounts', () {
    testWidgets('session invalid on load hands over to a new login', (
      tester,
    ) async {
      var handedOver = 0;
      await pumpEntry(
        tester,
        _loads([const FinancialSessionInvalid()]),
        onSessionInvalid: () => handedOver++,
      );

      expect(handedOver, 1);
      expect(_loadFailed(), findsNothing);
    });

    testWidgets('a failed load shows retry, not the flow or home', (
      tester,
    ) async {
      await pumpEntry(tester, _loads([const FinancialUnavailable()]));

      expect(find.byKey(_unavailable), findsOneWidget);
      expect(
        find.text('고른 금융사나 저장된 정보는 바뀌지 않았어요. 계속 안 되면 앱을 닫았다가 다시 열어주세요.'),
        findsOneWidget,
      );
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text(_accountsHeading), findsNothing);
      expect(find.text(_selectHeading), findsNothing);
    });

    testWidgets('a connected response missing accounts shows retry', (
      tester,
    ) async {
      final json = betaJson({...betaBanks})..remove('accounts');
      await pumpEntry(tester, _loads([FinancialOk(json)]));

      expect(_loadFailed(), findsOneWidget);
      expect(find.text(_accountsHeading), findsNothing);
    });
  });

  testWidgets(
    'after 01-2 the entry reloads; a failed reload shows retry, not home',
    (tester) async {
      final kb = betaSnapshot({...betaBanks}).accounts!.first.accountId;
      final repo =
          _loads([
              FinancialOk(betaJson({...betaBanks})),
              const FinancialNetworkFailure('offline'),
              FinancialOk(
                betaJson({...betaBanks}, selected: {kb}, version: '2'),
              ),
            ])
            ..selectResults.add(
              written(betaJson({...betaBanks}, selected: {kb}, version: '2')),
            );
      await pumpEntry(tester, repo);
      for (final a in betaSnapshot({...betaBanks}).accounts!) {
        if (a.accountId != kb && a.productType == 'demand') {
          await tester.tap(find.byKey(ValueKey('account-${a.accountId}')));
        }
      }
      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('확인했어요'));
      await tester.pumpAndSettle();

      expect(find.byKey(_offline), findsOneWidget, reason: '네트워크 실패');
      expect(find.text('금융사 목록을\n불러오지 못했어요'), findsOneWidget);
      expect(find.text('인터넷 연결을 확인한 뒤 다시 시도해주세요.'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(repo.selectCalls.single.$1, [kb]);
    },
  );
}
