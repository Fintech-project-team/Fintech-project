import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/snapshot_projector.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';

import 'connection_test_utils.dart';
import 'snapshot_projector_test.dart' show projectWith;

/// 2026-10-30: v4 준비본(generated-v4) 원본 [stem]을 읽는다.
Map<String, Object?> readV4(String stem) => (jsonDecode(
  File('../api/fixtures/generated-v4/snapshots/$stem.json').readAsStringSync(),
) as Map).cast<String, Object?>();

/// 2026-10-30: 원본 [stem] 목록(v3·v4 같은 이름).
List<String> _stems(String dir) => [
  for (final f in Directory('../api/fixtures/$dir/snapshots').listSync())
    f.uri.pathSegments.last.replaceAll('.json', ''),
]..sort();

/// 2026-10-30: [json]의 모든 기관 코드.
Set<String> _allCodes(Map<String, Object?> json) => {
  for (final i in json['institutions']! as List) (i as Map)['code'] as String,
};

/// 2026-10-30: [json]의 첫 청구서 [index]의 항목 목록.
List<Map<String, Object?>> _items(Map<String, Object?> json, int index) => [
  for (final i
      in ((json['statements']! as List)[index] as Map)['items']! as List)
    (i as Map).cast<String, Object?>(),
];

Matcher _formatError(String where) => throwsA(
  isA<SnapshotFormatException>().having((e) => e.path, 'path', contains(where)),
);

void main() {
  const billing = [
    'alpha-billing-items',
    'beta-billing-items',
    'gamma-billing-items',
  ];

  group('v4 원본 읽기', () {
    for (final stem in _stems('generated-v4')) {
      test('$stem: 원본과 모든 기관 연결 응답을 v4로 읽는다', () {
        final source = readV4(stem);
        final raw = FinancialSnapshot.fromJson(source);
        expect(raw.schemaVersion, 'PAYSE-DRAFT-4');
        for (final s in raw.statements ?? const <Statement>[]) {
          expect(s.items, isNotNull, reason: 'v4 청구는 항목이 필수');
        }
        final codes = _allCodes(source);
        if (codes.isEmpty) return;
        if (_stems('generated').contains(stem)) {
          try {
            projectWith(readSource(stem), codes);
          } on SnapshotContractException {
            expect(
              () => projectWith(source, codes),
              throwsA(isA<SnapshotContractException>()),
              reason: 'v3에서 거절되는 사례는 v4에서도 거절',
            );
            return;
          }
        }
        final out = projectWith(source, codes);
        expect(out['schemaVersion'], 'PAYSE-API-0.6-4');
        final api = FinancialSnapshot.fromJson(out);
        expect(api.statements?.length, raw.statements?.length);
      });
    }

    test('반례 1: 음수 조정·청구액은 허용, 청구 원금 음수는 거절', () {
      final source = readV4('alpha-billing-items');
      final items = [
        for (final s in FinancialSnapshot.fromJson(source).statements!)
          ...s.items!,
      ];
      expect(items.any((i) => (i.feeOrAdjustmentAmountKrw ?? 0) < 0), isTrue);
      expect(items.any((i) => (i.billedAmountKrw ?? 0) < 0), isTrue);

      final bad = readV4('alpha-billing-items');
      final item = (_items(bad, 0)).first;
      item['billedPrincipalKRW'] = -1;
      ((bad['statements']! as List)[0] as Map)['items'] = [
        item,
        ..._items(bad, 0).skip(1),
      ];
      expect(
        () => FinancialSnapshot.fromJson(bad),
        _formatError('billedPrincipalKRW'),
      );
      expect(
        () => SnapshotProjector.validate(bad),
        throwsA(isA<SnapshotContractException>()),
      );
    });

    test('반례 2: 금액 null·연결 없음·독립 연회비를 그대로 읽는다', () {
      final items = [
        for (final s in FinancialSnapshot.fromJson(
          readV4('alpha-billing-items'),
        ).statements!)
          ...s.items!,
      ];
      final fee = items.firstWhere((i) => i.label == '카드 연회비');
      expect(fee.transactionId, isNull);
      expect(fee.transactionRestricted, isFalse);
      expect(fee.billedAmountKrw, 20000);
      expect(fee.billedPrincipalKrw, isNull, reason: 'null을 0으로 바꾸지 않는다');
      final unknown = items.firstWhere(
        (i) => i.label == '청구 조정' && i.billedAmountKrw == null,
      );
      expect(unknown.feeOrAdjustmentAmountKrw, isNull);
    });

    test('반례 4: 같은 구매를 여러 청구가 참조해도 거래를 복제하지 않는다', () {
      final snapshot = FinancialSnapshot.fromJson(
        readV4('alpha-billing-items'),
      );
      final installment = [
        for (final s in snapshot.statements!)
          for (final i in s.items!)
            if (i.label == '가전 할부') i,
      ];
      expect(installment, hasLength(2));
      expect(
        installment.map((i) => i.transactionId).toSet(),
        hasLength(1),
        reason: '두 회차가 같은 구매를 가리킨다',
      );
      expect(
        snapshot.transactions!.where(
          (t) => t.transactionId == installment.first.transactionId,
        ),
        hasLength(1),
      );
    });

    test('반례 4: v3에 items가 있거나 v4에 items가 없으면 거절', () {
      final v3 = readSource('alpha-ready');
      ((v3['statements']! as List)[0] as Map)['items'] = <Object?>[];
      expect(() => FinancialSnapshot.fromJson(v3), _formatError('items'));
      expect(
        () => SnapshotProjector.validate(v3),
        throwsA(isA<SnapshotContractException>()),
      );

      final v4 = readV4('alpha-ready');
      ((v4['statements']! as List)[0] as Map).remove('items');
      expect(() => FinancialSnapshot.fromJson(v4), _formatError('items'));
      expect(
        () => SnapshotProjector.validate(v4),
        throwsA(isA<SnapshotContractException>()),
      );
    });

    test('반례 4: 항목 키 누락·추가, 할부 순서, 파생 참조 불일치를 거절', () {
      Map<String, Object?> mutate(void Function(Map<String, Object?> item) f) {
        final json = readV4('alpha-billing-items');
        final items = _items(json, 1);
        f(items.first);
        ((json['statements']! as List)[1] as Map)['items'] = items;
        return json;
      }

      expect(
        () => FinancialSnapshot.fromJson(mutate((i) => i.remove('label'))),
        _formatError('statements'),
      );
      expect(
        () => FinancialSnapshot.fromJson(mutate((i) => i['cardId'] = 'x')),
        _formatError('statements'),
      );
      expect(
        () => FinancialSnapshot.fromJson(
          mutate((i) {
            i['installmentMonths'] = 2;
            i['installmentRound'] = 3;
          }),
        ),
        _formatError('statements'),
      );
      final refs = readV4('alpha-billing-items');
      ((refs['statements']! as List)[1] as Map)['includedTransactionRefs'] =
          <String>[];
      expect(
        () => FinancialSnapshot.fromJson(refs),
        _formatError('includedTransactionRefs'),
      );
    });
  });

  group('v4 공개 투영', () {
    test('반례 3·6: 미연결 거래 연결은 키만 생략하고 항목·청구 표식을 남긴다', () {
      final source = readV4('alpha-billing-items');
      final statement = (source['statements']! as List)[0] as Map;
      final itemTx = _items(source, 0).first['transactionId']! as String;
      final cardId = statement['cardId'] as String;
      final card = (source['cards']! as List).cast<Map>().firstWhere(
        (c) => c['cardId'] == cardId,
      );
      final accounts = (source['accounts']! as List).cast<Map>();
      final account = accounts.firstWhere(
        (a) => a['institutionCode'] != card['institutionCode'],
      );
      final tx = (source['transactions']! as List).cast<Map>().firstWhere(
        (t) => t['transactionId'] == itemTx,
      );
      tx['recordKind'] = 'account_entry';
      tx['accountId'] = account['accountId'];
      final codes = _allCodes(source)..remove(account['institutionCode']);

      final out = projectWith(source, codes);
      final public = ((out['statements']! as List).cast<Map>()).firstWhere(
        (s) => s['statementId'] == statement['statementId'],
      );
      final item = (public['items']! as List).cast<Map>().first;
      expect(item.containsKey('transactionId'), isFalse);
      expect(jsonEncode(public).contains(itemTx), isFalse, reason: '숨긴 ID 미노출');
      final marks = (out['accessRestrictions']! as List).cast<Map>();
      expect(
        marks.any(
          (m) =>
              m['ownerType'] == 'statementItem' &&
              m['ownerId'] == item['itemId'] &&
              m['field'] == 'transactionId',
        ),
        isTrue,
      );
      expect(
        marks.any(
          (m) =>
              m['ownerType'] == 'statement' &&
              m['ownerId'] == public['statementId'] &&
              m['field'] == 'includedTransactionRefs',
        ),
        isTrue,
      );
      final parsed = FinancialSnapshot.fromJson(out);
      final restored = parsed.statements!
          .firstWhere((s) => s.statementId == public['statementId'])
          .items!
          .first;
      expect(restored.transactionRestricted, isTrue);
      expect(restored.transactionId, isNull);

      final unmarked = jsonDecode(jsonEncode(out)) as Map<String, Object?>;
      unmarked['accessRestrictions'] = [
        for (final m in marks)
          if (m['ownerType'] != 'statementItem') m,
      ];
      expect(
        () => FinancialSnapshot.fromJson(unmarked),
        _formatError('statements'),
      );
    });

    test('카드가 미연결이면 청구 전체를 생략하고 기존 표식을 쓴다', () {
      final source = readV4('alpha-billing-items');
      final codes = {
        for (final c in _allCodes(source))
          if (c.startsWith('bank.')) c,
      };
      final out = projectWith(source, codes);
      expect(out['statements'], isEmpty);
      expect(
        (out['accessRestrictions']! as List).cast<Map>().any(
          (m) => m['ownerType'] == 'response' && m['field'] == 'statements',
        ),
        isTrue,
      );
    });

    test('v3 응답에는 statementItem 표식을 받지 않는다', () {
      final out = projectWith(
        readSource('alpha-ready'),
        _allCodes(readSource('alpha-ready')),
      );
      (out['accessRestrictions']! as List).add({
        'ownerType': 'statementItem',
        'ownerId': 'x',
        'field': 'transactionId',
        'targetKind': 'transaction',
        'reason': 'not_connected',
      });
      expect(
        () => FinancialSnapshot.fromJson(out),
        _formatError('accessRestrictions'),
      );
    });
  });

  group('반례 5: 기존 사례 홈 계산 불변', () {
    for (final stem in _stems('generated')) {
      if (billing.contains(stem)) continue;
      test(stem, () {
        String summary(HomeCalculation c) => switch (c) {
          HomeCalculationReady(:final result) => [
            result.b,
            result.e,
            result.r,
            result.o,
            result.u,
            result.insufficient,
            result.salaryCycle?.state,
          ].join('|'),
          HomeCalculationDataError() => 'data-error',
          HomeCalculationUnexpectedError() => 'unexpected',
        };
        final v3 = computeHomeCalculation(
          FinancialSnapshot.fromJson(readSource(stem)),
        );
        final v4 = computeHomeCalculation(
          FinancialSnapshot.fromJson(readV4(stem)),
        );
        expect(summary(v4), summary(v3));
      });
    }
  });
}
