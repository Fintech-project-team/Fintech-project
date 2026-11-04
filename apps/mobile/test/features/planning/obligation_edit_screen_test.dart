import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/overview_links.dart';
import 'package:payse/features/planning/obligation_edit_screen.dart'
    show balanceText;
import 'package:payse/features/planning/plan_screen.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/connection/connection_test_utils.dart' show rows;
import '../../data/connection/plan_write_test_utils.dart';
import '../connection/connection_test_support.dart';

/// 2026-11-03: 계획 탭을 앱 셸처럼 감싸 저장 응답 Snapshot을 공통 상태에 반영하는 시험용 화면 정보.
typedef _Host = ({FlakyRepository flaky, ValueNotifier<OverviewState> state});

/// 2026-11-03: 저장 연결이 있는 계획 탭을 띄운다.
Future<_Host> _pump(
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
  return (flaky: flaky, state: state);
}

/// 2026-11-03: [key] 입력칸의 TextField.
Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

/// 2026-11-03: 예정 지출 [label] 줄을 눌러 편집을 연다.
Future<void> _openRow(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).first);
  await tester.pumpAndSettle();
}

/// 2026-11-03: 추가 화면에서 통신비 55,000원·10/22·국민은행 입출금을 입력한다.
Future<void> _fillAdd(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('plan-add')));
  await tester.pumpAndSettle();
  await tester.enterText(_field('edit-label'), '인터넷');
  await tester.enterText(_field('edit-amount'), '55000');
  await tester.tap(find.byKey(const ValueKey('edit-date')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('22'));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('sheet-apply')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('edit-account')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('edit-account-$kbDemand')));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('sheet-apply')));
  await tester.pumpAndSettle();
}

/// 2026-11-03: 하단 저장 버튼 글자.
String _saveLabel(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('edit-save')),
        matching: find.byType(Text),
      ),
    )
    .data!;

/// 2026-11-03: 하단 버튼을 누르고 결과를 기다린다.
Future<void> _save(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.byKey(const ValueKey('edit-save')));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('추가: 단건 안내, 미리보기 변화량, 추가하기 → 목록 반영과 알림', (tester) async {
    await _pump(tester);
    await _fillAdd(tester);
    expect(find.text('이번 한 건의 예정 지출을 등록해요.'), findsOneWidget);
    expect(find.text('추가하면'), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-delta')), findsOneWidget);
    expect(find.text('−55,000원'), findsOneWidget);
    expect(_saveLabel(tester), '추가하기');
    await _save(tester);
    expect(
      find.byKey(const ValueKey('plan-add')),
      findsOneWidget,
      reason: '목록으로 돌아옴',
    );
    expect(find.text('예정 지출을 저장했어요.'), findsOneWidget);
    expect(find.text('인터넷'), findsOneWidget);
  });

  testWidgets('보고 있는 기간 밖 날짜: 예정일 아래 안내, 추가하면 그 날짜의 기간으로 이동', (tester) async {
    await _pump(tester);
    await _fillAdd(tester);
    await tester.tap(find.byKey(const ValueKey('edit-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-date-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sheet-apply')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('지금 보고 있는 기간(9/25 ~ 10/24)에는 표시되지 않아요.'),
      findsOneWidget,
    );
    await _save(tester);
    expect(find.text('예정 지출을 저장했어요. 11/10이 있는 기간으로 이동했어요.'), findsOneWidget);
    expect(find.text('인터넷'), findsOneWidget);
  });

  testWidgets('응답 유실: 노랑 결과 불명 띠, 입력 잠금, 다시 시도하기로 한 건만 저장', (tester) async {
    final host = await _pump(tester);
    host.flaky.lose = 1;
    await _fillAdd(tester);
    await _save(tester);
    expect(find.byKey(const ValueKey('edit-band-unknown')), findsOneWidget);
    expect(find.text('추가 결과를 확인하지 못했어요'), findsOneWidget);
    expect(_saveLabel(tester), '다시 시도하기');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('edit-label')),
        matching: find.byKey(const ValueKey('payse-text-field-dashed')),
      ),
      findsOneWidget,
      reason: '결과를 확인할 때까지 입력 잠금',
    );
    await _save(tester);
    expect(find.text('예정 지출을 저장했어요.'), findsOneWidget);
    final [first, second] = host.flaky.calls;
    expect(second.$2.idempotencyKey, first.$2.idempotencyKey);
    expect(find.text('인터넷'), findsOneWidget);
  });

  testWidgets('자료 충돌: 미리보기를 안내 문장으로 바꾸고, 최신 정보로 다시 계산한 뒤 추가', (tester) async {
    final host = await _pump(tester);
    await _fillAdd(tester);
    await tester.runAsync(
      () => host.flaky.inner.updateAccountNickname(
        kbDemand,
        '생활비',
        writeOf(host.state.value.calculation.snapshot, 'other'),
      ),
    );
    await _save(tester);
    expect(find.byKey(const ValueKey('edit-band-stale')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-preview-pending')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('최신 정보 불러오기'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-band-reloaded')), findsOneWidget);
    expect(find.text('−55,000원'), findsOneWidget);
    await _save(tester);
    expect(find.text('예정 지출을 저장했어요.'), findsOneWidget);
  });

  testWidgets('일부 출금 수정: 금액 하한 안내, 계좌 잠금, 취소 없음', (tester) async {
    await _pump(tester);
    await _openRow(tester, '수리비');
    expect(find.text('예정 지출 수정'), findsOneWidget);
    expect(
      find.text('40,000원이 이미 출금됐어요. 100,000원보다 적게 줄일 수 없어요.'),
      findsOneWidget,
    );
    expect(
      find.text(
        '잔액 1,500,000원\n'
        '일부 금액이 이미 출금되어 계좌 변경과 예정 지출 취소는 할 수 없어요.',
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('edit-account')),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('edit-cancel')), findsNothing);
    expect(find.text('바꾼 내용이 없어요.'), findsOneWidget);
    await tester.enterText(_field('edit-amount'), '90000');
    await tester.pump();
    expect(find.textContaining("남겨둘 돈 '현재 비상금'에 60,000원"), findsOneWidget);
    expect(find.text('계산 불가'), findsOneWidget);
  });

  testWidgets('연결 있는 취소: 확인창 문구와 변화량, 취소하기 → 알림', (tester) async {
    await _pump(tester, rentHeld: true);
    await _openRow(tester, '월세');
    await tester.tap(find.byKey(const ValueKey('edit-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('월세 예정 지출을 취소할까요?'), findsOneWidget);
    expect(find.text('현재 비상금과 연결한 30,000원도 연결 해제돼요.'), findsOneWidget);
    expect(find.text('취소 후 쓸 수 있는 돈'), findsOneWidget);
    expect(
      find.textContaining('(+270,000원)', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('돌아가기'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('cancel-confirm')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('예정 지출을 취소했어요.'), findsOneWidget);
  });

  testWidgets('출금 계좌 선택창: 기준 시각 한 번, 계좌마다 잔액, 적용 뒤 입력 아래 잔액 유지', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('plan-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-account')));
    await tester.pumpAndSettle();
    expect(find.text('10월 19일 12:00 기준 잔액'), findsOneWidget);
    expect(find.text('잔액 1,500,000원'), findsOneWidget);
    expect(find.text('잔액 300,000원 · 계산에서 뺀 계좌'), findsOneWidget);
    expect(find.text('잔액 0원 · 계산에서 뺀 계좌'), findsOneWidget);
    await tester.tap(
      find.byKey(
        const ValueKey('edit-account-48feba1a-c98e-5d0e-91e1-23d8e1ef00fc'),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sheet-apply')));
    await tester.pumpAndSettle();
    expect(
      find.text('잔액 300,000원\n계산에서 뺀 계좌라 지금 쓸 수 있는 돈에는 반영되지 않아요.'),
      findsOneWidget,
    );
  });

  testWidgets('금액 입력 중 예정일·출금 계좌를 고르거나 빈 곳을 누르면 입력 포커스가 풀린다', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('plan-add')));
    await tester.pumpAndSettle();
    bool focused() => tester
        .widget<EditableText>(
          find.descendant(
            of: _field('edit-amount'),
            matching: find.byType(EditableText),
          ),
        )
        .focusNode
        .hasFocus;
    await tester.tap(_field('edit-amount'));
    await tester.pump();
    expect(focused(), isTrue);
    await tester.tap(find.byKey(const ValueKey('edit-date')));
    await tester.pumpAndSettle();
    expect(focused(), isFalse, reason: '달력을 열면 키보드를 닫음');
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    await tester.tap(_field('edit-amount'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('edit-account')));
    await tester.pumpAndSettle();
    expect(focused(), isFalse, reason: '계좌 선택창을 열면 키보드를 닫음');
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    await tester.tap(_field('edit-amount'));
    await tester.pump();
    await tester.tapAt(
      tester.getBottomLeft(find.byKey(const ValueKey('edit-account'))) +
          const Offset(4, 120),
    );
    await tester.pump();
    expect(focused(), isFalse, reason: '입력칸 밖 빈 곳');
  });

  testWidgets('잔액보다 큰 예정 지출: 출금 계좌 아래 주의 안내, 추가는 그대로 가능, 금액을 줄이면 사라짐', (
    tester,
  ) async {
    await _pump(tester);
    await _fillAdd(tester);
    expect(find.byKey(const ValueKey('edit-balance-note')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('edit-account')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('edit-account-48feba1a-c98e-5d0e-91e1-23d8e1ef00fc'),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sheet-apply')));
    await tester.pumpAndSettle();
    await tester.enterText(_field('edit-amount'), '698708');
    await tester.pump();
    expect(
      find.text('현재 잔액보다 398,708원 많아요. 예정일까지 잔액을 확인해 주세요.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('edit-save')))
          .onPressed,
      isNotNull,
    );
    await tester.enterText(_field('edit-amount'), '300000');
    await tester.pump();
    expect(find.byKey(const ValueKey('edit-balance-note')), findsNothing);
  });

  test('잔액을 모르면 0원이 아니라 확인 불가', () {
    final json = planSource();
    (rows(json, 'accounts').first)['balanceKRW'] = null;
    final account = FinancialSnapshot.fromJson(json).accounts!.first;
    expect(balanceText(account), '잔액 확인 불가');
  });

  testWidgets('연결 없는 취소: 하단 취소 버튼, 공통 확인창 폭, 구분선·연결 안내 없음', (tester) async {
    await _pump(tester);
    await _openRow(tester, '월세');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('edit-preview')),
        matching: find.text('예정 지출 취소하기'),
      ),
      findsOneWidget,
      reason: '취소는 하단 버튼 줄의 저장 버튼 왼쪽(2026-11-03 결정)',
    );
    await tester.tap(find.byKey(const ValueKey('edit-cancel')));
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    expect(
      tester
          .getSize(
            find.descendant(of: dialog, matching: find.byType(Material)).first,
          )
          .width,
      390 - 2 * 24,
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(Divider)),
      findsNothing,
    );
    expect(find.textContaining('연결 해제'), findsNothing);
    expect(
      find.textContaining('(+300,000원)', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('취소 응답 유실: 하단 다시 시도하기로 같은 키 재전송, 한 번만 취소되고 목록으로 돌아와 알림', (
    tester,
  ) async {
    final host = await _pump(tester);
    host.flaky.lose = 1;
    await _openRow(tester, '월세');
    await tester.tap(find.byKey(const ValueKey('edit-cancel')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('cancel-confirm')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-band-unknown')), findsOneWidget);
    expect(_saveLabel(tester), '다시 시도하기');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('edit-save')))
          .onPressed,
      isNotNull,
    );
    await _save(tester);
    expect(find.text('예정 지출을 취소했어요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-add')), findsOneWidget);
    final [first, second] = host.flaky.calls;
    expect((first.$1, second.$1), ('cancel', 'cancel'));
    expect(second.$2.idempotencyKey, first.$2.idempotencyKey);
    expect(find.text('월세'), findsNothing, reason: '취소돼 목록에서 빠짐');
  });

  testWidgets('반복 회차는 이 회차만 바뀐다고 알린다', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('plan-next')));
    await tester.pumpAndSettle();
    await _openRow(tester, '통신비');
    expect(find.byKey(const ValueKey('edit-band-recurring')), findsOneWidget);
    expect(find.text('이 회차만 바뀌어요'), findsOneWidget);
  });

  testWidgets('카드 청구 행은 편집이 아니라 카드 결제 상세로 간다', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('plan-fold-done')));
    await tester.pumpAndSettle();
    await _openRow(tester, '카드 청구');
    expect(find.text('예정 지출 수정'), findsNothing);
  });

  testWidgets('320dp·글자 1.3배에서 오류·금액·저장 버튼이 넘치지 않고 보인다', (tester) async {
    await _pump(tester, width: 320, height: 760, textScale: 1.3);
    await _openRow(tester, '수리비');
    await tester.enterText(_field('edit-amount'), '90000');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('edit-save')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('계산 불가'), findsOneWidget);
  });
}
