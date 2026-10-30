import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/main_entry.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/features/connection/connection_presentation_policy.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../data/calculation_input_adapter_test.dart' show salaryOf;
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
/// 2026-10-27: 조회를 보류한 채 띄울 때는 [settle]을 false로 둔다(진입 로딩 표시가 계속 움직인다).
/// 2026-10-28: 표시 정책을 바꿀 때는 [policy]를 넘긴다.
Future<void> pumpEntry(
  WidgetTester tester,
  UserFinancialRepository repository, {
  VoidCallback? onSessionInvalid,
  bool settle = true,
  ConnectionPresentationPolicy? policy,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: MainEntry(
        financial: repository,
        policy: policy ?? instantPolicy(),
        reloadKey: 0,
        devEntryBuilder: (_) => null,
        onSessionInvalid: onSessionInvalid ?? () {},
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
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

/// 2026-10-26: 조회를 [results] 순서로 돌려주되 [hold]가 있으면 그 결과가 끝날 때까지 기다리는 저장소. 조회 수를 센다.
class _CountingRepository extends ScriptedRepository {
  int loads = 0;
  Completer<FinancialOutcome<Map<String, Object?>>>? hold;

  /// 2026-10-26: 조회 수를 세고 보류 중이면 기다린다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() async {
    loads++;
    final pending = hold;
    if (pending != null) {
      hold = null;
      return pending.future;
    }
    return super.loadSnapshot();
  }
}

/// 2026-10-26: 선택 계좌가 있는 홈 스냅샷 JSON. [balance]로 첫 포함 계좌 잔액을 바꿔 새 스냅샷임을 구분한다.
Map<String, Object?> _homeJson({int? balance, String version = '1'}) {
  final kb = betaSnapshot({...betaBanks}).accounts!.first.accountId;
  return betaJson(
    {...betaBanks},
    selected: {kb},
    version: version,
    mutate: balance == null
        ? null
        : (source) {
            for (final a in source['accounts']! as List) {
              final account = a as Map<String, Object?>;
              if (account['accountId'] == kb) account['balanceKRW'] = balance;
            }
          },
  );
}

/// 2026-10-27: 지난 회차 입금 근거가 없는 거래를 가리켜 계산 데이터 오류가 나는 홈 스냅샷 JSON.
Map<String, Object?> _dataErrorHomeJson() {
  final json = _homeJson();
  salaryOf(json)['receiptEvidence'] = [
    {
      'payMonth': '2026-09',
      'expectedPayDate': '2026-09-25',
      'transactionIds': ['missing-tx'],
      'confirmation': 'confirmed',
    },
  ];
  return json;
}

/// 2026-10-27: [repo]의 다음 조회를 보류하고 그 완료자를 반환한다.
Completer<FinancialOutcome<Map<String, Object?>>> _holdNext(
  _CountingRepository repo,
) => repo.hold = Completer<FinancialOutcome<Map<String, Object?>>>();

/// 2026-10-27: 보류한 조회 [hold]를 [outcome]으로 끝내고 화면을 반영한다.
Future<void> _finish(
  WidgetTester tester,
  Completer<FinancialOutcome<Map<String, Object?>>> hold,
  FinancialOutcome<Map<String, Object?>> outcome,
) async {
  hold.complete(outcome);
  await tester.pump();
  await tester.pump();
}

/// 2026-10-26: 홈 머리의 새로고침 버튼을 누르고 한 프레임 진행한다.
Future<void> _tapRefresh(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('home-reload')));
  await tester.pump();
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
    'after 01-2 the entry keeps the reviewed snapshot without reloading',
    (tester) async {
      final kb = betaSnapshot({...betaBanks}).accounts!.first.accountId;
      final repo = _CountingRepository()
        ..loadResults.add(FinancialOk(betaJson({...betaBanks})))
        ..selectResults.add(
          written(betaJson({...betaBanks}, selected: {kb}, version: '2')),
        );
      await pumpEntry(tester, repo);
      await tester.tap(find.byKey(ValueKey('account-$kb')));
      await tester.pump();
      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('review-defer')));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(repo.loads, 1, reason: '01-2가 보여 준 스냅샷을 그대로 쓴다');
      expect(repo.selectCalls.single.$1, [kb]);
    },
  );

  group('home refresh keeps the home and its previous snapshot', () {
    testWidgets(
      'loading shows the home skeleton, success shows the new snapshot',
      (tester) async {
        final repo = _CountingRepository()
          ..loadResults.addAll([
            FinancialOk(_homeJson()),
            FinancialOk(_homeJson(balance: 1234567, version: '2')),
          ]);
        await pumpEntry(tester, repo);
        final hold = Completer<FinancialOutcome<Map<String, Object?>>>();
        repo.hold = hold;

        await _tapRefresh(tester);
        expect(find.byKey(const ValueKey('home-loading')), findsOneWidget);
        expect(find.byType(NavigationBar), findsOneWidget, reason: '탭은 유지');
        expect(find.byKey(const ValueKey('home-reload')), findsNothing);

        hold.complete(repo.loadResults.removeFirst());
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('home-loading')), findsNothing);
        expect(find.text('1,234,567원'), findsOneWidget);
        expect(find.byKey(const ValueKey('home-refresh-failed')), findsNothing);
        expect(repo.loads, 2);
      },
    );

    testWidgets(
      'a failed refresh restores the previous snapshot; retry clears the notice',
      (tester) async {
        final repo = _CountingRepository()
          ..loadResults.addAll([
            FinancialOk(_homeJson(balance: 777000)),
            const FinancialUnavailable(),
            FinancialOk(_homeJson(balance: 888000, version: '2')),
          ]);
        await pumpEntry(tester, repo);
        expect(find.text('777,000원'), findsOneWidget);

        await _tapRefresh(tester);
        await tester.pump();
        await tester.pump();
        expect(find.text('새 정보를 불러오지 못했어요'), findsOneWidget);
        expect(find.text('777,000원'), findsOneWidget, reason: '이전 스냅샷 복원');

        await tester.tap(find.byKey(const ValueKey('home-refresh-retry')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('home-refresh-failed')),
          findsNothing,
          reason: '다시 시도하면 로딩으로',
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('888,000원'), findsOneWidget);
        expect(find.byKey(const ValueKey('home-refresh-failed')), findsNothing);
        expect(repo.loads, 3);
      },
    );

    testWidgets('a fast refresh still shows loading for 3 seconds', (
      tester,
    ) async {
      final repo = _CountingRepository()
        ..loadResults.addAll([
          FinancialOk(_homeJson(balance: 777000)),
          FinancialOk(_homeJson(balance: 888000, version: '2')),
          const FinancialUnavailable(),
        ]);
      await pumpEntry(
        tester,
        repo,
        policy: ConnectionPresentationPolicy(failuresEnabled: () => false),
      );
      await _tapRefresh(tester);
      await tester.pump(const Duration(milliseconds: 2900));
      expect(find.byKey(const ValueKey('home-loading')), findsOneWidget);
      expect(repo.loads, 2, reason: '조회는 바로 끝남');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.byKey(const ValueKey('home-loading')), findsNothing);
      expect(find.text('888,000원'), findsOneWidget);

      await _tapRefresh(tester);
      await tester.pump(const Duration(milliseconds: 2900));
      expect(find.byKey(const ValueKey('home-loading')), findsOneWidget);
      expect(find.text('새 정보를 불러오지 못했어요'), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('새 정보를 불러오지 못했어요'), findsOneWidget, reason: '실패도 3초 뒤');
    });

    testWidgets('a refresh in progress ignores repeated requests', (
      tester,
    ) async {
      final repo = _CountingRepository()
        ..loadResults.addAll([
          FinancialOk(_homeJson()),
          FinancialOk(_homeJson()),
        ]);
      await pumpEntry(tester, repo);
      final hold = Completer<FinancialOutcome<Map<String, Object?>>>();
      repo.hold = hold;
      await _tapRefresh(tester);
      await tester.tap(find.byType(NavigationBar).first, warnIfMissed: false);
      await tester.pump();
      expect(repo.loads, 2);
      hold.complete(repo.loadResults.removeFirst());
      await tester.pump();
      await tester.pump();
      expect(repo.loads, 2);
    });

    testWidgets('session invalid during refresh hands over to a new login', (
      tester,
    ) async {
      var handedOver = 0;
      final repo = _CountingRepository()
        ..loadResults.addAll([
          FinancialOk(_homeJson()),
          const FinancialSessionInvalid(),
        ]);
      await pumpEntry(tester, repo, onSessionInvalid: () => handedOver++);
      await _tapRefresh(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(handedOver, 1);
    });
  });

  group('first entry load keeps the approved entry screens', () {
    testWidgets('delay → failure → retry → success opens the home', (
      tester,
    ) async {
      final repo = _CountingRepository();
      var hold = _holdNext(repo);
      await pumpEntry(tester, repo, settle: false);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('home-loading')), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);

      await _finish(tester, hold, const FinancialUnavailable());
      expect(_loadFailed(), findsOneWidget);
      expect(find.byKey(const ValueKey('home-load-failed')), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);

      hold = _holdNext(repo);
      await tester.tap(find.text('다시 시도'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(_loadFailed(), findsNothing);

      await _finish(tester, hold, FinancialOk(_homeJson(balance: 654000)));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('654,000원'), findsOneWidget);
      expect(repo.loads, 2);
    });

    testWidgets(
      'a retry that finds no connection resumes the connection flow',
      (tester) async {
        final repo = _CountingRepository()
          ..loadResults.addAll([
            const FinancialUnavailable(),
            FinancialOk(betaJson({})),
          ]);
        await pumpEntry(tester, repo);
        expect(_loadFailed(), findsOneWidget);
        await tester.tap(find.text('다시 시도'));
        await tester.pumpAndSettle();
        expect(find.text('연결할 수 있는 금융사\n9곳을 찾았어요'), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
      },
    );

    testWidgets('a home that cannot calculate shows ④ when its refresh fails', (
      tester,
    ) async {
      final repo = _CountingRepository()
        ..loadResults.addAll([FinancialOk(_dataErrorHomeJson())]);
      await pumpEntry(tester, repo);
      expect(find.byKey(const ValueKey('home-data-error')), findsOneWidget);

      final hold = _holdNext(repo);
      await tester.tap(find.text('다시 불러오기'));
      await tester.pump();
      expect(find.byKey(const ValueKey('home-loading')), findsOneWidget);

      await _finish(tester, hold, const FinancialUnavailable());
      expect(find.byKey(const ValueKey('home-load-failed')), findsOneWidget);
      expect(find.text('금융 정보를 불러오지 못했어요'), findsOneWidget);
      expect(find.text('아직 계산할 수 없어요'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  testWidgets(
    'insufficient info survives a refresh: skeleton while loading, restored on failure',
    (tester) async {
      final repo = _CountingRepository()
        ..loadResults.addAll([FinancialOk(_homeJson())]);
      await pumpEntry(tester, repo);
      expect(find.text('월급 입금 확인 필요'), findsOneWidget);
      final reason = find.textContaining('예정된 월급의 입금 여부를 확인할 정보가 없어요');
      expect(reason, findsOneWidget);

      final hold = _holdNext(repo);
      await _tapRefresh(tester);
      expect(find.byKey(const ValueKey('home-loading')), findsOneWidget);
      expect(find.text('월급 입금 확인 필요'), findsNothing, reason: '로딩 틀로 가림');
      expect(find.byKey(const ValueKey('home-salary-notice')), findsNothing);

      await _finish(tester, hold, const FinancialUnavailable());
      expect(find.byKey(const ValueKey('home-refresh-failed')), findsOneWidget);
      expect(find.text('월급 입금 확인 필요'), findsOneWidget);
      expect(find.text('아직 계산할 수 없어요'), findsOneWidget);
      expect(reason, findsOneWidget);
      expect(find.byKey(const ValueKey('home-salary-notice')), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget, reason: '다시 시도는 띠 하나에만');
    },
  );
}
