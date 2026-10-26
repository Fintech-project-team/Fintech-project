import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot_repository.dart';
import 'package:payse/data/fixture_scenario.dart';
import 'package:payse/data/snapshot_source.dart';

/// 2026-10-20: 고정 원문을 돌려주거나 오류를 내는 테스트용 출처.
class _MemorySource implements SnapshotSource {
  /// 2026-10-20: 돌려줄 [raw] 또는 던질 [error]로 만든다.
  _MemorySource({this.raw, this.error});

  final String? raw;
  final Object? error;

  /// 2026-10-20: [scenario]와 무관하게 정해진 원문을 반환하거나 오류를 던진다.
  @override
  Future<String> load(FixtureScenario scenario) async {
    if (error != null) throw error!;
    return raw!;
  }
}

/// 2026-10-20: 모든 요청에 실패하는 에셋 묶음(에셋 누락 재현용).
class _MissingAssetBundle extends CachingAssetBundle {
  /// 2026-10-20: [key] 요청에 항상 FlutterError를 던진다.
  @override
  Future<ByteData> load(String key) async =>
      throw Exception('Unable to load asset: $key');
}

/// 2026-10-20: 계약 최소 필드를 갖춘 정상 스냅샷 맵을 반환한다. 테스트마다 일부를 바꿔 쓴다.
Map<String, Object?> _minimalSnapshot() => {
  'userId': 'u-1',
  'schemaVersion': 'PAYSE-DRAFT-3',
  'currency': 'KRW',
  'dataVersion': '7',
  'sourceVersion': 'src-7',
  'ruleVersion': 'PAYSE-CALC-1',
  'asOf': '2026-10-19T12:00:00+09:00',
  'institutions': <Object?>[],
  'institutionLinks': <Object?>[],
  'coverage': <Object?>[],
  'accounts': [
    {
      'accountId': 'a-1',
      'institutionCode': 'bank.kb',
      'productType': 'demand',
      'productName': '합성 입출금',
      'maskedNumber': '***-0001',
      'balanceKRW': 0,
      'asOf': '2026-10-19T12:00:00+09:00',
      'included': true,
      'nickname': null,
    },
  ],
  'cards': <Object?>[],
  'transactions': <Object?>[],
};

/// 2026-10-20: [json]을 원문으로 쓰는 Repository로 한 번 조회한 결과를 반환한다.
Future<SnapshotLoadResult> _loadRaw(String raw) =>
    FakeFinancialSnapshotRepository(source: _MemorySource(raw: raw))
        .loadSnapshot();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('real assets through AssetSnapshotSource', () {
    final source = AssetSnapshotSource(rootBundle);

    test('alpha-ready keeps integer amounts, as-of and versions', () async {
      final result = await FakeFinancialSnapshotRepository(source: source)
          .loadSnapshot();

      final snapshot = (result as SnapshotLoaded).snapshot;
      expect(snapshot.asOf, '2026-10-19T12:00:00+09:00');
      expect(snapshot.dataVersion, '1');
      expect(snapshot.sourceVersion, 'fixture-3:alpha:2026-10-19:base');
      expect(snapshot.ruleVersion, 'PAYSE-CALC-1');
      expect(snapshot.accounts, hasLength(6));
      expect(snapshot.cards, hasLength(4));
      expect(snapshot.transactions, hasLength(193));
      expect(snapshot.accounts!.first.balanceKrw, 1500000);
      expect(snapshot.accounts!.first.nickname, isNull);
      expect(
        snapshot.transactions!.where((t) => t.accountId == null),
        isNotEmpty,
        reason: '카드 거래의 계좌 null을 빈 문자열이나 다른 값으로 바꾸지 않는다',
      );
    });

    test('alpha-unconnected keeps absent bundles as null, not empty', () async {
      final result = await FakeFinancialSnapshotRepository(
        source: source,
        scenario: FixtureScenario.alphaUnconnected,
      ).loadSnapshot();

      final snapshot = (result as SnapshotLoaded).snapshot;
      expect(snapshot.accounts, isNull);
      expect(snapshot.cards, isNull);
      expect(snapshot.transactions, isNull);
      expect(snapshot.institutions, hasLength(9));
      expect(snapshot.institutionLinkCount, 0);
    });

    for (final scenario in FixtureScenario.values) {
      test('${scenario.fileStem} parses without format errors', () async {
        final result = await FakeFinancialSnapshotRepository(
          source: source,
          scenario: scenario,
        ).loadSnapshot();
        expect(result, isA<SnapshotLoaded>());
      });
    }
  });

  group('load failures stay distinct from data', () {
    test('missing asset becomes SnapshotLoadFailed', () async {
      final result = await FakeFinancialSnapshotRepository(
        source: AssetSnapshotSource(_MissingAssetBundle()),
      ).loadSnapshot();
      expect(result, isA<SnapshotLoadFailed>());
    });

    test('source error becomes SnapshotLoadFailed', () async {
      final result = await FakeFinancialSnapshotRepository(
        source: _MemorySource(error: Exception('network down')),
      ).loadSnapshot();
      expect(result, isA<SnapshotLoadFailed>());
    });
  });

  group('format errors are reported with the field path', () {
    test('broken JSON', () async {
      final result = await _loadRaw('{"userId": ');
      expect(result, isA<SnapshotFormatInvalid>());
      expect((result as SnapshotFormatInvalid).path, r'$');
    });

    test('missing required field', () async {
      final json = _minimalSnapshot()..remove('userId');
      final result = await _loadRaw(jsonEncode(json));
      expect((result as SnapshotFormatInvalid).path, r'$.userId');
    });

    test('non-integer amount is rejected, not rounded', () async {
      final json = _minimalSnapshot();
      (json['accounts']! as List).first['balanceKRW'] = 1500.5;
      final result = await _loadRaw(jsonEncode(json));
      expect(
        (result as SnapshotFormatInvalid).path,
        r'$.accounts[0].balanceKRW',
      );
    });

    test('as-of without offset is rejected', () async {
      final json = _minimalSnapshot()..['asOf'] = '2026-10-19T12:00:00';
      final result = await _loadRaw(jsonEncode(json));
      expect((result as SnapshotFormatInvalid).path, r'$.asOf');
    });

    test('non-KRW currency is rejected', () async {
      final json = _minimalSnapshot()..['currency'] = 'USD';
      final result = await _loadRaw(jsonEncode(json));
      expect((result as SnapshotFormatInvalid).path, r'$.currency');
    });

    test('accounts that is not an array is rejected', () async {
      final json = _minimalSnapshot()..['accounts'] = {'a': 1};
      final result = await _loadRaw(jsonEncode(json));
      expect((result as SnapshotFormatInvalid).path, r'$.accounts');
    });
  });

  group('values are preserved, never corrected', () {
    test('zero balance stays 0 and null balance stays null', () async {
      final json = _minimalSnapshot();
      final accounts = json['accounts']! as List;
      accounts.add(<String, Object?>{
        ...(accounts.first as Map<String, Object?>),
        'accountId': 'a-2',
        'balanceKRW': null,
      });

      final snapshot =
          ((await _loadRaw(jsonEncode(json))) as SnapshotLoaded).snapshot;
      expect(snapshot.accounts![0].balanceKrw, 0);
      expect(snapshot.accounts![1].balanceKrw, isNull);
    });

    test('empty array stays empty, distinct from absent key', () async {
      final json = _minimalSnapshot()..remove('cards');
      final snapshot =
          ((await _loadRaw(jsonEncode(json))) as SnapshotLoaded).snapshot;
      expect(snapshot.transactions, isEmpty);
      expect(snapshot.cards, isNull);
    });
  });

  group('strengthened date and value checks', () {
    /// 2026-10-20: 거래 1건과 조회 범위 1건을 넣은 정상 스냅샷을 반환한다.
    Map<String, Object?> withTransaction() {
      final json = _minimalSnapshot();
      json['transactions'] = [
        <String, Object?>{
          'transactionId': 't-1',
          'accountId': 'a-1',
          'cardId': null,
          'recordKind': 'account_entry',
          'amountKRW': 4500,
          'direction': 'out',
          'status': 'posted',
          'merchantName': '합성 가맹점',
          'bookingDate': '2026-10-18',
          'purchaseDate': null,
          'withdrawalDate': null,
          'payseTransactionType': 'expense',
        },
      ];
      json['coverage'] = [
        <String, Object?>{
          'targetKind': 'account',
          'targetId': 'a-1',
          'status': 'complete',
          'requestedStart': '2025-10-20',
          'requestedEnd': '2026-10-19',
        },
      ];
      return json;
    }

    /// 2026-10-20: [json]을 조회해 형식 오류이면 그 결과를, 아니면 실패를 반환한다.
    Future<SnapshotFormatInvalid> invalid(Map<String, Object?> json) async {
      final result = await _loadRaw(jsonEncode(json));
      expect(result, isA<SnapshotFormatInvalid>());
      return result as SnapshotFormatInvalid;
    }

    Map<String, Object?> tx(Map<String, Object?> json) =>
        (json['transactions']! as List).first as Map<String, Object?>;

    test('valid sample with dates still loads', () async {
      expect(
        await _loadRaw(jsonEncode(withTransaction())),
        isA<SnapshotLoaded>(),
      );
    });

    test('impossible calendar date is rejected', () async {
      final json = withTransaction();
      tx(json)['bookingDate'] = '2026-02-30';
      final e = await invalid(json);
      expect(e.path, r'$.transactions[0].bookingDate');
      expect(e.reason, contains('YYYY-MM-DD'));
    });

    test('slash-formatted date is rejected', () async {
      final json = withTransaction();
      (json['coverage']! as List).first['requestedEnd'] = '2026/10/19';
      final e = await invalid(json);
      expect(e.path, r'$.coverage[0].requestedEnd');
    });

    test('date with a time part is rejected for a business date', () async {
      final json = withTransaction();
      tx(json)['purchaseDate'] = '2026-10-18T00:00:00+09:00';
      final e = await invalid(json);
      expect(e.path, r'$.transactions[0].purchaseDate');
    });

    test('account as-of without offset is rejected', () async {
      final json = withTransaction();
      (json['accounts']! as List).first['asOf'] = '2026-10-19 12:00';
      final e = await invalid(json);
      expect(e.path, r'$.accounts[0].asOf');
      expect(e.reason, contains('오프셋'));
    });

    test(
      'negative transaction amount is rejected, negative balance is kept',
      () async {
        final negativeTx = withTransaction();
        tx(negativeTx)['amountKRW'] = -4500;
        final e = await invalid(negativeTx);
        expect(e.path, r'$.transactions[0].amountKRW');
        expect(e.reason, contains('음수 불가'));

        final negativeBalance = withTransaction();
        (negativeBalance['accounts']! as List).first['balanceKRW'] = -120000;
        final loaded =
            (await _loadRaw(jsonEncode(negativeBalance))) as SnapshotLoaded;
        expect(loaded.snapshot.accounts!.first.balanceKrw, -120000);
      },
    );

    test('amount above the contract cap is rejected', () async {
      final json = withTransaction();
      tx(json)['amountKRW'] = 9000000000001;
      final e = await invalid(json);
      expect(e.reason, contains('상한 초과'));
    });

    test('transaction with neither account nor card is rejected', () async {
      final json = withTransaction();
      tx(json)['accountId'] = null;
      final e = await invalid(json);
      expect(e.reason, contains('적어도 하나'));
    });

    test('messages tell missing field apart from wrong type', () async {
      final missing = withTransaction();
      tx(missing).remove('merchantName');
      expect((await invalid(missing)).reason, contains('필수 필드 없음'));

      final wrongType = withTransaction();
      tx(wrongType)['merchantName'] = 12;
      expect((await invalid(wrongType)).reason, contains('실제: 정수'));
    });
  });
}
