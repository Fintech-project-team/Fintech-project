/// 2026-10-21: 10-2·10-3·10-4 입력 형식 규칙(순수 함수). 서버 자격 존재 여부와 구분되는 로컬 형식 검사만 한다.
/// 2026-10-22: 인증 입력은 data/auth의 공통 규칙을 내보내고 PIN 규칙은 그대로 유지한다.
library;

export '../../data/auth/auth_input_rules.dart'
    show normalizeName, isValidName, normalizePhone, isValidPhone, isValidCode;

/// 2026-10-21: 6자리 [pin]이 같은 숫자 6개이거나 1씩 오르거나 내리는 숫자면 true를 반환한다(10-4 거절 규칙).
bool isWeakPin(String pin) {
  if (pin.length != 6) return false;
  final digits = pin.codeUnits.map((c) => c - 48).toList();
  bool every(int step) {
    for (var i = 1; i < digits.length; i++) {
      if (digits[i] - digits[i - 1] != step) return false;
    }
    return true;
  }

  return every(0) || every(1) || every(-1);
}
