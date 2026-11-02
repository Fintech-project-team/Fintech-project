import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_user_fixtures.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/data/fixture_scenario.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse_calculation/payse_calculation.dart'
    show InsufficientReason;

/// 2026-11-02: 데모베타·데모감마 생활 흐름(beta-life·gamma-life, 기준 시각 11/5) 앱 사본을 계산 패키지로 읽은 결과가
/// 생성기 catalog의 Flutter 기대값과 같은지 확인한다. 베타는 10월 회차까지 확인돼 계산된다(앱에는 아직 회차 확인을
/// 저장하는 기능이 없어 데이터로 정한다). 감마는 마이데이터로 받을 수 있는 원천만 있어 설정·분류·연결 관계가 없다.
void main() {
  /// [stem] 앱 사본 JSON을 읽는다.
  Map<String, Object?> read(String stem) =>
      (jsonDecode(File('assets/fixtures/$stem.json').readAsStringSync()) as Map)
          .cast<String, Object?>();

  /// [json]에서 sourceRef가 [ref]로 끝나는 거래를 [payMonth] 회차 입금 근거로 확인한 사본을 반환한다.
  Map<String, Object?> confirm(
    Map<String, Object?> json,
    String ref,
    String payMonth,
    String expectedPayDate,
  ) {
    final tx = (json['transactions']! as List).cast<Map>().singleWhere(
      (t) => (t['sourceRef'] as String).endsWith(ref),
    );
    final salary = (json['settings']! as Map)['salary']! as Map;
    (salary['receiptEvidence'] as List).add({
      'payMonth': payMonth,
      'expectedPayDate': expectedPayDate,
      'transactionIds': [tx['transactionId']],
      'confirmation': 'confirmed',
    });
    return json;
  }

  /// [json]을 파싱해 홈 계산 결과를 반환한다.
  HomeCalculationReady calculate(Map<String, Object?> json) {
    final calculation = computeHomeCalculation(
      FinancialSnapshot.fromJson(json),
    );
    expect(calculation, isA<HomeCalculationReady>());
    return calculation as HomeCalculationReady;
  }

  test('demo beta and gamma accounts open the life scenarios', () {
    expect(
      devUserFixtures['87f7bbf9-2355-5210-9325-f25d83a8ff35'],
      FixtureScenario.betaLife,
    );
    expect(
      devUserFixtures['d04073fd-f7ab-518d-8938-f2920d593db2'],
      FixtureScenario.gammaLife,
    );
  });

  test('beta-life computes with the 10/23 salary confirmed: B·U 4,924,500', () {
    final json = read('beta-life');
    expect(json['asOf'], '2026-11-05T12:00:00+09:00');
    final result = calculate(json).result;
    expect(
      result.insufficient,
      isEmpty,
      reason: '10월 회차는 급여 3,084,620원 한 건으로 확인',
    );
    expect(result.b, 4924500);
    expect(result.e, 0, reason: '등록된 예정 지출 없음');
    expect(result.r, 0);
    expect(result.u, 4924500);
  });

  /// 감마 원천에 연결 뒤 사용자가 할 설정(주거래 통장 선택, 월급 15일·2,850,000원)을 더한 사본을 반환한다.
  Map<String, Object?> gammaAfterSetup() {
    final json = read('gamma-life');
    final main = (json['accounts']! as List).cast<Map>().singleWhere(
      (a) => a['productName'] == '주거래 통장',
    );
    main['included'] = true;
    final salary = (json['settings']! as Map)['salary']! as Map;
    salary['salaryDay'] = 15;
    salary['salaryAmountKRW'] = 2850000;
    salary['salaryAccountId'] = main['accountId'];
    return json;
  }

  test('gamma-life keeps only source data: no settings, types, links', () {
    final json = read('gamma-life');
    expect(json['asOf'], '2026-11-05T12:00:00+09:00');
    final salary = (json['settings']! as Map)['salary']! as Map;
    expect(salary['salaryDay'], isNull);
    expect(salary['salaryAmountKRW'], isNull);
    expect(salary['salaryAccountId'], isNull);
    expect(salary['receiptEvidence'], isEmpty);
    expect(
      (json['accounts']! as List).every((a) => a['included'] == false),
      isTrue,
    );
    expect(json['transactionRelations'], isEmpty);
    expect(
      (json['transactions']! as List).every(
        (t) => t['payseTransactionType'] == null,
      ),
      isTrue,
    );
    final result = calculate(json).result;
    expect(result.b, isNull);
    expect(result.insufficient, [
      InsufficientReason.noIncludedAccount,
      InsufficientReason.salaryDayMissing,
    ]);
  });

  test('gamma-life after setup still waits for the 10/15 receipt', () {
    final result = calculate(gammaAfterSetup()).result;
    expect(result.b, 7791550);
    expect(result.e, isNull);
    expect(result.u, isNull);
    expect(result.insufficient, [InsufficientReason.receiptEvidenceAbsent]);
  });

  test('gamma-life also computes if the loan deposit is wrongly confirmed', () {
    final json = confirm(
      gammaAfterSetup(),
      '/life/loan/2026-10',
      '2026-10',
      '2026-10-15',
    );
    final result = calculate(json).result;
    expect(
      result.insufficient,
      isEmpty,
      reason: '계산은 확인 기록만 보고 거래 성격을 판단하지 않음',
    );
    expect(
      result.u,
      7791550,
      reason: '대출금 2,850,000원이 쓸 수 있는 돈에 섞임(정답 라벨 G14)',
    );
  });
}
