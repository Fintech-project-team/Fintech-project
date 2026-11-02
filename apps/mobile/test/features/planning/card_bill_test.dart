import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/data/statement_relations.dart';
import 'package:payse/features/planning/card_bill_screen.dart';
import 'package:payse/shared/design/amount_format.dart';

import '../../data/connection/connection_test_utils.dart';
import '../../data/connection/statement_items_test.dart' show readV4;

/// 2026-11-02: v4 demo-life 원본에 청구 항목 값([patch])을 넣고 청구를 바꾼 JSON을 반환한다.
Map<String, Object?> _bill({
  Map<String, Object?> statement = const {},
  List<Map<String, Object?>> items = const [],
}) {
  final json = readV4('demo-life');
  final s = rows(json, 'statements').first;
  final list = (s['items']! as List).cast<Map>();
  for (final (i, patch) in items.indexed) {
    list[i].addAll(patch);
  }
  s.addAll(statement);
  return json;
}

FinancialSnapshot _read(Map<String, Object?> json) =>
    FinancialSnapshot.fromJson(json);

void main() {
  group('청구 항목 수·안내', () {
    test('complete는 항목 수, partial은 확인된 항목, unavailable은 건수 없음, v3는 연결된 거래', () {
      final s = _read(_bill()).statements!.first;
      expect(billCountText(s), '${s.items!.length}건');
      expect(billNotice(s).band, isFalse);
      expect(billNotice(s).body, '이번 청구 금액은 카드사가 제공한 금액이에요.');

      final partial = _read(_bill(statement: {'detailCompleteness': 'partial'}))
          .statements!
          .first;
      expect(billCountText(partial), '확인된 항목 ${partial.items!.length}건');
      expect(billNotice(partial).title, '청구 내역 일부만 받았어요');

      final none = _read(
        _bill(statement: {'detailCompleteness': 'unavailable'}),
      ).statements!.first;
      expect(billCountText(none), isNull);
      expect(billNotice(none).title, '청구 내역을 받지 못했어요');

      final v3 = _read(readSource('beta-ready')).statements!.single;
      expect(billCountText(v3), '연결된 거래 ${v3.includedTransactionRefs.length}건');
    });
  });

  group('청구 항목 한 줄', () {
    test('할부는 그 청구 회차와 결제 전체 금액을 밝히고, 이번 청구 금액은 항목 값 그대로', () {
      final s = _read(
        _bill(
          items: [
            {
              'billedAmountKRW': 100000,
              'installmentMonths': 6,
              'installmentRound': 2,
            },
          ],
        ),
      );
      final st = s.statements!.first;
      final line = billItemLine(StatementRelations(s), st, st.items!.first);
      expect(line.billedKrw, 100000);
      expect(line.sub, contains('할부 2/6'));
      expect(line.notes.first, startsWith('결제 금액 '));
    });

    test('이번 청구 금액 0원과 받지 못함(null)을 구분하고 다른 금액으로 대신하지 않는다', () {
      final s = _read(
        _bill(
          items: [
            {'billedAmountKRW': 0},
            {'billedAmountKRW': null},
          ],
        ),
      );
      final st = s.statements!.first;
      final r = StatementRelations(s);
      final zero = billItemLine(r, st, st.items![0]);
      expect(zero.billedKrw, 0);
      expect(zero.notes, isNot(contains('이번 청구분 정보 없음')));
      final missing = billItemLine(r, st, st.items![1]);
      expect(missing.billedKrw, isNull);
      expect(missing.notes, contains('이번 청구분 정보 없음'));
    });

    test('모든 항목에 이번 청구분이 없으면 줄마다 쓰지 않고 목록 위 한 번', () {
      final s = _read(
        _bill(
          items: [
            {'billedAmountKRW': null},
            {'billedAmountKRW': null},
          ],
        ),
      );
      final st = s.statements!.first;
      expect(billedAllMissing(st), isTrue);
      final line = billItemLine(StatementRelations(s), st, st.items!.first);
      expect(line.notes, isNot(contains('이번 청구분 정보 없음')));
      expect(line.notes.first, startsWith('결제 금액 '));
    });

    test('거래 연결 없음과 확인하지 못한 연결을 구분한다', () {
      final s = _read(_bill());
      final st = s.statements!.first;
      final r = StatementRelations(s);
      StatementItem item({String? id, bool restricted = false}) =>
          StatementItem(
            itemId: 'x',
            transactionId: id,
            transactionRestricted: restricted,
            label: '연회비',
            merchantName: null,
            purchaseDate: null,
            originalUsedAmountKrw: null,
            billedPrincipalKrw: null,
            feeOrAdjustmentAmountKrw: null,
            billedAmountKrw: 10000,
            installmentMonths: null,
            installmentRound: null,
          );
      expect(billItemLine(r, st, item()).sub, '카드사 청구 항목 · 연결된 거래 없음');
      expect(
        billItemLine(r, st, item(id: 'missing')).notes,
        contains('거래 정보를 확인하지 못했어요'),
      );
    });
  });

  group('카드 결제 상세 화면', () {
    Future<void> pump(WidgetTester tester, FinancialSnapshot s) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CardBillScreen(
            snapshot: s,
            statementId: s.statements!.first.statementId,
          ),
        ),
      );
    }

    testWidgets('결제 예정일이 없어도 다른 청구 정보는 그대로, 날짜를 다른 값으로 채우지 않는다', (
      tester,
    ) async {
      final s = _read(_bill(statement: {'dueDate': null}));
      await pump(tester, s);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('bill-info-결제 예정일')))
            .data,
        '결제 예정일 미확인',
      );
      expect(
        find.text(formatKrw(s.statements!.first.amountKrw)),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('bill-info-결제 계좌')), findsOneWidget);
      expect(find.byKey(const ValueKey('bill-note')), findsOneWidget);
    });

    testWidgets('일부만 받으면 안내 띠와 확인된 항목, 받지 못하면 항목 없이 안내와 금액만', (tester) async {
      final partial = _read(
        _bill(statement: {'detailCompleteness': 'partial'}),
      );
      await pump(tester, partial);
      expect(find.text('청구 내역 일부만 받았어요'), findsOneWidget);
      expect(find.text('확인된 청구 항목'), findsOneWidget);
      expect(find.byKey(const ValueKey('bill-line-0')), findsOneWidget);

      final none = _read(
        _bill(statement: {'detailCompleteness': 'unavailable'}),
      );
      await pump(tester, none);
      expect(find.text('청구 내역을 받지 못했어요'), findsOneWidget);
      expect(find.byKey(const ValueKey('bill-line-0')), findsNothing);
      expect(find.byKey(const ValueKey('bill-info-청구 항목')), findsNothing);
      expect(
        find.text(formatKrw(none.statements!.first.amountKrw)),
        findsOneWidget,
      );
    });

    testWidgets('항목별 청구분이 모두 없으면 목록 위 안내 한 줄, 일부만 없으면 그 줄에만', (tester) async {
      await pump(
        tester,
        _read(
          _bill(
            items: [
              {'billedAmountKRW': null},
              {'billedAmountKRW': null},
            ],
          ),
        ),
      );
      expect(find.text(billedMissingNote), findsOneWidget);
      expect(find.textContaining('이번 청구분 정보 없음'), findsNothing);

      await pump(
        tester,
        _read(
          _bill(
            items: [
              {'billedAmountKRW': 5000},
              {'billedAmountKRW': null},
            ],
          ),
        ),
      );
      expect(find.text(billedMissingNote), findsNothing);
      expect(find.textContaining('이번 청구분 정보 없음'), findsOneWidget);
    });

    testWidgets('대표 예정 지출이 없으면 결제 계좌 미확인', (tester) async {
      final json = _bill();
      for (final o in rows(json, 'obligations')) {
        o['statementId'] = null;
      }
      await pump(tester, _read(json));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('bill-info-결제 계좌'))).data,
        '결제 계좌 미확인',
      );
    });

    testWidgets('320dp·글자 1.3배에서도 넘치지 않는다', (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 720),
            textScaler: TextScaler.linear(1.3),
          ),
          child: MaterialApp(
            home: CardBillScreen(
              snapshot: _read(_bill()),
              statementId: _read(_bill()).statements!.first.statementId,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
