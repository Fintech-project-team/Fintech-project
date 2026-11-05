import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 2026-11-04: 객체 키만 UTF-16 순으로 정렬하고 원문·배열·null·정수를 보존한다.
/// 입력은 공개 스키마가 허용한 JSON 값이며 반환 문자열에는 BOM·개행이 없다.
String canonical(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${canonical(value[key])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(canonical).join(',')}]';
  }
  return jsonEncode(value);
}

/// 2026-11-04: 정규 JSON의 UTF-8 SHA-256을 공개 접두어·소문자 64자리로 반환한다.
String digest(Object? value) =>
    'sha256:${sha256.convert(utf8.encode(canonical(value)))}';

/// 2026-11-04: 공개 입력만으로 memory/evidence/hint 중간값을 재현한다.
/// 테스트 참조 구현이며 서버 DB 결합 지문·권한 검사·모바일 제품 어댑터를 대신하지 않는다.
Map<String, dynamic> identity(Map<String, dynamic> input) {
  final task = input['semanticTaskKind'];
  final rows = <Map<String, dynamic>>[];
  final keys = <String>{};
  for (final item in input['items'] as List) {
    final direct = Set<String>.from(item['evidenceTransactionIds'] as List);
    final memoryKey = digest({
      'kind': task,
      if (task == 'transactionMeaning')
        'target': item['targetTransactionId']
      else
        'evidence': direct.toList()..sort(),
    });
    if (!keys.add(memoryKey)) {
      throw FormatException('Duplicate semantic target');
    }
    final refs = {...direct};
    while (true) {
      final before = refs.length;
      for (final transaction in input['transactions'] as List) {
        if (refs.contains(transaction['transactionId']) &&
            transaction['originalTransactionId'] != null) {
          refs.add(transaction['originalTransactionId'] as String);
        }
      }
      for (final relation in input['relations'] as List) {
        if (refs.contains(relation['fromId']) ||
            refs.contains(relation['toId'])) {
          refs.add(relation['fromId'] as String);
          refs.add(relation['toId'] as String);
        }
      }
      if (refs.length == before) break;
    }
    final facts = <String, dynamic>{};
    for (final field in [
      'transactions',
      'currentClassifications',
      'unavailableReferences',
    ]) {
      facts[field] =
          (input[field] as List)
              .where((row) => refs.contains(row['transactionId']))
              .toList()
            ..sort(
              (a, b) => (a['transactionId'] as String).compareTo(
                b['transactionId'] as String,
              ),
            );
    }
    facts['relations'] =
        (input['relations'] as List)
            .where(
              (row) =>
                  refs.contains(row['fromId']) || refs.contains(row['toId']),
            )
            .toList()
          ..sort((a, b) => canonical(a).compareTo(canonical(b)));
    for (final candidate in input['candidates'] as List) {
      if (candidate['candidateKey'] == item['candidateKey']) {
        final local = jsonDecode(jsonEncode(candidate)) as Map<String, dynamic>;
        for (final field in ['candidateKey', 'sourceVersion', 'ruleVersion']) {
          local.remove(field);
        }
        local['evidenceTransactionIds'] = direct.toList()..sort();
        (local['features']['observedMonths'] as List).sort();
        facts['candidate'] = local;
      }
    }
    rows.add({
      'itemKey': item['itemKey'],
      'memoryKey': memoryKey,
      'evidenceHash': digest(facts),
      'canonicalEvidence': canonical(facts),
    });
  }
  final ordered = [...rows]
    ..sort(
      (a, b) => (a['memoryKey'] as String).compareTo(b['memoryKey'] as String),
    );
  final material = {
    'semanticTaskKind': task,
    'items': [
      for (final row in ordered)
        {'memoryKey': row['memoryKey'], 'evidenceHash': row['evidenceHash']},
    ],
  };
  return {
    'canonicalInput': canonical(input),
    'items': rows,
    'canonicalHint': canonical(material),
    'inputHashHint': digest(material),
  };
}

/// 2026-11-04: 공개 30개 파일을 읽고 모든 중간 문자열·해시를 비교한다.
/// 인자는 선택적인 fixture 경로 하나다. 비밀·DB·네트워크·모델에 접근하지 않는다.
void main(List<String> arguments) {
  if (arguments.length > 1) throw ArgumentError('Optional fixture path only');
  final file = arguments.isEmpty
      ? File.fromUri(
          Platform.script.resolve('../fixtures/identity-vectors.json'),
        )
      : File(arguments.single);
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final cases = fixture['cases'] as List;
  if (fixture['format'] != 'PAYSE-IDENTITY-VECTORS-1' || cases.length != 30) {
    throw FormatException('Expected 30 public identity vectors');
  }
  final seen = <String, String>{};
  for (final vector in cases) {
    final id = vector['id'] as String;
    final actual = identity(vector['input'] as Map<String, dynamic>);
    if (canonical(actual) != canonical(vector['expected'])) {
      throw StateError('$id canonical input/evidence/hint mismatch');
    }
    final hint = actual['inputHashHint'] as String;
    if (seen.containsKey(id) ||
        (vector['sameHintAs'] != null && seen[vector['sameHintAs']] != hint)) {
      throw StateError('$id duplicate or equivalent-input mismatch');
    }
    seen[id] = hint;
  }
  stdout.writeln('PASS: Dart canonical JSON and SHA-256 match all 30 vectors');
}
