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
      expect(find.text('계좌 5개 · 10월 19일 12:00 기준'), findsOneWidget);

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
      expect(
        find.byKey(const ValueKey('period-list')),
        findsOneWidget,
        reason: '처음 들어가면 이번 기간 내역',
      );
      await tester.tap(find.byKey(const ValueKey('inner-tab-all')));
      await tester.pumpAndSettle();
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
      await tester.ensureVisible(
        find.byKey(const ValueKey('account-open-$_hanaDemand')),
      );
      await tester.pumpAndSettle();
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
      expect(find.text('계좌 4개 · 10월 19일 12:00 기준'), findsOneWidget);
    },
  );

  testWidgets('홈 이번 기간 내역 보기 → 계좌·카드 탭 / 계산 내역의 계좌 → 그 계좌 입출금 → 뒤로 계산 내역', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = await _connected();
    final records = MemoryFirstCalcRecordStore();
    await records.save(devDemoAccounts.first.userId, FirstCalcRecord.explained);
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
    final period = find.byKey(const ValueKey('home-period-button'));
    await tester.ensureVisible(period);
    await tester.tap(period);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('period-list')), findsOneWidget);
    expect(find.text('9/25 – 10/24'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(NavigationBar), matching: find.text('홈')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-row-balance')));
    await tester.pumpAndSettle();
    final account = find.byKey(
      const ValueKey('receipt-account-6069b37a-abf5-56fc-8bf0-153f5301fd1c'),
    );
    expect(account, findsOneWidget, reason: '계좌 잔액 항목이 펼쳐져 있다');
    await tester.tap(account);
    await tester.pumpAndSettle();
    expect(find.text('입출금 내역'), findsOneWidget);
    expect(find.text('계산에 포함'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('계산 내역'), findsOneWidget);
    expect(account, findsOneWidget, reason: '펼침 상태 유지');
  });

  testWidgets('전체 거래에서 고른 기간은 개별 조회로 이어지고, 계좌 관리에서는 이번 달로 시작한다', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = await _connected();
    final records = MemoryFirstCalcRecordStore();
    await records.save(devDemoAccounts.first.userId, FirstCalcRecord.explained);
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
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('계좌·카드'),
      ),
    );
    await tester.pumpAndSettle();
    final scopeTop = tester
        .getTopLeft(find.byKey(const ValueKey('flow-scope')))
        .dy;
    await tester.tap(find.byKey(const ValueKey('inner-tab-all')));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('tx-scope'))).dy,
      scopeTop,
      reason: '세 탭 범위 문구는 같은 높이에서 시작',
    );
    final txBasis = tester
        .getTopLeft(find.byKey(const ValueKey('tx-basis')))
        .dy;
    await tester.tap(find.byKey(const ValueKey('period-prev')));
    await tester.pumpAndSettle();
    void expectCentered(String month) {
      Rect icon(String key, IconData data) => tester.getRect(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byIcon(data),
        ),
      );
      final prev = icon('period-prev', Icons.chevron_left);
      final next = icon('period-next', Icons.chevron_right);
      final more = icon('period-title', Icons.expand_more);
      final text = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('period-title')),
          matching: find.text(month),
        ),
      );
      expect(
        (next.left - more.right) - (text.left - prev.right),
        closeTo(-4, 0.5),
        reason: '▾ 글자 오른쪽 빈 공간(약 4dp)만큼 오른쪽 여백을 줄여 ‹·› 사이 가운데로 보이게 한다',
      );
    }

    Finder title(String text) => find.descendant(
      of: find.byKey(const ValueKey('period-title')),
      matching: find.text(text),
    );
    expect(title('2026년 9월'), findsOneWidget);
    expect(
      (tester.getTopLeft(find.byKey(const ValueKey('period-prev'))).dx +
              tester
                  .getTopRight(find.byKey(const ValueKey('period-next')))
                  .dx) /
          2,
      closeTo(390 / 2, 0.5),
      reason: '전체 거래의 ‹ 기간 ▾ › 묶음은 화면 가운데',
    );
    expectCentered('2026년 9월');
    await tester.tap(find.byKey(const ValueKey('tx-pick-instrument')));
    await tester.pumpAndSettle();
    expect(find.text('계좌 6개'), findsOneWidget, reason: '전체 거래는 연결한 전체');
    await tester.tap(
      find.byKey(
        const ValueKey(
          'instrument-choice-6069b37a-abf5-56fc-8bf0-153f5301fd1c',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(title('2026년 9월'), findsOneWidget, reason: '부모 기간으로 시작');
    await tester.tap(find.byKey(const ValueKey('period-next')));
    await tester.pumpAndSettle();
    expect(title('2026년 10월'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(title('2026년 9월'), findsOneWidget, reason: '자식 기간 변경이 부모를 덮지 않는다');

    await tester.tap(find.byKey(const ValueKey('inner-tab-accounts')));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('계산에 포함한 계좌 잔액')).dy,
      scopeTop,
      reason: '계좌 관리 범위 문구도 같은 높이',
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('accounts-meta'))).dy,
      txBasis,
      reason: '핵심 정보 줄 높이가 같아 기준 시각도 같은 자리',
    );
    await tester.tap(
      find.byKey(
        const ValueKey('account-open-6069b37a-abf5-56fc-8bf0-153f5301fd1c'),
      ),
    );
    await tester.pumpAndSettle();
    expect(title('2026년 10월'), findsOneWidget, reason: '계좌 관리는 이번 달');
    expectCentered('2026년 10월');
  });
}
