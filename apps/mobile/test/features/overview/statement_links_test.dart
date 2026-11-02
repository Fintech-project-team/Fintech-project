import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/snapshot_projector.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/transaction_sheets.dart';
import 'package:payse/features/planning/card_bill_screen.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/connection/connection_test_utils.dart';

/// 2026-11-02: [snapshot]의 거래 [transactionId] 상세 시트를 여는 버튼 화면을 띄우고 연다.
Future<void> _open(
  WidgetTester tester,
  FinancialSnapshot snapshot,
  bool Function(SourceTransaction) pick,
) async {
  final t = [...?snapshot.transactions].firstWhere(pick);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open'),
            onPressed: () => showPayseSheet<void>(
              context,
              TransactionDetailSheet(snapshot: snapshot, transaction: t),
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

/// 2026-11-02: beta 원본을 현대카드만 빼고 연결한 응답(청구 미연결로 예정 지출의 청구 연결이 제한됨).
FinancialSnapshot _withoutHyundai() {
  final source = readSource('beta-ready');
  final codes = {
    for (final i in source['institutions']! as List) (i as Map)['code'],
  }..remove('card.hyundai');
  return FinancialSnapshot.fromJson(
    SnapshotProjector.project(
      source,
      ProjectionState(
        institutionLinks: [
          for (final code in codes)
            {
              'userId': source['userId'],
              'linkId': 'link-$code',
              'institutionCode': code,
              'consentedAt': '2026-10-22T10:00:00Z',
              'disconnectedAt': null,
            },
        ],
        selectedAccountIds: null,
        dataVersion: '3',
      ),
    ),
  );
}

void main() {
  final alpha = FinancialSnapshot.fromJson(readSource('alpha-ready'));
  final statement = alpha.statements!.single;
  final payer = alpha.obligations!.firstWhere(
    (o) => o.statementId == statement.statementId,
  );
  final paidTx = alpha.settlements!
      .firstWhere((s) => s.obligationId == payer.obligationId)
      .transactionId;

  testWidgets('카드 사용 상세: 포함된 청구를 누르면 카드 결제 상세, 뒤로 가면 목록', (tester) async {
    await _open(
      tester,
      alpha,
      (t) => t.transactionId == statement.includedTransactionRefs.first,
    );
    expect(find.text('포함된 청구'), findsOneWidget);
    expect(find.text('10월 10일 결제 청구'), findsOneWidget);
    expect(find.textContaining('청구 금액 110,000원'), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('detail-statement-${statement.statementId}')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CardBillScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(CardBillScreen), findsNothing);
    expect(find.byKey(const ValueKey('open')), findsOneWidget);
  });

  testWidgets('계좌 출금 상세: 정산으로 이어진 청구만 결제한 카드 대금', (tester) async {
    await _open(tester, alpha, (t) => t.transactionId == paidTx);
    expect(find.text('결제한 카드 대금'), findsOneWidget);
    expect(
      find.byKey(ValueKey('detail-statement-${statement.statementId}')),
      findsOneWidget,
    );
  });

  testWidgets('관계가 없는 출금·입금에는 청구 줄이 없다', (tester) async {
    final settled = {for (final s in alpha.settlements!) s.transactionId};
    await _open(
      tester,
      alpha,
      (t) =>
          t.recordKind == 'account_entry' &&
          t.direction == 'out' &&
          !settled.contains(t.transactionId),
    );
    expect(find.byKey(const ValueKey('detail-statements')), findsNothing);
  });

  testWidgets('청구 연결이 제한으로 끊기면 카드 대신 확인할 수 없다는 안내', (tester) async {
    final s = _withoutHyundai();
    final hidden = s.obligations!.firstWhere(
      (o) => s.isRestricted('obligation', o.obligationId, 'statementId'),
    );
    final tx = s.settlements!
        .firstWhere((x) => x.obligationId == hidden.obligationId)
        .transactionId;
    await _open(tester, s, (t) => t.transactionId == tx);
    expect(
      find.byKey(const ValueKey('detail-statement-restricted')),
      findsOneWidget,
    );
  });
}
