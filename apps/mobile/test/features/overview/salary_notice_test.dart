import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/home_screen.dart';
import 'package:payse/features/overview/salary_notice.dart';
import 'package:payse/shared/design/amount_hero.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/calculation_input_adapter_test.dart' show alphaWithReceipt;
import '../../data/connection/connection_test_utils.dart';

const _kbDemand = '6069b37a-abf5-56fc-8bf0-153f5301fd1c';
const _hanaDemand = '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc';
const _ibkDemand = '4021635f-1b2c-534d-b5b6-9680b3c8d5f2';
const _kakaoDemand = '1ce9128d-d667-5bfc-bed0-949a571c78f5';

/// 2026-10-29: [json]의 기준 시각(asOf)을 모두 [to]로 옮긴다(테스트 입력 사본).
Object? _moveAsOf(Object? json, String to) => switch (json) {
  final Map<String, Object?> map => {
    for (final e in map.entries)
      e.key: e.key == 'asOf' ? to : _moveAsOf(e.value, to),
  },
  final List<Object?> list => [for (final v in list) _moveAsOf(v, to)],
  _ => json,
};

/// 2026-10-29: 월급일(10/25) 다음 날 08:00 기준의 입금 대기 Snapshot.
FinancialSnapshot _dayAfterPayday() => FinancialSnapshot.fromJson(
  (_moveAsOf(readSource('salary-wait'), '2026-10-26T08:00:00+09:00')!
          as Map<String, Object?>)
      .cast<String, Object?>(),
);

HomeCalculationReady _ready(FinancialSnapshot s) =>
    computeHomeCalculation(s) as HomeCalculationReady;

/// 2026-10-29: 접힘 상태를 들고 있는 시험용 홈. [folded]로 시작하고 접기·펴기를 [log]에 남긴다.
class _Home extends StatefulWidget {
  const _Home({
    super.key,
    required this.calculation,
    this.folded,
    required this.log,
  });

  final HomeCalculationReady calculation;
  final String? folded;
  final List<String?> log;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late String? _folded = widget.folded;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: HomeScreen(
      calculation: widget.calculation,
      onReload: () {},
      salaryNotice: (
        foldedKey: _folded,
        onFoldedKey: (key) {
          widget.log.add(key);
          setState(() => _folded = key);
        },
        onEdit: () => widget.log.add('edit'),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  HomeCalculationReady calculation, {
  String? folded,
  List<String?>? log,
}) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: _Home(
        key: UniqueKey(),
        calculation: calculation,
        folded: folded,
        log: log ?? [],
      ),
    ),
  );
}

/// 2026-10-29: 데모알파 금융사 [codes]를 연결하고 [accounts]를 계산에 포함한 세션을 반환한다.
Future<(FakeUserFinancialRepository, FinancialSnapshot)> _session(
  List<String> codes,
  List<String> accounts,
) async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (_) async => readSource('demo-ready'),
  );
  final a = devDemoAccounts.first;
  final session = await auth.createSession(
    DemoCredentials(name: a.name, phone: a.phone, code: a.code),
  );
  final repo = FakeUserFinancialRepository(
    server: server,
    accessToken: (session as AuthOk<DemoSession>).value.accessToken,
  );
  WriteContext w(String v, String k) => WriteContext(
    expectedDataVersion: v,
    ruleVersion: 'PAYSE-CALC-1',
    idempotencyKey: k,
  );
  await repo.linkInstitutions(codes, w('1', 'l'));
  final saved = await repo.selectAccounts(accounts, w('2', 's'));
  return (
    repo,
    FinancialSnapshot.fromJson(
      (saved as FinancialOk<WriteSuccess>).value.snapshot,
    ),
  );
}

void main() {
  group('안내 대상', () {
    testWidgets('① 예정일이 지났는데 입금이 확인되지 않으면 큰 안내와 반영 대기 지출을 보인다', (tester) async {
      final ready = _ready(_dayAfterPayday());
      final notice = salaryNoticeOf(ready.snapshot, ready.result)!;
      expect(notice.kind, SalaryNoticeKind.awaiting);
      await _pump(tester, ready);
      expect(find.text('월급 입금 확인이 필요해요'), findsOneWidget);
      expect(
        find.text('10월 25일에 예정된 월급의 입금 여부를 확인하지 못했어요. 월급 정보가 바뀌었다면 수정해 주세요.'),
        findsOneWidget,
        reason: '날짜는 계산 결과의 확인 회차 예정일',
      );
      final waiting = ready.result.placementTotals!.values.firstWhere(
        (t) => t.totalKrw > 0,
      );
      expect(
        find.byKey(const ValueKey('home-awaiting-caption')),
        findsOneWidget,
      );
      expect(waiting.count, greaterThan(0));
      expect(
        find.byKey(const ValueKey('home-awaiting-notice')),
        findsNothing,
        reason: '큰 안내와 기존 입금 확인 전 안내를 겹쳐 보이지 않는다',
      );
    });

    testWidgets('월급 정보 확인은 편집 화면 열기로만 이어지고 접힘·계산을 바꾸지 않는다', (tester) async {
      final log = <String?>[];
      await _pump(tester, _ready(_dayAfterPayday()), log: log);
      await tester.tap(find.byKey(const ValueKey('salary-notice-edit')));
      await tester.pump();
      expect(log, ['edit']);
      expect(find.byKey(const ValueKey('home-salary-notice')), findsOneWidget);
    });

    testWidgets('월급일 당일은 기존 입금 확인 전 안내만 둔다', (tester) async {
      final ready = _ready(
        FinancialSnapshot.fromJson(readSource('salary-wait')),
      );
      expect(salaryNoticeOf(ready.snapshot, ready.result), isNull);
      await _pump(tester, ready);
      expect(find.byKey(const ValueKey('home-salary-notice')), findsNothing);
      expect(
        find.byKey(const ValueKey('home-awaiting-notice')),
        findsOneWidget,
      );
    });

    test('④ 입금이 확인된 정상 계산이면 안내가 없다', () {
      final ready = _ready(FinancialSnapshot.fromJson(alphaWithReceipt()));
      expect(ready.result.u, isNotNull);
      expect(salaryNoticeOf(ready.snapshot, ready.result), isNull);
    });
  });

  group('나중에 확인', () {
    testWidgets('② 접으면 작은 표시만 남고 다시 들어와도 접힌 채이며 계산 결과는 그대로다', (tester) async {
      final ready = _ready(_dayAfterPayday());
      final log = <String?>[];
      await _pump(tester, ready, log: log);
      final amount = tester.widget<AmountHero>(find.byType(AmountHero));

      await tester.tap(find.byKey(const ValueKey('salary-notice-later')));
      await tester.pump();
      final key = salaryNoticeOf(ready.snapshot, ready.result)!.key;
      expect(log, [key]);
      expect(find.byKey(const ValueKey('home-salary-notice')), findsNothing);
      expect(find.byKey(const ValueKey('salary-notice-open')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-awaiting-caption')),
        findsOneWidget,
        reason: '⑦ 접어도 반영 대기 지출 설명은 남는다',
      );
      expect(
        tester.widget<AmountHero>(find.byType(AmountHero)).amountKrw,
        amount.amountKrw,
      );

      await _pump(tester, ready, folded: key);
      expect(
        find.byKey(const ValueKey('salary-notice-open')),
        findsOneWidget,
        reason: '같은 회차·같은 상태면 재진입에도 접힌 채',
      );

      await tester.tap(find.byKey(const ValueKey('salary-notice-open')));
      await tester.pump();
      expect(find.byKey(const ValueKey('home-salary-notice')), findsOneWidget);
    });

    testWidgets('③ 새 회차나 월급 설정이 바뀌면 다시 펼친다', (tester) async {
      final ready = _ready(_dayAfterPayday());
      final key = salaryNoticeOf(ready.snapshot, ready.result)!.key;
      final changed = FinancialSnapshot.fromJson(
        (_moveAsOf(readSource('salary-wait'), '2026-10-26T08:00:00+09:00')!
                as Map<String, Object?>)
            .cast<String, Object?>()
          ..update('settings', (s) {
            final settings = (s! as Map).cast<String, Object?>();
            final salary = (settings['salary']! as Map).cast<String, Object?>();
            return {
              ...settings,
              'salary': {...salary, 'salaryAmountKRW': 3100000},
            };
          }),
      );
      final next = _ready(changed);
      expect(salaryNoticeOf(next.snapshot, next.result)!.key, isNot(key));
      await _pump(tester, next, folded: key);
      expect(find.byKey(const ValueKey('home-salary-notice')), findsOneWidget);
    });

    testWidgets('⑦ 계산 불가를 접어도 아직 계산할 수 없어요와 사유가 남는다', (tester) async {
      final ready = _ready(
        FinancialSnapshot.fromJson(readSource('alpha-ready')),
      );
      final notice = salaryNoticeOf(ready.snapshot, ready.result)!;
      expect(notice.kind, SalaryNoticeKind.absent);
      await _pump(tester, ready, folded: notice.key);
      expect(find.byKey(const ValueKey('home-salary-notice')), findsNothing);
      expect(find.byKey(const ValueKey('salary-notice-open')), findsOneWidget);
      expect(find.text('아직 계산할 수 없어요'), findsOneWidget);
      expect(find.text('9/25에 예정된 월급의 입금 여부를 확인할 정보가 없어요.'), findsOneWidget);
      expect(find.text('0원'), findsNothing);
    });
  });

  group('원인과 월급 계좌', () {
    test('⑥ 월급 계좌를 계산에서만 빼면 안내가 없고, 금융사 연결이 없으면 원인 안내다', () async {
      final (_, excluded) = await _session(
        const [
          'bank.kb',
          'bank.shinhan',
          'bank.hana',
          'bank.ibk',
          'bank.kakao',
          'card.hyundai',
          'card.samsung',
          'card.woori',
          'card.kb',
        ],
        const [_hanaDemand, _ibkDemand, _kakaoDemand],
      );
      final a = _ready(excluded);
      expect(a.result.u, isNotNull);
      expect(salaryNoticeOf(excluded, a.result), isNull);

      final (_, unlinked) = await _session(
        const ['bank.hana', 'bank.ibk', 'bank.kakao'],
        const [_hanaDemand, _ibkDemand, _kakaoDemand],
      );
      expect(unlinked.settings!.salary.salaryAccountRestricted, isTrue);
      final b = _ready(unlinked);
      final notice = salaryNoticeOf(unlinked, b.result);
      expect(notice?.kind, SalaryNoticeKind.unlinked);
      expect(notice!.title, '월급 계좌의 은행이 연결되지 않았어요');
    });

    test('⑤ 월급 계좌를 바꿔도 지난 입금 근거는 그대로다', () async {
      final (repo, before) = await _session(
        const [
          'bank.kb',
          'bank.shinhan',
          'bank.hana',
          'bank.ibk',
          'bank.kakao',
          'card.hyundai',
          'card.samsung',
          'card.woori',
          'card.kb',
        ],
        const [_kbDemand, _hanaDemand, _ibkDemand, _kakaoDemand],
      );
      final saved = await repo.updateSalarySettings(
        const SalaryPatch(salaryAccountId: (value: _hanaDemand)),
        WriteContext(
          expectedDataVersion: before.dataVersion,
          ruleVersion: before.ruleVersion,
          idempotencyKey: 'salary-account',
        ),
      );
      final after = FinancialSnapshot.fromJson(
        (saved as FinancialOk<WriteSuccess>).value.snapshot,
      );
      expect(after.settings!.salary.salaryAccountId, _hanaDemand);
      String evidence(FinancialSnapshot s) => [
        for (final r in s.settings!.salary.receiptEvidence!)
          '${r.payMonth}:${r.expectedPayDate}:${r.confirmation}:'
              '${r.transactionIds.join('+')}',
      ].join('|');
      expect(evidence(after), evidence(before));
    });
  });
}
