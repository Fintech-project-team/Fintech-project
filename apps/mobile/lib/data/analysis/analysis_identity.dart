import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 2026-11-05: 분석 입력 한 항목의 지문 중간값. 공동 대조 사례(identity-vectors.json)의
/// `expected.items[]`와 같은 이름·의미다.
final class AnalysisItemIdentity {
  /// 2026-11-05: 입력 항목 [itemKey], 의미 대상 지문 [memoryKey], 근거 지문 [evidenceHash],
  /// 근거의 정규 JSON [canonicalEvidence]로 만든다.
  const AnalysisItemIdentity({
    required this.itemKey,
    required this.memoryKey,
    required this.evidenceHash,
    required this.canonicalEvidence,
  });

  final String itemKey;
  final String memoryKey;
  final String evidenceHash;
  final String canonicalEvidence;
}

/// 2026-11-05: 분석 입력 전체의 지문 결과. [inputHashHint]는 접수 본문에 넣는 힌트이며
/// 서버 analysisInputHash가 아니다. 권한 확인·결과 재사용 판단에 쓰지 않는다.
final class AnalysisIdentity {
  /// 2026-11-05: 입력 순서대로의 항목 지문 [items], 힌트 재료의 정규 JSON [canonicalHint],
  /// 최종 힌트 [inputHashHint]로 만든다.
  AnalysisIdentity({
    required Iterable<AnalysisItemIdentity> items,
    required this.canonicalHint,
    required this.inputHashHint,
  }) : items = List.unmodifiable(items);

  final List<AnalysisItemIdentity> items;
  final String canonicalHint;
  final String inputHashHint;
}

/// 2026-11-05: PAYSE-IDENTITY-1 정규 JSON. 객체 키만 UTF-16 코드 단위 순으로 재귀 정렬하고,
/// 배열 순서·문자열 원문·null·bool·정수를 그대로 둔다. 공백·개행·BOM이 없다.
/// [value]에 문자열 키가 아닌 객체, 실수, 그 밖의 타입이 있으면 [ArgumentError]다.
String canonicalJson(Object? value) {
  if (value is Map) {
    final keys = <String>[];
    for (final key in value.keys) {
      if (key is! String) throw ArgumentError.value(key, 'key', '문자열 키만 허용');
      keys.add(key);
    }
    keys.sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(canonicalJson).join(',')}]';
  if (value == null || value is String || value is bool || value is int) {
    return jsonEncode(value);
  }
  throw ArgumentError.value(value, 'value', '정수·문자열·bool·null·배열·객체만 허용');
}

/// 2026-11-05: [value]의 정규 JSON을 UTF-8로 SHA-256 해시해 `sha256:` + 소문자 64자리로 반환한다.
String canonicalDigest(Object? value) =>
    'sha256:${sha256.convert(utf8.encode(canonicalJson(value)))}';

/// 2026-11-05: Java `AnalysisIdentity.hint(input)`과 같은 입력 지문을 만든다(docs/analysis-protocol.md §2).
/// [input]은 공개 스키마의 transactionMeaning·recurringMeaning 입력 JSON이다. 항목별 근거는
/// 직접 근거 ID에서 원거래·명시 관계의 양끝으로 더 늘지 않을 때까지 넓힌다.
/// 같은 의미 대상이 두 번 나오거나 필수 필드 형식이 다르면 [FormatException]이다.
AnalysisIdentity identifyAnalysisInput(Map<String, Object?> input) {
  final task = _string(input, 'semanticTaskKind');
  final transactions = _rows(input, 'transactions');
  final relations = _rows(input, 'relations');
  final classifications = _rows(input, 'currentClassifications');
  final unavailable = _rows(input, 'unavailableReferences');
  final candidates = _rows(input, 'candidates');

  final items = <AnalysisItemIdentity>[];
  final memoryKeys = <String>{};
  for (final item in _rows(input, 'items')) {
    final direct = _ids(item, 'evidenceTransactionIds');
    final memoryKey = canonicalDigest({
      'kind': task,
      if (task == 'transactionMeaning')
        'target': item['targetTransactionId']
      else
        'evidence': direct,
    });
    if (!memoryKeys.add(memoryKey)) {
      throw const FormatException('같은 의미 대상이 두 번 들어 있다');
    }

    final refs = _expand(direct.toSet(), transactions, relations);
    final evidence = <String, Object?>{
      'transactions': _byTransactionId(transactions, refs),
      'currentClassifications': _byTransactionId(classifications, refs),
      'unavailableReferences': _byTransactionId(unavailable, refs),
      'relations':
          relations
              .where(
                (r) => refs.contains(r['fromId']) || refs.contains(r['toId']),
              )
              .toList()
            ..sort((a, b) => canonicalJson(a).compareTo(canonicalJson(b))),
    };
    final candidate = _candidateEvidence(
      candidates,
      item['candidateKey'],
      direct,
    );
    if (candidate != null) evidence['candidate'] = candidate;

    items.add(
      AnalysisItemIdentity(
        itemKey: _string(item, 'itemKey'),
        memoryKey: memoryKey,
        evidenceHash: canonicalDigest(evidence),
        canonicalEvidence: canonicalJson(evidence),
      ),
    );
  }

  final ordered = [...items]
    ..sort((a, b) => a.memoryKey.compareTo(b.memoryKey));
  final material = {
    'semanticTaskKind': task,
    'items': [
      for (final row in ordered)
        {'memoryKey': row.memoryKey, 'evidenceHash': row.evidenceHash},
    ],
  };
  return AnalysisIdentity(
    items: items,
    canonicalHint: canonicalJson(material),
    inputHashHint: canonicalDigest(material),
  );
}

/// 2026-11-05: 직접 근거 [direct]에 원거래 ID와 명시 관계 양끝을 더 늘지 않을 때까지 더한 집합을 반환한다.
Set<String> _expand(
  Set<String> direct,
  List<Map<String, Object?>> transactions,
  List<Map<String, Object?>> relations,
) {
  final refs = {...direct};
  while (true) {
    final before = refs.length;
    for (final row in transactions) {
      final original = row['originalTransactionId'];
      if (refs.contains(row['transactionId']) && original is String) {
        refs.add(original);
      }
    }
    for (final relation in relations) {
      if (refs.contains(relation['fromId']) ||
          refs.contains(relation['toId'])) {
        refs.add(_string(relation, 'fromId'));
        refs.add(_string(relation, 'toId'));
      }
    }
    if (refs.length == before) return refs;
  }
}

/// 2026-11-05: [rows] 중 transactionId가 [refs]에 있는 행만 transactionId 순으로 반환한다.
List<Map<String, Object?>> _byTransactionId(
  List<Map<String, Object?>> rows,
  Set<String> refs,
) => rows.where((row) => refs.contains(row['transactionId'])).toList()
  ..sort(
    (a, b) =>
        _string(a, 'transactionId').compareTo(_string(b, 'transactionId')),
  );

/// 2026-11-05: 반복 항목의 후보 근거. [candidateKey]가 같은 후보에서 candidateKey·sourceVersion·
/// ruleVersion을 빼고, 근거 ID를 직접 근거 [direct]로, 관찰 월을 정렬해 반환한다. 없으면 null이다.
Map<String, Object?>? _candidateEvidence(
  List<Map<String, Object?>> candidates,
  Object? candidateKey,
  List<String> direct,
) {
  Map<String, Object?>? found;
  for (final candidate in candidates) {
    if (candidate['candidateKey'] != candidateKey) continue;
    final local = jsonDecode(jsonEncode(candidate)) as Map<String, Object?>
      ..remove('candidateKey')
      ..remove('sourceVersion')
      ..remove('ruleVersion');
    local['evidenceTransactionIds'] = direct;
    final features = local['features'];
    if (features is! Map) throw const FormatException('후보 features가 없다');
    final months = features['observedMonths'];
    if (months is! List) throw const FormatException('후보 observedMonths가 없다');
    months.sort((a, b) => (a as String).compareTo(b as String));
    found = local;
  }
  return found;
}

/// 2026-11-05: [row]의 [field] 배열을 객체 목록으로 반환한다. 배열이 아니면 [FormatException]이다.
List<Map<String, Object?>> _rows(Map<String, Object?> row, String field) {
  final value = row[field];
  if (value is! List) throw FormatException('$field 배열이 없다');
  return [
    for (final entry in value)
      if (entry is Map<String, Object?>)
        entry
      else
        throw FormatException('$field 항목이 객체가 아니다'),
  ];
}

/// 2026-11-05: [row]의 [field] ID 배열을 정렬해 반환한다.
List<String> _ids(Map<String, Object?> row, String field) {
  final value = row[field];
  if (value is! List) throw FormatException('$field 배열이 없다');
  return [
    for (final id in value)
      if (id is String) id else throw FormatException('$field에 문자열이 아닌 값'),
  ]..sort();
}

/// 2026-11-05: [row]의 [field] 문자열을 반환한다. 없거나 문자열이 아니면 [FormatException]이다.
String _string(Map<String, Object?> row, String field) {
  final value = row[field];
  if (value is! String) throw FormatException('$field 문자열이 없다');
  return value;
}
