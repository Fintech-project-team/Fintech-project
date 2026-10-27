import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/data/fixture_scenario.dart';
import 'package:payse/features/overview/home_calculation.dart';

/// 2026-10-27: #100 일상 지출 시연(demo-ready) 앱 사본을 파서→어댑터→계산 패키지로 읽은 결과가 인계 문서의
/// 기대값과 같은지 확인한다. 앱은 금액을 따로 계산하지 않고 계산 패키지 결과만 비교한다.
void main() {
  test('demo-ready is the default scenario', () {
    expect(FixtureScenario.defaultScenario, FixtureScenario.demoReady);
    expect(FixtureScenario.demoReady.fileStem, 'demo-ready');
  });

  test(
    'demo-ready calculates B 2,000,000 · E 300,000 · R−O 400,000 · U 1,300,000',
    () {
      final json = (jsonDecode(
        File('assets/fixtures/demo-ready.json').readAsStringSync(),
      ) as Map).cast<String, Object?>();
      final calculation = computeHomeCalculation(
        FinancialSnapshot.fromJson(json),
      );

      expect(calculation, isA<HomeCalculationReady>());
      final result = (calculation as HomeCalculationReady).result;
      expect(result.insufficient, isEmpty, reason: '9월 회차 급여 근거가 confirmed');
      expect(result.b, 2000000);
      expect(result.e, 300000, reason: '월세만. 완료된 카드값·다음 기간 통신비 제외');
      expect(result.r, 400000);
      expect(result.o, 0, reason: '비상금에 지출 배정 없음');
      expect(result.u, 1300000);
    },
  );
}
