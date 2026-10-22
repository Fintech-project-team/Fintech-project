/// 2026-10-22: 인증 입력 정규화·형식 규칙(docs/api-contract.md §2 '인증 입력과 단일 이름'). 10-2 화면 검사와
/// FakeAuthRepository의 422 검사가 같은 함수를 쓴다. 서버도 같은 공백 처리 규칙을 적용하기로 확인했다(구현 완료 아님).
library;

final RegExp _edgeSpaces = RegExp(r'^ +| +$');
final RegExp _namePattern = RegExp(r'^[가-힣A-Za-z]{2,20}$');
final RegExp _phoneSeparators = RegExp(r'[ -]');
final RegExp _phonePattern = RegExp(r'^010[0-9]{8}$');
final RegExp _codePattern = RegExp(r'^[0-9]{6}$');

/// 2026-10-22: [raw]의 앞뒤 일반 공백(U+0020)만 지운 이름을 반환한다. 탭·줄바꿈·NBSP·전각 공백과
/// 가운데 공백은 지우지 않아 형식 검사에서 거절되게 한다. 대소문자 접기·NFC 변환은 하지 않는다.
String normalizeName(String raw) => raw.replaceAll(_edgeSpaces, '');

/// 2026-10-22: 정규화한 [name]이 한글 완성형·영문 2~20자면 true를 반환한다.
bool isValidName(String name) => _namePattern.hasMatch(name);

/// 2026-10-22: [raw]에서 일반 공백(U+0020)과 하이픈(U+002D)만 지운 번호를 반환한다. 다른 문자는 남겨 거절되게 한다.
String normalizePhone(String raw) => raw.replaceAll(_phoneSeparators, '');

/// 2026-10-22: 정규화한 [phone]이 010으로 시작하는 ASCII 숫자 11자리면 true를 반환한다.
bool isValidPhone(String phone) => _phonePattern.hasMatch(phone);

/// 2026-10-22: [code]가 정규화 없이 ASCII 숫자 6자리면 true를 반환한다.
bool isValidCode(String code) => _codePattern.hasMatch(code);
