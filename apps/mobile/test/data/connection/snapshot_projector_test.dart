import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/snapshot_projector.dart';
import 'package:payse/data/financial_snapshot.dart';

import 'connection_test_utils.dart';

const _banks = {
  'bank.kb',
  'bank.shinhan',
  'bank.hana',
  'bank.ibk',
  'bank.kakao',
};
const _cards = {'card.hyundai', 'card.samsung', 'card.woori', 'card.kb'};

/// 2026-10-22: [codes]를 연결한 상태(선택 [selected])로 [source]를 투영한다.
Map<String, Object?> projectWith(
  Map<String, Object?> source,
  Set<String> codes, {
  Set<String>? selected,
  String version = '5',
}) => SnapshotProjector.project(
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
    selectedAccountIds: selected,
    dataVersion: version,
  ),
);

void main() {
  group('before connection', () {
    for (final stem in ['alpha-ready', 'beta-ready', 'gamma-month-end']) {
      test(
        '$stem: same transform gives exactly the 10 pre-connection keys',
        () {
          final source = readSource(stem);
          final out = projectWith(source, {}, version: '1');

          expect(out.keys.toSet(), {
            'userId',
            'schemaVersion',
            'currency',
            'dataVersion',
            'sourceVersion',
            'ruleVersion',
            'asOf',
            'institutions',
            'institutionLinks',
            'coverage',
          });
          expect(out['schemaVersion'], 'PAYSE-API-0.6-2');
          expect(out['userId'], source['userId']);
          expect(out['institutionLinks'], isEmpty);
          expect(out['coverage'], isEmpty);
          expect(
            out['institutions'],
            source['institutions'],
            reason: '기관 목록은 사용자별 원본 그대로',
          );
          expect(FinancialSnapshot.fromJson(out).institutionLinkCount, 0);
        },
      );
    }
  });

  group('full connection', () {
    test(
      'every array is public, no restriction, included only from selection',
      () {
        final source = readSource('alpha-ready');
        final out = projectWith(source, {..._banks, ..._cards});

        for (final key in [
          'accounts',
          'cards',
          'transactions',
          'statements',
          'obligations',
          'reserves',
          'allocations',
          'settlements',
          'transactionRelations',
          'coverage',
        ]) {
          expect(
            rows(out, key),
            hasLength(rows(source, key).length),
            reason: key,
          );
        }
        expect(out['accessRestrictions'], isEmpty);
        expect(
          rows(out, 'accounts').every((a) => a['included'] == false),
          isTrue,
          reason: '연결만으로 계좌 선택을 확정하지 않음',
        );

        final chosen = rows(source, 'accounts').first['accountId'] as String;
        final picked = projectWith(
          source,
          {..._banks, ..._cards},
          selected: {chosen},
        );
        for (final a in rows(picked, 'accounts')) {
          expect(a['included'], a['accountId'] == chosen);
        }
        expect(FinancialSnapshot.fromJson(picked).accounts, hasLength(6));
      },
    );

    test('projection never mutates the source', () {
      final source = readSource('gamma-month-end');
      final before = jsonEncode(source);
      projectWith(source, {'bank.kb', 'card.hyundai'});
      projectWith(source, {..._banks, ..._cards}, selected: {'x'});
      expect(jsonEncode(source), before);
    });
  });

  group('partial connection', () {
    test('banks only: card data hidden, relations and statements restricted, no ID leak', () {
      final source = readSource('alpha-ready');
      final out = projectWith(source, _banks);
      final keys = restrictionKeys(out);

      expect(rows(out, 'cards'), isEmpty);
      expect(rows(out, 'statements'), isEmpty);
      expect(
        rows(
          out,
          'transactions',
        ).every((t) => t['recordKind'] == 'account_entry'),
        isTrue,
      );
      expect(
        keys,
        containsAll([
          'response|null|cards|card',
          'response|null|transactions|transaction',
          'response|null|statements|card',
          'response|null|coverage|card',
        ]),
      );
      final withStatement = rows(
        source,
        'obligations',
      ).where((o) => o['statementId'] != null);
      for (final o in withStatement) {
        final public = rows(
          out,
          'obligations',
        ).firstWhere((p) => p['obligationId'] == o['obligationId']);
        expect(
          public.containsKey('statementId'),
          isFalse,
          reason: '숨긴 청구 참조는 키 생략',
        );
        expect(
          keys,
          contains('obligation|${o['obligationId']}|statementId|statement'),
        );
      }
      expect(
        jsonEncode(out),
        isNot(contains(rows(source, 'cards').first['cardId'] as String)),
      );
      for (final id in hiddenSourceIds(source, _banks)) {
        expect(jsonEncode(out).contains(id), isFalse, reason: '숨긴 ID $id 노출');
      }
    });

    test('cards only (projection input): card fields kept, bank references omitted with restrictions', () {
      final source = readSource('alpha-ready');
      final out = projectWith(source, _cards);
      final keys = restrictionKeys(out);

      expect(rows(out, 'accounts'), isEmpty);
      expect(rows(out, 'cards'), hasLength(4));
      for (final c in rows(out, 'cards')) {
        expect(c.containsKey('withdrawalAccountId'), isFalse);
        expect(
          keys,
          contains('card|${c['cardId']}|withdrawalAccountId|account'),
        );
      }
      expect(
        rows(
          out,
          'transactions',
        ).every((t) => t['recordKind'] != 'account_entry'),
        isTrue,
        reason: '카드 연결만으로 은행 입출금 미공개',
      );
      final salary = (out['settings'] as Map)['salary'] as Map;
      expect(salary.containsKey('salaryAccountId'), isFalse);
      expect(salary['salaryDay'], 25, reason: '나머지 설정은 그대로');
      expect(keys, contains('settings|null|salary.salaryAccountId|account'));
      expect(rows(out, 'obligations'), isEmpty);
      expect(rows(out, 'reserves'), isEmpty);
      expect(
        keys,
        containsAll([
          'response|null|obligations|account',
          'response|null|reserves|account',
          'response|null|allocations|reserve',
        ]),
      );
      for (final id in hiddenSourceIds(source, _cards)) {
        expect(jsonEncode(out).contains(id), isFalse, reason: '숨긴 ID $id 노출');
      }
    });

    test('⑥ parsed model keeps restricted vs unknown, and rejects bad markers or versions', () {
      final out = projectWith(readSource('alpha-ready'), _cards);
      final model = FinancialSnapshot.fromJson(out);
      final card = model.cards!.first;
      expect(card.withdrawalAccountId, isNull);
      expect(
        card.withdrawalAccountRestricted,
        isTrue,
        reason: '생략(연결 제한)과 원래 미확인 null을 구분',
      );
      expect(
        model.isRestricted('card', card.cardId, 'withdrawalAccountId'),
        isTrue,
      );
      expect(model.accessRestrictions, isNotEmpty);

      final full = FinancialSnapshot.fromJson(
        projectWith(readSource('alpha-ready'), {..._banks, ..._cards}),
      );
      expect(full.cards!.every((c) => !c.withdrawalAccountRestricted), isTrue);

      final badMarker = projectWith(readSource('alpha-ready'), _cards);
      (badMarker['accessRestrictions'] as List).add({
        'ownerType': 'card',
        'ownerId': null,
        'field': 'withdrawalAccountId',
        'targetKind': 'account',
        'reason': 'not_connected',
      });
      expect(
        () => FinancialSnapshot.fromJson(badMarker),
        throwsA(isA<SnapshotFormatException>()),
      );

      final noMarker = projectWith(readSource('alpha-ready'), _cards)
        ..['accessRestrictions'] = <Object?>[];
      expect(
        () => FinancialSnapshot.fromJson(noMarker),
        throwsA(isA<SnapshotFormatException>()),
        reason: '표식 없는 생략은 형식 오류',
      );

      final oldSchema = projectWith(readSource('alpha-ready'), _banks)
        ..['schemaVersion'] = 'PAYSE-API-0.6-1';
      expect(
        () => FinancialSnapshot.fromJson(oldSchema),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('mixed: card kept with its bank; other card pair relations restricted on the public side', () {
      final source = readSource('alpha-ready');
      final codes = {'bank.kb', 'card.hyundai'};
      final out = projectWith(source, codes);
      final keys = restrictionKeys(out);

      final hyundai = rows(out, 'cards').single;
      expect(hyundai['institutionCode'], 'card.hyundai');
      expect(
        hyundai.containsKey('withdrawalAccountId'),
        isTrue,
        reason: '출금 은행(국민)이 연결돼 있음',
      );
      final visibleTx = {
        for (final t in rows(out, 'transactions')) t['transactionId'],
      };
      for (final r in rows(out, 'transactionRelations')) {
        expect(visibleTx, containsAll([r['fromId'], r['toId']]));
      }
      for (final key in keys.where(
        (k) =>
            k.startsWith('transaction|') &&
            k.endsWith('|transactionRelations|transaction'),
      )) {
        expect(
          visibleTx.contains(key.split('|')[1]),
          isTrue,
          reason: '관계 제한은 공개 거래에만',
        );
      }
      for (final id in hiddenSourceIds(source, codes)) {
        expect(jsonEncode(out).contains(id), isFalse, reason: '숨긴 ID $id 노출');
      }
    });

    test('salary account bank not connected: salary account omitted, other settings kept', () {
      final source = readSource('salary-confirmed');
      final codes = {'bank.shinhan', 'card.hyundai'};
      final out = projectWith(source, codes);
      final salary = (out['settings'] as Map)['salary'] as Map;

      expect(salary.containsKey('salaryAccountId'), isFalse);
      expect(
        salary.containsKey('receiptEvidence'),
        isFalse,
        reason: '급여 계좌를 드러내는 근거도 생략',
      );
      expect(
        restrictionKeys(out),
        containsAll([
          'settings|null|salary.salaryAccountId|account',
          'settings|null|salary.receiptEvidence|account',
        ]),
      );
      expect(salary['salaryAmountKRW'], 3000000);
    });

    test('unselected connected accounts still expose their transactions', () {
      final source = readSource('alpha-ready');
      final hana = rows(
        source,
        'accounts',
      ).firstWhere((a) => a['institutionCode'] == 'bank.hana');
      final out = projectWith(
        source,
        {..._banks},
        selected: {rows(source, 'accounts').first['accountId'] as String},
      );

      final hanaRow = rows(
        out,
        'accounts',
      ).firstWhere((a) => a['accountId'] == hana['accountId']);
      expect(hanaRow['included'], isFalse);
      final sourceHanaTx = rows(
        source,
        'transactions',
      ).where((t) => t['accountId'] == hana['accountId']).length;
      final outHanaTx = rows(
        out,
        'transactions',
      ).where((t) => t['accountId'] == hana['accountId']).length;
      expect(
        outHanaTx,
        sourceHanaTx,
        reason: '홈 선택(included=false)은 접근 제한이 아님',
      );
    });

    test(
      'every restriction marker is a registered combination with valid ownerId',
      () {
        final source = readSource('gamma-month-end');
        for (final codes in [
          {'bank.kb'},
          {'bank.hana', 'card.kb'},
          {'bank.shinhan', 'card.samsung', 'card.woori'},
          _banks,
          {'bank.kb', ..._cards},
        ]) {
          final out = projectWith(source, codes);
          for (final r in rows(out, 'accessRestrictions')) {
            expect(r['reason'], 'not_connected');
            final responseLike =
                r['ownerType'] == 'response' || r['ownerType'] == 'settings';
            expect(r['ownerId'] == null, responseLike, reason: '$r');
          }
          final markers = rows(
            out,
            'accessRestrictions',
          ).map(jsonEncode).toList();
          expect(
            markers.toSet(),
            hasLength(markers.length),
            reason: '같은 표식은 한 번만',
          );
          expect(() => FinancialSnapshot.fromJson(out), returnsNormally);
        }
      },
    );
  });

  group('contract errors', () {
    test('wrongly typed source fields are contract errors, not TypeErrors', () {
      final cases = <String, void Function(Map<String, Object?>)>{
        'numeric account id': (src) =>
            rows(src, 'accounts').first['accountId'] = 7,
        'non-object row': (src) => (src['transactions'] as List).add('row'),
        'string institution count': (src) =>
            rows(src, 'institutions').first['accountCount'] = 'bad',
        'numeric institution code': (src) =>
            rows(src, 'institutions').first['code'] = 1,
        'non-string evidence id': (src) =>
            rows(src, 'statements').first['includedTransactionRefs'] = [1],
        'non-object settings': (src) => src['settings'] = 'x',
        'numeric rule version': (src) => src['ruleVersion'] = 1,
      };
      cases.forEach((name, mutate) {
        final unconnected = readSource('alpha-ready');
        mutate(unconnected);
        expect(
          () => projectWith(unconnected, const {}),
          throwsA(isA<SnapshotContractException>()),
          reason: '$name (연결 전)',
        );
        final connected = readSource('alpha-ready');
        mutate(connected);
        expect(
          () => SnapshotProjector.validate(connected),
          throwsA(isA<SnapshotContractException>()),
          reason: '$name (원본 검증)',
        );
      });
      expect(
        () => SnapshotProjector.validate(readSource('alpha-ready')),
        returnsNormally,
      );
    });

    test('unsupported source schema and unknown record kind are refused', () {
      final old = readSource('alpha-ready')
        ..['schemaVersion'] = 'PAYSE-DRAFT-1';
      expect(
        () => projectWith(old, _banks),
        throwsA(isA<SnapshotContractException>()),
      );

      final odd = readSource('alpha-ready');
      rows(odd, 'transactions').first['recordKind'] = 'mystery';
      expect(
        () => projectWith(odd, _banks),
        throwsA(isA<SnapshotContractException>()),
      );
    });

    test('④ an unverified missing original is refused even with every institution connected', () {
      expect(
        () => projectWith(readSource('refund-unavailable-original'), {
          ..._banks,
          ..._cards,
        }),
        throwsA(isA<SnapshotContractException>()),
      );
      expect(
        () => projectWith(readSource('refund-outside-window'), {
          ..._banks,
          ..._cards,
        }),
        returnsNormally,
        reason: '원거래가 relatedTransactions에 있으면 근거 있음',
      );
    });

    test('③ rows owned by another user and missing parents are refused before projection', () {
      final owner = readSource('alpha-ready');
      rows(owner, 'transactions').first['userId'] = 'someone-else';
      expect(
        () => projectWith(owner, {}),
        throwsA(isA<SnapshotContractException>()),
        reason: '연결 전 응답도 원본 검증',
      );

      final orphan = readSource('gamma-month-end');
      rows(orphan, 'occurrenceOverrides').first['planRevisionId'] = 'missing';
      expect(
        () => projectWith(orphan, _banks),
        throwsA(isA<SnapshotContractException>()),
      );
    });

    test('⑥-a a missing original alone is refused (independent of referenceResolutions)', () {
      final source = readSource('refund-unavailable-original')
        ..['referenceResolutions'] = <Object?>[];
      expect(
        () => projectWith(source, {..._banks, ..._cards}),
        throwsA(
          isA<SnapshotContractException>().having(
            (e) => e.where,
            'where',
            'transactions.originalTransactionId',
          ),
        ),
      );
    });

    test('⑥-b an unknown referenceResolutions entry alone is refused (independent of originals)', () {
      final source = readSource('alpha-ready')
        ..['referenceResolutions'] = [
          {
            'transactionId': 'aaaaaaaa-0000-4000-8000-000000000001',
            'status': 'unavailable',
            'reason': 'not_provided',
          },
        ];
      expect(
        () => projectWith(source, {..._banks, ..._cards}),
        throwsA(
          isA<SnapshotContractException>().having(
            (e) => e.where,
            'where',
            'referenceResolutions',
          ),
        ),
      );
    });

    test('1 a plan carrying an old duplicate field is refused instead of leaking it', () {
      final source = readSource('alpha-ready');
      final hana = rows(
        source,
        'accounts',
      ).firstWhere((a) => a['institutionCode'] == 'bank.hana')['accountId'];
      rows(source, 'recurringPlans').first['withdrawalAccountId'] = hana;
      expect(
        () => projectWith(source, {'bank.kb'}),
        throwsA(
          isA<SnapshotContractException>().having(
            (e) => e.where,
            'where',
            'recurringPlans',
          ),
        ),
      );
      final cardLeak = readSource('alpha-ready');
      rows(cardLeak, 'recurringPlans').first['cardId'] = rows(
        cardLeak,
        'cards',
      ).first['cardId'];
      expect(
        () => projectWith(cardLeak, {'bank.kb'}),
        throwsA(isA<SnapshotContractException>()),
      );
    });

    test('2 an opposite reference that does not exist is a contract error, not "not connected"', () {
      final source = readSource('alpha-ready');
      rows(source, 'transactions').firstWhere(
        (t) => t['recordKind'] == 'card_purchase',
      )['accountId'] = 'aaaaaaaa-0000-4000-8000-000000000002';
      expect(
        () => projectWith(source, {..._banks, ..._cards}),
        throwsA(
          isA<SnapshotContractException>().having(
            (e) => e.where,
            'where',
            'transactions.accountId',
          ),
        ),
      );
      final related = readSource('refund-outside-window');
      rows(related, 'relatedTransactions').first['accountId'] =
          'aaaaaaaa-0000-4000-8000-000000000003';
      expect(
        () => projectWith(related, {..._banks, ..._cards}),
        throwsA(isA<SnapshotContractException>()),
      );
    });

    test(
      '3 an override pinned to another plan\'s existing revision is refused',
      () {
        final source = readSource('gamma-month-end');
        final revision = rows(source, 'recurringPlanRevisions').first;
        const otherPlan = 'aaaaaaaa-0000-4000-8000-000000000010';
        const otherRevision = 'aaaaaaaa-0000-4000-8000-000000000011';
        (source['recurringPlans'] as List).add({
          'userId': source['userId'],
          'planId': otherPlan,
          'firstOccurrenceMonth': '2027-01',
        });
        (source['recurringPlanRevisions'] as List).add({
          ...revision,
          'revisionId': otherRevision,
          'planId': otherPlan,
        });
        expect(
          () => projectWith(source, {..._banks, ..._cards}),
          returnsNormally,
          reason: '대조군: 다른 계획과 그 버전을 더한 원본은 정상',
        );
        rows(source, 'occurrenceOverrides').first['planRevisionId'] =
            otherRevision;
        expect(
          () => projectWith(source, {..._banks, ..._cards}),
          throwsA(
            isA<SnapshotContractException>().having(
              (e) => e.where,
              'where',
              'occurrenceOverrides.planRevisionId',
            ),
          ),
        );
      },
    );

    test('linking an institution the user was not offered is refused', () {
      expect(
        () => projectWith(readSource('alpha-ready'), {'bank.unknown'}),
        throwsA(isA<SnapshotContractException>()),
      );
    });
  });

  group('response parser', () {
    test('4 connected API response missing a required array or the restriction list is refused', () {
      final source = readSource('alpha-ready');
      final full = projectWith(source, {..._banks, ..._cards});
      expect(() => FinancialSnapshot.fromJson(full), returnsNormally);

      expect(
        () => FinancialSnapshot.fromJson(Map.of(full)..remove('accounts')),
        throwsA(isA<SnapshotFormatException>()),
      );
      final partial = projectWith(source, {'bank.kb'});
      expect(
        () => FinancialSnapshot.fromJson(
          Map.of(partial)..remove('accessRestrictions'),
        ),
        throwsA(isA<SnapshotFormatException>()),
        reason: '제한 목록이 사라지면 숨긴 자료가 있다는 사실을 알 수 없음',
      );
      final before = projectWith(source, {}, version: '1');
      expect(() => FinancialSnapshot.fromJson(before), returnsNormally);
      expect(
        () => FinancialSnapshot.fromJson(Map.of(before)..['accounts'] = []),
        throwsA(isA<SnapshotFormatException>()),
        reason: '연결 전 응답에는 금융 키가 없어야 함',
      );
    });

    test('connected API response with null or wrongly typed required values is refused', () {
      final full = projectWith(readSource('alpha-ready'), {
        ..._banks,
        ..._cards,
      });
      for (final (key, value) in [
        ('settings', null),
        ('page', null),
        ('accounts', null),
        ('settings', <Object?>[]),
        ('page', 'x'),
        ('accessRestrictions', <String, Object?>{}),
      ]) {
        expect(
          () => FinancialSnapshot.fromJson(Map.of(full)..[key] = value),
          throwsA(isA<SnapshotFormatException>()),
          reason: '$key=$value',
        );
      }
    });

    test('source missing a base array or holding a null connected key is a contract error', () {
      final cases = <String, void Function(Map<String, Object?>)>{
        'institutions missing': (src) => src.remove('institutions'),
        'coverage null': (src) => src['coverage'] = null,
        'settings null': (src) => src['settings'] = null,
        'page missing': (src) => src.remove('page'),
      };
      cases.forEach((name, mutate) {
        final source = readSource('alpha-ready');
        mutate(source);
        expect(
          () => projectWith(source, {'bank.kb'}),
          throwsA(isA<SnapshotContractException>()),
          reason: '$name (연결 후)',
        );
        expect(
          () => SnapshotProjector.validate(source),
          throwsA(isA<SnapshotContractException>()),
          reason: '$name (원본 검증)',
        );
      });
      final unconnected = readSource('alpha-unconnected');
      expect(() => projectWith(unconnected, const {}), returnsNormally);
      expect(
        () => SnapshotProjector.validate(unconnected),
        throwsA(isA<SnapshotContractException>()),
        reason: '서버는 연결할 수 없는 원본을 열지 않음',
      );
    });

    test('5 a restriction whose owner is not a public object is refused', () {
      final source = readSource('alpha-ready');
      final kbOnly = projectWith(source, {'bank.kb'});
      expect(rows(kbOnly, 'cards'), isEmpty);
      final hiddenCard = rows(source, 'cards').first['cardId'];
      final forged = Map.of(kbOnly)
        ..['accessRestrictions'] = [
          ...rows(kbOnly, 'accessRestrictions'),
          {
            'ownerType': 'card',
            'ownerId': hiddenCard,
            'field': 'withdrawalAccountId',
            'targetKind': 'account',
            'reason': 'not_connected',
          },
        ];
      expect(
        () => FinancialSnapshot.fromJson(forged),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('all 1,536 valid institution subsets (3 accounts x 2^9) still project and parse', () {
      final codes = [..._banks, ..._cards];
      var checked = 0;
      for (final stem in ['alpha-ready', 'beta-ready', 'gamma-month-end']) {
        final source = readSource(stem);
        for (var mask = 0; mask < (1 << codes.length); mask++) {
          final subset = {
            for (var i = 0; i < codes.length; i++)
              if (mask & (1 << i) != 0) codes[i],
          };
          final out = projectWith(source, subset);
          FinancialSnapshot.fromJson(out);
          checked++;
        }
      }
      expect(checked, 1536);
    });
  });
}
