import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/connection/connection_flow.dart';
import 'package:payse/features/connection/connection_flow_controller.dart';
import 'package:payse/features/connection/connection_presentation_policy.dart';
import 'package:payse/features/connection/connection_screens.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/shared/design/institution_mark.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/primary_button.dart';
import 'package:payse/shared/design/selection_controls.dart';
import 'package:payse/shared/design/payse_tokens.dart';
import 'package:payse/shared/design/status_notice.dart';

import '../../data/calculation_input_adapter_test.dart' show alphaWithReceipt;
import '../../data/connection/connection_test_utils.dart';
import 'connection_test_support.dart';

/// 2026-10-22: 휴대폰 크기(390×844) 화면에 [child]를 테마와 함께 띄운다.
/// [height]로 세로 길이를 늘려 긴 목록 전체를 그릴 수 있다.
Future<void> _show(
  WidgetTester tester,
  Widget child, {
  double height = 844,
}) async {
  tester.view.physicalSize = Size(1170, height * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildPayseTheme(), home: child));
}

/// 2026-10-22: 버튼 글자 [label]의 아래 버튼이 눌리는지 반환한다.
bool _enabled(WidgetTester tester, String label) =>
    tester
        .widget<PrimaryButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(PrimaryButton),
          ),
        )
        .onPressed !=
    null;

/// 2026-10-22: 연결 전 beta Snapshot의 흐름 상태를 만든다.
ConnectionFlowController _flow(
  UserFinancialRepository repo, {
  ConnectionPresentationPolicy? policy,
  FinancialSnapshot? snapshot,
}) => ConnectionFlowController(
  repository: repo,
  snapshot: snapshot ?? betaSnapshot(const {}),
  policy: policy ?? instantPolicy(),
  onSessionInvalid: () {},
  random: Random(3),
);

/// 2026-10-22: [codes]를 고르고 모두 동의한다.
void _consentAll(ConnectionFlowController c, Set<String> codes) {
  for (final code in codes) {
    c.toggleChosen(code);
  }
  c.enterConsent();
  c.setAllConsent(true);
}

const _selectHeading = '어느 금융사의 정보를\n불러올까요?';
const _cardWarning = '쓸 수 있는 돈을 계산하려면 은행을 1곳 이상 골라주세요.';
const _consentWarning = '은행 1곳 이상 동의해야 계좌를 불러올 수 있어요.';

void main() {
  group('12-1 and 12-2', () {
    testWidgets('groups select all, show counts and need a bank to go on', (
      tester,
    ) async {
      final c = _flow(ScriptedRepository());
      await _show(
        tester,
        InstitutionSelectScreen(controller: c, onNext: () {}),
        height: 1600,
      );
      expect(find.byType(InstitutionMark), findsNWidgets(9));
      expect(find.text('모두 선택'), findsNWidgets(2), reason: '처음에는 모두 미선택');
      expect(find.text(_cardWarning), findsNothing, reason: '버튼 위 안내 없음');
      expect(_enabled(tester, '다음'), isFalse);

      Finder inGroup(String key, String text) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.text(text),
      );
      await tester.tap(inGroup('group-cards', '모두 선택'));
      await tester.pump();
      expect(find.textContaining('· 4곳 선택'), findsOneWidget);
      expect(inGroup('group-cards', '모두 해제'), findsOneWidget);
      expect(find.text(_cardWarning), findsNothing);
      expect(_enabled(tester, '다음'), isFalse, reason: '카드사만으로는 진행 불가');

      await tester.tap(find.byKey(const ValueKey('institution-bank.kb')));
      await tester.pump();
      expect(find.textContaining('· 1곳 선택'), findsOneWidget);
      expect(inGroup('group-banks', '모두 선택'), findsOneWidget, reason: '일부 선택');
      expect(_enabled(tester, '다음'), isTrue);

      await tester.tap(inGroup('group-banks', '모두 선택'));
      await tester.pump();
      expect(find.textContaining('· 5곳 선택'), findsOneWidget);
      await tester.tap(inGroup('group-banks', '모두 해제'));
      await tester.pump();
      expect(c.hasChosenBank, isFalse);
      expect(c.isChosen('card.hyundai'), isTrue, reason: '다른 묶음은 그대로');
      expect(_enabled(tester, '다음'), isFalse);
    });

    testWidgets('consent starts unchecked and needs a bank', (tester) async {
      final c = _flow(ScriptedRepository())
        ..toggleChosen('bank.kb')
        ..toggleChosen('card.hyundai')
        ..enterConsent();
      await _show(
        tester,
        ConsentScreen(
          controller: c,
          onBack: () {},
          onViewItems: (_) {},
          onNext: () {},
        ),
      );
      expect(find.text(_consentWarning), findsNothing);
      expect(_enabled(tester, '동의하고 불러오기'), isFalse);
      await tester.tap(find.byKey(const ValueKey('consent-card.hyundai')));
      await tester.pump();
      expect(find.text(_consentWarning), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('consent-all')));
      await tester.pump();
      expect(find.text(_consentWarning), findsNothing);
      expect(_enabled(tester, '동의하고 불러오기'), isTrue);
    });
  });

  group('12-3', () {
    testWidgets('with the toggle off, real save failures are still explained', (
      tester,
    ) async {
      final repo = ScriptedRepository()
        ..linkResults.addAll([
          const FinancialNetworkFailure('offline'),
          const FinancialStaleData(),
        ]);
      final c = _flow(
        repo,
        policy: instantPolicy(draws: [0.05], failuresEnabled: false),
      );
      _consentAll(c, {'bank.kb'});
      await c.startLoading();
      await _show(
        tester,
        InstitutionLoadingScreen(
          controller: c,
          onBack: () {},
          onSaved: () {},
          onRestart: () {},
        ),
      );
      expect(find.text('불러오지 못했어요'), findsNothing, reason: '연출 실패 없음');
      await tester.tap(find.text('계속하기'));
      await tester.pump();
      expect(find.text('연결을 저장하지 못했어요'), findsOneWidget);
      await tester.tap(find.text('다시 시도'));
      await tester.pump();
      expect(find.text('저장 전에 정보가 바뀌었어요'), findsOneWidget);
    });

    testWidgets(
      'while loading there is no back, no exclude button and no save',
      (tester) async {
        final c = _flow(
          ScriptedRepository(),
          policy: ConnectionPresentationPolicy(
            failuresEnabled: () => true,
            random: SequenceRandom(doubles: [0.5], ints: [0]),
          ),
        );
        _consentAll(c, {'bank.kb', 'card.hyundai'});
        await _show(
          tester,
          InstitutionLoadingScreen(
            controller: c,
            onBack: () {},
            onSaved: () {},
            onRestart: () {},
          ),
        );
        final loading = c.startLoading();
        await tester.pump();
        expect(find.text('금융사 정보를\n불러오고 있어요'), findsOneWidget);
        expect(find.text('2곳 중 0곳 완료'), findsOneWidget);
        expect(find.text('0%'), findsOneWidget);
        expect(find.textContaining('정보를 불러오는 중이에요.'), findsOneWidget);
        expect(find.text('불러오는 중'), findsOneWidget);
        expect(find.text('기다리는 중'), findsOneWidget);
        expect(find.byTooltip('뒤로'), findsNothing);
        expect(_enabled(tester, '불러오는 중이에요'), isFalse);
        expect(find.textContaining('제외하고'), findsNothing);
        await tester.pump(const Duration(milliseconds: 1000));
        await tester.pump(const Duration(milliseconds: 1000));
        await loading;
        await tester.pump();
        expect(find.text('금융사 정보를\n다 불러왔어요'), findsOneWidget);
        expect(find.byTooltip('뒤로'), findsOneWidget);
        expect(_enabled(tester, '계속하기'), isTrue);
      },
    );

    testWidgets('one or two failures name the exclusion and retry clears it', (
      tester,
    ) async {
      final one = _flow(
        ScriptedRepository(),
        policy: instantPolicy(draws: [0.5, 0.05, 0.5]),
      );
      _consentAll(one, {'bank.kb', 'bank.shinhan', 'card.hyundai'});
      await one.startLoading();
      await _show(
        tester,
        InstitutionLoadingScreen(
          controller: one,
          onBack: () {},
          onSaved: () {},
          onRestart: () {},
        ),
      );
      expect(find.text('1곳의 정보를\n불러오지 못했어요'), findsOneWidget);
      expect(find.text('신한은행 제외하고 계속하기'), findsOneWidget);
      expect(find.text('불러오지 못했어요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('retry-bank.shinhan')));
      await tester.pump();
      await tester.pump();
      expect(find.text('계속하기'), findsOneWidget);

      final two = _flow(
        ScriptedRepository(),
        policy: instantPolicy(draws: [0.05, 0.05, 0.5]),
      );
      _consentAll(two, {'bank.kb', 'bank.shinhan', 'bank.kakao'});
      await two.startLoading();
      await _show(
        tester,
        InstitutionLoadingScreen(
          controller: two,
          onBack: () {},
          onSaved: () {},
          onRestart: () {},
        ),
      );
      expect(find.text('2곳 제외하고 계속하기'), findsOneWidget);
    });

    testWidgets(
      'saving hides retry, and reloading shows progress then its failure',
      (tester) async {
        final repo = _HoldingRepository();
        final c = _flow(repo, policy: instantPolicy(draws: [0.5, 0.05]));
        _consentAll(c, {'bank.kb', 'bank.shinhan'});
        await c.startLoading();
        await _show(
          tester,
          InstitutionLoadingScreen(
            controller: c,
            onBack: () {},
            onSaved: () {},
            onRestart: () {},
          ),
        );
        const retryKey = ValueKey('retry-bank.shinhan');
        expect(find.byKey(retryKey), findsOneWidget);
        final link = Completer<FinancialOutcome<WriteSuccess>>();
        repo.link = link;
        await tester.tap(find.text('신한은행 제외하고 계속하기'));
        await tester.pump();
        expect(find.byKey(retryKey), findsNothing, reason: '저장 중 다시 시도 없음');
        expect(find.text('제외'), findsOneWidget);

        link.complete(const FinancialStaleData());
        await tester.pump();
        expect(find.text('저장 전에 정보가 바뀌었어요'), findsOneWidget);
        expect(find.byKey(retryKey), findsOneWidget);

        final load = Completer<FinancialOutcome<Map<String, Object?>>>();
        repo.load = load;
        await tester.tap(find.text('다시 불러오기'));
        await tester.pump();
        expect(find.text('불러오고 있어요'), findsOneWidget);
        expect(_enabled(tester, '불러오고 있어요'), isFalse);

        load.complete(const FinancialNetworkFailure('offline'));
        await tester.pump();
        expect(find.text('최신 정보를 불러오지 못했어요'), findsOneWidget);
        expect(find.text('저장 전에 정보가 바뀌었어요'), findsNothing);
        expect(_enabled(tester, '다시 불러오기'), isTrue);
      },
    );

    testWidgets('no bank left blocks the flow with a notice', (tester) async {
      final c = _flow(
        ScriptedRepository(),
        policy: instantPolicy(draws: [0.05, 0.5]),
      );
      _consentAll(c, {'bank.kb', 'card.hyundai'});
      await c.startLoading();
      await _show(
        tester,
        InstitutionLoadingScreen(
          controller: c,
          onBack: () {},
          onSaved: () {},
          onRestart: () {},
        ),
      );
      expect(find.text('국민은행 제외하고 계속하기'), findsOneWidget);
      expect(_enabled(tester, '국민은행 제외하고 계속하기'), isFalse);
      expect(find.text('계산할 은행 계좌가 없어요. 은행을 다시 시도해주세요.'), findsOneWidget);
    });

    testWidgets(
      'moves on only after the save succeeds and explains each failure',
      (tester) async {
        var saved = 0;
        var restarted = 0;
        final repo = ScriptedRepository()
          ..linkResults.addAll([
            const FinancialNetworkFailure('offline'),
            const FinancialStaleData(),
            const FinancialForbidden(),
            written(betaJson({'bank.kb'}, version: '2')),
          ]);
        final c = _flow(repo);
        _consentAll(c, {'bank.kb'});
        await c.startLoading();
        await _show(
          tester,
          InstitutionLoadingScreen(
            controller: c,
            onBack: () {},
            onSaved: () => saved++,
            onRestart: () => restarted++,
          ),
        );
        await tester.tap(find.text('계속하기'));
        await tester.pump();
        expect(saved, 0);
        expect(find.text('연결을 저장하지 못했어요'), findsOneWidget);
        await tester.tap(find.text('다시 시도'));
        await tester.pump();
        expect(find.text('저장 전에 정보가 바뀌었어요'), findsOneWidget);
        expect(find.text('다시 불러오기'), findsOneWidget);
        repo.loadResults.add(FinancialOk(betaJson(const {}, version: '1')));
        await tester.tap(find.text('다시 불러오기'));
        await tester.pump();
        await tester.tap(find.text('계속하기'));
        await tester.pump();
        expect(find.text('연결을 저장할 수 없어요'), findsOneWidget);
        await tester.tap(find.text('금융사 다시 고르기'));
        expect(restarted, 1);
        expect(saved, 0);
      },
    );
  });

  group('01-1', () {
    testWidgets(
      'nothing is selected first; the zero state only blocks saving',
      (tester) async {
        final c = _flow(
          ScriptedRepository(),
          snapshot: betaSnapshot({...betaBanks}),
        );
        await _show(tester, AccountSelectScreen(controller: c, onSaved: () {}));
        expect(
          find.text('쓸 수 있는 돈 계산에 넣을 계좌를 골라주세요.\n선택하지 않아도 금융사 연결은 유지돼요.'),
          findsOneWidget,
        );
        expect(find.text('계산에 사용할 계좌를 1개 이상 골라주세요.'), findsOneWidget);
        expect(_enabled(tester, '이 계좌로 계산하기'), isFalse);
        expect(
          find.byKey(const ValueKey('excluded-reserve-hint')),
          findsOneWidget,
          reason: '모아둘 돈이 있는 계좌가 미선택',
        );
        expect(
          find.text('모아둘 돈이 있는 계좌예요'),
          findsNothing,
          reason: '처음 미선택은 해제 경고 없음',
        );
        expect(find.text('1,500,000원'), findsOneWidget);

        final kb = c.accounts.first.accountId;
        await tester.tap(find.byKey(ValueKey('account-$kb')));
        await tester.pump();
        expect(_enabled(tester, '이 계좌로 계산하기'), isTrue);
        expect(find.textContaining('· 1개 선택'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('excluded-reserve-hint')),
          findsNothing,
        );
        await tester.tap(find.byKey(ValueKey('account-$kb')));
        await tester.pump();
        expect(
          find.text('모아둘 돈이 있는 계좌예요'),
          findsOneWidget,
          reason: '골랐다가 하나씩 풀면 안내',
        );
        expect(
          find.textContaining('국민은행 입출금 ····0001을 빼면 이 계좌의 모아둘 돈(현재 비상금)도'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'clearing a group with reserves asks once and cancel keeps it',
      (tester) async {
        final c = _flow(
          ScriptedRepository(),
          snapshot: betaSnapshot({...betaBanks}),
        );
        await _show(tester, AccountSelectScreen(controller: c, onSaved: () {}));
        Finder inGroup(String text) => find.descendant(
          of: find.byKey(const ValueKey('group-demand')),
          matching: find.text(text),
        );
        await tester.tap(inGroup('모두 선택'));
        await tester.pump();
        final demand = [
          for (final a in c.accounts)
            if (a.productType == 'demand') a.accountId,
        ];
        expect(demand.every(c.isAccountSelected), isTrue);
        expect(
          c.accounts
              .where((a) => a.productType != 'demand')
              .any((a) => c.isAccountSelected(a.accountId)),
          isFalse,
        );

        await tester.tap(inGroup('모두 해제'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('clear-reserve-dialog')),
          findsOneWidget,
        );
        expect(
          find.text('입출금 계좌 ${demand.length}개를 모두 선택 해제할까요?'),
          findsOneWidget,
          reason: '실제로 해제되는 계좌 수',
        );
        expect(
          find.text(
            '이 중 1개 계좌에는 모아둘 돈이 있어요.\n선택을 해제한 계좌의 잔액과 연결된 모아둘 돈은 계산에서 제외돼요. '
            '모아둘 돈 설정은 삭제되지 않아요.',
          ),
          findsOneWidget,
        );
        expect(find.text('취소'), findsOneWidget);
        expect(find.text('모두 선택 해제'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('clear-reserve-cancel')));
        await tester.pumpAndSettle();
        expect(demand.every(c.isAccountSelected), isTrue, reason: '취소하면 선택 유지');

        await tester.tap(inGroup('모두 해제'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('clear-reserve-confirm')));
        await tester.pumpAndSettle();
        expect(demand.any(c.isAccountSelected), isFalse);
        expect(find.text('모아둘 돈이 있는 계좌예요'), findsNothing, reason: '경고는 한 번만');
        expect(_enabled(tester, '이 계좌로 계산하기'), isFalse);
      },
    );

    testWidgets('after a failed save, retry needs at least one account', (
      tester,
    ) async {
      final repo = ScriptedRepository()
        ..selectResults.add(const FinancialNetworkFailure('offline'));
      final c = _flow(repo, snapshot: betaSnapshot({...betaBanks}));
      await _show(tester, AccountSelectScreen(controller: c, onSaved: () {}));
      c.setAccounts([
        for (final a in c.accounts)
          if (a.productType == 'demand') a.accountId,
      ], selected: true);
      await tester.pump();
      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pump();
      expect(find.text('계좌 선택을 저장하지 못했어요'), findsOneWidget);
      expect(_enabled(tester, '다시 시도'), isTrue);

      final kb = c.accounts.first.accountId;
      for (final a in c.accounts) {
        if (c.isAccountSelected(a.accountId)) c.toggleAccount(a.accountId);
      }
      await tester.pump();
      expect(_enabled(tester, '다시 시도'), isFalse, reason: '0개면 눌러도 반응 없는 버튼 없음');

      repo.selectResults.add(
        written(betaJson({...betaBanks}, selected: {kb}, version: '2')),
      );
      await tester.tap(find.byKey(ValueKey('account-$kb')));
      await tester.pump();
      expect(_enabled(tester, '다시 시도'), isTrue);
      await tester.tap(find.text('다시 시도'));
      await tester.pump();
      expect(repo.selectCalls, hasLength(2));
      expect(repo.selectCalls.last.$1, [kb]);
    });
  });

  group('01-2', () {
    /// 2026-10-23: [snapshot]으로 01-2를 띄운다.
    /// 2026-10-27: 같은 스냅샷의 홈 계산 결과로 버튼을 정한다.
    Future<void> showReview(
      WidgetTester tester,
      FinancialSnapshot snapshot, {
      double height = 1600,
      VoidCallback? onCalculate,
      VoidCallback? onDefer,
      VoidCallback? onReload,
      ReviewReload reload = ReviewReload.idle,
    }) => _show(
      tester,
      ConnectionReviewScreen(
        snapshot: snapshot,
        calculation: computeHomeCalculation(snapshot),
        onBack: () {},
        onCalculate: onCalculate ?? () {},
        onDefer: onDefer ?? () {},
        onReload: onReload ?? () {},
        reload: reload,
      ),
      height: height,
    );

    /// 2026-10-23: 글자 [text]의 글자 모양을 반환한다.
    TextStyle styleOf(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text).first).style!;

    /// 2026-10-27: 모든 은행·카드사를 연결하고 첫 계좌만 고른 기본 스냅샷.
    FinancialSnapshot full({void Function(Map<String, Object?>)? mutate}) =>
        betaSnapshot(
          {...betaBanks, ...betaCards},
          selected: {'1d383795-5b7c-56f9-9535-ff418040183d'},
          mutate: mutate,
        );

    testWidgets('shows saved values read-only without edit entries', (
      tester,
    ) async {
      await showReview(tester, full());
      expect(find.text('다음 월급일까지 쓸 수 있는 돈을\n알아볼까요?'), findsOneWidget);
      expect(find.text('계산에 필요한 금융 정보를 확인해 주세요.'), findsOneWidget);
      expect(find.textContaining('거래 분석'), findsNothing, reason: '분석 결과 수신 전');
      expect(find.text('매월 25일'), findsOneWidget);
      expect(find.text('3,000,000원'), findsOneWidget);
      expect(find.text('다음 결제 11월 10일'), findsNWidgets(3));
      expect(find.text('결제일 확인 불가'), findsOneWidget);
      expect(find.text('현재 비상금'), findsOneWidget);
      expect(find.text('400,000원'), findsOneWidget);
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .toList();
      expect(
        labels.indexOf('카드 청구') < labels.indexOf('월세'),
        isTrue,
        reason: '예정 지출은 날짜순',
      );
      expect(find.text('확인·수정'), findsNothing, reason: '수정 진입을 넘기지 않으면 없음');
      expect(find.textContaining('계획'), findsNothing, reason: '계획 탭 안내는 #29');
      expect(find.byKey(const ValueKey('review-scope-note')), findsNothing);
      expect(find.byKey(const ValueKey('review-load-band')), findsNothing);
    });

    testWidgets(
      'section heads use the 01-2 icon header, not the shared token',
      (tester) async {
        await showReview(tester, full());
        for (final title in ['월급', '카드 결제일', '모아둘 돈', '예정 지출']) {
          final style = styleOf(tester, title);
          expect(style.fontSize, 16);
          expect(style.fontWeight, FontWeight.w600);
          expect(style.color, PayseColors.textPrimary);
        }
        expect(
          PayseTypography.sectionTitle.fontSize,
          14,
          reason: '공통 섹션 제목은 그대로',
        );
        expect(
          find.descendant(
            of: find.byType(ConnectionReviewScreen),
            matching: find.byType(CustomPaint),
          ),
          findsAtLeastNWidgets(4),
        );
      },
    );

    testWidgets('amounts alone are emphasized; dates and states are not', (
      tester,
    ) async {
      await showReview(
        tester,
        betaSnapshot(
          {...betaBanks, ...betaCards},
          mutate: (source) {
            ((source['settings']! as Map)['salary']!
                    as Map)['salaryAmountKRW'] =
                null;
          },
        ),
      );
      final amount = styleOf(tester, '400,000원');
      expect(amount.fontSize, 16);
      expect(amount.fontWeight, FontWeight.w700);
      final date = styleOf(tester, '다음 결제 11월 10일');
      expect(date.fontSize, 15);
      expect(date.fontWeight, FontWeight.w500);
      final unset = styleOf(tester, '금액 미입력');
      expect(unset.fontSize, 15);
      expect(unset.fontWeight, isNot(FontWeight.w700));
      expect(unset.color, PayseColors.textSecondary);
      expect(
        PayseTypography.ledgerAmount.fontSize,
        15,
        reason: '홈·01-1이 쓰는 공통 금액 토큰은 그대로',
      );
    });

    testWidgets('a computed result enables the calculate button', (
      tester,
    ) async {
      var calculated = 0;
      final snapshot = FinancialSnapshot.fromJson(alphaWithReceipt());
      final calculation = computeHomeCalculation(snapshot);
      expect(
        calculation is HomeCalculationReady && calculation.result.u != null,
        isTrue,
        reason: '기본 시연 스냅샷은 계산된다',
      );
      await showReview(tester, snapshot, onCalculate: () => calculated++);
      expect(_enabled(tester, '쓸 수 있는 돈 계산하기'), isTrue);
      expect(find.byKey(const ValueKey('review-defer')), findsNothing);
      expect(find.byKey(const ValueKey('review-reason')), findsNothing);
      expect(find.text('입금 확인됨'), findsOneWidget);
      expect(find.byKey(const ValueKey('review-value-check')), findsOneWidget);
      await tester.tap(find.text('쓸 수 있는 돈 계산하기'));
      expect(calculated, 1);
    });

    testWidgets('a missing past receipt disables the button with a reason', (
      tester,
    ) async {
      var deferred = 0;
      final snapshot = full();
      expect(
        (computeHomeCalculation(
          snapshot,
        ) as HomeCalculationReady).result.insufficient,
        contains(calc.InsufficientReason.receiptEvidenceAbsent),
      );
      await showReview(tester, snapshot, onDefer: () => deferred++);
      expect(
        find.byKey(const ValueKey('review-receipt-needed')),
        findsOneWidget,
      );
      expect(find.text('입금 확인 필요'), findsOneWidget);
      expect(
        find.text('월급이 들어왔는지에 따라 이번 계산에 포함할 예정 지출이 달라져요.'),
        findsOneWidget,
      );
      expect(
        find.text('지금은 월급 입금 여부를 확인할 수 없어 계산을 진행할 수 없어요. 홈에서 확인된 정보를 볼 수 있어요.'),
        findsOneWidget,
      );
      expect(_enabled(tester, '쓸 수 있는 돈 계산하기'), isFalse);
      expect(find.byKey(const ValueKey('review-load-band')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('review-defer')));
      expect(deferred, 1);
    });

    testWidgets('missing plans show the reload band and are not empty', (
      tester,
    ) async {
      var reloads = 0;
      final json = alphaWithReceipt();
      rows(json, 'settlements').first['transactionId'] = 'missing-tx';
      json['page'] = {'nextCursor': 'cursor-2'};
      final snapshot = FinancialSnapshot.fromJson(json);
      await showReview(
        tester,
        snapshot,
        height: 2400,
        onReload: () => reloads++,
      );
      expect(find.byKey(const ValueKey('review-load-band')), findsOneWidget);
      expect(find.text('일부 정보를 불러오지 못했어요'), findsOneWidget);
      expect(find.text('일부 예정 지출 정보를 확인할 수 없어요.'), findsOneWidget);
      expect(
        find.text('등록된 예정 지출이 없어요.'),
        findsNothing,
        reason: '미수신은 빈 목록이 아님',
      );
      expect(find.text('계산에 필요한 정보를 불러오지 못했어요. 다시 불러와 주세요.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('review-reload')));
      expect(reloads, 1);

      await showReview(tester, snapshot, reload: ReviewReload.loading);
      expect(find.text('불러오는 중'), findsOneWidget);
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('review-reload')),
      );
      expect(button.onPressed, isNull, reason: '불러오는 중에는 다시 요청하지 않음');
    });

    testWidgets('empty groups use the approved sentences only when loaded', (
      tester,
    ) async {
      await showReview(
        tester,
        full(
          mutate: (source) => source
            ..['reserves'] = <Object?>[]
            ..['allocations'] = <Object?>[]
            ..['obligations'] = <Object?>[]
            ..['settlements'] = <Object?>[]
            ..['occurrenceLinks'] = <Object?>[],
        ),
      );
      expect(find.text('등록된 모아둘 돈이 없어요.'), findsOneWidget);
      expect(find.text('등록된 예정 지출이 없어요.'), findsOneWidget);
      expect(find.textContaining('찾지 못했어요'), findsNothing, reason: '분석 전');
      expect(find.textContaining('연결한 계좌'), findsNothing);
    });

    testWidgets('partial connection reads as scope, not an error', (
      tester,
    ) async {
      await showReview(tester, betaSnapshot({'bank.shinhan', 'card.hyundai'}));
      expect(find.text('연결하지 않은 금융사의 정보는 포함되지 않았어요.'), findsOneWidget);
      expect(find.byType(StatusNotice), findsNothing, reason: '경고 띠 없음');
      expect(find.text('월급 계좌 정보를 볼 수 없어요'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('review-unlinked-band')),
        findsOneWidget,
      );
      expect(find.text('월급 계좌의 은행이 연결되지 않았어요'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('review-load-band')),
        findsNothing,
        reason: '연결 제한은 재조회 띠 아님',
      );
      expect(find.text('출금 계좌'), findsOneWidget);
      expect(find.text('연결 안 함'), findsOneWidget);
      expect(find.text('매월 25일'), findsOneWidget, reason: '월급일은 그대로');
      expect(find.text('3,000,000원'), findsOneWidget, reason: '금액도 그대로');
      expect(find.text('연결한 계좌에서 확인되는 모아둘 돈이 없어요.'), findsOneWidget);
      expect(find.text('연결한 계좌에서 확인되는 예정 지출이 없어요.'), findsOneWidget);
      expect(find.text('등록된 모아둘 돈이 없어요.'), findsNothing, reason: '숨김은 없음과 다름');
      expect(_enabled(tester, '쓸 수 있는 돈 계산하기'), isFalse);
      expect(
        find.byKey(const ValueKey('review-reason')),
        findsNothing,
        reason: '띠가 이유를 말함',
      );
      expect(find.byKey(const ValueKey('review-defer')), findsOneWidget);
    });

    testWidgets('hidden and partly hidden groups read differently', (
      tester,
    ) async {
      await showReview(
        tester,
        betaSnapshot(
          {'bank.shinhan'},
          mutate: (source) {
            final shinhan = rows(source, 'accounts').firstWhere(
              (a) => a['institutionCode'] == 'bank.shinhan',
            )['accountId'];
            rows(source, 'obligations').first['withdrawalAccountId'] = shinhan;
          },
        ),
      );
      expect(find.text('연결한 계좌 기준으로 보여드려요.'), findsOneWidget);
      expect(find.text('연결한 계좌에서 확인되는 예정 지출이 없어요.'), findsNothing);
    });

    testWidgets('unset and planned values read differently', (tester) async {
      await showReview(
        tester,
        betaSnapshot(
          {...betaBanks, ...betaCards},
          mutate: (source) {
            final settings = source['settings']! as Map;
            (settings['salary']! as Map)
              ..['salaryDay'] = null
              ..['salaryAmountKRW'] = null
              ..['salaryAccountId'] = null;
            (settings['cardPlans']! as List).add({
              'userId': source['userId'],
              'cardId': rows(source, 'cards').first['cardId'],
              'plannedPaymentDay': 15,
            });
          },
        ),
      );
      expect(find.text('월급일 미입력'), findsOneWidget);
      expect(find.text('금액 미입력'), findsOneWidget);
      expect(find.text('월급 계좌 미선택'), findsOneWidget);
      expect(find.text('매월 15일'), findsOneWidget);
      expect(find.text('연결 안 함'), findsNothing, reason: '미입력은 미연결이 아님');
    });

    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'long amounts and dates are not cut on a small phone at text x$scale',
        (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          tester.view.physicalSize = const Size(960, 1704);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          final snapshot = betaSnapshot(
            {'bank.shinhan', 'card.hyundai'},
            mutate: (source) {
              ((source['settings']! as Map)['salary']!
                      as Map)['salaryAmountKRW'] =
                  8999999999999;
              for (final card in rows(source, 'cards')) {
                for (final e in card['scheduleEvidence']! as List) {
                  (e as Map)['dueDate'] = '2027-01-10';
                }
              }
            },
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: buildPayseTheme(),
              home: ConnectionReviewScreen(
                snapshot: snapshot,
                calculation: computeHomeCalculation(snapshot),
                onBack: () {},
                onCalculate: () {},
                onDefer: () {},
                onReload: () {},
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: '넘침 없음');
          for (final text in ['8,999,999,999,999원', '다음 결제 2027년 1월 10일']) {
            final finder = find.text(text);
            await tester.scrollUntilVisible(
              finder,
              80,
              scrollable: find.byType(Scrollable).first,
            );
            expect(finder, findsOneWidget);
            expect(
              tester.renderObject<RenderParagraph>(finder).didExceedMaxLines,
              isFalse,
              reason: '$text 잘림 없음',
            );
            expect(tester.getRect(finder).right, lessThanOrEqualTo(320));
          }
        },
      );
    }
  });

  group('flow', () {
    testWidgets(
      'entry loading finds banks, then cards, shows the count, and waits for next',
      (tester) async {
        final waits = <Completer<void>>[];
        final policy = ConnectionPresentationPolicy(
          failuresEnabled: () => true,
          random: SequenceRandom(),
          wait: (_) {
            final c = Completer<void>();
            waits.add(c);
            return c.future;
          },
        );
        await _show(
          tester,
          ConnectionFlow(
            repository: ScriptedRepository(),
            snapshot: betaSnapshot(const {}),
            policy: policy,
            onFinished: (_, {required deferred}) {},
            onSessionInvalid: () {},
            userName: '데모베타',
          ),
        );
        await tester.pump();
        Finder step(String key, String text) => find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.text(text),
        );
        expect(find.text('데모베타님이 연결할 수 있는\n금융사를 찾고 있어요'), findsOneWidget);
        expect(step('entry-step-banks', '찾는 중'), findsOneWidget);
        expect(step('entry-step-cards', '기다리는 중'), findsOneWidget);

        waits[0].complete();
        await tester.pump();
        expect(step('entry-step-banks', '5곳 찾았어요'), findsOneWidget);
        expect(step('entry-step-cards', '찾는 중'), findsOneWidget);

        expect(
          tester
              .widget<IgnorePointer>(
                find
                    .ancestor(
                      of: find.byKey(const ValueKey('entry-next')),
                      matching: find.byType(IgnorePointer),
                    )
                    .first,
              )
              .ignoring,
          isTrue,
          reason: '찾는 동안 다음 버튼은 누를 수 없음',
        );

        waits[1].complete();
        await tester.pumpAndSettle();
        expect(find.text('연결할 수 있는 금융사\n9곳을 찾았어요'), findsOneWidget);
        expect(find.text('이제 불러올 금융사를 골라주세요.'), findsOneWidget);
        expect(step('entry-step-cards', '4곳 찾았어요'), findsOneWidget);
        expect(waits, hasLength(2), reason: '다 찾은 뒤 자동 이동 대기 없음');
        expect(find.text(_selectHeading), findsNothing);

        await tester.tap(find.byKey(const ValueKey('entry-next')));
        await tester.pumpAndSettle();
        expect(find.text(_selectHeading), findsOneWidget);
      },
    );

    testWidgets('runs 12-1 to 01-2 and finishes only after both saves', (
      tester,
    ) async {
      var finished = 0;
      final repo = ScriptedRepository()
        ..linkResults.addAll([
          written(betaJson({'bank.kb'}, version: '2')),
          written(betaJson({'bank.kb'}, version: '3')),
        ])
        ..selectResults.add(
          written(
            betaJson(
              {'bank.kb'},
              selected: {'1d383795-5b7c-56f9-9535-ff418040183d'},
              version: '4',
            ),
          ),
        );
      await _show(
        tester,
        ConnectionFlow(
          repository: repo,
          snapshot: betaSnapshot(const {}),
          policy: instantPolicy(),
          onFinished: (_, {required deferred}) => finished++,
          onSessionInvalid: () {},
          random: Random(1),
        ),
      );
      expect(find.text('연결할 수 있는\n금융사를 찾고 있어요'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('entry-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('institution-bank.kb')));
      await tester.pump();
      await tester.tap(find.text('다음'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('consent-all')));
      await tester.pump();
      await tester.tap(find.text('동의하고 불러오기'));
      await tester.pumpAndSettle();
      expect(repo.linkCalls, isEmpty, reason: '연출만으로 저장하지 않음');
      await tester.tap(find.text('계속하기'));
      await tester.pumpAndSettle();
      expect(repo.linkCalls.single.$1, ['bank.kb']);
      expect(find.text('쓸 수 있는 돈을 계산할\n계좌를 골라주세요'), findsOneWidget);
      const kbAccount = ValueKey(
        'account-1d383795-5b7c-56f9-9535-ff418040183d',
      );
      bool picked() =>
          tester.widget<SelectionListRow>(find.byKey(kbAccount)).selected;
      expect(picked(), isFalse, reason: '처음에는 미선택');
      await tester.tap(find.byKey(kbAccount));
      await tester.pump();
      expect(picked(), isTrue);

      await tester.tap(find.byTooltip('뒤로'));
      await tester.pumpAndSettle();
      expect(
        find.text('금융사 정보를\n다 불러왔어요'),
        findsOneWidget,
        reason: '01-1 뒤로 → 12-3 결과',
      );
      await tester.tap(find.text('계속하기'));
      await tester.pumpAndSettle();
      expect(repo.linkCalls, hasLength(2), reason: '계속할 때마다 최종 목록 재전송');
      expect(
        repo.linkCalls[1].$2.idempotencyKey,
        isNot(repo.linkCalls[0].$2.idempotencyKey),
      );
      expect(repo.linkCalls[1].$2.expectedDataVersion, '2');
      expect(picked(), isTrue, reason: '같은 흐름에서 돌아와 다시 진행해도 선택 유지');
      expect(finished, 0);
    });

    testWidgets('a saved connection without chosen accounts resumes at 01-1', (
      tester,
    ) async {
      var finished = 0;
      final repo = ScriptedRepository()
        ..selectResults.add(
          written(
            betaJson(
              {'bank.kb'},
              selected: {'1d383795-5b7c-56f9-9535-ff418040183d'},
              version: '3',
            ),
          ),
        );
      await _show(
        tester,
        ConnectionFlow(
          repository: repo,
          snapshot: betaSnapshot({'bank.kb'}, version: '2'),
          policy: instantPolicy(),
          onFinished: (_, {required deferred}) => finished++,
          onSessionInvalid: () {},
          random: Random(1),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('쓸 수 있는 돈을 계산할\n계좌를 골라주세요'), findsOneWidget);
      expect(find.byTooltip('뒤로'), findsNothing);
      await tester.tap(
        find.byKey(
          const ValueKey('account-1d383795-5b7c-56f9-9535-ff418040183d'),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pumpAndSettle();
      expect(find.text('다음 월급일까지 쓸 수 있는 돈을\n알아볼까요?'), findsOneWidget);
      expect(
        _enabled(tester, '쓸 수 있는 돈 계산하기'),
        isFalse,
        reason: '지난 회차 입금 근거 없음',
      );
      await tester.tap(find.byKey(const ValueKey('review-defer')));
      expect(finished, 1);
    });
  });
}

/// 2026-10-23: 정해 둔 연결·조회 응답을 테스트가 끝낼 때까지 기다리게 하는 저장소.
class _HoldingRepository extends ScriptedRepository {
  Completer<FinancialOutcome<WriteSuccess>>? link;
  Completer<FinancialOutcome<Map<String, Object?>>>? load;

  /// 2026-10-23: 기록한 뒤 [link]가 있으면 그 응답을 기다린다.
  @override
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> institutionCodes,
    WriteContext write,
  ) {
    linkCalls.add((institutionCodes, write));
    return link?.future ?? super.linkInstitutions(institutionCodes, write);
  }

  /// 2026-10-23: [load]가 있으면 그 응답을 기다린다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() =>
      load?.future ?? super.loadSnapshot();
}
