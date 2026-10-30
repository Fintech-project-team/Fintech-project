import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/app/main_entry.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/first_calc_record_store.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../data/connection/connection_test_utils.dart';
import '../features/connection/connection_test_support.dart';

const _kbDeposit = '2c56e23d-2e82-59ed-8fce-21459e226167';
const _hanaDemand = '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc';

/// 2026-10-29: 데모알파(demo-ready)를 모두 연결하고 입출금 4개를 계산에 포함한 가짜 서버 세션 저장소를 반환한다.
Future<FakeUserFinancialRepository> _connected() async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (userId) async => readSource('demo-ready'),
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
  await repo.linkInstitutions(const [
    'bank.kb',
    'bank.shinhan',
    'bank.hana',
    'bank.ibk',
    'bank.kakao',
    'card.hyundai',
    'card.samsung',
    'card.woori',
    'card.kb',
  ], w('1', 'l'));
  await repo.selectAccounts(const [
    '6069b37a-abf5-56fc-8bf0-153f5301fd1c',
    _hanaDemand,
    '4021635f-1b2c-534d-b5b6-9680b3c8d5f2',
    '1ce9128d-d667-5bfc-bed0-949a571c78f5',
  ], w('2', 's'));
  return repo;
}

void main() {
  testWidgets(
    'renaming and changing the included accounts on the accounts tab update the home',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final repo = await _connected();
      final records = MemoryFirstCalcRecordStore();
      await records.save(
        devDemoAccounts.first.userId,
        FirstCalcRecord.explained,
      );
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
      expect(
        find.textContaining('1,300,000', findRichText: true),
        findsWidgets,
        reason: '데모알파 홈 쓸 수 있는 돈',
      );

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('계좌·카드'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inner-tab-accounts')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('account-rename-$_hanaDemand')),
        120,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('accounts-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('account-row-$_hanaDemand')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('account-rename-$_hanaDemand')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), '생활비');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('account-row-$_hanaDemand')),
          matching: find.text('생활비'),
        ),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('accounts-meta')),
        -120,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('accounts-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('accounts-change-selection')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('account-$_kbDeposit')),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const ValueKey('account-$_kbDeposit')));
      await tester.pump();
      await tester.tap(find.text('이 계좌로 계산하기'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('accounts-meta')),
        -120,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('accounts-list')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('계산에 포함한 계좌 5개 · 10월 19일 12:00 기준'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('홈'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('2,300,000', findRichText: true),
        findsWidgets,
        reason: '정기예금 1,000,000원이 계산에 더해진 새 Snapshot으로 다시 계산',
      );
    },
  );

  testWidgets(
    '계좌·카드 탭: 안쪽 탭은 다른 하단 탭에 다녀와도 유지, 계좌 행은 그 계좌 거래 내역을 열고 돌아오면 스크롤 유지',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final repo = await _connected();
      final records = MemoryFirstCalcRecordStore();
      await records.save(
        devDemoAccounts.first.userId,
        FirstCalcRecord.explained,
      );
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
      Future<void> bottom(String label) async {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
        );
        await tester.pumpAndSettle();
      }

      await bottom('계좌·카드');
      expect(find.byKey(const ValueKey('transactions-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('chip-means')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inner-tab-accounts')));
      await tester.pumpAndSettle();
      await bottom('홈');
      await bottom('계좌·카드');
      expect(find.byKey(const ValueKey('accounts-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('chip-means')), findsNothing);

      final list = find.descendant(
        of: find.byKey(const ValueKey('accounts-list')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('account-open-$_hanaDemand')),
        120,
        scrollable: list,
      );
      final offset = tester.state<ScrollableState>(list).position.pixels;
      await tester.tap(find.byKey(const ValueKey('account-open-$_hanaDemand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('account-tx-title')), findsOneWidget);
      expect(find.byKey(const ValueKey('chip-means')), findsNothing);
      expect(find.byKey(const ValueKey('chip-type')), findsOneWidget);
      expect(find.text('모아결식품 해솔길점'), findsOneWidget);
      expect(find.text('새온결플러스'), findsNothing, reason: '다른 거래 수단 제외');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(list).position.pixels,
        offset,
        reason: '계좌 관리 스크롤 유지',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('accounts-meta')),
        -120,
        scrollable: list,
      );
      expect(find.text('계산에 포함한 계좌 4개 · 10월 19일 12:00 기준'), findsOneWidget);
    },
  );
}
