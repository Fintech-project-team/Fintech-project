import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/connection/connection_screens.dart';
import 'package:payse/features/connection/salary_settings_screen.dart';
import 'package:payse/features/overview/accounts_screen.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/payse_tokens.dart';

import '../../data/connection/connection_test_utils.dart';
import '../connection/connection_test_support.dart';

const _kbDemand = '6069b37a-abf5-56fc-8bf0-153f5301fd1c';
const _shinhanSavings = '67521b1b-de86-54cf-98ba-91bb04d0a256';
const _hanaDemand = '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc';
const _ibkDemand = '4021635f-1b2c-534d-b5b6-9680b3c8d5f2';
const _kakaoDemand = '1ce9128d-d667-5bfc-bed0-949a571c78f5';
const _kbDeposit = '2c56e23d-2e82-59ed-8fce-21459e226167';
const _allAlpha = [
  'bank.kb',
  'bank.shinhan',
  'bank.hana',
  'bank.ibk',
  'bank.kakao',
  'card.hyundai',
  'card.samsung',
  'card.woori',
  'card.kb',
];

/// 2026-10-29: 데모알파(demo-ready)를 모두 연결하고 입출금 4개를 계산에 포함한 가짜 서버 세션을 만든다.
Future<(FakeUserFinancialRepository, FinancialSnapshot)> _connected() async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (userId) async => readSource('demo-ready'),
  );
  final a = devDemoAccounts.first;
  final session = await auth.createSession(
    DemoCredentials(name: a.name, phone: a.phone, code: a.code),
  );
  final token = (session as AuthOk<DemoSession>).value.accessToken;
  final repo = FakeUserFinancialRepository(server: server, accessToken: token);
  WriteContext w(String v, String k) => WriteContext(
    expectedDataVersion: v,
    ruleVersion: 'PAYSE-CALC-1',
    idempotencyKey: k,
  );
  await repo.linkInstitutions(_allAlpha, w('1', 'l'));
  final saved = await repo.selectAccounts([
    _kbDemand,
    _hanaDemand,
    _ibkDemand,
    _kakaoDemand,
  ], w('2', 's'));
  final json = (saved as FinancialOk<WriteSuccess>).value.snapshot;
  return (repo, FinancialSnapshot.fromJson(json));
}

/// 2026-10-29: 계좌 탭을 앱 셸처럼 감싸 저장 뒤 Snapshot을 바꿔 다시 그리는 시험용 화면.
class _Host extends StatefulWidget {
  /// 2026-10-29: 저장소 [repository]와 시작 Snapshot [snapshot]으로 만든다.
  const _Host({required this.repository, required this.snapshot});

  final UserFinancialRepository repository;
  final FinancialSnapshot snapshot;

  /// 2026-10-29: 상태 객체를 반환한다.
  @override
  State<_Host> createState() => _HostState();
}

/// 2026-10-29: 현재 Snapshot과 그 홈 계산을 가진다.
class _HostState extends State<_Host> {
  late FinancialSnapshot _snapshot = widget.snapshot;
  int sessionInvalid = 0;

  /// 2026-10-29: 계좌 탭을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AccountsScreen(
        snapshot: _snapshot,
        calculation: computeHomeCalculation(_snapshot),
        writer: (
          repository: widget.repository,
          policy: instantPolicy(),
          onSessionInvalid: () => sessionInvalid++,
          onSnapshot: (s) => setState(() => _snapshot = s),
        ),
      ),
    );
  }
}

/// 2026-10-29: [repository]·[snapshot]으로 계좌 탭을 띄운다.
Future<void> _pump(
  WidgetTester tester,
  UserFinancialRepository repository,
  FinancialSnapshot snapshot, {
  double textScale = 1,
}) async {
  if (textScale == 1) {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: _Host(repository: repository, snapshot: snapshot),
    ),
  );
  await tester.pumpAndSettle();
}

/// 2026-10-29: 계좌 [id] 줄 안에서 [matcher]에 맞는 글자를 찾는다.
Finder _inRow(String id, String text) => find.descendant(
  of: find.byKey(ValueKey('account-row-$id')),
  matching: find.text(text),
);

/// 2026-10-29: 화면에 그려진 계좌 줄 ID를 위에서부터 반환한다.
List<String> _rowOrder(WidgetTester tester) {
  final keys = [
    for (final e
        in find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('account-row-'),
            )
            .evaluate())
      e.widget.key! as ValueKey<String>,
  ];
  keys.sort(
    (a, b) => tester
        .getRect(find.byKey(a))
        .top
        .compareTo(tester.getRect(find.byKey(b)).top),
  );
  return [for (final k in keys) k.value.substring('account-row-'.length)];
}

/// 2026-10-29: 금융사 머리 [names]를 위에서부터 정렬해 반환한다.
List<String> _bankOrder(WidgetTester tester, List<String> names) =>
    [...names]..sort(
      (a, b) => tester
          .getRect(find.text(a))
          .top
          .compareTo(tester.getRect(find.text(b)).top),
    );

const _banks = ['국민은행', '신한은행', '하나은행', '기업은행', '카카오뱅크'];

/// 2026-10-29: 계좌 [id] 보조 줄을 반환한다. 두 줄로 나뉘었으면 ' · '로 잇는다.
String _detail(WidgetTester tester, String id) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(ValueKey('account-detail-$id')),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data)
    .join(' · ');

/// 2026-10-29: 계좌 [id]의 이름 바꾸기 시트를 연다.
Future<void> _openRename(WidgetTester tester, String id) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey('account-rename-$id')),
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.byKey(ValueKey('account-rename-$id')));
  await tester.pumpAndSettle();
}

/// 2026-10-29: 시트의 저장 버튼이 눌리는지 반환한다.
bool _saveEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.byKey(const ValueKey('rename-save')))
        .onPressed !=
    null;

void main() {
  group('02-3 계좌 관리', () {
    testWidgets('summary, change button, groups and excluded accounts', (
      tester,
    ) async {
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);

      expect(find.text('계산에 포함한 계좌 잔액'), findsOneWidget);
      expect(find.text('계산에 포함한 계좌 4개 · 10월 19일 12:00 기준'), findsOneWidget);
      expect(find.byKey(const ValueKey('accounts-total')), findsOneWidget);
      final button = tester.getRect(
        find.byKey(const ValueKey('accounts-change-selection')),
      );
      expect(
        button.top,
        lessThan(tester.getRect(find.text('국민은행')).top),
        reason: '계산에 포함할 계좌 바꾸기는 잔액 요약 바로 아래, 목록 위',
      );
      expect(
        _detail(tester, _kbDemand),
        '····0001 · 모아둘 돈 400,000원 · 카드 3장 결제',
      );
      expect(
        find.byKey(const ValueKey('account-salary-$_kbDemand')),
        findsOneWidget,
        reason: '월급 계좌는 이름 옆 라벨',
      );
      expect(
        find.byKey(const ValueKey('account-salary-$_hanaDemand')),
        findsNothing,
      );
      expect(_detail(tester, _hanaDemand), '····0003 · 카드 1장 결제');
      expect(
        tester.getSize(find.byKey(ValueKey('account-salary-$_kbDemand'))).width,
        lessThan(100),
        reason: '라벨은 글자 폭만큼만 차지',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('account-excluded-$_kbDeposit')),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const ValueKey('account-excluded-$_kbDeposit')),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('account-excluded-$_kbDeposit')))
            .width,
        lessThan(120),
        reason: '계산에서 제외 라벨은 글자 폭만큼만 차지',
      );
      expect(
        find.byKey(const ValueKey('account-excluded-$_shinhanSavings')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('account-excluded-$_kbDemand')),
        findsNothing,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('account-rename-$_kbDemand'))),
        const Size(48, 48),
      );
    });

    testWidgets('banks with an included account come first; '
        'included accounts lead inside a bank', (tester) async {
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);
      expect(_bankOrder(tester, _banks), [
        '국민은행',
        '하나은행',
        '기업은행',
        '카카오뱅크',
        '신한은행',
      ], reason: '모두 제외한 신한은행은 뒤로, 나머지는 데이터 순서');
      expect(_rowOrder(tester), [
        _kbDemand,
        _kbDeposit,
        _hanaDemand,
        _ibkDemand,
        _kakaoDemand,
        _shinhanSavings,
      ]);
    });

    testWidgets('inside a mixed bank the included account moves up', (
      tester,
    ) async {
      final (repo, snapshot) = await _connected();
      final saved = await repo.selectAccounts(
        [_kbDeposit, _hanaDemand, _ibkDemand, _kakaoDemand],
        WriteContext(
          expectedDataVersion: snapshot.dataVersion,
          ruleVersion: snapshot.ruleVersion,
          idempotencyKey: 'swap',
        ),
      );
      await _pump(
        tester,
        repo,
        FinancialSnapshot.fromJson(
          (saved as FinancialOk<WriteSuccess>).value.snapshot,
        ),
      );
      expect(_rowOrder(tester).take(2), [
        _kbDeposit,
        _kbDemand,
      ], reason: '데이터 순서는 입출금→정기예금이지만 포함한 정기예금이 먼저');
      expect(_bankOrder(tester, _banks).first, '국민은행');
    });

    testWidgets('bank groups: 계산에서 제외 next to the name, '
        'a strong line only between banks, number line first', (tester) async {
      final pretendard = FontLoader('Pretendard');
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        pretendard.addFont(rootBundle.load('assets/fonts/Pretendard-$w.otf'));
      }
      await pretendard.load();
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);
      final name = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('account-row-$_kbDeposit')),
          matching: find.text('정기예금'),
        ),
      );
      final tag = tester.getRect(
        find.byKey(const ValueKey('account-excluded-$_kbDeposit')),
      );
      expect(tag.left, greaterThan(name.right), reason: '이름 옆 라벨');
      expect(tag.center.dy, closeTo(name.center.dy, 4));

      Color line(String id) {
        final box = tester.widget<Container>(
          find
              .descendant(
                of: find.byKey(ValueKey('account-row-$id')),
                matching: find.byType(Container),
              )
              .first,
        );
        final border = (box.decoration! as BoxDecoration).border! as Border;
        return border.bottom.color;
      }

      expect(line(_kbDemand), PayseColors.dividerRow, reason: '같은 은행 계좌 사이');
      expect(line(_kbDeposit), PayseColors.dividerSection, reason: '은행 끝');
      expect(
        line(_shinhanSavings),
        PayseColors.dividerRow,
        reason: '마지막 은행 아래는 연한 선',
      );

      final kb = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('account-detail-$_kbDemand')),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data)
          .toList();
      expect(kb, [
        '····0001',
        '모아둘 돈 400,000원',
        '카드 3장 결제',
      ], reason: '한 줄에 안 들어가면 계좌 번호 / 모아둘 돈 / 카드 결제 의미 단위로 줄바꿈');
    });

    testWidgets('월급 정보 opens the salary editor; saving returns with a notice', (
      tester,
    ) async {
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);
      final row = find.byKey(const ValueKey('accounts-salary'));
      expect(
        find.descendant(of: row, matching: find.text('월급 정보')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text('매월 25일 · 3,000,000원 · 국민은행 ····0001'),
        ),
        findsOneWidget,
      );

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(SalarySettingsScreen), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('salary-amount')),
          matching: find.byType(TextField),
        ),
        '3100000',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('salary-save')));
      await tester.pumpAndSettle();

      expect(find.byType(SalarySettingsScreen), findsNothing);
      expect(find.text('월급 정보를 저장했어요'), findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.text('매월 25일 · 3,100,000원 · 국민은행 ····0001'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a row itself opens nothing in 29-1', (tester) async {
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);
      await tester.tap(_inRow(_hanaDemand, '생활비 통장'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountSelectScreen), findsNothing);
      expect(find.byKey(const ValueKey('rename-field')), findsNothing);
    });

    testWidgets('320dp with 1.3x text has no overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot, textScale: 1.3);
      expect(tester.takeException(), isNull);
      await _openRename(tester, _kbDemand);
      expect(tester.takeException(), isNull);
    });
  });

  group('02-6 계좌 이름 바꾸기', () {
    testWidgets('saves a name, shows it first and announces it', (
      tester,
    ) async {
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);
      await _openRename(tester, _hanaDemand);

      expect(find.text('하나은행 생활비 통장 ····0003'), findsOneWidget);
      expect(find.text('0/12'), findsOneWidget);
      expect(
        _saveEnabled(tester),
        isFalse,
        reason: '이름이 없던 계좌를 비운 채 두면 저장할 것이 없음',
      );

      await tester.enterText(find.byType(EditableText), '생활비');
      await tester.pump();
      await tester.pump();
      expect(find.text('3/12'), findsOneWidget);
      expect(_saveEnabled(tester), isTrue);

      final before = _rowOrder(tester);
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rename-field')), findsNothing);
      expect(find.text('계좌 이름을 바꿨어요.'), findsOneWidget);
      expect(_rowOrder(tester), before, reason: '이름만 바꾸면 순서 그대로');
      expect(_inRow(_hanaDemand, '생활비'), findsOneWidget);
      expect(_detail(tester, _hanaDemand), '생활비 통장 ····0003 · 카드 1장 결제');
    });

    testWidgets('clearing a saved name reverts to the original', (
      tester,
    ) async {
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);
      await _openRename(tester, _hanaDemand);
      await tester.enterText(find.byType(EditableText), '생활비');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await _openRename(tester, _hanaDemand);
      expect(find.text('3/12'), findsOneWidget, reason: '저장된 이름으로 시작');
      expect(_saveEnabled(tester), isFalse, reason: '바꾸지 않았으면 비활성');
      await tester.enterText(find.byType(EditableText), '   ');
      await tester.pump();
      expect(_saveEnabled(tester), isTrue, reason: '공백만이면 원래 이름으로 되돌림');
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await tester.pumpAndSettle();
      expect(find.text('원래 이름으로 되돌렸어요.'), findsOneWidget);
      expect(_inRow(_hanaDemand, '생활비 통장'), findsOneWidget);
      expect(_detail(tester, _hanaDemand), '····0003 · 카드 1장 결제');
    });

    testWidgets('input rules: specials only, blocked letters, 12 graphemes', (
      tester,
    ) async {
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);
      await _openRename(tester, _ibkDemand);
      final field = find.byType(EditableText);

      await tester.enterText(field, '!!!');
      await tester.pump();
      expect(find.text('한글, 영문, 숫자, 이모지를 1자 이상 넣어주세요.'), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);

      await tester.enterText(field, '生活비');
      await tester.pump();
      expect(tester.widget<EditableText>(field).controller.text, '비');
      expect(find.byKey(const ValueKey('rename-blocked')), findsOneWidget);

      await tester.enterText(field, '여행 통장');
      await tester.pump();
      expect(find.byKey(const ValueKey('rename-blocked')), findsNothing);
      expect(find.byKey(const ValueKey('rename-guide')), findsOneWidget);

      await tester.enterText(field, '가나다라마바사아자차카타파');
      await tester.pump();
      expect(
        tester.widget<EditableText>(field).controller.text,
        '가나다라마바사아자차카타',
      );
      expect(find.text('12/12'), findsOneWidget);

      await tester.enterText(field, '👨‍👩‍👧‍👦💰');
      await tester.pump();
      expect(find.text('2/12'), findsOneWidget);
      expect(_saveEnabled(tester), isTrue, reason: '이모지만인 이름은 허용');
    });

    testWidgets(
      'failures keep the input; retry reuses the key; rejected is final',
      (tester) async {
        final (_, snapshot) = await _connected();
        final repo = ScriptedRepository()
          ..nicknameResults.addAll([
            const FinancialUnavailable(),
            const FinancialNetworkFailure('offline'),
            const FinancialInvalid(),
          ]);
        await _pump(tester, repo, snapshot);
        await _openRename(tester, _hanaDemand);
        await tester.enterText(find.byType(EditableText), '생활비');
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('rename-save')));
        await tester.pumpAndSettle();
        expect(find.text('계좌 이름을 저장하지 못했어요'), findsOneWidget);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          '생활비',
        );
        await tester.tap(find.byKey(const ValueKey('rename-save')));
        await tester.pumpAndSettle();
        expect(
          repo.nicknameCalls[1].$3.idempotencyKey,
          repo.nicknameCalls[0].$3.idempotencyKey,
          reason: '응답을 받지 못한 같은 내용의 재시도는 같은 키',
        );
        expect(repo.nicknameCalls[0].$2, '생활비');

        await tester.tap(find.byKey(const ValueKey('rename-save')));
        await tester.pumpAndSettle();
        expect(find.text('계좌 이름을 저장할 수 없어요'), findsOneWidget);
      },
    );

    testWidgets('stale data asks to reload the latest information', (
      tester,
    ) async {
      final (_, snapshot) = await _connected();
      final repo = ScriptedRepository()
        ..nicknameResults.add(const FinancialStaleData())
        ..loadResults.add(const FinancialUnavailable());
      await _pump(tester, repo, snapshot);
      await _openRename(tester, _hanaDemand);
      await tester.enterText(find.byType(EditableText), '생활비');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await tester.pumpAndSettle();
      expect(find.text('저장 전에 정보가 바뀌었어요'), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
      await tester.tap(find.byKey(const ValueKey('rename-reload')));
      await tester.pumpAndSettle();
      expect(find.text('최신 정보를 불러오지 못했어요'), findsOneWidget);
    });
  });

  group('계산에 포함할 계좌 바꾸기', () {
    testWidgets(
      'starts from the current selection; unchanged returns without saving',
      (tester) async {
        final (repo, snapshot) = await _connected();
        await _pump(tester, repo, snapshot);
        await tester.tap(
          find.byKey(const ValueKey('accounts-change-selection')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AccountSelectScreen), findsOneWidget);
        expect(
          find.textContaining('4개 선택', findRichText: true),
          findsOneWidget,
        );

        await tester.tap(find.text('이 계좌로 계산하기'));
        await tester.pumpAndSettle();
        expect(find.byType(AccountSelectScreen), findsNothing);
        final now = await repo.loadSnapshot();
        expect(
          (now as FinancialOk<Map<String, Object?>>).value['dataVersion'],
          snapshot.dataVersion,
          reason: '바꾸지 않았으면 저장하지 않음',
        );
      },
    );

    testWidgets('leaving after a change asks; saving updates the tab', (
      tester,
    ) async {
      await (FontLoader('Pretendard')
            ..addFont(rootBundle.load('assets/fonts/Pretendard-SemiBold.otf')))
          .load();
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);
      await tester.tap(find.byKey(const ValueKey('accounts-change-selection')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('account-$_kbDeposit')),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const ValueKey('account-$_kbDeposit')));
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('selection-leave-dialog')),
        findsOneWidget,
      );
      final leave = tester.getRect(
        find.byKey(const ValueKey('selection-leave')),
      );
      final keep = tester.getRect(find.byKey(const ValueKey('selection-keep')));
      expect(leave.top, keep.top, reason: '두 버튼은 한 줄에 나란히');
      expect(leave.right, lessThan(keep.left), reason: '왼쪽 나가기, 오른쪽 계속 고르기');
      await tester.tap(find.byKey(const ValueKey('selection-keep')));
      await tester.pumpAndSettle();
      expect(find.byType(AccountSelectScreen), findsOneWidget);

      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountSelectScreen), findsNothing);
      expect(find.text('계산에 포함한 계좌 5개 · 10월 19일 12:00 기준'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('account-excluded-$_kbDeposit')),
        findsNothing,
      );
    });

    testWidgets('the selection screen shows the saved account name', (
      tester,
    ) async {
      final (repo, snapshot) = await _connected();
      final renamed = await repo.updateAccountNickname(
        _hanaDemand,
        '생활비',
        WriteContext(
          expectedDataVersion: snapshot.dataVersion,
          ruleVersion: snapshot.ruleVersion,
          idempotencyKey: 'rename',
        ),
      );
      await _pump(
        tester,
        repo,
        FinancialSnapshot.fromJson(
          (renamed as FinancialOk<WriteSuccess>).value.snapshot,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('accounts-change-selection')));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('account-$_hanaDemand'));
      expect(
        find.descendant(of: row, matching: find.text('생활비')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('하나은행 생활비 통장 ····0003')),
        findsOneWidget,
        reason: '바꾼 이름 아래에 원래 상품명',
      );
    });

    testWidgets('rows stay put while choosing; the tab reorders after saving', (
      tester,
    ) async {
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);
      expect(_bankOrder(tester, _banks).last, '신한은행');
      await tester.tap(find.byKey(const ValueKey('accounts-change-selection')));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('account-$_shinhanSavings'));
      await tester.scrollUntilVisible(
        row,
        120,
        scrollable: find.byType(Scrollable).last,
      );
      final top = tester.getRect(row).top;
      await tester.tap(row);
      await tester.pump();
      expect(tester.getRect(row).top, top, reason: '고르는 동안 행이 움직이지 않음');

      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountSelectScreen), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('accounts-meta')),
        -120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(_bankOrder(tester, _banks), [
        '국민은행',
        '신한은행',
        '하나은행',
        '기업은행',
        '카카오뱅크',
      ], reason: '저장 뒤 신한은행에 포함 계좌가 생겨 데이터 순서 자리로');
    });

    testWidgets('leaving after a change can discard it', (tester) async {
      final (repo, snapshot) = await _connected();
      await _pump(tester, repo, snapshot);
      await tester.tap(find.byKey(const ValueKey('accounts-change-selection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-$_kakaoDemand')));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('selection-leave')));
      await tester.pumpAndSettle();
      expect(find.byType(AccountSelectScreen), findsNothing);
      expect(find.text('계산에 포함한 계좌 4개 · 10월 19일 12:00 기준'), findsOneWidget);
    });
  });
}
