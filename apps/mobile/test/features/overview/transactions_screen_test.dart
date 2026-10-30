import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/transactions_screen.dart';
import 'package:payse/shared/design/payse_theme.dart';
import 'package:payse/shared/design/payse_tokens.dart';

import '../../data/connection/connection_test_utils.dart';
import '../connection/connection_test_support.dart';

const _kbDemand = '6069b37a-abf5-56fc-8bf0-153f5301fd1c';
const _ibkDemand = '4021635f-1b2c-534d-b5b6-9680b3c8d5f2';
const _codes = [
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

/// 2026-10-30: 원본 [stem] 스냅샷(연결 상태 그대로, 다음 페이지 없음).
FinancialSnapshot _source(String stem) =>
    FinancialSnapshot.fromJson(readSource(stem));

/// 2026-10-30: [snapshot]을 시험 크기로 띄운다. [accountId]가 있으면 계좌별 화면이다.
Future<void> _pump(
  WidgetTester tester,
  FinancialSnapshot snapshot, {
  UserFinancialRepository? repository,
  String? accountId,
  double textScale = 1,
  Size size = const Size(390, 1400),
  VoidCallback? onSessionInvalid,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: TransactionsScreen(
          snapshot: snapshot,
          repository: repository,
          accountId: accountId,
          onSessionInvalid: onSessionInvalid,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 2026-10-30: 키 [key] 위젯 안의 글자 [text].
Finder _in(String key, String text) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.text(text),
  matchRoot: true,
);

/// 2026-10-30: 시트를 열고 [steps] 키를 차례로 누른 뒤 '적용'한다.
Future<void> _sheet(
  WidgetTester tester,
  String open,
  List<String> steps,
) async {
  await tester.tap(find.byKey(ValueKey(open)));
  await tester.pumpAndSettle();
  for (final k in steps) {
    await tester.ensureVisible(find.byKey(ValueKey(k)));
    await tester.tap(find.byKey(ValueKey(k)));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('sheet-apply')));
  await tester.pumpAndSettle();
}

/// 2026-10-30: 거래를 [pageSize]씩 나누는 가짜 서버에 데모알파를 모두 연결한 저장소와 원본 Snapshot JSON을 반환한다.
Future<(FakeUserFinancialRepository, Map<String, Object?>)> _paged() async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (_) async => readSource('demo-ready'),
    transactionPageSize: 100,
  );
  final a = devDemoAccounts.first;
  final session = await auth.createSession(
    DemoCredentials(name: a.name, phone: a.phone, code: a.code),
  );
  final token = (session as AuthOk<DemoSession>).value.accessToken;
  final repo = FakeUserFinancialRepository(server: server, accessToken: token);
  await repo.linkInstitutions(
    _codes,
    const WriteContext(
      expectedDataVersion: '1',
      ruleVersion: 'PAYSE-CALC-1',
      idempotencyKey: 'link',
    ),
  );
  final json =
      ((await repo.loadSnapshot()) as FinancialOk<Map<String, Object?>>).value;
  return (repo, json);
}

void main() {
  group('02-4 거래 내역 목록', () {
    final s = _source('demo-ready');
    final cancel = s.transactions!.firstWhere(
      (t) => t.recordKind == 'card_cancellation',
    );
    final original = s.transactions!.firstWhere(
      (t) => t.transactionId == cancel.originalTransactionId,
    );

    testWidgets('기본 조건: 이번 달·전체 거래 수단·거래 종류 전체, 날짜 최신순 머리', (tester) async {
      await _pump(tester, s);
      expect(_in('period-title', '2026년 10월'), findsOneWidget);
      expect(find.text('(19일까지)'), findsNothing);
      expect(_in('chip-means', '전체 거래 수단'), findsOneWidget);
      expect(_in('chip-type', '거래 종류 전체'), findsOneWidget);
      expect(
        find.text('10월 19일 12:00 기준 · 연결된 계좌와 카드의 거래 내역이에요'),
        findsOneWidget,
      );
      final next = tester.widget<IconButton>(
        find.byKey(const ValueKey('period-next')),
      );
      expect(next.onPressed, isNull, reason: '이번 달 다음 달 없음');
      final top17 = tester.getRect(find.text('10월 17일 토요일')).top;
      final top16 = tester.getRect(find.text('10월 16일 금요일')).top;
      expect(top17, lessThan(top16));
    });

    testWidgets('승인 취소 행은 + 부호·카드 이름, 라벨은 원거래에만', (tester) async {
      await _pump(tester, s);
      final row = 'tx-${cancel.transactionId}';
      await tester.ensureVisible(find.byKey(ValueKey(row)));
      expect(
        find.descendant(
          of: find.byKey(ValueKey(row)),
          matching: find.textContaining('+'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey(row)),
          matching: find.textContaining('승인 취소 · '),
        ),
        findsOneWidget,
      );
      expect(_in(row, '승인 취소'), findsNothing, reason: '종류와 라벨 중복 없음');
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('tx-${original.transactionId}')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(_in('tx-${original.transactionId}', '승인 취소'), findsOneWidget);
    });

    testWidgets('행을 누르면 읽기 전용 상세 시트: 취소일·원래 결제, 편집 없음', (tester) async {
      await _pump(tester, s);
      final row = find.byKey(ValueKey('tx-${cancel.transactionId}'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(_in('detail-title', cancel.merchantName), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-row-취소일')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-row-원래 결제')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-row-거래 내용')), findsNothing);
      expect(find.text('적요'), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      await tester.tap(find.byKey(const ValueKey('detail-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-title')), findsNothing);
    });

    testWidgets('달 이동과 최근 3개월: 범위만 보이고 화살표 없음, 다른 조건 유지', (tester) async {
      await _pump(tester, s);
      await tester.tap(find.byKey(const ValueKey('period-prev')));
      await tester.pumpAndSettle();
      expect(_in('period-title', '2026년 9월'), findsOneWidget);
      await _sheet(tester, 'chip-type', ['type-accountOut']);
      await _sheet(tester, 'period-title', ['period-recent3']);
      expect(_in('period-title', '최근 3개월'), findsOneWidget);
      expect(find.text('2026년 7월 20일 ~ 10월 19일'), findsOneWidget);
      expect(find.byKey(const ValueKey('period-prev')), findsNothing);
      expect(_in('chip-type', '계좌 출금'), findsOneWidget, reason: '기간을 바꿔도 유지');
    });

    testWidgets('기간 시트: 선택지는 이름만, 조회 기간은 적용 위 한 번, 양 끝 달 표시', (tester) async {
      await _pump(tester, s);
      await tester.tap(find.byKey(const ValueKey('period-title')));
      await tester.pumpAndSettle();
      expect(_in('sheet-note', '조회 기간 2026년 10월 1일 ~ 10월 19일'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('period-recent1y')));
      await tester.pumpAndSettle();
      expect(
        _in('sheet-note', '조회 기간 2025년 10월 20일 ~ 2026년 10월 19일'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('period-month')));
      await tester.pumpAndSettle();
      expect(_in('month-2025-10', '20일부터'), findsOneWidget);
      expect(_in('month-2026-10', '19일까지'), findsOneWidget);
      expect(find.byKey(const ValueKey('month-2025-09')), findsNothing);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(
        _in('period-title', '2026년 10월'),
        findsOneWidget,
        reason: '닫으면 이전 조건',
      );
    });

    testWidgets('거래 수단: 0개면 적용 불가, 카드 하나만 고르면 칩 이름·카드 종류만', (tester) async {
      await _pump(tester, s);
      final card = s.cards!.first;
      await tester.tap(find.byKey(const ValueKey('chip-means')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('means-all')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('sheet-apply')))
            .onPressed,
        isNull,
      );
      expect(_in('sheet-note', '거래 수단을 1개 이상 골라 주세요'), findsOneWidget);
      await tester.ensureVisible(find.byKey(ValueKey('means-${card.cardId}')));
      await tester.tap(find.byKey(ValueKey('means-${card.cardId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sheet-apply')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('chip-means')),
          matching: find.textContaining(card.productName),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('chip-type')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('type-accountIn')), findsNothing);
      expect(find.byKey(const ValueKey('type-cardPurchase')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('type-cardCancellation')),
        findsOneWidget,
      );
    });

    testWidgets('거래 수단 시트: 은행 이름은 은행마다 한 번, 묶음 머리 위에만 진한 선', (tester) async {
      await _pump(tester, s);
      await tester.tap(find.byKey(const ValueKey('chip-means')));
      await tester.pumpAndSettle();
      expect(find.text('국민은행'), findsOneWidget, reason: '같은 은행 계좌를 한 묶음으로');
      Border? line(String key) =>
          (tester
                          .widget<Container>(
                            find
                                .descendant(
                                  of: find.byKey(ValueKey(key)),
                                  matching: find.byType(Container),
                                )
                                .first,
                          )
                          .decoration
                      as BoxDecoration?)
                  ?.border
              as Border?;
      expect(line('means-accounts')!.top.color, PayseColors.dividerSection);
      await tester.ensureVisible(find.byKey(const ValueKey('means-cards')));
      expect(line('means-cards')!.top.color, PayseColors.dividerSection);
      expect(line('means-all'), isNull);
      expect(line('means-${s.cards!.first.cardId}'), isNull);
    });

    testWidgets('거래 수단 묶음 요약과 맞지 않게 된 거래 종류는 전체로', (tester) async {
      await _pump(tester, s);
      await _sheet(tester, 'chip-type', ['type-accountOut']);
      await _sheet(tester, 'chip-means', ['means-accounts']);
      expect(_in('chip-means', '카드 전체'), findsOneWidget);
      expect(_in('chip-type', '거래 종류 전체'), findsOneWidget);
    });

    testWidgets('조건 결과 없음: 기간 변경·거래 수단 변경', (tester) async {
      await _pump(tester, s);
      await _sheet(tester, 'period-title', ['period-month', 'month-2025-10']);
      await _sheet(tester, 'chip-means', ['means-accounts']);
      expect(find.text('선택한 조건의 거래 내역이 없어요'), findsOneWidget);
      expect(find.byKey(const ValueKey('tx-action-기간 변경')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tx-action-거래 수단 변경')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('means-all')), findsOneWidget);
    });

    testWidgets('이번 달 거래가 없으면 최근 1년 보기', (tester) async {
      final json = readSource('demo-ready');
      (json['transactions']! as List).removeWhere((t) {
        final m = t as Map;
        final d =
            (m['bookingDate'] ??
                    m['purchaseDate'] ??
                    m['refundDate'] ??
                    m['cancellationDate'])
                as String;
        return d.startsWith('2026-10');
      });
      await _pump(tester, FinancialSnapshot.fromJson(json));
      expect(find.text('이번 달 거래 내역이 없어요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tx-action-최근 1년 보기')));
      await tester.pumpAndSettle();
      expect(_in('period-title', '최근 1년'), findsOneWidget);
      expect(find.text('10월 9일 금요일'), findsNothing);
      expect(find.textContaining('9월 '), findsWidgets);
    });

    testWidgets('일부만 조회된 계좌: 다시 시도 없는 안내 띠, 그 계좌를 빼면 사라짐', (tester) async {
      final partial = _source('partial-history');
      await _pump(tester, partial);
      expect(find.byKey(const ValueKey('tx-band-partial')), findsOneWidget);
      expect(find.text('일부 거래 내역만 확인할 수 있어요'), findsOneWidget);
      expect(
        find.textContaining('금융사에서 일부 기간의 거래 내역을 받지 못했어요'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('tx-retry')), findsNothing);
      await _sheet(tester, 'chip-means', ['means-accounts']);
      expect(find.byKey(const ValueKey('tx-band-partial')), findsNothing);
    });

    testWidgets('320dp·글자 1.3배에서 넘침 없음(목록·시트)', (tester) async {
      await _pump(tester, s, textScale: 1.3, size: const Size(320, 800));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('chip-means')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('tx-${original.transactionId}'));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('계좌별 거래 내역', () {
    final s = _source('demo-ready');

    testWidgets('계좌 고정: 입출금 칩만, 둘째 줄에 거래 수단 생략, 입출금 결과 없음 버튼', (tester) async {
      await _pump(tester, s, accountId: _ibkDemand);
      expect(find.byKey(const ValueKey('chip-means')), findsNothing);
      expect(_in('chip-type', '입출금 전체'), findsOneWidget);
      expect(find.textContaining('기업은행'), findsNothing);
      await _sheet(tester, 'chip-type', ['type-accountIn']);
      expect(_in('chip-type', '입금'), findsOneWidget);
      expect(find.text('선택한 조건의 거래 내역이 없어요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tx-action-입출금 전체 보기')));
      await tester.pumpAndSettle();
      expect(_in('chip-type', '입출금 전체'), findsOneWidget);
      expect(find.text('별해울마트 모래별점'), findsOneWidget);
    });

    testWidgets('다른 계좌 거래는 보이지 않는다', (tester) async {
      await _pump(tester, s, accountId: _kbDemand);
      for (final t in s.transactions!) {
        if (t.accountId != _kbDemand && t.bookingDate == '2026-10-15') {
          expect(find.byKey(ValueKey('tx-${t.transactionId}')), findsNothing);
        }
      }
    });
  });

  group('거래 페이지 수집', () {
    testWidgets('다음 페이지까지 모두 받아 목록에 보인다', (tester) async {
      final (repo, json) = await _paged();
      final first = FinancialSnapshot.fromJson(json);
      final inFirst = {for (final t in first.transactions!) t.transactionId};
      final later = FinancialSnapshot.fromJson(readSource('demo-ready'))
          .transactions!
          .firstWhere(
            (t) =>
                !inFirst.contains(t.transactionId) &&
                (t.bookingDate ?? t.purchaseDate ?? '').startsWith('2026-10'),
          );
      expect(first.nextTransactionCursor, isNotNull);
      await _pump(tester, first, repository: repo);
      final row = find.byKey(ValueKey('tx-${later.transactionId}'));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(row, findsOneWidget, reason: '다음 페이지에서 받은 이번 달 거래');
    });

    testWidgets('불러오기 실패: 처음이면 조회 실패와 다시 시도, 성공 뒤 실패면 이전 내역과 안내 띠', (
      tester,
    ) async {
      final (real, json) = await _paged();
      final first = FinancialSnapshot.fromJson(json);
      final pages = <FinancialOutcome<Map<String, Object?>>>[];
      String? cursor = first.nextTransactionCursor;
      while (cursor != null) {
        final page = await real.loadTransactionPage(cursor);
        pages.add(page);
        final value = (page as FinancialOk<Map<String, Object?>>).value;
        cursor = (value['page']! as Map)['nextCursor'] as String?;
      }
      final scripted = ScriptedRepository()
        ..pageResults.add(const FinancialUnavailable())
        ..pageResults.addAll(pages)
        ..pageResults.add(const FinancialUnavailable());
      await _pump(tester, first, repository: scripted);
      expect(find.text('거래 내역을 불러오지 못했어요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tx-action-다시 시도')));
      await tester.pumpAndSettle();
      expect(find.text('10월 17일 토요일'), findsOneWidget);
      expect(find.byKey(const ValueKey('tx-band-stale')), findsNothing);

      final next = Map<String, Object?>.of(json)..['dataVersion'] = '99';
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPayseTheme(),
          home: Scaffold(
            body: TransactionsScreen(
              snapshot: FinancialSnapshot.fromJson(next),
              repository: scripted,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('새로고침하지 못했어요'), findsOneWidget);
      expect(find.byKey(const ValueKey('tx-retry')), findsOneWidget);
      final band = tester.getRect(find.byKey(const ValueKey('tx-band-stale')));
      final title = tester.getRect(find.text('새로고침하지 못했어요'));
      final body = tester.getRect(find.text('이전 정보를 보여드려요.'));
      final label = tester.getRect(find.text('다시 시도'));
      final touch = tester.getRect(find.byKey(const ValueKey('tx-retry')));
      expect(title.top - band.top, 16, reason: '위 16dp');
      expect(body.top - title.bottom, 4, reason: '제목-설명 4dp');
      expect(label.top - body.bottom, 8, reason: '설명-다시 시도 8dp');
      expect(
        (band.bottom - 1) - label.bottom,
        16,
        reason: '아래 16dp(아래 선 1px 제외)',
      );
      expect(touch.height, 48, reason: '터치 영역 유지');
      expect(
        touch.bottom,
        lessThanOrEqualTo(band.bottom),
        reason: '터치 영역이 띠 안',
      );
      expect(find.text('10월 17일 토요일'), findsOneWidget, reason: '이전 내역 유지');
    });

    testWidgets('세션이 끝나면 세션 무효 처리로 보낸다', (tester) async {
      final (real, json) = await _paged();
      final scripted = ScriptedRepository()
        ..pageResults.add(const FinancialSessionInvalid());
      var invalid = 0;
      await _pump(
        tester,
        FinancialSnapshot.fromJson(json),
        repository: scripted,
        onSessionInvalid: () => invalid++,
      );
      expect(invalid, 1);
      expect(real, isNotNull);
    });
  });
}
