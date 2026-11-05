import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/main_entry.dart';
import 'package:payse/data/analysis/analysis_wait_session.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/data/first_calc_record_store.dart';
import 'package:payse/features/connection/analysis_wait_screen.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../data/calculation_input_adapter_test.dart' show alphaWithReceipt;
import '../data/connection/connection_test_utils.dart' show rows;
import '../features/connection/connection_test_support.dart';

/// 2026-11-04: 테스트가 상태를 직접 바꾸는 분석 추적. 시작·다시 시도·폐기 횟수를 센다.
class _FakeSession implements AnalysisWaitSession {
  /// 2026-11-04: 01-2가 넘긴 [snapshot]으로 만든다.
  _FakeSession(this.snapshot);

  final FinancialSnapshot snapshot;
  final ValueNotifier<AnalysisWaitState> notifier = ValueNotifier(
    const AnalysisRunning(),
  );
  int retries = 0;
  int pauses = 0;
  int resumes = 0;
  int forgets = 0;
  bool disposed = false;

  /// 2026-11-04: 현재 상태 알림을 반환한다.
  @override
  ValueListenable<AnalysisWaitState> get state => notifier;

  /// 2026-11-04: 다시 시도 횟수를 늘리고 기다리는 중으로 돌린다.
  @override
  void retry() {
    retries++;
    notifier.value = const AnalysisRunning(inputReceived: true);
  }

  /// 2026-11-05: 멈춤 횟수를 센다.
  @override
  void pause() => pauses++;

  /// 2026-11-05: 재개 횟수를 센다.
  @override
  void resume() => resumes++;

  /// 2026-11-05: 기록 삭제 횟수를 센다.
  @override
  Future<void> forget() async => forgets++;

  /// 2026-11-04: 폐기됐다고 표시한다.
  @override
  void dispose() => disposed = true;
}

/// 2026-11-04: 01-1에서 시작해 01-2까지 간다. [startAnalysis]가 있으면 분석 대기 화면을 거친다.
Future<void> _toReview(
  WidgetTester tester, {
  AnalysisWaitStarter? startAnalysis,
  bool pending = false,
}) async {
  final unchosen = alphaWithReceipt();
  for (final a in rows(unchosen, 'accounts')) {
    a['included'] = false;
  }
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: MainEntry(
        financial: ScriptedRepository()
          ..loadResults.add(FinancialOk(unchosen))
          ..selectResults.add(written(alphaWithReceipt())),
        policy: instantPolicy(),
        reloadKey: 0,
        devEntryBuilder: (_) => null,
        onSessionInvalid: () {},
        firstCalcRecords: MemoryFirstCalcRecordStore(),
        userName: '데모알파',
        analysis: startAnalysis == null
            ? null
            : AnalysisLauncher(
                start: startAnalysis,
                pending: (_) async => pending,
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey('group-demand')),
      matching: find.text('모두 선택'),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('이 계좌로 계산하기'));
  await tester.pumpAndSettle();
}

/// 2026-11-04: 화면 전환이 끝날 때까지 시간을 보낸다(기다리는 표시가 계속 돌아 pumpAndSettle을 쓰지 않음).
Future<void> _pass(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1500));
}

void main() {
  const first = ValueKey('first-calc-step-1');

  testWidgets('without a tracker 01-2 goes straight to 01-3', (tester) async {
    await _toReview(tester);
    await tester.tap(find.byKey(const ValueKey('review-calculate')));
    await tester.pumpAndSettle();
    expect(find.byType(AnalysisWaitScreen), findsNothing);
    expect(find.text('데모알파님의 거래를\n살펴보고 있어요'), findsNothing);
    expect(find.byKey(first), findsOneWidget);
  });

  testWidgets('01-2 → analysis wait → next → 01-3', (tester) async {
    final sessions = <_FakeSession>[];
    await _toReview(
      tester,
      startAnalysis: (snapshot) {
        final s = _FakeSession(snapshot);
        sessions.add(s);
        return s;
      },
    );
    expect(sessions, isEmpty, reason: '01-2 확인 전에는 분석을 시작하지 않음');

    await tester.tap(find.byKey(const ValueKey('review-calculate')));
    await _pass(tester);
    expect(find.text('데모알파님의 거래를\n살펴보고 있어요'), findsOneWidget);
    expect(sessions, hasLength(1));
    expect(sessions.single.snapshot.userId, alphaWithReceipt()['userId']);
    expect(find.byKey(first), findsNothing);

    sessions.single.notifier.value = AnalysisFinished(
      transactionCount: 40,
      candidateCount: 2,
      outcome: AnalysisOutcome.failed,
    );
    await _pass(tester);
    expect(find.byKey(first), findsNothing, reason: '끝나도 자동으로 넘어가지 않음');
    await tester.tap(find.byKey(const ValueKey('analysis-retry')));
    expect(sessions.single.retries, 1);
    sessions.single.notifier.value = AnalysisFinished(
      transactionCount: 40,
      candidateCount: 2,
      outcome: AnalysisOutcome.interpreted,
    );
    await _pass(tester);

    await tester.tap(find.byKey(const ValueKey('analysis-next')));
    await tester.pumpAndSettle();
    expect(find.byKey(first), findsOneWidget);
    expect(sessions.single.disposed, isTrue);
    expect(sessions.single.forgets, 1, reason: '다음을 누르면 기기 기록을 지움');
  });

  testWidgets('background pauses polling and coming back resumes it', (
    tester,
  ) async {
    final sessions = <_FakeSession>[];
    await _toReview(
      tester,
      startAnalysis: (snapshot) {
        final s = _FakeSession(snapshot);
        sessions.add(s);
        return s;
      },
    );
    await tester.tap(find.byKey(const ValueKey('review-calculate')));
    await _pass(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(sessions.single.pauses, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(sessions.single.resumes, 1);
    expect(sessions.single.disposed, isFalse, reason: '나가도 추적을 버리지 않음');
  });

  testWidgets('back from the wait returns to 01-2 and drops the tracker', (
    tester,
  ) async {
    final sessions = <_FakeSession>[];
    await _toReview(
      tester,
      startAnalysis: (snapshot) {
        final s = _FakeSession(snapshot);
        sessions.add(s);
        return s;
      },
    );
    await tester.tap(find.byKey(const ValueKey('review-calculate')));
    await _pass(tester);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await _pass(tester);
    expect(find.byKey(const ValueKey('review-calculate')), findsOneWidget);
    expect(sessions.single.disposed, isTrue);
  });

  testWidgets(
    'a relaunch with an unfinished analysis resumes the wait before home',
    (tester) async {
      final sessions = <_FakeSession>[];
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPayseTheme(),
          home: MainEntry(
            financial: ScriptedRepository()
              ..loadResults.add(FinancialOk(alphaWithReceipt())),
            policy: instantPolicy(),
            reloadKey: 0,
            devEntryBuilder: (_) => null,
            onSessionInvalid: () {},
            firstCalcRecords: MemoryFirstCalcRecordStore(),
            userName: '데모알파',
            analysis: AnalysisLauncher(
              start: (snapshot) {
                final s = _FakeSession(snapshot);
                sessions.add(s);
                return s;
              },
              pending: (userId) async => userId == alphaWithReceipt()['userId'],
            ),
          ),
        ),
      );
      await _pass(tester);
      expect(find.byType(AnalysisWaitScreen), findsOneWidget);
      expect(sessions, hasLength(1));

      sessions.single.notifier.value = AnalysisFinished(
        transactionCount: 40,
        candidateCount: 2,
        outcome: AnalysisOutcome.interpreted,
      );
      await _pass(tester);
      await tester.tap(find.byKey(const ValueKey('analysis-next')));
      await _pass(tester);
      expect(find.byType(AnalysisWaitScreen), findsNothing);
      expect(sessions.single.forgets, 1);
    },
  );

  testWidgets('without an unfinished analysis a relaunch goes home directly', (
    tester,
  ) async {
    var started = 0;
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPayseTheme(),
        home: MainEntry(
          financial: ScriptedRepository()
            ..loadResults.add(FinancialOk(alphaWithReceipt())),
          policy: instantPolicy(),
          reloadKey: 0,
          devEntryBuilder: (_) => null,
          onSessionInvalid: () {},
          firstCalcRecords: MemoryFirstCalcRecordStore(),
          analysis: AnalysisLauncher(
            start: (snapshot) {
              started++;
              return _FakeSession(snapshot);
            },
            pending: (_) async => false,
          ),
        ),
      ),
    );
    await _pass(tester);
    expect(find.byType(AnalysisWaitScreen), findsNothing);
    expect(started, 0);
  });
}
