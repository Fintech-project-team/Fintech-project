import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/fixture_scenario.dart';

/// 2026-10-20: 앱 에셋 복사본이 apps/api 원본과 바이트 단위로 같은지 검사한다.
/// 원본이 바뀌면 이 테스트가 실패한다. 복사본을 자동으로 덮어쓰지 않으며,
/// 변경 내용을 확인한 사람이 원본을 assets/fixtures/에 다시 복사해 동기화한다.
void main() {
  for (final scenario in FixtureScenario.values) {
    test('asset copy of ${scenario.fileStem} matches apps/api original', () {
      final original = File(
        '../api/fixtures/generated/snapshots/${scenario.fileStem}.json',
      );
      final copy = File('assets/fixtures/${scenario.fileStem}.json');

      expect(original.existsSync(), isTrue, reason: '원본 없음: ${original.path}');
      expect(copy.existsSync(), isTrue, reason: '복사본 없음: ${copy.path}');
      expect(
        copy.readAsBytesSync(),
        orderedEquals(original.readAsBytesSync()),
        reason:
            '${scenario.fileStem}: apps/api 원본이 바뀌었어요. 변경 내용을 확인한 뒤 '
            '원본을 apps/mobile/assets/fixtures/에 다시 복사해 동기화하세요(자동 덮어쓰기 없음).',
      );
    });
  }
}
