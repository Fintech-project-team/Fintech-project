/// 2026-10-22: 인증 화면과 FakeAuthRepository가 공유하는 순수 입력 규칙.
/// 정규화는 허용된 ASCII 구분자만 다루며 자격 존재 여부를 판단하지 않는다.
library;

final RegExp _invalidNameCharacter = RegExp(r'[^가-힣A-Za-z]');
final RegExp _invalidPhoneCharacter = RegExp(r'[^0-9 \-]');
final RegExp _phoneSeparators = RegExp(r'[ \-]');
final RegExp _nonAsciiDigit = RegExp(r'[^0-9]');

/// 2026-10-21: [raw]의 앞뒤 공백만 지운 이름을 반환한다.
/// 2026-10-22: 공유 계약에 맞춰 U+0020만 제거하고 다른 공백·대소문자·Unicode 표현은 보존한다.
String normalizeName(String raw) {
  var start = 0;
  var end = raw.length;
  while (start < end && raw.codeUnitAt(start) == 0x20) {
    start++;
  }
  while (end > start && raw.codeUnitAt(end - 1) == 0x20) {
    end--;
  }
  return raw.substring(start, end);
}

/// 2026-10-21: 정규화한 [name]이 이름 형식에 맞으면 true를 반환한다.
/// 2026-10-22: 한글 완성형·영문 2~20자만 허용하며 내부 공백을 허용하지 않는다.
bool isValidName(String name) =>
    name.length >= 2 &&
    name.length <= 20 &&
    !_invalidNameCharacter.hasMatch(name);

/// 2026-10-21: [raw]의 허용 구분자만 제거한 전화번호를 반환하고 다른 문자가 있으면 null을 반환한다.
/// 2026-10-22: U+0020 공백·U+002D 하이픈만 제거하며 탭·줄바꿈 등은 정규화하지 않는다.
String? normalizePhone(String raw) {
  if (_invalidPhoneCharacter.hasMatch(raw)) return null;
  return raw.replaceAll(_phoneSeparators, '');
}

/// 2026-10-21: 정규화한 [phone]이 010으로 시작하는 ASCII 11자리면 true를 반환한다.
bool isValidPhone(String? phone) =>
    phone != null &&
    phone.length == 11 &&
    phone.startsWith('010') &&
    !_nonAsciiDigit.hasMatch(phone);

/// 2026-10-21: [code]가 정규화 없이 ASCII 숫자 6자리면 true를 반환한다.
bool isValidCode(String code) =>
    code.length == 6 && !_nonAsciiDigit.hasMatch(code);
