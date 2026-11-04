import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/accounts_screen.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/overview_links.dart';
import 'package:payse/features/planning/obligation_edit.dart';
import 'package:payse/features/planning/plan_screen.dart';
import 'package:payse/features/planning/reserve_edit_controller.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/connection/plan_write_test_utils.dart';
import '../connection/connection_test_support.dart';

const _shinhan = '67521b1b-de86-54cf-98ba-91bb04d0a256';
const _repairAllocation = 'b13023bf-0ce7-5616-9bbb-efb70f816cc6';

/// 2026-11-04: 컨트롤러 시험 준비. 앱 반영([applied])을 남긴다.
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

/// 2026-11-04: alpha-ready 원본에서 월급일을 지운 원본(월급 주기를 정할 수 없음).
Map<String, Object?> _noCycle() {
  final json = planSource();
  ((json['settings']! as Map)['salary'] as Map)['salaryDay'] = null;
  return json;
}

Future<_Rig> _rig({Map<String, Object?>? source}) async =>
    _Rig(await connectPlan(source ?? planSource()));

/// 2026-11-04: 요청 본문의 allocationChanges.
Object? _changes(FlakyRepository flaky) =>
    (flaky.calls.last.$3! as Map)['allocationChanges'];

/// 2026-11-04: 남겨둘 돈 탭이 열린 계획 탭(저장 연결 있음).
Future<FlakyRepository> _pump(
  WidgetTester tester, {
  Map<String, Object?>? source,
  double width = 390,
  double height = 900,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = await tester.runAsync(
    () => connectPlan(source ?? planSource()),
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

/// 2026-11-04: [key] 입력칸의 TextField.
Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

/// 2026-11-04: 하단 버튼을 누르고 결과를 기다린다.
Future<void> _tapAsync(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

/// 2026-11-04: 지금 비상금 수정 화면을 연다.
Future<void> _openReserve(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('plan-reserve-open-$reserveId')));
  await tester.pumpAndSettle();
}

void main() {
  group('컨트롤러', () {
    test('후보는 이번 월급 주기 활성 예정 지출 중 아직 고르지 않은 것, 최대 금액은 남은 금액', () async {
      final c = (await _rig()).controller(reserveId);
      expect(c.cycleRange, '9/25 ~ 10/24');
      expect(c.plans.map((p) => (p.label, p.amountKrw, p.releasedKrw)), [
        ('수리비', 60000, 40000),
      ]);
      expect(c.candidates.map((x) => (x.label, x.maxKrw)), [('월세', 300000)]);
      expect(c.planMax(repairId), 60000);
      expect(c.planMax(phoneId), 0, reason: '다음 월급 기간 지출');
      expect(c.planAdjustable(phoneId), isFalse);
    });

    test('추가: 고른 지출은 create로 보내고 미리보기는 겹친 만큼 덜 줄어든다', () async {
      final r = await _rig();
      final c = r.controller()
        ..setLabel('여행 자금')
        ..setAmount('300000')
        ..setAccount(_shinhan);
      final before = (c.preview! as PreviewReady).deltaKrw;
      c.addPlan(rentId, 100000);
      expect(c.plans.single.label, '월세');
      expect((c.preview! as PreviewReady).deltaKrw, before + 100000);
      expect(await c.submit(), isTrue);
      expect(_changes(r.flaky), {
        'create': [
          {'amountKRW': 100000, 'obligationId': rentId},
        ],
        'remove': [],
        'update': [],
      });
    });

    test('최대 금액은 남겨둘 금액에서 다른 사용 계획을 뺀 값을 넘지 않고, 넘는 금액은 고를 수 없다', () async {
      final c = (await _rig()).controller(reserveId)..setAmount('100000');
      expect(c.planMax(rentId), 40000, reason: '100,000 − 수리비 60,000');
      c.addPlan(rentId, 40001);
      expect(c.plans, hasLength(1));
      c.addPlan(rentId, 40000);
      expect(c.plans, hasLength(2));
    });

    test('금액 변경: 이미 나간 금액을 더한 총 배정액으로 update한다', () async {
      final r = await _rig();
      final c = r.controller(reserveId)..setPlanAmount(repairId, 50000);
      expect(c.plans.single.amountKrw, 50000);
      c.setPlanAmount(repairId, 60001);
      expect(c.plans.single.amountKrw, 50000, reason: '최대 금액 초과는 무시');
      expect(await c.submit(), isTrue);
      expect(_changes(r.flaky), {
        'create': [],
        'remove': [],
        'update': [
          {'allocationId': _repairAllocation, 'amountKRW': 90000},
        ],
      });
      expect(
        r.applied.single.allocations!
            .singleWhere((a) => a.allocationId == _repairAllocation)
            .amountKrw,
        90000,
      );
    });

    test('해제: 이력이 있으면 이미 나간 금액까지 update, 되돌리면 바뀐 내용 없음', () async {
      final r = await _rig();
      final c = r.controller(reserveId)..unplan(repairId);
      expect(c.plans, isEmpty);
      expect(c.lastUnplanned?.label, '수리비');
      expect(c.changes.toJson()['update'], [
        {'allocationId': _repairAllocation, 'amountKRW': 40000},
      ]);
      expect((c.preview! as PreviewReady).deltaKrw, -60000);
      c.undoUnplan();
      expect(c.unchanged, isTrue);
      c.unplan(repairId);
      expect(await c.submit(), isTrue);
      expect(_changes(r.flaky), {
        'create': [],
        'remove': [],
        'update': [
          {'allocationId': _repairAllocation, 'amountKRW': 40000},
        ],
      });
    });

    test('해제: 이력이 없으면 remove', () async {
      final r = _Rig(await connectPlan(planSource(rentHeld: true)));
      final c = r.controller(reserveId)..unplan(rentId);
      expect(c.changes.toJson()['remove'], [rentAllocationId]);
    });

    test('해제한 저장 배정을 다시 고르면 새로 만들지 않고 그 배정을 쓴다', () async {
      final c = (await _rig()).controller(reserveId)..unplan(repairId);
      expect(c.candidates.map((x) => x.label), contains('수리비'));
      c.addPlan(repairId, 60000);
      expect(c.unchanged, isTrue);
      c
        ..unplan(repairId)
        ..addPlan(repairId, 30000);
      expect(c.changes.toJson(), {
        'create': [],
        'remove': [],
        'update': [
          {'allocationId': _repairAllocation, 'amountKRW': 70000},
        ],
      });
    });

    test('응답 유실 뒤 다시 시도하면 같은 키로 보내 배정은 한 건만 생긴다', () async {
      final r = await _rig();
      r.flaky.lose = 1;
      final c = r.controller(reserveId)..addPlan(rentId, 100000);
      expect(await c.submit(), isFalse);
      expect(c.locked, isTrue);
      expect(await c.submit(), isTrue);
      final [first, second] = r.flaky.calls;
      expect(second.$2.idempotencyKey, first.$2.idempotencyKey);
      expect(
        r.applied.last.allocations!.where(
          (a) => a.reserveId == reserveId && a.obligationId == rentId,
        ),
        hasLength(1),
      );
    });

    test('사용 계획 합계보다 적게 줄이면 저장을 막는다', () async {
      final c = (await _rig()).controller(reserveId)..addPlan(rentId, 100000);
      c.setAmount('150000');
      expect(c.problems.amount, '수리비·월세에 쓸 160,000원보다 적게 줄일 수 없어요.');
      expect(c.canSave, isFalse);
    });

    test('월급 주기를 정할 수 없으면 새로 고를 수 없고, 기존 계획은 줄이기·해제만 된다', () async {
      final c = (await _rig(source: _noCycle())).controller(reserveId);
      expect(c.cycleKnown, isFalse);
      expect(c.candidates, isEmpty);
      c.addPlan(rentId, 1000);
      expect(c.plans, hasLength(1));
      expect(c.planAdjustable(repairId), isTrue);
      expect(c.planMax(repairId), 60000);
      c.setPlanAmount(repairId, 60001);
      expect(c.plans.single.amountKrw, 60000);
      c.setPlanAmount(repairId, 20000);
      expect(c.plans.single.amountKrw, 20000);
      c.unplan(repairId);
      expect(c.plans, isEmpty);
    });

    test('다른 남겨둘 돈이 다 쓰기로 한 지출은 최대 0원, 그 이름을 함께 준다', () async {
      final r = await _rig();
      final add = r.controller()
        ..setLabel('여행 자금')
        ..setAmount('300000')
        ..setAccount(_shinhan)
        ..addPlan(rentId, 300000);
      expect(await add.submit(), isTrue);
      final c = r.controller(reserveId);
      final rent = c.candidates.singleWhere((x) => x.obligationId == rentId);
      expect((rent.maxKrw, rent.heldBy), (0, '여행 자금'));
      c.addPlan(rentId, 1);
      expect(c.plans, hasLength(1));
    });
  });

  group('화면', () {
    testWidgets('추가: 지출 선택 → 선택창에서 고르고 금액 입력 → 행과 지출 더 선택하기', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('plan-reserve-add')));
      await tester.pumpAndSettle();
      expect(find.textContaining('(선택)', findRichText: true), findsOneWidget);
      expect(find.text('지출 선택'), findsOneWidget);
      expect(find.text('남겨둘 돈에서 낼 예정 지출이 있으면 골라 주세요.'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('reserve-plan-pick')),
      );
      await tester.tap(find.byKey(const ValueKey('reserve-plan-pick')));
      await tester.pumpAndSettle();
      expect(find.text('이 돈으로 낼 지출 선택'), findsOneWidget);
      expect(find.text('이번 월급 주기(9/25 ~ 10/24) 예정 지출에서 골라요'), findsOneWidget);
      expect(find.text('10/22 예정 · 최대 300,000원'), findsOneWidget);
      expect(find.text('10/18 예정 · 현재 비상금에서 낼 계획이 있어요'), findsOneWidget);
      expect(find.text('통신비'), findsNothing, reason: '다음 월급 기간');
      await tester.tap(find.byKey(ValueKey('plan-candidate-$rentId')));
      await tester.pumpAndSettle();
      expect(find.text('최대 300,000원'), findsOneWidget);
      await tester.enterText(_field('plan-amount'), '300001');
      await tester.pump();
      expect(find.text('최대 금액보다 많아요.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('plan-sheet-apply')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(_field('plan-amount'), '100000');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('plan-sheet-apply')));
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('reserve-plan-$rentId'));
      expect(
        find.descendant(of: row, matching: find.text('100,000원')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('10/22 예정')),
        findsOneWidget,
      );
      expect(find.text('지출 더 선택하기'), findsOneWidget);
      expect(find.text('지출 선택'), findsNothing);
    });

    testWidgets('행 시트: 이미 나간 금액·최대 금액, 금액을 바꾸면 행에 반영', (tester) async {
      await _pump(tester);
      await _openReserve(tester);
      await tester.ensureVisible(
        find.byKey(ValueKey('reserve-plan-$repairId')),
      );
      await tester.tap(find.byKey(ValueKey('reserve-plan-$repairId')));
      await tester.pumpAndSettle();
      expect(find.text('이미 40,000원이 나갔어요'), findsOneWidget);
      expect(find.text('최대 60,000원'), findsOneWidget);
      expect(find.text('사용 계획 해제'), findsOneWidget);
      await tester.enterText(_field('plan-amount'), '50000');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('plan-sheet-apply')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(ValueKey('reserve-plan-$repairId')),
          matching: find.text('50,000원'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('해제 → 알림·되돌리기, 저장하면 이미 나간 금액까지만 남긴다', (tester) async {
      final flaky = await _pump(tester);
      await _openReserve(tester);
      await tester.ensureVisible(
        find.byKey(ValueKey('reserve-plan-$repairId')),
      );
      await tester.tap(find.byKey(ValueKey('reserve-plan-$repairId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plan-row-release')));
      await tester.pumpAndSettle();
      expect(find.text('수리비는 이 돈으로 내지 않아요. 예정 지출에는 그대로 있어요.'), findsOneWidget);
      expect(find.byKey(ValueKey('reserve-plan-$repairId')), findsNothing);
      await tester.tap(find.text('되돌리기'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('reserve-plan-$repairId')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('reserve-plan-$repairId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plan-row-release')));
      await tester.pumpAndSettle();
      await _tapAsync(tester, find.byKey(const ValueKey('edit-save')));
      expect(find.text('남겨둘 돈을 수정했어요.'), findsOneWidget);
      expect(_changes(flaky), {
        'create': [],
        'remove': [],
        'update': [
          {'allocationId': _repairAllocation, 'amountKRW': 40000},
        ],
      });
    });

    testWidgets('320dp·글자 1.3배: 사용 계획 행과 시트가 넘치지 않는다', (tester) async {
      await _pump(tester, width: 320, height: 1000, textScale: 1.3);
      await _openReserve(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(ValueKey('reserve-plan-$repairId')),
      );
      await tester.tap(find.byKey(ValueKey('reserve-plan-$repairId')));
      await tester.pumpAndSettle();
      expect(find.text('이미 40,000원이 나갔어요'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('reserve-plan-more')),
      );
      await tester.tap(find.byKey(const ValueKey('reserve-plan-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('plan-candidate-$rentId')));
      await tester.pumpAndSettle();
      expect(find.text('최대 300,000원'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('수정 화면에서 고른 지출이 없으면 선택 행 보조 문구는 두 번 빼지 않는다는 안내', (
      tester,
    ) async {
      await _pump(tester);
      await _openReserve(tester);
      await tester.tap(find.byKey(ValueKey('reserve-plan-$repairId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plan-row-release')));
      await tester.pumpAndSettle();
      expect(find.text('지출 선택'), findsOneWidget);
      expect(find.text('예정 지출에 쓸 몫은 두 번 빼지 않아요.'), findsOneWidget);
    });

    testWidgets('월급 주기를 정할 수 없으면 지출 더 선택하기를 막고 이유를 한 줄로', (tester) async {
      await _pump(tester, source: _noCycle());
      await _openReserve(tester);
      expect(find.text('월급 주기를 확인할 수 없어 지출을 새로 고를 수 없어요.'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('reserve-plan-more')),
      );
      await tester.tap(find.byKey(const ValueKey('reserve-plan-more')));
      await tester.pumpAndSettle();
      expect(find.text('이 돈으로 낼 지출 선택'), findsNothing);
      await tester.tap(find.byKey(ValueKey('reserve-plan-$repairId')));
      await tester.pumpAndSettle();
      expect(find.text('월급 주기를 확인할 수 없어 줄이기만 할 수 있어요'), findsOneWidget);
    });
  });
}
