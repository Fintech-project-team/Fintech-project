import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/analysis/analysis_wait_session.dart';
import 'package:payse/features/connection/analysis_illustration.dart';
import 'package:payse/features/connection/analysis_wait_screen.dart';
import 'package:payse/shared/design/payse_theme.dart';

/// 2026-11-04: 화면 상태 [state]로 분석 대기 화면을 띄운다. 누른 횟수는 [taps]에 남는다.
/// [still]이면 기기의 움직임 줄이기가 켜진 상태다.
Future<void> _pump(
  WidgetTester tester,
  ValueNotifier<AnalysisWaitState> state,
  Map<String, int> taps, {
  String? userName = '데모알파',
  bool still = false,
}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(360, 780),
          disableAnimations: still,
        ),
        child: AnalysisWaitScreen(
          state: state,
          userName: userName,
          onRetry: () => taps['retry'] = (taps['retry'] ?? 0) + 1,
          onNext: () => taps['next'] = (taps['next'] ?? 0) + 1,
        ),
      ),
    ),
  );
}

/// 2026-11-04: 결과가 다 올라오고 '다음'이 보일 때까지 시간을 보낸다.
Future<void> _settleResult(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1200));
}

/// 2026-11-04: 지금 그림 장면을 반환한다.
AnalysisArt _art(WidgetTester tester) => tester
    .widgetList<AnalysisIllustration>(find.byType(AnalysisIllustration))
    .last
    .art;

/// 2026-11-04: '다음'을 누를 수 있으면 true다.
bool _nextEnabled(WidgetTester tester) => !tester
    .widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('analysis-next')),
            matching: find.byType(IgnorePointer),
          )
          .first,
    )
    .ignoring;

void main() {
  testWidgets('waiting shows no done marks and cycles every 10 seconds', (
    tester,
  ) async {
    final state = ValueNotifier<AnalysisWaitState>(const AnalysisRunning());
    addTearDown(state.dispose);
    await _pump(tester, state, {});

    expect(find.text('데모알파님의 거래를\n살펴보고 있어요'), findsOneWidget);
    expect(find.text('보통 3~5분 걸려요.\n앱을 나가도 분석은 계속돼요.'), findsOneWidget);
    expect(find.text('거래 내역을 정리하고 있어요'), findsOneWidget);
    expect(_art(tester), AnalysisArt.sorting);
    expect(find.textContaining('건'), findsNothing, reason: '기다리는 동안 건수 없음');
    expect(find.textContaining('완료'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(_nextEnabled(tester), isFalse);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('반복되는 지출과 수입을 찾고 있어요'), findsOneWidget);
    expect(_art(tester), AnalysisArt.finding);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('첫 계산을 준비하고 있어요'), findsOneWidget);
    expect(_art(tester), AnalysisArt.preparing);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('거래 내역을 정리하고 있어요'), findsOneWidget, reason: '30초 뒤 처음부터');
  });

  testWidgets('after 5 minutes only the explanation changes', (tester) async {
    final state = ValueNotifier<AnalysisWaitState>(const AnalysisRunning());
    addTearDown(state.dispose);
    await _pump(tester, state, {}, userName: null);
    expect(find.text('거래를\n살펴보고 있어요'), findsOneWidget, reason: '이름 없으면 이름 없이');

    await tester.pump(const Duration(minutes: 4, seconds: 59));
    expect(find.text('보통 3~5분 걸려요.\n앱을 나가도 분석은 계속돼요.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('생각보다 오래 걸리고 있어요.\n조금만 더 기다려주세요.'), findsOneWidget);
    expect(find.text('거래를\n살펴보고 있어요'), findsOneWidget);
  });

  testWidgets('finished with candidates rises three rows then next', (
    tester,
  ) async {
    final state = ValueNotifier<AnalysisWaitState>(const AnalysisRunning());
    addTearDown(state.dispose);
    final taps = <String, int>{};
    await _pump(tester, state, taps);

    state.value = AnalysisFinished(
      transactionCount: 1284,
      candidateCount: 7,
      interpreted: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_nextEnabled(tester), isFalse, reason: '줄이 다 올라온 뒤에 다음');

    await _settleResult(tester);
    expect(find.text('첫 계산 준비를\n마쳤어요'), findsOneWidget);
    expect(find.text('이제 쓸 수 있는 돈을 확인해 보세요.'), findsOneWidget);
    expect(find.text('거래 1,284건을 확인했어요'), findsOneWidget);
    expect(find.text('반복 후보 7개를 찾았어요'), findsOneWidget);
    expect(find.text('첫 계산이 준비되었어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('analysis-retry')), findsNothing);
    expect(find.text('거래 내역을 정리하고 있어요'), findsNothing);
    expect(_art(tester), AnalysisArt.done);
    expect(_nextEnabled(tester), isTrue);
    expect(taps['next'], isNull, reason: '자동으로 넘어가지 않음');

    await tester.tap(find.byKey(const ValueKey('analysis-next')));
    expect(taps['next'], 1);
  });

  testWidgets('zero candidates is its own result, not a failure', (
    tester,
  ) async {
    final state = ValueNotifier<AnalysisWaitState>(const AnalysisRunning());
    addTearDown(state.dispose);
    await _pump(tester, state, {});
    state.value = AnalysisFinished(
      transactionCount: 32,
      candidateCount: 0,
      interpreted: false,
    );
    await _settleResult(tester);

    expect(find.text('이번에는 반복 후보를 찾지 못했어요'), findsOneWidget);
    expect(find.text('나중에 홈 화면에서 안내해드릴게요.'), findsOneWidget);
    expect(find.text('내용 분석은 마치지 못했어요.'), findsNothing);
    expect(find.byKey(const ValueKey('analysis-retry')), findsNothing);
    expect(_art(tester), AnalysisArt.empty);
    expect(_nextEnabled(tester), isTrue);
  });

  testWidgets('unfinished analysis offers retry and next', (tester) async {
    final state = ValueNotifier<AnalysisWaitState>(const AnalysisRunning());
    addTearDown(state.dispose);
    final taps = <String, int>{};
    await _pump(tester, state, taps);
    await tester.pump(const Duration(minutes: 6));
    state.value = AnalysisFinished(
      transactionCount: 1284,
      candidateCount: 7,
      interpreted: false,
    );
    await _settleResult(tester);

    expect(find.text('반복 후보 7개를 찾았어요'), findsOneWidget);
    expect(find.text('내용 분석은 마치지 못했어요.'), findsOneWidget);
    expect(_art(tester), AnalysisArt.unfinished);
    expect(_nextEnabled(tester), isTrue, reason: '실패여도 01-3으로 계속');

    await tester.tap(find.byKey(const ValueKey('analysis-retry')));
    expect(taps['retry'], 1);
    state.value = const AnalysisRunning();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('거래 내역을 정리하고 있어요'), findsOneWidget);
    expect(
      find.text('보통 3~5분 걸려요.\n앱을 나가도 분석은 계속돼요.'),
      findsOneWidget,
      reason: '다시 시도하면 5분 기준도 처음부터',
    );
    expect(find.text('거래 1,284건을 확인했어요'), findsNothing);
    expect(_nextEnabled(tester), isFalse);
  });

  testWidgets('reduced motion shows the result at once', (tester) async {
    final state = ValueNotifier<AnalysisWaitState>(
      AnalysisFinished(
        transactionCount: 1284,
        candidateCount: 7,
        interpreted: true,
      ),
    );
    addTearDown(state.dispose);
    await _pump(tester, state, {}, still: true);
    await tester.pump();

    expect(_nextEnabled(tester), isTrue);
    final row = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.text('첫 계산이 준비되었어요'),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(row.opacity, 1);
  });

  test('negative counts are rejected', () {
    expect(
      () => AnalysisFinished(
        transactionCount: -1,
        candidateCount: 0,
        interpreted: true,
      ),
      throwsArgumentError,
    );
    expect(
      () => AnalysisFinished(
        transactionCount: 0,
        candidateCount: -1,
        interpreted: true,
      ),
      throwsArgumentError,
    );
  });
}
