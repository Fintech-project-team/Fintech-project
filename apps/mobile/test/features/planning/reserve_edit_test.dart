import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/accounts_screen.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/overview_links.dart';
import 'package:payse/features/planning/obligation_edit.dart';
import 'package:payse/features/planning/obligation_edit_controller.dart';
import 'package:payse/features/planning/plan_screen.dart';
import 'package:payse/features/planning/reserve_edit_controller.dart';
import 'package:payse/features/planning/reserve_edit_screen.dart'
    show withTopic;
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/connection/plan_write_test_utils.dart';
import '../connection/connection_test_support.dart';

const _shinhan = '67521b1b-de86-54cf-98ba-91bb04d0a256';
const _hana = '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc';

/// 2026-11-03: 컨트롤러 시험 준비. 앱 반영([applied])을 남긴다.
class _Rig {
  _Rig(this.session) : flaky = FlakyRepository(session.repository);

  final PlanSession session;
  final FlakyRepository flaky;
  final List<FinancialSnapshot> applied = [];

  AccountsWriter get writer => (
    repository: flaky,
    policy: instantPolicy(),
    onSessionInvalid: () {},
    onSnapshot: applied.add,
  );

  ReserveEditController controller([String? id]) => ReserveEditController(
    snapshot: applied.isEmpty ? session.snapshot : applied.last,
    writer: writer,
    reserveId: id,
  );
}

Future<_Rig> _rig({bool rentHeld = false}) async =>
    _Rig(await connectPlan(planSource(rentHeld: rentHeld)));

/// 2026-11-03: 남겨둘 돈 탭이 열린 계획 탭(저장 연결 있음).
Future<FlakyRepository> _pump(
  WidgetTester tester, {
  bool rentHeld = false,
  double width = 390,
  double height = 900,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = await tester.runAsync(
    () => connectPlan(planSource(rentHeld: rentHeld)),
  );
  final flaky = FlakyRepository(session!.repository);
  final state = ValueNotifier<OverviewState>((
    calculation: computeHomeCalculation(session.snapshot),
    history: null,
  ));
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: PlanScreen(
          links: OverviewLinks(
            state: state,
            writer: (
              repository: flaky,
              policy: instantPolicy(),
              onSessionInvalid: () {},
              onSnapshot: (FinancialSnapshot s) => state.value = (
                calculation: computeHomeCalculation(s),
                history: null,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('plan-tab-reserves')));
  await tester.pump();
  return flaky;
}

/// 2026-11-03: [key] 입력칸의 TextField.
Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

/// 2026-11-03: 하단 버튼을 누르고 결과를 기다린다.
Future<void> _tapAsync(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

void main() {
  group('컨트롤러', () {
    test('추가: 미리보기는 설정액만큼 줄고 저장 뒤 앱에 반영, 본문은 빈 연결 변경', () async {
      final r = await _rig();
      final c = r.controller()
        ..setLabel('여행 자금')
        ..setAmount('300000')
        ..setAccount(kbDemand);
      expect((c.preview! as PreviewReady).deltaKrw, -300000);
      expect(await c.submit(), isTrue);
      expect(r.applied.single.reserves!.map((x) => x.label), contains('여행 자금'));
      expect((r.flaky.calls.single.$3! as Map)['allocationChanges'], {
        'create': [],
        'remove': [],
        'update': [],
      });
    });

    test('계산에서 뺀 계좌는 새로 고를 수 없다', () async {
      final c = (await _rig()).controller()..setAccount(_hana);
      expect(c.draft.accountId, isNull);
      c.setAccount(_shinhan);
      expect(c.draft.accountId, _shinhan);
    });

    test('이 돈으로 낼 금액보다 적게 줄이면 이유를 말하고 저장을 막는다', () async {
      final c = (await _rig(rentHeld: true)).controller(reserveId)
        ..setAmount('50000');
      expect(c.facts!.floorKrw, 90000);
      expect(c.problems.amount, '수리비·월세에 쓸 90,000원보다 적게 줄일 수 없어요.');
      expect(c.canSave, isFalse);
      c.setAmount('90000');
      expect(c.canSave, isTrue);
      expect(c.patch!.toJson(), {'amountKRW': 90000});
    });

    test('취소: 미해제 연결을 정확히 보내고 예정 지출은 그대로, 미리보기는 남겨둘 금액만큼 늘어남', () async {
      final r = await _rig();
      final c = r.controller(reserveId);
      expect((c.cancelPreview! as PreviewReady).deltaKrw, 340000);
      expect(await c.cancel(), isTrue);
      expect(r.flaky.calls.single.$3, [
        {
          'allocationId': 'b13023bf-0ce7-5616-9bbb-efb70f816cc6',
          'unreleasedKRW': 60000,
        },
      ]);
      expect(
        r.applied.single.reserves!
            .singleWhere((x) => x.reserveId == reserveId)
            .cancelledAt,
        isNotNull,
      );
    });

    test('응답 유실: 같은 키로 다시 보내 한 건만, 충돌 뒤 재조회 실패면 저장 막음', () async {
      final r = await _rig();
      r.flaky.lose = 1;
      final c = r.controller()
        ..setLabel('여행')
        ..setAmount('1000')
        ..setAccount(_shinhan);
      expect(await c.submit(), isFalse);
      expect(c.save, isA<EditUnknown>());
      expect(await c.submit(), isTrue);
      final [first, second] = r.flaky.calls;
      expect(second.$2.idempotencyKey, first.$2.idempotencyKey);

      final d = r.controller(reserveId)..setAmount('70000');
      await r.session.repository.updateAccountNickname(
        kbDemand,
        '생활비',
        writeOf(r.applied.last, 'other'),
      );
      expect(await d.submit(), isFalse);
      expect(d.save, isA<EditStale>());
      r.flaky.failLoads = 1;
      await d.reload();
      expect(d.canSave, isFalse);
      expect(await d.cancel(), isFalse);
      await d.reload();
      expect(d.canSave, isTrue);
    });

    test('서버 422 LIMIT_EXCEEDED는 한도 거절로, 입력 유지', () async {
      final r = await _rig();
      r.flaky.scripted.add(
        const FinancialInvalid(status: 422, code: 'LIMIT_EXCEEDED'),
      );
      final c = r.controller(reserveId)..setAmount('900000');
      expect(await c.submit(), isFalse);
      expect((c.save as EditRejected).reason, EditRejection.limit);
      expect(c.draft.amountKrw, 900000);
    });
  });

  group('화면', () {
    testWidgets('목록에서 추가: 세 칸만, 계좌 선택창은 계산 포함 계좌만, 추가하기 → 목록과 알림', (
      tester,
    ) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('plan-reserve-add')));
      await tester.pumpAndSettle();
      expect(find.text('남겨둘 돈 추가'), findsWidgets);
      expect(find.text('이체하지 않고 계좌에 남겨둬요. 쓸 수 있는 돈 계산에서만 빼요.'), findsOneWidget);
      expect(find.text('이 돈으로 낼 지출'), findsNothing);
      await tester.enterText(_field('reserve-label'), '여행 자금');
      await tester.enterText(_field('reserve-amount'), '300000');
      await tester.tap(find.byKey(const ValueKey('reserve-account')));
      await tester.pumpAndSettle();
      expect(
        find.text('10월 19일 12:00 기준 잔액 · 계산에 포함한 계좌만 고를 수 있어요'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('edit-account-$_hana')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('edit-account-$_shinhan')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sheet-apply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit-cancel')), findsNothing);
      await _tapAsync(tester, find.byKey(const ValueKey('edit-save')));
      expect(find.text('남겨둘 돈을 저장했어요.'), findsOneWidget);
      expect(find.text('여행 자금'), findsOneWidget);
    });

    testWidgets('수정: 이 돈으로 낼 지출은 읽기 전용, 적게 줄이면 금액 아래 이유, 하단에 취소 버튼', (
      tester,
    ) async {
      await _pump(tester, rentHeld: true);
      await tester.tap(
        find.byKey(const ValueKey('plan-reserve-open-$reserveId')),
      );
      await tester.pumpAndSettle();
      expect(find.text('남겨둘 돈 수정'), findsOneWidget);
      final uses = find.byKey(const ValueKey('reserve-uses'));
      expect(
        find.descendant(of: uses, matching: find.text('수리비')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: uses, matching: find.text('10/22 예정')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.chevron_right), findsWidgets);
      await tester.enterText(_field('reserve-amount'), '50000');
      await tester.pump();
      expect(find.text('수리비·월세에 쓸 90,000원보다 적게 줄일 수 없어요.'), findsOneWidget);
      expect(find.text('남겨둘 돈 취소하기'), findsOneWidget);
    });

    testWidgets('취소: 확인창 한 줄 설명과 변화량, 취소하기 → 목록에서 빠지고 알림', (tester) async {
      await _pump(tester);
      await tester.tap(
        find.byKey(const ValueKey('plan-reserve-open-$reserveId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('현재 비상금 남겨둘 돈을 취소할까요?'), findsOneWidget);
      expect(find.text('이 돈으로 낼 수리비는 예정 지출에 그대로 남아요.'), findsOneWidget);
      expect(
        find.textContaining('(+340,000원)', findRichText: true),
        findsOneWidget,
      );
      await _tapAsync(tester, find.byKey(const ValueKey('cancel-confirm')));
      expect(find.text('남겨둘 돈을 취소했어요.'), findsOneWidget);
      expect(find.text('현재 비상금'), findsNothing);
    });

    testWidgets('320dp·글자 1.3배: 하단 두 버튼을 쌓고 넘치지 않는다', (tester) async {
      await _pump(
        tester,
        rentHeld: true,
        width: 320,
        height: 1000,
        textScale: 1.3,
      );
      await tester.tap(
        find.byKey(const ValueKey('plan-reserve-open-$reserveId')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('edit-buttons-stacked')),
        findsOneWidget,
      );
    });
  });

  test('주제 조사는 받침에 맞춘다', () {
    expect(withTopic('수리비·통신비'), '수리비·통신비는');
    expect(withTopic('월세 외 1건'), '월세 외 1건은');
    expect(withTopic('Netflix'), 'Netflix은(는)');
  });
}
