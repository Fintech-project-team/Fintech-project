import 'package:flutter/foundation.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../data/calculation_input_adapter.dart';
import '../../data/financial_snapshot.dart';

/// 2026-10-23: 한 스냅샷으로 한 번 계산한 홈 결과. 홈·계산 내역·첫 계산이 같은 객체를 함께 쓴다.
sealed class HomeCalculation {
  const HomeCalculation(this.snapshot);

  /// 2026-10-23: 계산에 쓴 스냅샷. 결과와 다른 시점의 스냅샷을 섞지 않는다.
  final FinancialSnapshot snapshot;
}

/// 2026-10-23: 계산을 마쳤다. 정보 부족이면 result의 값이 null이고 insufficient에 이유가 있다.
final class HomeCalculationReady extends HomeCalculation {
  /// 2026-10-23: [snapshot]과 계산 결과 [result]로 만든다.
  const HomeCalculationReady(super.snapshot, this.result);

  final calc.CurrentAmountResult result;
}

/// 2026-10-23: 받은 금융 정보가 계약에 맞지 않아 계산하지 않았다. 이전 금액을 대신 보이지 않는다.
final class HomeCalculationDataError extends HomeCalculation {
  /// 2026-10-23: [snapshot]과 개발 확인용 설명 [detail]로 만든다. [detail]은 사용자 문구가 아니다.
  const HomeCalculationDataError(super.snapshot, this.detail);

  final String detail;
}

/// 2026-10-23: 예상하지 못한 오류로 계산하지 못했다. 데이터 오류나 정보 부족으로 바꾸지 않는다.
final class HomeCalculationUnexpectedError extends HomeCalculation {
  /// 2026-10-23: [snapshot]으로 만든다. 오류 내용은 Flutter 오류 보고로 남긴다.
  const HomeCalculationUnexpectedError(super.snapshot);
}

/// 2026-10-23: [snapshot]으로 홈 금액을 계산한다. 계약 위반(어댑터·계산 패키지 입력 검사)은 데이터 오류,
/// 그 밖의 예외는 Flutter 오류로 보고한 뒤 예상하지 못한 오류로 반환한다. 정보 부족으로 바꾸지 않는다.
/// [toInputs]는 입력 변환 함수이며 테스트에서만 바꾼다.
HomeCalculation computeHomeCalculation(
  FinancialSnapshot snapshot, {
  CalculationInputs Function(FinancialSnapshot) toInputs =
      calculationInputsFromSnapshot,
}) {
  try {
    final inputs = toInputs(snapshot);
    final result = calc.calculateCurrentAmount(
      calc.CurrentAmountInput(ledger: inputs.ledger, salary: inputs.salary),
    );
    return HomeCalculationReady(snapshot, result);
  } on CalculationContractException catch (e) {
    return HomeCalculationDataError(snapshot, e.toString());
  } on calc.CalculationInputException catch (e) {
    return HomeCalculationDataError(snapshot, e.toString());
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack, library: 'payse'),
    );
    return HomeCalculationUnexpectedError(snapshot);
  }
}
