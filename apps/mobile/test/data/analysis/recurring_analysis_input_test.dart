import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/analysis/analysis_identity.dart';
import 'package:payse/data/analysis/recurring_analysis_input.dart';
import 'package:payse/data/analysis/recurring_source.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

/// 2026-11-05: A의 분석 HTTP 계약. 만든 입력·접수 본문을 이 스키마로 직접 검사한다.
final Map<String, dynamic> _schema = jsonDecode(
  File('../api/contracts/analysis-http.schema.json').readAsStringSync(),
) as Map<String, dynamic>;

/// 2026-11-05: v4 더미 스냅샷 파일 전체.
final List<File> _snapshots =
    Directory('../api/fixtures/generated-v4/snapshots')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

/// 2026-11-05: v4 더미 [stem]을 스냅샷으로 읽는다.
FinancialSnapshot _read(String stem) => FinancialSnapshot.fromJson(
  jsonDecode(
    File('../api/fixtures/generated-v4/snapshots/$stem.json')
        .readAsStringSync(),
  ),
);

/// 2026-11-05: 스냅샷 [s]의 첫 페이지 거래로 탐지·입력 준비까지 한다.
RecurringAnalysisPlan _plan(FinancialSnapshot s, {String trigger = 'A'}) {
  final transactions = s.transactions ?? const <SourceTransaction>[];
  final detection = calc.detectRecurring(
    recurringInputFromSnapshot(
      snapshot: s,
      transactions: transactions,
      coverage: s.coverage,
    ),
  );
  return planRecurringAnalysis(
    snapshot: s,
    detection: detection,
    transactions: transactions,
    localSessionEpoch: 3,
    triggerKind: trigger,
  );
}

/// 2026-11-05: 스키마 [schema]에 맞지 않는 곳을 [path]부터 모아 반환한다. 이 계약이 쓰는 키워드만 다룬다
/// (type·enum·pattern·길이·범위·required·additionalProperties·items·$ref·oneOf).
List<String> _violations(
  Object? value,
  Map<String, dynamic> schema,
  String path,
) {
  final ref = schema[r'$ref'] as String?;
  if (ref != null) {
    final name = ref.split('/').last;
    return _violations(
      value,
      _schema[r'$defs'][name] as Map<String, dynamic>,
      path,
    );
  }
  final oneOf = schema['oneOf'] as List?;
  if (oneOf != null) {
    final passing = oneOf
        .where(
          (s) => _violations(value, s as Map<String, dynamic>, path).isEmpty,
        )
        .length;
    return passing == 1 ? [] : ['$path: oneOf 통과 $passing개'];
  }
  final out = <String>[];
  final type = schema['type'];
  final types = type is List
      ? type.cast<String>()
      : [if (type != null) type as String];
  bool isType(String t) => switch (t) {
    'object' => value is Map,
    'array' => value is List,
    'string' => value is String,
    'integer' => value is int,
    'boolean' => value is bool,
    'null' => value == null,
    _ => false,
  };
  if (types.isNotEmpty && !types.any(isType)) {
    return ['$path: 타입 $types 아님($value)'];
  }
  final allowed = schema['enum'] as List?;
  if (allowed != null && !allowed.contains(value)) {
    out.add('$path: enum 밖 $value');
  }
  if (value is String) {
    final pattern = schema['pattern'] as String?;
    if (pattern != null && !RegExp(pattern).hasMatch(value)) {
      out.add('$path: pattern');
    }
    if ((schema['minLength'] as int?) case final min? when value.length < min) {
      out.add('$path: 너무 짧음');
    }
  }
  if (value is int) {
    if ((schema['minimum'] as int?) case final min? when value < min) {
      out.add('$path: 최소값');
    }
    if ((schema['maximum'] as int?) case final max? when value > max) {
      out.add('$path: 최대값');
    }
  }
  if (value is List) {
    if ((schema['minItems'] as int?) case final min? when value.length < min) {
      out.add('$path: 항목 부족');
    }
    if ((schema['maxItems'] as int?) case final max? when value.length > max) {
      out.add('$path: 항목 초과');
    }
    final items = schema['items'] as Map<String, dynamic>?;
    if (items != null) {
      for (var i = 0; i < value.length; i++) {
        out.addAll(_violations(value[i], items, '$path[$i]'));
      }
    }
  }
  if (value is Map) {
    final props = (schema['properties'] as Map<String, dynamic>?) ?? const {};
    for (final key in (schema['required'] as List?) ?? const []) {
      if (!value.containsKey(key)) out.add('$path.$key: 필수 누락');
    }
    for (final entry in value.entries) {
      final sub = props[entry.key] as Map<String, dynamic>?;
      if (sub == null) {
        if (schema['additionalProperties'] == false) {
          out.add('$path.${entry.key}: 허용 안 됨');
        }
      } else {
        out.addAll(_violations(entry.value, sub, '$path.${entry.key}'));
      }
    }
  }
  return out;
}

/// 2026-11-05: 공개 스키마 정의 [name]에 [value]가 맞는지 검사한다.
void _expectSchema(Object? value, String name) => expect(
  _violations(value, _schema[r'$defs'][name] as Map<String, dynamic>, r'$'),
  isEmpty,
  reason: name,
);

/// 2026-11-05: 테스트용 v4 스냅샷 JSON. demo-life에서 계좌·카드·조회 범위를 두고 거래·관계만 바꾼다.
Map<String, Object?> _base({
  required List<Map<String, Object?>> transactions,
  List<Map<String, Object?>> relations = const [],
  List<Map<String, Object?>>? coverage,
  List<Map<String, Object?>> resolutions = const [],
}) {
  final json = jsonDecode(
    File('../api/fixtures/generated-v4/snapshots/demo-life.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  json['transactions'] = transactions;
  json['transactionRelations'] = relations;
  json['referenceResolutions'] = resolutions;
  if (coverage != null) json['coverage'] = coverage;
  return json.cast<String, Object?>();
}

void main() {
  final life = _read('demo-life');
  final accountId = life.accounts!.first.accountId;
  final cardId = life.cards!.first.cardId;
  final template =
      (jsonDecode(
                    File(
                      '../api/fixtures/generated-v4/snapshots/demo-life.json',
                    ).readAsStringSync(),
                  )['transactions']
                  as List)
              .first
          as Map<String, dynamic>;

  /// 2026-11-05: [id] 거래를 [overrides]로 바꾼 원천 거래 JSON을 만든다.
  Map<String, Object?> tx(String id, Map<String, Object?> overrides) => {
    ...template,
    'transactionId': id,
    'accountId': accountId,
    'cardId': null,
    'recordKind': 'account_entry',
    'direction': 'out',
    'status': 'posted',
    'amountKRW': 55000,
    'merchantName': '하늘텔레콤',
    'description': null,
    'purchaseDate': null,
    'withdrawalDate': null,
    'bookingDate': null,
    'refundDate': null,
    'cancellationDate': null,
    'occurredAt': null,
    'occurredAtBasis': null,
    'originalTransactionId': null,
    'payseTransactionType': 'expense',
    'reflectionReason': 'reflected',
    'sourceVersion': life.sourceVersion,
    ...overrides,
  };

  /// 2026-11-05: 0부터 [n]번째 거래 ID(UUID 형식).
  String id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

  group('every v4 fixture', () {
    for (final file in _snapshots) {
      final stem = file.uri.pathSegments.last.replaceAll('.json', '');
      test('$stem builds schema-valid input and accept bodies', () {
        final s = _read(stem);
        final plan = _plan(s);
        final candidates = plan.batches.expand(
          (b) => b.candidateByItemKey.values,
        );
        expect(
          {...candidates, ...plan.notAnalyzed.map((n) => n.candidate.key)},
          plan.detection.candidates.map((c) => c.key).toSet(),
          reason: '후보는 묶음이나 분석하지 못한 목록 중 한 곳에 꼭 있다',
        );
        for (final batch in plan.batches) {
          _expectSchema(batch.input, 'recurringInput');
          _expectSchema({
            ...batch.accept,
            'idempotencyKey': 'test-key',
          }, 'acceptRequest');
          expect(
            batch.accept['inputHashHint'],
            identifyAnalysisInput(batch.input).inputHashHint,
          );
          expect(batch.accept['triggerKind'], 'A');
          expect(batch.accept['context'], batch.input['context']);
        }
        expect(
          canonicalJson([for (final b in _plan(s).batches) b.input]),
          canonicalJson([for (final b in plan.batches) b.input]),
          reason: '같은 스냅샷은 같은 입력',
        );
      });
    }
  });

  test('the schema check itself rejects broken bodies', () {
    final input = _plan(life).batches.single.input;
    final noDescription = jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
    ((noDescription['transactions'] as List).first as Map).remove(
      'description',
    );
    final stringAmount = jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
    ((stringAmount['candidates'] as List).first as Map)['suggestedAmountKRW'] =
        '55000';
    final extra = {...input, 'note': 1};
    final def = _schema[r'$defs']['recurringInput'] as Map<String, dynamic>;
    expect(
      _violations(noDescription, def, r'$'),
      isNotEmpty,
      reason: '필수 nullable 누락',
    );
    expect(_violations(stringAmount, def, r'$'), isNotEmpty, reason: '금액은 정수');
    expect(_violations(extra, def, r'$'), isNotEmpty, reason: '추가 필드');
  });

  test(
    'demo-life input carries snapshot context and its own evidence only',
    () {
      final plan = _plan(life);
      expect(plan.batches, hasLength(1));
      final batch = plan.batches.single;
      final context = batch.input['context'] as Map;
      expect(context['schemaVersion'], 'PAYSE-API-0.6-4');
      expect(context['dataVersion'], life.dataVersion);
      expect(context['sourceVersion'], life.sourceVersion);
      expect(context['ruleVersion'], life.ruleVersion);
      expect(context['asOf'], life.asOf, reason: '기기 시각으로 바꾸지 않음');
      expect(context['localSessionEpoch'], 3);
      expect(context['inputRevision'], 0);
      expect(
        context['selectedAccountIds'],
        [
          for (final a in life.accounts!)
            if (a.included) a.accountId,
        ]..sort(),
      );

      final byId = {for (final t in life.transactions!) t.transactionId: t};
      final sent = {
        for (final row in batch.input['transactions'] as List)
          (row as Map)['transactionId'] as String: row,
      };
      for (final item in batch.input['items'] as List) {
        final ids = (item as Map)['evidenceTransactionIds'] as List;
        expect(sent.keys, containsAll(ids));
        final candidate = (batch.input['candidates'] as List).firstWhere(
          (c) => (c as Map)['candidateKey'] == item['candidateKey'],
        ) as Map;
        expect(candidate['evidenceTransactionIds'], ids);
        expect(candidate['ruleVersion'], life.ruleVersion);
        expect(candidate['sourceVersion'], life.sourceVersion);
        expect(batch.candidateByItemKey[item['itemKey']], item['candidateKey']);
      }
      for (final MapEntry(:key, :value) in sent.entries) {
        final source = byId[key]!;
        expect(value['merchantName'], source.merchantName);
        expect(value['description'], source.description);
        expect(value['reflectionReason'], source.reflectionReason);
      }
      expect(
        {
          for (final c in batch.input['currentClassifications'] as List)
            (c as Map)['transactionId']: c['value'],
        },
        {
          for (final key in sent.keys)
            if (byId[key]!.payseTransactionType != null)
              key: byId[key]!.payseTransactionType,
        },
      );
      for (final r in batch.input['relations'] as List) {
        expect(sent.keys, containsAll([(r as Map)['fromId'], r['toId']]));
      }
      final names = plan.detection.candidates.map((c) => c.normalizedName);
      expect(names, contains('하늘텔레콤'));
    },
  );

  group('recurring source mapping', () {
    test('uses withdrawal and purchase dates, never booking dates', () {
      final s = FinancialSnapshot.fromJson(
        _base(
          transactions: [
            tx(id(1), {
              'withdrawalDate': '2026-10-20',
              'bookingDate': '2026-10-19',
            }),
            tx(id(2), {'withdrawalDate': null, 'bookingDate': '2026-10-19'}),
            tx(id(3), {
              'accountId': null,
              'cardId': cardId,
              'recordKind': 'card_purchase',
              'status': 'approved',
              'purchaseDate': '2026-10-11',
            }),
            tx(id(4), {'direction': 'in', 'bookingDate': '2026-10-02'}),
          ],
        ),
      );
      final entries = {
        for (final e in recurringInputFromSnapshot(
          snapshot: s,
          transactions: s.transactions!,
          coverage: s.coverage,
        ).entries)
          e.id: e,
      };
      expect(entries[id(1)]!.date.toString(), '2026-10-20');
      expect(entries[id(1)]!.kind, calc.RecurringEntryKind.accountOutflow);
      expect(entries[id(2)]!.date, isNull, reason: '기장일로 채우지 않음');
      expect(entries[id(3)]!.date.toString(), '2026-10-11');
      expect(entries[id(3)]!.instrumentId, cardId);
      expect(entries[id(3)]!.confirmed, isTrue);
      expect(entries[id(4)]!.kind, calc.RecurringEntryKind.other);
    });

    test('excludes only explicit transfers, card bills and the paired account side', () {
      final s = FinancialSnapshot.fromJson(
        _base(
          transactions: [
            tx(id(1), {'withdrawalDate': '2026-10-01'}),
            tx(id(2), {
              'withdrawalDate': '2026-10-01',
              'payseTransactionType': 'card_payment',
            }),
            tx(id(3), {
              'withdrawalDate': '2026-10-01',
              'payseTransactionType': null,
            }),
            tx(id(4), {'withdrawalDate': '2026-10-01'}),
            tx(id(5), {
              'accountId': null,
              'cardId': cardId,
              'recordKind': 'card_purchase',
              'status': 'posted',
              'purchaseDate': '2026-10-01',
            }),
            tx(id(6), {
              'accountId': null,
              'cardId': cardId,
              'recordKind': 'card_refund',
              'direction': 'in',
              'refundDate': '2026-10-03',
              'originalTransactionId': id(5),
            }),
          ],
          relations: [
            {
              'kind': 'internal_transfer',
              'fromId': id(3),
              'toId': id(1),
              'evidenceRef': 'test',
            },
            {
              'kind': 'card_account_pair',
              'fromId': id(5),
              'toId': id(4),
              'evidenceRef': 'test',
            },
          ],
        ),
      );
      final entries = {
        for (final e in recurringInputFromSnapshot(
          snapshot: s,
          transactions: s.transactions!,
          coverage: s.coverage,
        ).entries)
          e.id: e,
      };
      expect(
        entries[id(1)]!.exclusion,
        calc.RecurringExclusion.internalTransfer,
      );
      expect(
        entries[id(3)]!.exclusion,
        calc.RecurringExclusion.internalTransfer,
      );
      expect(
        entries[id(2)]!.exclusion,
        calc.RecurringExclusion.cardBillPayment,
      );
      expect(entries[id(4)]!.exclusion, calc.RecurringExclusion.duplicate);
      expect(entries[id(5)]!.exclusion, isNull, reason: '카드 쪽을 남긴다');
      expect(entries[id(6)]!.kind, calc.RecurringEntryKind.reversal);
      expect(entries[id(6)]!.originalId, id(5));
      expect(entries[id(6)]!.date.toString(), '2026-10-03');
    });

    test('coverage keeps only known complete ranges', () {
      Map<String, Object?> range(
        String status,
        List<Map<String, String>> missing,
      ) => {
        'targetKind': 'account',
        'targetId': accountId,
        'requestedStart': '2025-11-01',
        'requestedEnd': '2026-10-31',
        'status': status,
        'coveredRanges': const [],
        'missingRanges': missing,
      };
      List<String> ranges(Map<String, Object?> c) {
        final s = FinancialSnapshot.fromJson(
          _base(transactions: const [], coverage: [c]),
        );
        return [
          for (final r in recurringInputFromSnapshot(
            snapshot: s,
            transactions: const [],
            coverage: s.coverage,
          ).coverage)
            '${r.from}~${r.through}:${r.complete}',
        ];
      }

      expect(ranges(range('complete', const [])), [
        '2025-11-01~2026-10-31:true',
      ]);
      expect(
        ranges(
          range('partial', [
            {'start': '2026-03-01', 'end': '2026-03-31'},
          ]),
        ),
        ['2025-11-01~2026-02-28:true', '2026-04-01~2026-10-31:true'],
      );
      expect(ranges(range('partial', const [])), [
        '2025-11-01~2026-10-31:false',
      ]);
      expect(ranges(range('failed', const [])), [
        '2025-11-01~2026-10-31:false',
      ]);
    });
  });

  group('splitting', () {
    /// 2026-11-05: 거래 [ids]를 근거로 하는 계좌 출금 후보를 만든다. 근거 날짜는 서로 다른 달이다.
    calc.RecurringCandidate candidate(
      String key,
      List<String> ids,
      calc.CalculationContext context,
    ) => calc.RecurringCandidate(
      key: key,
      context: context,
      instrumentId: accountId,
      kind: calc.RecurringEntryKind.accountOutflow,
      normalizedName: '하늘텔레콤',
      evidence: [
        for (var i = 0; i < ids.length; i++)
          calc.RecurringEntry(
            id: ids[i],
            instrumentId: accountId,
            kind: calc.RecurringEntryKind.accountOutflow,
            name: '하늘텔레콤',
            date: calc.BusinessDate(2026, 8 + i % 3, 20),
            amountKrw: 55000,
            confirmed: true,
          ),
      ],
      suggestedAmountKrw: 55000,
      suggestedDay: 20,
      amountVaries: false,
    );

    final s = FinancialSnapshot.fromJson(
      _base(
        transactions: [
          for (var n = 0; n < 70; n++)
            tx(id(n), {'withdrawalDate': '2026-10-20'}),
        ],
      ),
    );
    final context = calc.CalculationContext(
      dataVersion: s.dataVersion,
      sourceVersion: s.sourceVersion,
      ruleVersion: s.ruleVersion,
      asOf: s.asOf,
      inputRevision: 0,
    );

    /// 2026-11-05: [candidates]만 있는 탐지 결과로 입력을 준비한다.
    RecurringAnalysisPlan plan(List<calc.RecurringCandidate> candidates) =>
        planRecurringAnalysis(
          snapshot: s,
          detection: calc.RecurringDetection(
            context,
            calc.BusinessDate(2026, 7, 31),
            candidates,
            const [],
          ),
          transactions: s.transactions!,
          localSessionEpoch: 0,
          triggerKind: 'A',
        );

    test('no candidates means no input', () {
      final p = plan(const []);
      expect(p.batches, isEmpty);
      expect(p.notAnalyzed, isEmpty);
    });

    test('21 candidates split at 20 in candidate key order', () {
      final candidates = [
        for (var c = 20; c >= 0; c--)
          candidate('k${c.toString().padLeft(2, '0')}', [
            id(c * 3),
            id(c * 3 + 1),
            id(c * 3 + 2),
          ], context),
      ];
      final p = plan(candidates);
      expect(p.batches.map((b) => b.candidateByItemKey.length), [20, 1]);
      expect(p.batches.first.candidateByItemKey['recurring-0'], 'k00');
      expect(p.batches.last.candidateByItemKey.values, ['k20']);
      for (final b in p.batches) {
        _expectSchema(b.input, 'recurringInput');
      }
    });

    test('a batch never goes over 60 transactions', () {
      final p = plan([
        candidate('a', [for (var n = 0; n < 40; n++) id(n)], context),
        candidate('b', [for (var n = 40; n < 70; n++) id(n)], context),
      ]);
      expect(p.batches, hasLength(2));
      expect(
        [for (final b in p.batches) (b.input['transactions'] as List).length],
        [40, 30],
      );
    });

    test('a single candidate over 60 transactions is held whole', () {
      final p = plan([
        candidate('big', [for (var n = 0; n < 61; n++) id(n)], context),
        candidate('ok', [id(61), id(62), id(63)], context),
      ]);
      expect(p.batches.single.candidateByItemKey.values, ['ok']);
      final held = p.notAnalyzed.single;
      expect(held.candidate.key, 'big');
      expect(held.reason, RecurringNotAnalyzedReason.groupTooLarge);
      expect(held.groupKeys, ['big']);
    });

    /// 2026-11-05: 거래 [rows]·관계 [relations]·서버 미확보 표식 [resolutions]가 있는 스냅샷으로 [candidates]를 준비한다.
    RecurringAnalysisPlan planWith(
      List<calc.RecurringCandidate> candidates, {
      List<Map<String, Object?>>? rows,
      List<Map<String, Object?>> relations = const [],
      List<Map<String, Object?>> resolutions = const [],
      SourceTransaction Function(SourceTransaction)? edit,
    }) {
      final snapshot = FinancialSnapshot.fromJson(
        _base(
          transactions:
              rows ??
              [
                for (var n = 0; n < 70; n++)
                  tx(id(n), {'withdrawalDate': '2026-10-20'}),
              ],
          relations: relations,
          resolutions: resolutions,
        ),
      );
      return planRecurringAnalysis(
        snapshot: snapshot,
        detection: calc.RecurringDetection(
          context,
          calc.BusinessDate(2026, 7, 31),
          candidates,
          const [],
        ),
        transactions: [
          for (final t in snapshot.transactions!) edit == null ? t : edit(t),
        ],
        localSessionEpoch: 0,
        triggerKind: 'A',
      );
    }

    /// 2026-11-05: [from]·[to]를 잇는 card_account_pair 관계.
    Map<String, Object?> pair(int from, int to) => {
      'kind': 'card_account_pair',
      'fromId': id(from),
      'toId': id(to),
      'evidenceRef': 'test',
    };

    test('candidates sharing expanded evidence stay in one job', () {
      // 재현 사례: 계좌 출금 99가 a의 10월분(2)과 z의 10월분(62) 양쪽과 같은 사건으로 연결된다.
      // 그 사이 순서의 후보 19개 때문에 예전에는 a와 z가 서로 다른 작업으로 갈렸다.
      final rows = [
        for (var n = 0; n < 70; n++)
          tx(id(n), {'withdrawalDate': '2026-10-20'}),
        tx(id(99), {'withdrawalDate': '2026-10-20'}),
      ];
      final candidates = [
        candidate('a', [id(0), id(1), id(2)], context),
        for (var m = 1; m < 20; m++)
          candidate('m${m.toString().padLeft(2, '0')}', [
            id(m * 3),
            id(m * 3 + 1),
            id(m * 3 + 2),
          ], context),
        candidate('z', [id(60), id(61), id(62)], context),
      ];
      final p = planWith(
        candidates,
        rows: rows,
        relations: [pair(2, 99), pair(62, 99)],
      );
      expect(p.notAnalyzed, isEmpty);
      final together = p.batches.where(
        (b) => b.candidateByItemKey.values.contains('a'),
      );
      expect(
        together.single.candidateByItemKey.values,
        containsAll(['a', 'z']),
      );
      expect(
        p.batches.where((b) => b.candidateByItemKey.values.contains('z')),
        hasLength(1),
      );
      final shared = [id(2), id(62), id(99)];
      expect(
        p.batches.where(
          (b) => (b.input['transactions'] as List).any(
            (t) => shared.contains((t as Map)['transactionId']),
          ),
        ),
        hasLength(1),
        reason: '공유 거래는 한 작업에만 들어간다',
      );
      expect(
        [for (final b in p.batches) b.candidateByItemKey.length],
        [19, 2],
        reason: 'a·z 그룹(거래 7개)부터 채우고, 거래 60개를 넘기 직전에 다음 묶음',
      );
      for (final b in p.batches) {
        _expectSchema(b.input, 'recurringInput');
      }
    });

    test('a–b and b–c chain a, b and c into one group', () {
      final p = planWith(
        [
          candidate('a', [id(0), id(1), id(2)], context),
          candidate('b', [id(3), id(4), id(5)], context),
          candidate('c', [id(6), id(7), id(8)], context),
          candidate('d', [id(9), id(10), id(11)], context),
        ],
        relations: [pair(2, 3), pair(5, 6)],
      );
      expect(p.batches.single.candidateByItemKey.values, ['a', 'b', 'c', 'd']);
      expect((p.batches.single.input['transactions'] as List).length, 12);
    });

    test('a group over the limits is held whole, never split', () {
      // 21개 후보가 관계로 사슬처럼 이어진다.
      final chained = planWith(
        [
          for (var c = 0; c < 21; c++)
            candidate('k${c.toString().padLeft(2, '0')}', [
              id(c * 3),
              id(c * 3 + 1),
              id(c * 3 + 2),
            ], context),
        ],
        relations: [for (var c = 0; c < 20; c++) pair(c * 3 + 2, c * 3 + 3)],
      );
      expect(chained.batches, isEmpty);
      expect(chained.notAnalyzed, hasLength(21));
      expect(chained.notAnalyzed.map((n) => n.reason).toSet(), {
        RecurringNotAnalyzedReason.groupTooLarge,
      });
      expect(chained.notAnalyzed.first.groupKeys, hasLength(21));

      // 후보 2개지만 겹치는 거래를 한 번만 세도 61개다.
      final wide = planWith([
        candidate('a', [for (var n = 0; n < 31; n++) id(n)], context),
        candidate('b', [for (var n = 30; n < 61; n++) id(n)], context),
        candidate('c', [id(61), id(62), id(63)], context),
      ]);
      expect(wide.batches.single.candidateByItemKey.values, ['c']);
      expect(
        {for (final n in wide.notAnalyzed) n.candidate.key: n.reason},
        {
          'a': RecurringNotAnalyzedReason.groupTooLarge,
          'b': RecurringNotAnalyzedReason.groupTooLarge,
        },
      );

      // 겹치는 거래를 한 번만 세면 60개라 보낼 수 있다.
      final fits = planWith([
        candidate('a', [for (var n = 0; n < 31; n++) id(n)], context),
        candidate('b', [for (var n = 30; n < 60; n++) id(n)], context),
      ]);
      expect(fits.notAnalyzed, isEmpty);
      expect((fits.batches.single.input['transactions'] as List).length, 60);
    });

    test('unavailable evidence keeps three separate reasons', () {
      final rows = [
        for (var n = 0; n < 20; n++)
          tx(id(n), {
            'withdrawalDate': '2026-10-20',
            if (n == 3) 'originalTransactionId': id(500),
          }),
      ];
      final p = planWith(
        [
          candidate('missing', [id(0), id(1), id(2)], context),
          candidate('original', [id(3), id(4), id(5)], context),
          candidate('field', [id(6), id(7), id(8)], context),
          candidate('ok', [id(9), id(10), id(11)], context),
          candidate('sharer', [id(12), id(13), id(14)], context),
        ],
        rows: rows,
        relations: [pair(2, 400), pair(14, 600)],
        // v4 파서는 reflectionReason 누락을 거절하므로, 앱 안에서 만든 거래 객체로 누락을 재현한다.
        edit: (t) => t.transactionId != id(6)
            ? t
            : SourceTransaction(
                transactionId: t.transactionId,
                accountId: t.accountId,
                cardId: t.cardId,
                recordKind: t.recordKind,
                amountKrw: t.amountKrw,
                direction: t.direction,
                status: t.status,
                merchantName: t.merchantName,
                bookingDate: t.bookingDate,
                purchaseDate: t.purchaseDate,
                withdrawalDate: t.withdrawalDate,
                payseTransactionType: t.payseTransactionType,
              ),
        resolutions: [
          {
            'transactionId': id(500),
            'status': 'unavailable',
            'reason': 'outside_retention',
          },
          {
            'transactionId': id(600),
            'status': 'unavailable',
            'reason': 'not_provided',
          },
        ],
      );
      expect(p.batches.single.candidateByItemKey.values, ['ok']);
      final byKey = {for (final n in p.notAnalyzed) n.candidate.key: n};
      expect(
        byKey['missing']!.reason,
        RecurringNotAnalyzedReason.transactionNotReceived,
      );
      expect(byKey['missing']!.transactionIds, [id(400)]);
      expect(
        byKey['original']!.reason,
        RecurringNotAnalyzedReason.originalUnavailable,
      );
      expect(
        byKey['original']!.serverReason,
        'outside_retention',
        reason: '서버 사유 원문',
      );
      expect(byKey['original']!.transactionIds, [id(500)]);
      expect(
        byKey['field']!.reason,
        RecurringNotAnalyzedReason.sourceFieldMissing,
      );
      expect(byKey['field']!.transactionIds, [id(6)]);
      expect(
        byKey['sharer']!.reason,
        RecurringNotAnalyzedReason.transactionNotReceived,
        reason: '관계 상대는 원거래가 아니라 서버 원거래 미확보 표식을 쓰지 않는다',
      );
      expect(byKey['sharer']!.serverReason, isNull);
    });

    test('a clean candidate sharing evidence with a held one is held too', () {
      final p = planWith(
        [
          candidate('broken', [id(0), id(1), id(2)], context),
          candidate('clean', [id(3), id(4), id(5)], context),
        ],
        relations: [pair(2, 3), pair(1, 400)],
      );
      expect(p.batches, isEmpty);
      final byKey = {for (final n in p.notAnalyzed) n.candidate.key: n};
      expect(
        byKey['broken']!.reason,
        RecurringNotAnalyzedReason.transactionNotReceived,
      );
      expect(
        byKey['clean']!.reason,
        RecurringNotAnalyzedReason.groupMemberHeld,
      );
      expect(byKey['clean']!.groupKeys, ['broken', 'clean']);
    });

    test('the same input always gives the same groups and batches', () {
      final candidates = [
        for (var c = 0; c < 23; c++)
          candidate('k${c.toString().padLeft(2, '0')}', [
            id(c * 3),
            id(c * 3 + 1),
            id(c * 3 + 2),
          ], context),
      ];
      final relations = [pair(2, 66), pair(20, 41)];
      String dump(RecurringAnalysisPlan p) => canonicalJson([
        for (final b in p.batches) [b.input, b.accept],
      ]);
      final first = planWith(candidates, relations: relations);
      final shuffled = planWith([
        ...candidates.reversed.skip(10),
        ...candidates.reversed.take(10),
      ], relations: relations);
      expect(dump(shuffled), dump(first));
    });

    test('a non-v4 snapshot is refused', () {
      final v3 = FinancialSnapshot.fromJson(
        jsonDecode(
          File('../api/fixtures/generated/snapshots/alpha-ready.json')
              .readAsStringSync(),
        ),
      );
      expect(
        () => planRecurringAnalysis(
          snapshot: v3,
          detection: calc.RecurringDetection(
            context,
            calc.BusinessDate(2026, 7, 31),
            const [],
            const [],
          ),
          transactions: const [],
          localSessionEpoch: 0,
          triggerKind: 'A',
        ),
        throwsFormatException,
      );
    });
  });
}
