import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/app/main_entry.dart';
import 'package:payse/app/payse_app.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../features/connection/connection_test_support.dart';
import 'app_test_utils.dart';

const _selectHeading = '어느 금융사의 정보를\n불러올까요?';
const _accountsHeading = '쓸 수 있는 돈을 계산할\n계좌를 골라주세요';

/// 2026-10-23: 세션·PIN이 있는 alpha 기기로 앱을 띄우고 11-1을 통과해 첫 화면까지 간다.
/// [draws]는 실패 추첨 실수열(0.1 미만이면 실패), [devTools]는 개발 설정 진입 여부다.
Future<FakeAuthRepository> _openAlpha(
  WidgetTester tester, {
  List<double> draws = const [0.9],
  bool devTools = false,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final (sessions, pins, auth) = await signedInStores();
  await tester.pumpWidget(
    PayseApp(
      snapshotSource: PreloadedAssetSource(),
      enableDevTools: devTools,
      authRepository: auth,
      sessionStore: sessions,
      pinStore: pins,
      presentationPolicy: instantPresentation(draws: draws),
    ),
  );
  await tester.pumpAndSettle();
  await enterPin(tester, testPin);
  await passEntryLoading(tester);
  return auth;
}

/// 2026-10-23: 12-1 목록 맨 위로 돌아가 첫 은행 하나를 골라 동의하고 12-3 불러오기 연출을 끝낸다.
Future<void> _loadFirstBank(WidgetTester tester) async {
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
}

/// 2026-10-23: 12-1의 은행 행 위젯이면 true를 반환한다.
bool _isBankRow(Widget w) {
  final key = w.key;
  return key is ValueKey<String> && key.value.startsWith('institution-bank.');
}

/// 2026-10-23: 12-1·01-1 목록 끝의 개발 설정을 열고 실패 연출 토글을 [enabled]로 맞춘 뒤 돌아온다.
Future<void> _setFailurePresentation(WidgetTester tester, bool enabled) async {
  await tester.scrollUntilVisible(find.text('개발 설정'), 200);
  await tester.tap(find.text('개발 설정'));
  await tester.pumpAndSettle();
  final toggle = find.byKey(const ValueKey('failure-presentation-toggle'));
  if (tester.widget<SwitchListTile>(toggle).value != enabled) {
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }
  await tester.pageBack();
  await tester.pumpAndSettle();
}

/// 2026-10-23: 12-3에서 표시상 실패한 기관 행(다시 시도 버튼)을 찾는다.
Finder _failedRows() => find.byWidgetPredicate((w) {
  final key = w.key;
  return key is ValueKey<String> && key.value.startsWith('retry-');
});

/// 2026-10-21: 이름·번호를 넣고 인증번호 받기를 누른다.
Future<void> _fillIdentity(
  WidgetTester tester,
  String name,
  String phone,
) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(const ValueKey('identity-name')),
      matching: find.byType(TextField),
    ),
    name,
  );
  await tester.enterText(
    find.descendant(
      of: find.byKey(const ValueKey('identity-phone')),
      matching: find.byType(TextField),
    ),
    phone,
  );
  await tester.pump();
  await tester.tap(find.text('인증번호 받기'));
  await tester.pumpAndSettle();
}

/// 2026-10-21: 인증번호를 넣고 확인을 누른다.
Future<void> _submitCode(WidgetTester tester, String code) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(const ValueKey('code-field')),
      matching: find.byType(TextField),
    ),
    code,
  );
  await tester.pump();
  await tester.tap(find.text('확인'));
  await tester.pumpAndSettle();
}

/// 2026-10-23: 연결 저장 응답이 [pending]이 끝날 때까지 오지 않는 저장소.
class _HeldLinkRepository extends ScriptedRepository {
  /// 2026-10-23: 늦게 끝날 연결 응답 [pending]으로 만든다.
  _HeldLinkRepository(this.pending);

  final Completer<FinancialOutcome<WriteSuccess>> pending;

  /// 2026-10-23: 요청을 기록하고 늦게 끝날 응답을 반환한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> institutionCodes,
    WriteContext write,
  ) {
    linkCalls.add((institutionCodes, write));
    return pending.future;
  }
}

/// 2026-10-23: 조회 응답이 [pending]이 끝날 때까지 오지 않는 저장소.
class _HeldLoadRepository extends ScriptedRepository {
  /// 2026-10-23: 늦게 끝날 조회 응답 [pending]으로 만든다.
  _HeldLoadRepository(this.pending);

  final Completer<FinancialOutcome<Map<String, Object?>>> pending;

  /// 2026-10-23: 늦게 끝날 조회 응답을 반환한다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() =>
      pending.future;
}

/// 2026-10-23: [repository] 세션으로 MainEntry를 띄운다. [reloadKey]가 바뀌면 세션이 바뀐 것이다.
/// [onSessionInvalid]로 신규 로그인 전환 호출을 센다.
Widget _entry(
  UserFinancialRepository repository,
  int reloadKey, {
  VoidCallback? onSessionInvalid,
}) => MaterialApp(
  theme: buildPayseTheme(),
  home: MainEntry(
    financial: repository,
    policy: instantPolicy(),
    reloadKey: reloadKey,
    devEntryBuilder: (_) => null,
    onSessionInvalid: onSessionInvalid ?? () {},
  ),
);

void main() {
  testWidgets('a new user runs 12-1 to 01-2 and lands on home', (tester) async {
    await _openAlpha(tester);
    expect(find.text(_selectHeading), findsOneWidget);

    await connectAndChooseAccounts(tester);

    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets(
    'a user who connected but chose no accounts resumes at 01-1 after a new login',
    (tester) async {
      final auth = await _openAlpha(tester);
      await _loadFirstBank(tester);
      await tester.tap(find.text('계속하기'));
      await tester.pumpAndSettle();
      expect(find.text(_accountsHeading), findsOneWidget);

      final alpha = devDemoAccounts.first;
      auth.terminateSessionOf(alpha.userId);
      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('identity-name')),
        findsOneWidget,
        reason: '계좌 선택 저장이 401이면 신규 로그인',
      );

      await _fillIdentity(tester, alpha.name, alpha.phone);
      await _submitCode(tester, alpha.code);
      await enterPin(tester, testPin);
      await enterPin(tester, testPin);

      expect(find.text(_accountsHeading), findsOneWidget);
      expect(find.text(_selectHeading), findsNothing);
      expect(find.byTooltip('뒤로'), findsNothing, reason: '재개한 01-1은 뒤로 없음');
    },
  );

  testWidgets(
    'a late save from the previous session never reaches the new one',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final pending = Completer<FinancialOutcome<WriteSuccess>>();
      final previous = _HeldLinkRepository(pending)
        ..loadResults.add(FinancialOk(betaJson(const {})));
      final next = ScriptedRepository()
        ..loadResults.add(FinancialOk(betaJson({...betaBanks})));

      await tester.pumpWidget(_entry(previous, 0));
      await tester.pumpAndSettle();
      await passEntryLoading(tester);
      await tester.tap(find.byKey(const ValueKey('institution-bank.kb')));
      await tester.pump();
      await tester.tap(find.text('다음'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('consent-all')));
      await tester.pump();
      await tester.tap(find.text('동의하고 불러오기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('계속하기'));
      await tester.pump();
      expect(find.text('저장하고 있어요'), findsOneWidget);

      await tester.pumpWidget(_entry(next, 1));
      await tester.pumpAndSettle();
      expect(find.text(_accountsHeading), findsOneWidget);

      pending.complete(written(betaJson({'bank.kb'}, version: '2')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(_accountsHeading), findsOneWidget);
      expect(find.text('저장하고 있어요'), findsNothing);
      expect(previous.linkCalls, hasLength(1));
      expect(next.linkCalls, isEmpty);
      expect(next.selectCalls, isEmpty);
    },
  );

  for (final (label, late)
      in <(String, FinancialOutcome<Map<String, Object?>>)>[
        ('succeeds', FinancialOk(betaJson(const {}))),
        ('ends with 401', const FinancialSessionInvalid()),
      ]) {
    testWidgets(
      'a previous-session load that later $label never replaces the new session',
      (tester) async {
        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        var handedOver = 0;
        final pending = Completer<FinancialOutcome<Map<String, Object?>>>();
        final previous = _HeldLoadRepository(pending);
        final next = ScriptedRepository()
          ..loadResults.add(FinancialOk(betaJson({...betaBanks})));

        await tester.pumpWidget(
          _entry(previous, 0, onSessionInvalid: () => handedOver++),
        );
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        await tester.pumpWidget(
          _entry(next, 1, onSessionInvalid: () => handedOver++),
        );
        await tester.pumpAndSettle();
        expect(find.text(_accountsHeading), findsOneWidget);

        pending.complete(late);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          find.text(_accountsHeading),
          findsOneWidget,
          reason: '새 세션 화면 유지',
        );
        expect(find.text(_selectHeading), findsNothing);
        expect(handedOver, 0, reason: '이전 세션의 401로 신규 로그인하지 않음');
      },
    );
  }

  testWidgets(
    'a dev preview of another sample changes neither the entry nor the save target',
    (tester) async {
      await _openAlpha(tester, devTools: true);
      await tester.scrollUntilVisible(find.text('개발 설정'), 200);
      await tester.tap(find.text('개발 설정'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('scenario-beta-ready')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('scenario-beta-ready')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(
        find.text(_selectHeading),
        findsOneWidget,
        reason: '연결된 beta 견본을 봐도 현재 계정은 연결 전',
      );
      expect(find.byType(NavigationBar), findsNothing);

      await connectAndChooseAccounts(tester);
      expect(
        find.byType(NavigationBar),
        findsOneWidget,
        reason: '저장·재조회가 현재 계정 세션 저장소에서 이뤄짐',
      );
    },
  );

  group('failure presentation toggle', () {
    testWidgets('on by default: the drawn bank fails in 12-3', (tester) async {
      await _openAlpha(tester, draws: [0.05], devTools: true);
      await _loadFirstBank(tester);

      expect(_failedRows(), findsOneWidget);
    });

    testWidgets('turned off before the draw applies to the current flow', (
      tester,
    ) async {
      await _openAlpha(tester, draws: [0.05], devTools: true);
      await _setFailurePresentation(tester, false);
      await _loadFirstBank(tester);

      expect(_failedRows(), findsNothing);
      expect(find.text('계속하기'), findsOneWidget);
    });

    testWidgets(
      'turned off after the draw keeps this flow; going back does not redraw',
      (tester) async {
        await _openAlpha(tester, draws: [0.05], devTools: true);
        await _loadFirstBank(tester);
        expect(_failedRows(), findsOneWidget);

        await tester.tap(find.byTooltip('뒤로'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('뒤로'));
        await tester.pumpAndSettle();
        expect(find.text(_selectHeading), findsOneWidget);
        await _setFailurePresentation(tester, false);
        await tester.tap(find.text('다음'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('동의하고 불러오기'));
        await tester.pumpAndSettle();

        expect(_failedRows(), findsOneWidget, reason: '추첨 결과 유지');
      },
    );
  });
}
