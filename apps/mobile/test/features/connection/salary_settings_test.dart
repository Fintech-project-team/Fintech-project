import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/connection/connection_flow.dart';
import 'package:payse/features/connection/salary_settings_controller.dart';
import 'package:payse/features/connection/salary_settings_screen.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/primary_button.dart';

import 'connection_test_support.dart';

const _kbDemand = '1d383795-5b7c-56f9-9535-ff418040183d';
const _shinhanSavings = '193eba4d-a29e-5a1a-9087-08b3f2aa353b';
const _hanaDemand = '89abcc26-5a13-5031-944d-f6fa79fad474';
const _all = {...betaBanks, ...betaCards};
const _selected = {_kbDemand, _hanaDemand};

/// 2026-10-28: 원본 월급 설정을 [salary]로 덮는 변경을 반환한다.
void Function(Map<String, Object?>) _salary(Map<String, Object?> salary) =>
    (source) => ((source['settings']! as Map)['salary']! as Map).addAll(salary);

/// 2026-10-28: 전체 연결·국민/하나 입출금 선택 beta 응답 JSON. [salary]로 월급 설정을 덮는다.
Map<String, Object?> _json({
  String version = '3',
  Map<String, Object?> salary = const {},
  Set<String> codes = _all,
  Set<String> selected = _selected,
  void Function(Map<String, Object?> source)? mutate,
}) => betaJson(
  codes,
  selected: selected,
  version: version,
  mutate: (source) {
    _salary(salary)(source);
    mutate?.call(source);
  },
);

/// 2026-10-28: [_json]을 화면 모델로 읽어 반환한다.
FinancialSnapshot _snapshot({
  String version = '3',
  Map<String, Object?> salary = const {},
  Set<String> codes = _all,
  Set<String> selected = _selected,
  void Function(Map<String, Object?> source)? mutate,
}) => FinancialSnapshot.fromJson(
  _json(
    version: version,
    salary: salary,
    codes: codes,
    selected: selected,
    mutate: mutate,
  ),
);

/// 2026-10-28: 화면 폭 [width]·높이 [height]·글자 배율 [scale]로 [child]를 띄운다.
Future<void> _show(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double height = 1000,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    ),
  );
}

void main() {
  late ScriptedRepository repo;
  late SalarySettingsController controller;
  late List<FinancialSnapshot> received;
  late int left;
  var sessionInvalid = 0;

  /// 2026-10-28: [snapshot]으로 월급 설정 화면을 띄운다.
  Future<void> open(
    WidgetTester tester,
    FinancialSnapshot snapshot, {
    double width = 390,
    double height = 1000,
    double scale = 1,
  }) async {
    repo = ScriptedRepository();
    received = [];
    left = 0;
    sessionInvalid = 0;
    controller = SalarySettingsController(
      repository: repo,
      snapshot: snapshot,
      onSessionInvalid: () => sessionInvalid++,
      random: Random(1),
    );
    addTearDown(controller.dispose);
    await _show(
      tester,
      SalarySettingsScreen(
        controller: controller,
        onSnapshot: received.add,
        onBack: () => left++,
      ),
      width: width,
      height: height,
      scale: scale,
    );
  }

  /// 2026-10-28: 저장 버튼이 눌리면 true를 반환한다.
  bool saveEnabled(WidgetTester tester) =>
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('salary-save')))
          .onPressed !=
      null;

  /// 2026-10-28: 금액 칸에 [text]를 입력한다.
  Future<void> typeAmount(WidgetTester tester, String text) async {
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('salary-amount')),
        matching: find.byType(TextField),
      ),
      text,
    );
    await tester.pump();
  }

  /// 2026-10-28: 월급일 선택에서 [day]일을 고른다.
  Future<void> pickDay(WidgetTester tester, int day) async {
    await tester.tap(find.byKey(const ValueKey('salary-day')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('salary-day-$day')));
    await tester.pumpAndSettle();
  }

  group('salary settings screen', () {
    testWidgets('shows saved values in the mockup layout', (tester) async {
      await open(tester, _snapshot());
      expect(find.text('월급 정보를\n확인해 주세요'), findsOneWidget);
      expect(find.text('월급 설정을 확인하고 필요하면 수정해 주세요.'), findsOneWidget);
      expect(find.text('월급 설정'), findsOneWidget);
      expect(find.text('매월 25일'), findsOneWidget);
      expect(find.text('3,000,000'), findsOneWidget);
      expect(find.text('원'), findsOneWidget);
      expect(find.text('국민은행 입출금 ····5821'), findsNothing);
      expect(find.textContaining('입출금 ····'), findsOneWidget);
      expect(find.text('해당 날짜가 없는 달에는 말일로 계산해요.'), findsOneWidget);
      expect(
        find.text('앞으로 받을 것으로 예상하는 금액이며, 현재 잔액에는 더하지 않아요.'),
        findsOneWidget,
      );
      expect(find.text('계산에 쓰기로 고른 계좌 중에서 고를 수 있어요.'), findsOneWidget);
      expect(find.text('월급 설정 저장하기'), findsOneWidget);
      expect(saveEnabled(tester), isFalse, reason: '바꾼 값 없음');
      expect(find.text('확인 화면으로 돌아가기'), findsOneWidget);
      expect(find.textContaining('입금 내역'), findsNothing, reason: '입금 확인은 4b-2');
      expect(
        tester.getSemantics(find.byKey(const ValueKey('salary-save'))),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );
    });

    testWidgets('save turns on only while a value differs from the saved one', (
      tester,
    ) async {
      await open(tester, _snapshot());
      await typeAmount(tester, '3100000');
      expect(find.text('3,100,000'), findsOneWidget, reason: '쉼표 표시');
      expect(saveEnabled(tester), isTrue);
      await typeAmount(tester, '3000000');
      expect(saveEnabled(tester), isFalse, reason: '원래 값으로 되돌림');

      await pickDay(tester, 10);
      expect(find.text('매월 10일'), findsOneWidget);
      expect(saveEnabled(tester), isTrue);
      await pickDay(tester, 25);
      expect(saveEnabled(tester), isFalse);

      await tester.tap(find.byKey(const ValueKey('salary-account')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('월급 계좌 선택'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('salary-account-$_kbDemand')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('salary-account-$_shinhanSavings')),
        findsNothing,
        reason: '계산에 고른 계좌만',
      );
      await tester.tap(
        find.byKey(const ValueKey('salary-account-$_hanaDemand')),
      );
      await tester.pumpAndSettle();
      expect(saveEnabled(tester), isTrue);
      expect(controller.patch.toJson(), {'salaryAccountId': _hanaDemand});
    });

    testWidgets('the payday opens as a calendar bottom sheet', (tester) async {
      await open(tester, _snapshot());
      await tester.tap(find.byKey(const ValueKey('salary-day')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('월급일 선택'), findsOneWidget);
      for (var day = 1; day <= 31; day++) {
        expect(find.byKey(ValueKey('salary-day-$day')), findsOneWidget);
      }
      final first = tester.getCenter(
        find.byKey(const ValueKey('salary-day-1')),
      );
      final eighth = tester.getCenter(
        find.byKey(const ValueKey('salary-day-8')),
      );
      final seventh = tester.getCenter(
        find.byKey(const ValueKey('salary-day-7')),
      );
      expect(seventh.dy, first.dy, reason: '한 줄 7칸');
      expect(eighth.dx, first.dx);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('salary-day-25'))),
        isSemantics(label: '매월 25일', isButton: true, isSelected: true),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('salary-day-3'))).height,
        greaterThanOrEqualTo(44),
      );
      await tester.tap(find.byKey(const ValueKey('salary-day-3')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('매월 3일'), findsOneWidget);
    });

    testWidgets('many accounts scroll inside a sheet below the status bar', (
      tester,
    ) async {
      await open(
        tester,
        _snapshot(
          mutate: (source) {
            final accounts = source['accounts']! as List;
            final base = (accounts.first as Map).cast<String, Object?>();
            for (var i = 0; i < 15; i++) {
              accounts.add({
                ...base,
                'accountId': '00000000-0000-4000-8000-${'$i'.padLeft(12, '0')}',
                'maskedNumber': '***-***-${'$i'.padLeft(4, '0')}',
                'productName': '추가 통장 $i',
              });
            }
          },
          selected: {
            ..._selected,
            for (var i = 0; i < 15; i++)
              '00000000-0000-4000-8000-${'$i'.padLeft(12, '0')}',
          },
        ),
        height: 844,
      );
      tester.view.padding = const FakeViewPadding(top: 47 * 3);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('salary-account')));
      await tester.pumpAndSettle();
      final sheet = tester.getRect(find.byType(BottomSheet));
      expect(sheet.top, greaterThanOrEqualTo(47), reason: '상태 표시줄 아래');
      expect(tester.takeException(), isNull);
      final last = find.byKey(
        const ValueKey('salary-account-00000000-0000-4000-8000-000000000014'),
      );
      await tester.scrollUntilVisible(
        last,
        200,
        scrollable: find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        ),
      );
      expect(sheet.height, lessThanOrEqualTo(844 * 0.85));
      expect(
        tester.getRect(find.text('월급 계좌 선택')).top,
        lessThan(sheet.top + 80),
        reason: '목록만 스크롤하고 제목은 고정',
      );
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.text('추가 통장 14'), findsNothing);
      expect(controller.patch.toJson(), {
        'salaryAccountId': '00000000-0000-4000-8000-000000000014',
      });
    });

    for (final (width, columns) in [(320.0, 5), (360.0, 6), (390.0, 7)]) {
      testWidgets(
        'payday cells keep 48dp at ${width}dp with $columns columns',
        (tester) async {
          await open(tester, _snapshot(), width: width);
          await tester.tap(find.byKey(const ValueKey('salary-day')));
          await tester.pumpAndSettle();
          Rect cell(int day) =>
              tester.getRect(find.byKey(ValueKey('salary-day-$day')));
          for (var day = 1; day <= 31; day++) {
            expect(
              cell(day).width,
              greaterThanOrEqualTo(48),
              reason: '$day일 폭',
            );
            expect(
              cell(day).height,
              greaterThanOrEqualTo(48),
              reason: '$day일 높이',
            );
          }
          expect(cell(columns).top, cell(1).top, reason: '한 줄 $columns칸');
          expect(cell(columns + 1).left, cell(1).left, reason: '다음 줄 시작');
          expect(cell(2).left, cell(1).right, reason: '칸이 겹치지 않음');

          await tester.tapAt(cell(3).centerRight - const Offset(1, 0));
          await tester.pumpAndSettle();
          expect(find.text('매월 3일'), findsOneWidget, reason: '오른쪽 끝도 3일');
          await tester.tap(find.byKey(const ValueKey('salary-day')));
          await tester.pumpAndSettle();
          await tester.tapAt(cell(4).centerLeft + const Offset(1, 0));
          await tester.pumpAndSettle();
          expect(find.text('매월 4일'), findsOneWidget, reason: '바로 옆 왼쪽 끝은 4일');
          await tester.tap(find.byKey(const ValueKey('salary-day')));
          await tester.pumpAndSettle();
          final below = cell(3 + columns);
          await tester.tapAt(below.topCenter + const Offset(0, 1));
          await tester.pumpAndSettle();
          expect(
            find.text('매월 ${3 + columns}일'),
            findsOneWidget,
            reason: '아래 칸 위쪽 끝',
          );
        },
      );
    }

    testWidgets('an empty amount shows an error and sends nothing', (
      tester,
    ) async {
      await open(tester, _snapshot());
      await typeAmount(tester, '');
      expect(saveEnabled(tester), isTrue);
      await tester.tap(find.byKey(const ValueKey('salary-save')));
      await tester.pump();
      expect(find.text('예상 월급 금액을 입력해 주세요.'), findsOneWidget);
      expect(repo.salaryCalls, isEmpty);
      await typeAmount(tester, '1');
      expect(find.text('예상 월급 금액을 입력해 주세요.'), findsNothing);
    });

    testWidgets('the bottom button points back', (tester) async {
      await open(tester, _snapshot());
      final button = find.byKey(const ValueKey('salary-done'));
      expect(tester.widget<PrimaryButton>(button).back, isTrue);
      final left = find.descendant(
        of: button,
        matching: find.byIcon(Icons.chevron_left),
      );
      expect(left, findsOneWidget);
      expect(
        find.descendant(of: button, matching: find.byIcon(Icons.chevron_right)),
        findsNothing,
      );
      expect(
        tester.getCenter(left).dx,
        lessThan(tester.getCenter(find.text('확인 화면으로 돌아가기')).dx),
        reason: '화살표가 왼쪽 끝',
      );
    });

    testWidgets('success adopts the response, disables save and tells 01-2', (
      tester,
    ) async {
      await open(tester, _snapshot());
      await pickDay(tester, 10);
      await typeAmount(tester, '3100000');
      repo.salaryResults.add(
        written(
          _json(
            version: '4',
            salary: {'salaryDay': 10, 'salaryAmountKRW': 3100000},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('salary-save')));
      await tester.pump();
      final (patch, write) = repo.salaryCalls.single;
      expect(patch.toJson(), {'salaryAmountKRW': 3100000, 'salaryDay': 10});
      expect(write.expectedDataVersion, '3');
      expect(find.text('월급 설정을 저장했어요.'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
      expect(received.single.settings!.salary.salaryDay, 10);
      expect(controller.snapshot.dataVersion, '4');
      await tester.tap(find.byKey(const ValueKey('salary-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('salary-leave-dialog')), findsNothing);
      expect(left, 1, reason: '저장 뒤에는 바로 나감');
    });

    testWidgets(
      'an unknown result keeps the input and retries with the same key',
      (tester) async {
        await open(tester, _snapshot());
        await typeAmount(tester, '3200000');
        repo.salaryResults
          ..add(const FinancialNetworkFailure('timeout'))
          ..add(const FinancialUnavailable());
        await tester.tap(find.byKey(const ValueKey('salary-save')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('salary-band-retryable')),
          findsOneWidget,
        );
        expect(find.text('월급 설정을 저장하지 못했어요'), findsOneWidget);
        expect(find.text('3,200,000'), findsOneWidget, reason: '입력 보존');
        expect(saveEnabled(tester), isTrue);
        expect(received, isEmpty);
        await tester.tap(find.byKey(const ValueKey('salary-save')));
        await tester.pump();
        expect(
          repo.salaryCalls[1].$2.idempotencyKey,
          repo.salaryCalls[0].$2.idempotencyKey,
          reason: '같은 논리 작업은 같은 키',
        );
        await typeAmount(tester, '3300000');
        repo.salaryResults.add(const FinancialUnavailable());
        await tester.tap(find.byKey(const ValueKey('salary-save')));
        await tester.pump();
        expect(
          repo.salaryCalls[2].$2.idempotencyKey,
          isNot(repo.salaryCalls[0].$2.idempotencyKey),
          reason: '내용이 바뀌면 새 키',
        );
      },
    );

    testWidgets('a rejected save keeps the input and says it cannot be saved', (
      tester,
    ) async {
      await open(tester, _snapshot());
      await typeAmount(tester, '3200000');
      repo.salaryResults.add(const FinancialInvalid());
      await tester.tap(find.byKey(const ValueKey('salary-save')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('salary-band-rejected')),
        findsOneWidget,
      );
      expect(find.text('3,200,000'), findsOneWidget);
      expect(controller.dirty, isTrue);
    });

    testWidgets('a version conflict asks to reload; reload keeps the input', (
      tester,
    ) async {
      await open(tester, _snapshot());
      await typeAmount(tester, '3200000');
      repo.salaryResults.add(const FinancialStaleData());
      await tester.tap(find.byKey(const ValueKey('salary-save')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('salary-band-outdated')),
        findsOneWidget,
      );
      expect(saveEnabled(tester), isFalse, reason: '최신 정보를 먼저 불러와야 함');

      repo.loadResults.add(const FinancialUnavailable());
      await tester.tap(find.byKey(const ValueKey('salary-reload')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('salary-band-reload-failed')),
        findsOneWidget,
      );
      expect(find.text('3,200,000'), findsOneWidget);

      repo.loadResults.add(
        FinancialOk(_json(version: '5', salary: {'salaryDay': 1})),
      );
      await tester.tap(find.byKey(const ValueKey('salary-reload')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('salary-band-reload-failed')),
        findsNothing,
      );
      expect(find.text('매월 1일'), findsOneWidget, reason: '바꾸지 않은 칸은 새 저장 값');
      expect(find.text('3,200,000'), findsOneWidget, reason: '입력 유지');
      expect(saveEnabled(tester), isTrue);
      expect(received.single.dataVersion, '5');
      repo.salaryResults.add(const FinancialUnavailable());
      await tester.tap(find.byKey(const ValueKey('salary-save')));
      await tester.pump();
      expect(repo.salaryCalls.last.$2.expectedDataVersion, '5');
    });

    testWidgets('an invalid session goes to sign-in', (tester) async {
      await open(tester, _snapshot());
      await typeAmount(tester, '3200000');
      repo.salaryResults.add(const FinancialSessionInvalid());
      await tester.tap(find.byKey(const ValueKey('salary-save')));
      await tester.pump();
      expect(sessionInvalid, 1);
    });

    testWidgets('every way out asks before dropping changes', (tester) async {
      await open(tester, _snapshot());
      await typeAmount(tester, '3200000');

      Future<void> expectDialog() async {
        await tester.pumpAndSettle();
        expect(find.text('저장하지 않은 변경이 있어요'), findsOneWidget);
        expect(find.text('나가면 바꾼 월급 설정이 저장되지 않아요.'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('salary-keep-editing')));
        await tester.pumpAndSettle();
        expect(left, 0);
        expect(find.text('3,200,000'), findsOneWidget);
      }

      await tester.tap(find.byTooltip('뒤로'));
      await expectDialog();
      await tester.binding.handlePopRoute();
      await expectDialog();
      await tester.tap(find.byKey(const ValueKey('salary-done')));
      await expectDialog();

      await tester.tap(find.byKey(const ValueKey('salary-done')));
      await tester.pumpAndSettle();
      expect(find.text('저장 안 하고 나가기'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('salary-leave')));
      await tester.pumpAndSettle();
      expect(left, 1);
      expect(repo.salaryCalls, isEmpty);
    });

    for (final (width, scale, stacked) in [
      (600.0, 1.0, false),
      (390.0, 1.0, true),
      (320.0, 1.3, true),
    ]) {
      testWidgets('leave buttons at ${width}dp x$scale stacked=$stacked', (
        tester,
      ) async {
        await open(tester, _snapshot(), width: width, scale: scale);
        await typeAmount(tester, '3200000');
        await tester.tap(find.byTooltip('뒤로'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final leave = tester.getRect(
          find.byKey(const ValueKey('salary-leave')),
        );
        final keep = tester.getRect(
          find.byKey(const ValueKey('salary-keep-editing')),
        );
        if (stacked) {
          expect(keep.bottom, lessThanOrEqualTo(leave.top), reason: '차콜이 위');
          expect(keep.width, leave.width);
        } else {
          expect(leave.right, lessThanOrEqualTo(keep.left), reason: '테두리 왼쪽');
          expect(leave.top, keep.top);
        }
      });
    }

    testWidgets('without changes every way out leaves at once', (tester) async {
      await open(tester, _snapshot());
      await tester.tap(find.byTooltip('뒤로'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('salary-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('salary-leave-dialog')), findsNothing);
      expect(left, 3);
    });

    testWidgets('a hidden salary account is shown as unknown until replaced', (
      tester,
    ) async {
      final snapshot = _snapshot(
        codes: {'bank.hana', ...betaCards},
        selected: {_hanaDemand},
      );
      expect(snapshot.settings!.salary.salaryAccountRestricted, isTrue);
      await open(tester, snapshot);
      expect(find.text('월급 계좌 정보를 볼 수 없어요'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
      await tester.tap(find.byKey(const ValueKey('salary-account')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('salary-account-$_hanaDemand')),
      );
      await tester.pumpAndSettle();
      expect(controller.patch.toJson(), {'salaryAccountId': _hanaDemand});
    });

    for (final (width, scale) in [(320.0, 1.0), (320.0, 1.3), (390.0, 1.3)]) {
      testWidgets('no overflow at ${width}dp with text x$scale', (
        tester,
      ) async {
        await open(
          tester,
          _snapshot(),
          width: width,
          height: 700,
          scale: scale,
        );
        await typeAmount(tester, '1234567890123');
        repo.salaryResults.add(const FinancialStaleData());
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('salary-save')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byKey(const ValueKey('salary-save')));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byType(PrimaryButton), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('salary-day')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('salary-day')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('salary-day-31')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '월급일 시트도 넘침 없음');
      });
    }
  });

  group('01-2 entry', () {
    testWidgets('edit opens settings and a save refreshes 01-2 and the flow', (
      tester,
    ) async {
      final repo = ScriptedRepository()
        ..selectResults.add(written(_json(version: '3')))
        ..salaryResults.add(
          written(_json(version: '4', salary: {'salaryDay': 10})),
        )
        ..selectResults.add(
          written(
            _json(
              version: '5',
              salary: {'salaryDay': 10},
              selected: {_kbDemand},
            ),
          ),
        );
      FinancialSnapshot? finished;
      await _show(
        tester,
        ConnectionFlow(
          repository: repo,
          snapshot: FinancialSnapshot.fromJson(betaJson(_all, version: '2')),
          policy: instantPolicy(),
          onFinished: (snapshot, {required deferred}) => finished = snapshot,
          onSessionInvalid: () {},
          random: Random(1),
        ),
        height: 1400,
      );
      await tester.pumpAndSettle();
      for (final id in _selected) {
        await tester.tap(find.byKey(ValueKey('account-$id')));
        await tester.pump();
      }
      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pumpAndSettle();
      expect(find.text('매월 25일'), findsOneWidget);
      expect(find.text('확인·수정'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('review-salary-edit')));
      await tester.pumpAndSettle();
      await pickDay(tester, 10);
      await tester.tap(find.byKey(const ValueKey('salary-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('salary-done')));
      await tester.pumpAndSettle();

      expect(find.text('다음 월급일까지 쓸 수 있는 돈을\n알아볼까요?'), findsOneWidget);
      expect(find.text('매월 10일'), findsOneWidget, reason: '01-2 갱신');
      expect(find.text('매월 25일'), findsNothing);
      final defer = find.byKey(const ValueKey('review-defer'));
      await tester.tap(
        defer.evaluate().isEmpty
            ? find.byKey(const ValueKey('review-calculate'))
            : defer,
      );
      await tester.pump();
      expect(finished!.settings!.salary.salaryDay, 10, reason: '홈도 새 스냅샷');
      expect(finished!.dataVersion, '4');

      await tester.tap(find.byTooltip('뒤로'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-$_hanaDemand')));
      await tester.pump();
      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pumpAndSettle();
      expect(
        repo.selectCalls.last.$2.expectedDataVersion,
        '4',
        reason: '01-1 재저장도 새 버전',
      );
    });
  });
}
