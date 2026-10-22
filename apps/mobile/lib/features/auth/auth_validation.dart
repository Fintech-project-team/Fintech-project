/// 2026-10-21: 10-2·10-3·10-4 입력 형식 규칙(순수 함수). 서버 자격 존재 여부와 구분되는 로컬 형식 검사만 한다.
library;

/// 2026-10-21: 이름 형식. 한글 완성형·영문 단어를 가운데 공백 하나로 이은 2~20자.
/// 가운데 공백 허용은 시드 이름('PAYSE 합성 alpha')과 맞추기 위한 임시 해석이며 A 확인 대기다(apps/mobile/docs/auth.md).
final RegExp _namePattern = RegExp(r'^[가-힣A-Za-z]+( [가-힣A-Za-z]+)*$');
final RegExp _phonePattern = RegExp(r'^010\d{8}$');
final RegExp _phoneAllowed = RegExp(r'^[0-9 \-]*$');
final RegExp _codePattern = RegExp(r'^[0-9]{6}$');

/// 2026-10-21: [raw]의 앞뒤 공백만 지운 이름을 반환한다(product-baseline: 이름은 앞뒤 공백만 정규화).
String normalizeName(String raw) => raw.trim();

/// 2026-10-21: 정규화한 [name]이 이름 형식에 맞으면 true를 반환한다.
bool isValidName(String name) =>
    name.length >= 2 && name.length <= 20 && _namePattern.hasMatch(name);

/// 2026-10-21: [raw]에서 허용 구분자(공백·하이픈)만 지운 번호를 반환한다. 다른 문자가 있으면 null이다.
String? normalizePhone(String raw) {
  final trimmed = raw.trim();
  if (!_phoneAllowed.hasMatch(trimmed)) return null;
  return trimmed.replaceAll(RegExp(r'[ \-]'), '');
}

/// 2026-10-21: 정규화한 [phone]이 010으로 시작하는 11자리면 true를 반환한다.
bool isValidPhone(String? phone) =>
    phone != null && _phonePattern.hasMatch(phone);

/// 2026-10-21: [code]가 ASCII 숫자 6자리면 true를 반환한다.
bool isValidCode(String code) => _codePattern.hasMatch(code);

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
