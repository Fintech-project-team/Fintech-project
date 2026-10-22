/// 2026-10-21: 10-2·10-3·10-4 입력 형식 규칙(순수 함수). 서버 자격 존재 여부와 구분되는 로컬 형식 검사만 한다.
/// 이름·전화번호·인증번호 규칙은 서버 계약과 같은 함수를 쓰도록 데이터 계층에서 가져온다.
library;

export '../../data/auth/auth_input_format.dart';

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
