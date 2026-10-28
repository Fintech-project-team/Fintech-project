import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/main_entry.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/data/first_calc_record_store.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/shared/design/amount_format.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/primary_button.dart';

import '../data/calculation_input_adapter_test.dart'
    show alphaWithReceipt, salaryOf;
import '../data/connection/connection_test_utils.dart' show rows;
import '../features/connection/connection_test_support.dart';

/// 2026-10-27: 기록 저장소 [records]와 조회 결과 [results]로 MainEntry를 띄운다. [reloadKey]가 바뀌면 다시 조회한다.
Future<void> _pump(
  WidgetTester tester,
  FirstCalcRecordStore records,
  List<FinancialOutcome<Map<String, Object?>>> results, {
  Object reloadKey = 0,
  List<FinancialOutcome<WriteSuccess>> selectResults = const [],
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: MainEntry(
        financial: ScriptedRepository()
          ..loadResults.addAll(results)
          ..selectResults.addAll(selectResults),
        policy: instantPolicy(),
        reloadKey: reloadKey,
        devEntryBuilder: (_) => null,
        onSessionInvalid: () {},
        firstCalcRecords: records,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 2026-10-27: U가 계산되는 홈 스냅샷 JSON.
Map<String, Object?> _computable() => alphaWithReceipt();

/// 2026-10-27: 지난 회차 입금 근거가 없어 U가 없는 홈 스냅샷 JSON.
Map<String, Object?> _insufficient() {
  final kb = betaSnapshot({...betaBanks}).accounts!.first.accountId;
  return betaJson({...betaBanks}, selected: {kb});
}

const _home = ValueKey('home-detail-button');

/// 2026-10-28: 계좌를 아직 고르지 않은(01-1부터 시작하는) 사본으로 바꾼다.
Map<String, Object?> _unchosen(Map<String, Object?> json) {
  for (final a in rows(json, 'accounts')) {
    a['included'] = false;
  }
  return json;
}

/// 2026-10-28: 01-1에서 시작해 [select] 응답으로 01-2까지 간다. 이후 조회는 [loads] 차례로 돌려준다.
Future<void> _toReview(
  WidgetTester tester,
  FirstCalcRecordStore records,
  Map<String, Object?> select, {
  List<FinancialOutcome<Map<String, Object?>>> loads = const [],
}) async {
  await _pump(
    tester,
    records,
    [FinancialOk(_unchosen(_computable())), ...loads],
    selectResults: [written(select)],
  );
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

void main() {
  testWidgets('a calculation error goes home without a deferred record', (
    tester,
  ) async {
    final records = MemoryFirstCalcRecordStore();
    final broken = _computable();
    salaryOf(broken)['receiptEvidence'] = [
      {
        'payMonth': '2026-09',
        'expectedPayDate': '2026-09-25',
        'transactionIds': ['missing-tx'],
        'confirmation': 'confirmed',
      },
    ];
    await _toReview(tester, records, broken);
    expect(find.text('홈으로 가기'), findsOneWidget, reason: '오류는 나중에 확인할 일이 아님');
    await tester.tap(find.byKey(const ValueKey('review-defer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-data-error')), findsOneWidget);
    final userId = broken['userId']! as String;
    expect(await records.read(userId), isNull, reason: '오류는 보완 미룸이 아님');

    await _pump(tester, records, [FinancialOk(_computable())], reloadKey: 1);
    expect(
      find.byKey(const ValueKey('first-calc-step-1')),
      findsOneWidget,
      reason: '정상 데이터로 다시 들어오면 첫 계산 설명',
    );
  });

  testWidgets('different balance times can be reloaded until it computes', (
    tester,
  ) async {
    final mismatch = _computable();
    final included = [
      for (final a in rows(mismatch, 'accounts'))
        if (a['included'] == true) a,
    ];
    included.last['asOf'] = '2026-10-19T11:00:00+09:00';
    await _toReview(
      tester,
      MemoryFirstCalcRecordStore(),
      mismatch,
      loads: [FinancialOk(_computable())],
    );
    expect(find.text('계좌 잔액의 기준 시각이 서로 달라요'), findsOneWidget);
    expect(find.text('같은 시각의 잔액으로 계산하려면 다시 불러와 주세요.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('review-reload')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-load-band')), findsNothing);
    final calculate = find.byKey(const ValueKey('review-calculate'));
    expect(tester.widget<PrimaryButton>(calculate).onPressed, isNotNull);
  });

  testWidgets('back on the first 1/4 stays instead of leaving the app', (
    tester,
  ) async {
    await _pump(tester, MemoryFirstCalcRecordStore(), [
      FinancialOk(_computable()),
    ]);
    expect(
      await tester.binding.handlePopRoute(),
      isTrue,
      reason: '앱이 뒤로 가기를 처리',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('first-calc-step-1')), findsOneWidget);
  });

  testWidgets('a new user reaches 01-3 only after calculating on 01-2', (
    tester,
  ) async {
    final records = MemoryFirstCalcRecordStore();
    final unchosen = _computable();
    for (final a in unchosen['accounts']! as List) {
      (a as Map<String, Object?>)['included'] = false;
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
            ..selectResults.add(written(_computable())),
          policy: instantPolicy(),
          reloadKey: 0,
          devEntryBuilder: (_) => null,
          onSessionInvalid: () {},
          firstCalcRecords: records,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('이 계좌로 계산하기'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('group-demand')),
        matching: find.text('모두 선택'),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('이 계좌로 계산하기'));
    await tester.pumpAndSettle();
    expect(find.text('다음 월급일까지 쓸 수 있는 돈을\n알아볼까요?'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('first-calc-step-1')),
      findsNothing,
      reason: '01-3은 01-2 계산하기 뒤에만',
    );
    await tester.tap(find.byKey(const ValueKey('review-calculate')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('first-calc-step-1')), findsOneWidget);
    expect(
      await records.read(unchosen['userId']! as String),
      isNull,
      reason: '진입만으로는 기록하지 않음',
    );
  });

  testWidgets('a salary saved on 01-2 drives 01-3 and home', (tester) async {
    final records = MemoryFirstCalcRecordStore();
    final unchosen = _unchosen(_computable());
    final saved = _computable();
    salaryOf(saved)['salaryDay'] = 20;
    saved['dataVersion'] = '2';
    final before = computeHomeCalculation(
      FinancialSnapshot.fromJson(_computable()),
    );
    final after = computeHomeCalculation(FinancialSnapshot.fromJson(saved));
    final u = (after as HomeCalculationReady).result.u!;
    expect(u, isNot((before as HomeCalculationReady).result.u));
    final repo = ScriptedRepository()
      ..loadResults.add(FinancialOk(unchosen))
      ..selectResults.add(written(_computable()))
      ..salaryResults.add(written(saved));
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPayseTheme(),
        home: MainEntry(
          financial: repo,
          policy: instantPolicy(),
          reloadKey: 0,
          devEntryBuilder: (_) => null,
          onSessionInvalid: () {},
          firstCalcRecords: records,
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
    await tester.tap(find.byKey(const ValueKey('review-salary-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('salary-day')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('salary-day-20')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('salary-save')));
    await tester.pumpAndSettle();
    expect(repo.salaryCalls.single.$1.toJson(), {'salaryDay': 20});
    await tester.tap(find.byKey(const ValueKey('salary-done')));
    await tester.pumpAndSettle();
    expect(find.text('매월 20일'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('review-calculate')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('first-calc-next')));
      await tester.pumpAndSettle();
    }
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('first-calc-result'))).data,
      formatKrw(u),
      reason: '01-3도 저장한 월급일로 계산',
    );
    await tester.tap(find.byKey(const ValueKey('first-calc-next')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.text('홈으로 가기'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(_home), findsOneWidget);
    expect(find.textContaining(formatKrw(u)), findsWidgets, reason: '홈도 같은 계산');
  });

  testWidgets('a computed first entry explains 1/4 to 4/4 and records it', (
    tester,
  ) async {
    final records = MemoryFirstCalcRecordStore();
    final json = _computable();
    await _pump(tester, records, [FinancialOk(json)]);
    expect(find.byKey(const ValueKey('first-calc-step-1')), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing, reason: '홈보다 먼저');
    expect(find.text('다음 월급일까지 쓸 수 있는 돈을 계산해 볼게요'), findsOneWidget);
    expect(find.text('금융사에서 받은 잔액 그대로예요.'), findsOneWidget);
    for (final step in [2, 3, 4]) {
      await tester.tap(find.byKey(const ValueKey('first-calc-next')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('first-calc-step-$step')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('first-calc-skip')), findsNothing);
    expect(find.text('계산을 마쳤어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('first-calc-result')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('first-calc-next')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(
      await records.read(json['userId']! as String),
      isNull,
      reason: '시작 화면 전에는 기록 없음',
    );
    await tester.tap(find.byKey(const ValueKey('first-calc-start-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(_home), findsOneWidget);
    final userId = json['userId']! as String;
    expect(await records.read(userId), FirstCalcRecord.explained);
  });

  testWidgets('skipping records skipped and later entries go straight home', (
    tester,
  ) async {
    final records = MemoryFirstCalcRecordStore();
    final json = _computable();
    await _pump(tester, records, [FinancialOk(json)]);
    await tester.tap(find.byKey(const ValueKey('first-calc-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('first-calc-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(_home), findsOneWidget);
    expect(
      await records.read(json['userId']! as String),
      FirstCalcRecord.skipped,
    );

    await _pump(tester, records, [FinancialOk(json)], reloadKey: 1);
    expect(find.byKey(_home), findsOneWidget, reason: '같은 실행 중 재로그인은 기록 유지');
    expect(find.byKey(const ValueKey('first-calc-step-1')), findsNothing);
  });

  testWidgets('back on 2/4 returns to 1/4 without leaving', (tester) async {
    await _pump(tester, MemoryFirstCalcRecordStore(), [
      FinancialOk(_computable()),
    ]);
    await tester.tap(find.byKey(const ValueKey('first-calc-next')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('first-calc-step-1')), findsOneWidget);
  });

  testWidgets('no result and no record goes home without recording', (
    tester,
  ) async {
    final records = MemoryFirstCalcRecordStore();
    final json = _insufficient();
    await _pump(tester, records, [FinancialOk(json)]);
    expect(find.byKey(_home), findsOneWidget);
    expect(find.byKey(const ValueKey('first-calc-step-1')), findsNothing);
    expect(await records.read(json['userId']! as String), isNull);
  });

  testWidgets('a deferred user sees the replay button only with a result', (
    tester,
  ) async {
    final records = MemoryFirstCalcRecordStore();
    final json = _computable();
    final userId = json['userId']! as String;
    await records.save(userId, FirstCalcRecord.deferred);
    await _pump(tester, records, [FinancialOk(json)]);
    expect(find.byKey(const ValueKey('first-calc-step-1')), findsNothing);
    final button = find.byKey(const ValueKey('home-first-calc-button'));
    await tester.scrollUntilVisible(
      button,
      80,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('first-calc-step-1')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(_home), findsOneWidget, reason: '다시 보기 1/4 뒤로 가기는 홈');
    await tester.scrollUntilVisible(
      button,
      80,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('first-calc-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(_home), findsOneWidget);
    expect(
      await records.read(userId),
      FirstCalcRecord.deferred,
      reason: '다시 보기는 기록을 바꾸지 않음',
    );

    final other = _insufficient();
    await records.save(other['userId']! as String, FirstCalcRecord.deferred);
    await _pump(tester, records, [FinancialOk(other)], reloadKey: 1);
    expect(find.byKey(const ValueKey('home-first-calc-button')), findsNothing);
  });

  testWidgets('records are kept per user', (tester) async {
    final records = MemoryFirstCalcRecordStore();
    final json = _computable();
    await records.save('another-user', FirstCalcRecord.explained);
    await _pump(tester, records, [FinancialOk(json)]);
    expect(
      find.byKey(const ValueKey('first-calc-step-1')),
      findsOneWidget,
      reason: '다른 사용자의 기록은 쓰지 않음',
    );
  });
}
