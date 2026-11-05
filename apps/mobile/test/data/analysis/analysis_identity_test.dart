import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/analysis/analysis_identity.dart';

/// 2026-11-05: A가 공개한 공동 지문 사례 파일. 기대값은 Java·Python·Dart 참조에서 만든 값이라 고치지 않는다.
final _fixture = File('../api/testing/protocol/fixtures/identity-vectors.json');

/// 2026-11-05: 사례 파일 전체. 형식 검사는 첫 테스트에서 한다.
final Map<String, dynamic> _json =
    jsonDecode(_fixture.readAsStringSync()) as Map<String, dynamic>;

void main() {
  final cases = (_json['cases'] as List).cast<Map<String, dynamic>>();

  test('there are 30 public vectors, transaction and recurring', () {
    expect(_json['format'], 'PAYSE-IDENTITY-VECTORS-1');
    expect(_json['identityProfile'], 'PAYSE-IDENTITY-1');
    expect(cases, hasLength(30));
    final kinds = cases.map((c) => c['input']['semanticTaskKind']).toSet();
    expect(kinds, {'transactionMeaning', 'recurringMeaning'});
  });

  for (final vector in cases) {
    test(
      '${vector['id']} ${vector['name']} matches every intermediate value',
      () {
        final input = vector['input'] as Map<String, dynamic>;
        final expected = vector['expected'] as Map<String, dynamic>;
        final actual = identifyAnalysisInput(input);

        expect(canonicalJson(input), expected['canonicalInput']);
        final items = (expected['items'] as List).cast<Map<String, dynamic>>();
        expect(actual.items, hasLength(items.length));
        for (var i = 0; i < items.length; i++) {
          expect(actual.items[i].itemKey, items[i]['itemKey']);
          expect(
            actual.items[i].canonicalEvidence,
            items[i]['canonicalEvidence'],
          );
          expect(actual.items[i].evidenceHash, items[i]['evidenceHash']);
          expect(actual.items[i].memoryKey, items[i]['memoryKey']);
        }
        expect(actual.canonicalHint, expected['canonicalHint']);
        expect(actual.inputHashHint, expected['inputHashHint']);
      },
    );
  }

  test('pairs marked sameHintAs share the hint', () {
    final hints = {
      for (final c in cases)
        c['id'] as String: identifyAnalysisInput(c['input']).inputHashHint,
    };
    final pairs = cases.where((c) => c['sameHintAs'] != null).toList();
    expect(pairs, isNotEmpty);
    for (final c in pairs) {
      expect(hints[c['id']], hints[c['sameHintAs']], reason: '${c['id']}');
    }
  });

  test('the identity does not change the input', () {
    final input = cases.last['input'] as Map<String, dynamic>;
    final before = canonicalJson(input);
    final raw = jsonEncode(input);
    identifyAnalysisInput(input);
    expect(canonicalJson(input), before);
    expect(jsonEncode(input), raw, reason: '배열 순서도 그대로');
  });

  test('a duplicated meaning target is an input error', () {
    final input =
        jsonDecode(jsonEncode(cases.first['input'])) as Map<String, dynamic>;
    final items = input['items'] as List;
    items.add({...items.first as Map<String, dynamic>, 'itemKey': 'again'});
    expect(() => identifyAnalysisInput(input), throwsFormatException);
  });

  test('canonical JSON keeps text and rejects non-integer numbers', () {
    expect(
      canonicalJson({
        'b': 'a 😀',
        'a': null,
        'c': [2, 1],
      }),
      '{"a":null,"b":"a 😀","c":[2,1]}',
    );
    expect(() => canonicalJson({'amount': 1.5}), throwsArgumentError);
    expect(canonicalDigest('').length, 'sha256:'.length + 64);
  });
}
