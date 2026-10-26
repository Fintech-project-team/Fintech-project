/// 2026-10-23: PAYSE 로컬 계산(PAYSE-CALC-1). 순수 Dart이며 네트워크·DB·현재 시각을 읽지 않는다.
library;

export 'src/business_date.dart' show BusinessDate, PayMonth;
export 'src/current_amount.dart';
export 'src/inputs.dart';
export 'src/ledger.dart' show InsufficientReason;
export 'src/money.dart'
    show maxAbsKrw, InputErrorCode, CalculationInputException;
export 'src/projection.dart';
export 'src/salary_cycle.dart';
