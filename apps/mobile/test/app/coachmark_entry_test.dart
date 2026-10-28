import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/main_entry.dart';
import 'package:payse/data/coachmark_record_store.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/first_calc_record_store.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../data/calculation_input_adapter_test.dart'
    show alphaWithReceipt, salaryOf;
import '../data/connection/connection_test_utils.dart' show rows;
import '../features/connection/connection_test_support.dart';

const _coach = ValueKey('home-coachmark');

/// 2026-10-28: 기록 저장소 [records]·[coachmarks](없으면 코치마크 꺼짐)와 저장소 [repo]로 MainEntry를 띄운다. [reloadKey]가 바뀌면 다시 조회한다.
Future<void> _pump(
  WidgetTester tester,
  ScriptedRepository repo,
  FirstCalcRecordStore records,
  CoachmarkRecordStore? coachmarks, {
  Object reloadKey = 0,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: MainEntry(
        financial: repo,
        policy: instantPolicy(),
        reloadKey: reloadKey,
        devEntryBuilder: (_) => null,
        onSessionInvalid: () {},
        firstCalcRecords: records,
        coachmarkRecords: coachmarks,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
}

/// 2026-10-28: 계좌를 아직 고르지 않은(01-1부터 시작하는) 사본으로 바꾼다.
Map<String, Object?> _unchosen(Map<String, Object?> json) {
  for (final a in rows(json, 'accounts')) {
    a['included'] = false;
  }
  return json;
}

/// 2026-10-28: 01-1에서 입출금을 모두 골라 01-2로 간다.
Future<void> _chooseDemand(WidgetTester tester) async {
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
  testWidgets('after 01-3 the home shows the coachmark once per user', (
    tester,
  ) async {
    final records = MemoryFirstCalcRecordStore();
    final coachmarks = MemoryCoachmarkRecordStore();
    final json = alphaWithReceipt();
    final userId = json['userId']! as String;
    await _pump(
      tester,
      ScriptedRepository()
        ..loadResults.add(FinancialOk(_unchosen(alphaWithReceipt())))
        ..selectResults.add(written(json)),
      records,
      coachmarks,
    );
    await _chooseDemand(tester);
    await tester.tap(find.byKey(const ValueKey('review-calculate')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('first-calc-step-1')), findsOneWidget);
    expect(find.byKey(_coach), findsNothing, reason: '01-3이 먼저');

    await tester.tap(find.byKey(const ValueKey('first-calc-skip')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(_coach), findsOneWidget, reason: '01-3 뒤 홈에서');
    expect(find.text('지금 쓸 수 있는 돈이에요'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('coachmark-skip')));
    await tester.pumpAndSettle();
    expect(await coachmarks.read(userId), CoachmarkRecord.skipped);
    expect(find.byKey(_coach), findsNothing);

    await _pump(
      tester,
      ScriptedRepository()..loadResults.add(FinancialOk(alphaWithReceipt())),
      records,
      coachmarks,
      reloadKey: 1,
    );
    expect(find.byKey(const ValueKey('home-detail-button')), findsOneWidget);
    expect(find.byKey(_coach), findsNothing, reason: '같은 실행 안 재로그인 뒤 유지');
  });

  testWidgets('a returning user with a first-calc record sees it on home', (
    tester,
  ) async {
    final records = MemoryFirstCalcRecordStore();
    final coachmarks = MemoryCoachmarkRecordStore();
    final json = alphaWithReceipt();
    await records.save(json['userId']! as String, FirstCalcRecord.explained);
    await _pump(
      tester,
      ScriptedRepository()..loadResults.add(FinancialOk(json)),
      records,
      coachmarks,
    );
    expect(find.byKey(_coach), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('coachmark-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.byKey(_coach), findsNothing);
    expect(
      await coachmarks.read(json['userId']! as String),
      CoachmarkRecord.completed,
    );

    final beta = betaJson(
      {...betaBanks},
      selected: {
        betaSnapshot({...betaBanks}).accounts!.first.accountId,
      },
    );
    await records.save(beta['userId']! as String, FirstCalcRecord.deferred);
    await _pump(
      tester,
      ScriptedRepository()..loadResults.add(FinancialOk(beta)),
      records,
      coachmarks,
      reloadKey: 1,
    );
    expect(find.byKey(_coach), findsOneWidget, reason: '다른 사용자와 분리');
  });

  testWidgets('deferring on 01-2 shows the insufficient copy on home', (
    tester,
  ) async {
    final kb = betaSnapshot({...betaBanks}).accounts!.first.accountId;
    final insufficient = betaJson({...betaBanks}, selected: {kb});
    await _pump(
      tester,
      ScriptedRepository()
        ..loadResults.add(FinancialOk(_unchosen(betaJson({...betaBanks}))))
        ..selectResults.add(written(insufficient)),
      MemoryFirstCalcRecordStore(),
      MemoryCoachmarkRecordStore(),
    );
    await _chooseDemand(tester);
    await tester.tap(find.byKey(const ValueKey('review-defer')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(_coach), findsOneWidget);
    expect(find.text('월급 입금을 확인하면 계산해요'), findsOneWidget);
  });

  testWidgets('without a coachmark store the home shows none', (tester) async {
    final records = MemoryFirstCalcRecordStore();
    final json = alphaWithReceipt();
    await records.save(json['userId']! as String, FirstCalcRecord.explained);
    await _pump(
      tester,
      ScriptedRepository()..loadResults.add(FinancialOk(json)),
      records,
      null,
    );
    expect(find.byKey(const ValueKey('home-detail-button')), findsOneWidget);
    expect(find.byKey(_coach), findsNothing, reason: '기본은 숨김');
  });

  testWidgets('a data error home does not show it', (tester) async {
    final broken = alphaWithReceipt();
    salaryOf(broken)['receiptEvidence'] = [
      {
        'payMonth': '2026-09',
        'expectedPayDate': '2026-09-25',
        'transactionIds': ['missing-tx'],
        'confirmation': 'confirmed',
      },
    ];
    final records = MemoryFirstCalcRecordStore();
    await records.save(broken['userId']! as String, FirstCalcRecord.explained);
    await _pump(
      tester,
      ScriptedRepository()..loadResults.add(FinancialOk(broken)),
      records,
      MemoryCoachmarkRecordStore(),
    );
    expect(find.byKey(const ValueKey('home-data-error')), findsOneWidget);
    expect(find.byKey(_coach), findsNothing);
  });
}
