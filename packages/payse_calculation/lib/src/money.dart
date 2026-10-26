/// 2026-10-23: 금액·중간 합계의 절댓값 상한(계산 규칙·데이터 모델 9,000,000,000,000원).
const int maxAbsKrw = 9000000000000;

/// 2026-10-23: 계산 입력 오류 종류. 정보 부족(insufficientData)과 달리 계약을 어긴 입력이다.
enum InputErrorCode {
  amountOutOfRange,
  invalidDate,
  invalidValue,
  duplicateId,
  unknownReference,
  overSettlement,
  overAllocation,
  unsupportedRuleVersion,
  invalidSchedule,
}

/// 2026-10-23: 계약을 어긴 계산 입력. 값을 보정하지 않고 계산을 멈춘다.
class CalculationInputException implements Exception {
  /// 2026-10-23: 오류 종류 [code], 문제 위치 [path], 설명 [detail]로 만든다.
  const CalculationInputException(this.code, this.path, this.detail);

  final InputErrorCode code;
  final String path;
  final String detail;

  /// 2026-10-23: 종류·위치·설명을 합친 문자열을 반환한다.
  @override
  String toString() =>
      'CalculationInputException(${code.name} at $path: $detail)';
}

/// 2026-10-23: Money(0~상한)인지 확인해 [value]를 그대로 반환한다. [path]는 오류 위치다.
int requireMoney(int value, String path) {
  if (value < 0 || value > maxAbsKrw) {
    throw CalculationInputException(
      InputErrorCode.amountOutOfRange,
      path,
      '0~$maxAbsKrw 범위가 아님($value)',
    );
  }
  return value;
}

/// 2026-10-23: PositiveMoney(1~상한)인지 확인해 [value]를 그대로 반환한다.
int requirePositiveMoney(int value, String path) {
  if (value < 1 || value > maxAbsKrw) {
    throw CalculationInputException(
      InputErrorCode.amountOutOfRange,
      path,
      '1~$maxAbsKrw 범위가 아님($value)',
    );
  }
  return value;
}

/// 2026-10-23: 부호 있는 금액(±상한)인지 확인해 [value]를 그대로 반환한다. 잔액·합계·파생값에 쓴다.
int requireSignedMoney(int value, String path) {
  if (value < -maxAbsKrw || value > maxAbsKrw) {
    throw CalculationInputException(
      InputErrorCode.amountOutOfRange,
      path,
      '±$maxAbsKrw 범위가 아님($value)',
    );
  }
  return value;
}

/// 2026-10-23: 범위 안의 두 금액 [a]+[b]를 계산하고 결과도 ±상한인지 검사한다.
/// 피연산자가 상한 안이므로 64비트 정수 overflow 없이 중간 합계마다 검사할 수 있다.
int addKrw(int a, int b, String path) => requireSignedMoney(a + b, path);

/// 2026-10-23: 범위 안의 두 금액 [a]−[b]를 계산하고 결과도 ±상한인지 검사한다.
int subtractKrw(int a, int b, String path) => requireSignedMoney(a - b, path);

/// 2026-10-23: 내부 ID 문자열이 비어 있지 않은지 확인해 [value]를 반환한다.
String requireId(String value, String path) {
  if (value.isEmpty) {
    throw CalculationInputException(InputErrorCode.invalidValue, path, '빈 ID');
  }
  return value;
}
