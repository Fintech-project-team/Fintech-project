/// 2026-10-20: 정수 원 금액을 화면 표기로 바꾼다. 계산하지 않고 형식만 다룬다.
/// [amountKrw]는 원 단위 정수. 음수는 U+2212(−) 기호를 붙인다.
/// 반환값 예: 1100000 → "1,100,000", -120000 → "−120,000".
String formatKrwDigits(int amountKrw) {
  final digits = amountKrw.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return amountKrw < 0 ? '−$buffer' : buffer.toString();
}

/// 2026-10-20: 단위 '원'까지 붙인 표기를 반환한다. [amountKrw]는 원 단위 정수.
String formatKrw(int amountKrw) => '${formatKrwDigits(amountKrw)}원';

/// 2026-10-20: 화면 읽기 프로그램용 금액 문장을 반환한다. 음수는 '마이너스'로 읽힌다.
String spokenKrw(int amountKrw) {
  final digits = formatKrwDigits(amountKrw.abs());
  return amountKrw < 0 ? '마이너스 $digits원' : '$digits원';
}
