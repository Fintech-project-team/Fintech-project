import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/connection/connection_flow.dart';
import 'package:payse/features/connection/connection_flow_controller.dart';
import 'package:payse/features/connection/connection_presentation_policy.dart';
import 'package:payse/features/connection/connection_screens.dart';
import 'package:payse/shared/design/institution_mark.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/primary_button.dart';

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

const _cardWarning = '쓸 수 있는 돈을 계산하려면 은행을 1곳 이상 골라주세요.';
const _consentWarning = '은행 1곳 이상 동의해야 계좌를 불러올 수 있어요.';

void main() {
  group('12-1 and 12-2', () {
    testWidgets('the bank warning appears only after choosing cards alone', (
      tester,
    ) async {
      final c = _flow(ScriptedRepository());
      await _show(
        tester,
        InstitutionSelectScreen(controller: c, onNext: () {}),
      );
      expect(find.byType(InstitutionMark), findsNWidgets(9));
      expect(find.text(_cardWarning), findsNothing, reason: '처음부터 띄우지 않음');
      expect(_enabled(tester, '다음'), isFalse);

      await tester.tap(find.byKey(const ValueKey('institution-card.hyundai')));
      await tester.pump();
      expect(find.text(_cardWarning), findsOneWidget);
      expect(_enabled(tester, '다음'), isFalse);

      await tester.tap(find.byKey(const ValueKey('institution-bank.kb')));
      await tester.pump();
      expect(find.text(_cardWarning), findsNothing);
      expect(_enabled(tester, '다음'), isTrue);
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
    testWidgets(
      'while loading there is no back, no exclude button and no save',
      (tester) async {
        final c = _flow(
          ScriptedRepository(),
          policy: ConnectionPresentationPolicy(
            failuresEnabled: true,
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
      expect(find.text('신한 제외하고 계속하기'), findsOneWidget);
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
        await tester.tap(find.text('신한 제외하고 계속하기'));
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
      expect(find.text('국민 제외하고 계속하기'), findsOneWidget);
      expect(_enabled(tester, '국민 제외하고 계속하기'), isFalse);
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
    testWidgets('defaults, balances, the reserve notice and the zero rule', (
      tester,
    ) async {
      final c = _flow(
        ScriptedRepository(),
        snapshot: betaSnapshot({...betaBanks}),
      );
      await _show(tester, AccountSelectScreen(controller: c, onSaved: () {}));
      expect(find.text('1,500,000원'), findsOneWidget);
      expect(find.text('모아둘 돈이 있는 계좌예요'), findsNothing);
      final kb = c.accounts.first.accountId;
      await tester.tap(find.byKey(ValueKey('account-$kb')));
      await tester.pump();
      expect(find.text('모아둘 돈이 있는 계좌예요'), findsOneWidget);
      expect(
        find.textContaining('국민 입출금 ····0001을 빼면 이 계좌의 모아둘 돈(현재 비상금)도'),
        findsOneWidget,
      );
      for (final a in c.accounts) {
        if (c.isAccountSelected(a.accountId)) c.toggleAccount(a.accountId);
      }
      await tester.pump();
      expect(_enabled(tester, '이 계좌로 계산하기'), isFalse);
    });

    testWidgets('after a failed save, retry needs at least one account', (
      tester,
    ) async {
      final repo = ScriptedRepository()
        ..selectResults.add(const FinancialNetworkFailure('offline'));
      final c = _flow(repo, snapshot: betaSnapshot({...betaBanks}));
      await _show(tester, AccountSelectScreen(controller: c, onSaved: () {}));
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
    testWidgets('shows saved values without calculating', (tester) async {
      final snapshot = betaSnapshot(
        {...betaBanks, ...betaCards},
        selected: {'1d383795-5b7c-56f9-9535-ff418040183d'},
      );
      await _show(
        tester,
        ConnectionReviewScreen(
          snapshot: snapshot,
          onBack: () {},
          onConfirmed: () {},
        ),
        height: 1600,
      );
      expect(find.text('매월 25일'), findsOneWidget);
      expect(find.text('3,000,000원'), findsOneWidget);
      expect(find.text('다음 결제 11월 10일'), findsNWidgets(3));
      expect(find.text('예정된 결제일 정보 없음'), findsOneWidget);
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
      expect(find.textContaining('보이지 않아요'), findsNothing);
    });

    testWidgets('hidden, unset and planned values read differently', (
      tester,
    ) async {
      final partial = betaSnapshot({'bank.shinhan', 'card.hyundai'});
      await _show(
        tester,
        ConnectionReviewScreen(
          snapshot: partial,
          onBack: () {},
          onConfirmed: () {},
        ),
        height: 1600,
      );
      expect(find.text('연결하지 않은 계좌'), findsOneWidget);
      expect(find.text('출금 계좌 정보 없음 · 연결하지 않은 은행'), findsOneWidget);
      expect(find.text('연결하지 않은 계좌의 모아둘 돈은 보이지 않아요.'), findsOneWidget);
      expect(find.text('연결하지 않은 계좌의 예정 지출은 보이지 않아요.'), findsOneWidget);
      expect(find.text('모아둘 돈이 없어요'), findsNothing);

      final unset = betaSnapshot(
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
      );
      await _show(
        tester,
        ConnectionReviewScreen(
          snapshot: unset,
          onBack: () {},
          onConfirmed: () {},
        ),
        height: 1600,
      );
      expect(find.text('월급일 미입력'), findsOneWidget);
      expect(find.text('금액 미입력'), findsOneWidget);
      expect(find.text('급여 계좌 미선택'), findsOneWidget);
      expect(find.text('매월 15일'), findsOneWidget);
    });
  });

  group('flow', () {
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
          onFinished: () => finished++,
          onSessionInvalid: () {},
          random: Random(1),
        ),
      );
      expect(find.text('정보를 받아올 금융사를 찾고 있어요'), findsOneWidget);
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
          onFinished: () => finished++,
          onSessionInvalid: () {},
          random: Random(1),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('쓸 수 있는 돈을 계산할\n계좌를 골라주세요'), findsOneWidget);
      expect(find.byTooltip('뒤로'), findsNothing);
      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pumpAndSettle();
      expect(find.text('불러온 정보를\n확인해주세요'), findsOneWidget);
      await tester.tap(find.text('확인했어요'));
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
