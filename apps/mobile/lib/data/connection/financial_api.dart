/// 2026-10-22: 금융 조회·연결 쓰기 계약(docs/api-contract.md §3·§5·§6). 가짜 구현과 실제 API 구현이 같은 의미를 지킨다.
/// 화면·ViewModel은 이 인터페이스만 쓰고 예외 대신 [FinancialOutcome]을 받는다.
library;

import 'package:flutter/widgets.dart' show StringCharacters;

/// 2026-10-22: 금융 쓰기 공통 필드 W. 같은 논리 작업의 재시도에는 같은 값을 다시 보낸다.
class WriteContext {
  /// 2026-10-22: 기대 자료 버전 [expectedDataVersion], 규칙 버전 [ruleVersion], 작업 키 [idempotencyKey]로 만든다.
  const WriteContext({
    required this.expectedDataVersion,
    required this.ruleVersion,
    required this.idempotencyKey,
  });

  final String expectedDataVersion;
  final String ruleVersion;
  final String idempotencyKey;
}

/// 2026-10-28: PATCH /settings의 월급 설정 변경(SalaryPatch). 바꾼 필드만 담으며 생략과 null(해제)을 구분한다.
/// 각 필드는 보낼 때만 `(value: 값)`이고, 보내지 않으면 null이다. 입금 근거를 바꾸는 값이 아니다.
class SalaryPatch {
  /// 2026-10-28: 월급일 [salaryDay](1~31|null), 예상 금액 [salaryAmountKrw](원|null), 월급 계좌 [salaryAccountId]로 만든다.
  const SalaryPatch({
    this.salaryDay,
    this.salaryAmountKrw,
    this.salaryAccountId,
  });

  final ({int? value})? salaryDay;
  final ({int? value})? salaryAmountKrw;
  final ({String? value})? salaryAccountId;

  /// 2026-10-28: 보낼 필드가 하나도 없으면 true를 반환한다(빈 patch는 보내지 않는다).
  bool get isEmpty =>
      salaryDay == null && salaryAmountKrw == null && salaryAccountId == null;

  /// 2026-10-28: 요청 본문의 salary 객체를 키 이름 순서로 반환한다. 보내지 않는 필드는 키가 없다.
  Map<String, Object?> toJson() => {
    if (salaryAccountId != null) 'salaryAccountId': salaryAccountId!.value,
    if (salaryAmountKrw != null) 'salaryAmountKRW': salaryAmountKrw!.value,
    if (salaryDay != null) 'salaryDay': salaryDay!.value,
  };
}

/// 2026-10-28: PATCH /accounts/{accountId}의 계좌 이름(nickname) 제약(api-contract §3). 앱 입력 검사와 가짜 서버가 같이 쓴다.
/// 앞뒤 공백을 지운 뒤 보이는 글자(grapheme) 1~12자이며, PC 키보드 특수문자 32종과 공백만으로 이뤄지면 안 된다.
/// 이모지만인 이름과 다른 계좌와 같은 이름은 허용한다. null(원래 이름으로 되돌리기)은 이 검사 대상이 아니다.
abstract final class AccountNicknameRule {
  static const int maxLength = 12;
  static const String specials = r"""!@#$%^&*()-_=+[]{}\|;:'",.<>/?`~""";

  /// 2026-10-28: [nickname]을 앞뒤 공백을 지우고 보이는 글자 수로 센 값을 반환한다.
  static int length(String nickname) => nickname.trim().characters.length;

  /// 2026-10-28: [nickname]이 저장할 수 있는 이름이면 true를 반환한다.
  static bool isValid(String nickname) {
    final chars = nickname.trim().characters;
    if (chars.isEmpty || chars.length > maxLength) return false;
    return chars.any((c) => c.trim().isNotEmpty && !specials.contains(c));
  }
}

/// 2026-10-22: 쓰기로 바뀐 자원 하나(ChangedRef).
class ChangedRef {
  /// 2026-10-22: 자원 종류 [resource]와 ID [id]로 만든다.
  const ChangedRef({required this.resource, required this.id});

  final String resource;
  final String id;
}

/// 2026-10-22: 쓰기 영수증의 공개 요약.
class WriteReceipt {
  /// 2026-10-22: 영수증 [receiptId], 작업 키 [operationKey], 결과 버전 [resultVersion], 생성 시각 [createdAt],
  /// 바뀐 자원 [changedRefs]로 만든다.
  const WriteReceipt({
    required this.receiptId,
    required this.operationKey,
    required this.resultVersion,
    required this.createdAt,
    required this.changedRefs,
  });

  final String receiptId;
  final String operationKey;
  final String resultVersion;
  final DateTime createdAt;
  final List<ChangedRef> changedRefs;
}

/// 2026-10-22: 금융 쓰기 성공 S. [snapshot]은 현재 조회 권한의 최신 Snapshot JSON이며 replay에서도 과거 상태가 아니다.
class WriteSuccess {
  /// 2026-10-22: 영수증 [receipt], 재전송 여부 [replayed], 최신 [snapshot]으로 만든다.
  const WriteSuccess({
    required this.receipt,
    required this.replayed,
    required this.snapshot,
  });

  final WriteReceipt receipt;
  final bool replayed;
  final Map<String, Object?> snapshot;
}

/// 2026-10-22: 금융 조회·쓰기 결과. 성공과 실패 종류를 하나의 타입으로 겹치지 않게 구분한다.
sealed class FinancialOutcome<T> {
  /// 2026-10-22: 하위 결과 타입만 만든다.
  const FinancialOutcome();
}

/// 2026-10-22: 성공. [value]는 응답 값이다.
final class FinancialOk<T> extends FinancialOutcome<T> {
  /// 2026-10-22: 응답 [value]로 만든다.
  const FinancialOk(this.value);

  final T value;
}

/// 2026-10-22: 422 VALIDATION_FAILED. 형식·제약 위반(빈 목록, 중복 ID, 은행 0곳 등).
final class FinancialInvalid<T> extends FinancialOutcome<T> {
  /// 2026-10-22: 형식 오류 결과를 만든다.
  const FinancialInvalid();
}

/// 2026-10-22: 403 RESOURCE_FORBIDDEN. 없는 자원·다른 사용자 자원·연결 권한 밖 자원을 구분하지 않는다.
final class FinancialForbidden<T> extends FinancialOutcome<T> {
  /// 2026-10-22: 권한 밖 결과를 만든다.
  const FinancialForbidden();
}

/// 2026-10-22: 409 STALE_DATA. 기대 자료 버전이 현재와 다르다. 최신 Snapshot을 다시 읽고 초안을 재검토한다.
final class FinancialStaleData<T> extends FinancialOutcome<T> {
  /// 2026-10-22: 자료 버전 불일치 결과를 만든다.
  const FinancialStaleData();
}

/// 2026-10-22: 409 RULE_VERSION_MISMATCH. 규칙 버전이 서버와 다르다. 자료 버전 불일치와 구분한다.
final class FinancialRuleVersionMismatch<T> extends FinancialOutcome<T> {
  /// 2026-10-22: 규칙 버전 불일치 결과를 만든다.
  const FinancialRuleVersionMismatch();
}

/// 2026-10-22: 409 IDEMPOTENCY_CONFLICT. 같은 작업 키로 다른 요청을 보냈다.
final class FinancialIdempotencyConflict<T> extends FinancialOutcome<T> {
  /// 2026-10-22: 작업 키 충돌 결과를 만든다.
  const FinancialIdempotencyConflict();
}

/// 2026-10-22: 401 SESSION_INVALID. 금융 접근을 멈추고 로컬 PIN으로 우회하지 않는다.
final class FinancialSessionInvalid<T> extends FinancialOutcome<T> {
  /// 2026-10-22: 무효 세션 결과를 만든다.
  const FinancialSessionInvalid();
}

/// 2026-10-22: 503 TEMPORARILY_UNAVAILABLE 등 서비스 불가(공개 권한을 판정할 수 없는 계약 오류 포함).
/// 쓰기는 같은 키로 결과를 확인한다. 0원·빈 자료로 대체하지 않는다.
final class FinancialUnavailable<T> extends FinancialOutcome<T> {
  /// 2026-10-22: 서비스 불가 결과를 만든다.
  const FinancialUnavailable();
}

/// 2026-10-22: 응답을 받지 못한 연결 실패. [error]는 원인이다.
final class FinancialNetworkFailure<T> extends FinancialOutcome<T> {
  /// 2026-10-22: 원인 [error]로 만든다.
  const FinancialNetworkFailure(this.error);

  final Object error;
}

/// 2026-10-22: 한 세션의 금융 조회·연결 쓰기 계약. 세션 토큰으로 사용자를 정하며 요청 본문에 userId를 넣지 않는다.
/// 세션이 끝나면 인스턴스와 그 조회 캐시를 버린다.
abstract interface class UserFinancialRepository {
  /// 2026-10-22: GET /snapshot. 현재 조회 권한의 Snapshot JSON을 반환한다.
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot();

  /// 2026-10-22: POST /institution-links. 최종 동의−제외 기관 [institutionCodes]를 [write]로 저장한다.
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> institutionCodes,
    WriteContext write,
  );

  /// 2026-10-22: PATCH /account-selection. 계산에 쓸 계좌 집합 [accountIds]를 [write]로 교체 저장한다.
  Future<FinancialOutcome<WriteSuccess>> selectAccounts(
    List<String> accountIds,
    WriteContext write,
  );

  /// 2026-10-28: PATCH /settings. 월급 설정 변경 [salary]를 [write]로 저장한다. 카드 계획은 보내지 않는다.
  Future<FinancialOutcome<WriteSuccess>> updateSalarySettings(
    SalaryPatch salary,
    WriteContext write,
  );

  /// 2026-10-28: PATCH /accounts/{accountId}. 계좌 [accountId]의 이름을 [nickname]으로 [write]로 저장한다.
  /// null은 이름 해제(원래 이름으로 되돌리기)다. 잔액·상품명·계산에는 영향이 없다.
  Future<FinancialOutcome<WriteSuccess>> updateAccountNickname(
    String accountId,
    String? nickname,
    WriteContext write,
  );

  /// 2026-10-22: 세션이 끝났음을 알린다. 이후 요청과 진행 중 요청의 늦은 응답을 반영하지 않는다.
  void close();
}

/// 2026-10-22: 실제 서버가 없는 빌드에서 쓰는 구현. 모든 요청을 서비스 불가로 돌려준다.
class UnavailableUserFinancialRepository implements UserFinancialRepository {
  /// 2026-10-22: 상태 없는 인스턴스를 만든다.
  const UnavailableUserFinancialRepository();

  /// 2026-10-22: 조회하지 않고 서비스 불가를 반환한다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() async =>
      const FinancialUnavailable();

  /// 2026-10-22: 저장하지 않고 서비스 불가를 반환한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> institutionCodes,
    WriteContext write,
  ) async => const FinancialUnavailable();

  /// 2026-10-22: 저장하지 않고 서비스 불가를 반환한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> selectAccounts(
    List<String> accountIds,
    WriteContext write,
  ) async => const FinancialUnavailable();

  /// 2026-10-28: 저장하지 않고 서비스 불가를 반환한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateSalarySettings(
    SalaryPatch salary,
    WriteContext write,
  ) async => const FinancialUnavailable();

  /// 2026-10-28: 저장하지 않고 서비스 불가를 반환한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateAccountNickname(
    String accountId,
    String? nickname,
    WriteContext write,
  ) async => const FinancialUnavailable();

  /// 2026-10-22: 상태가 없으므로 할 일이 없다.
  @override
  void close() {}
}
