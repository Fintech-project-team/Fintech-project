import 'connection/access_restriction.dart';

/// 2026-10-20: 더미 JSON 형식이 계약과 맞지 않을 때 던진다. [path]는 문제 필드 위치다.
class SnapshotFormatException implements Exception {
  /// 2026-10-20: 필드 위치 [path]와 이유 [reason]으로 만든다.
  const SnapshotFormatException(this.path, this.reason);

  final String path;
  final String reason;

  /// 2026-10-20: 위치와 이유를 합친 설명을 반환한다.
  @override
  String toString() => 'SnapshotFormatException($path: $reason)';
}

/// 2026-10-20: 금액·중간 합계의 절댓값 상한(계산 규칙·데이터 계약 9,000,000,000,000원).
const int maxAbsKrw = 9000000000000;

/// 2026-10-20: 한 JSON 객체에서 타입을 엄격하게 읽는 도우미. 값을 보정하지 않는다.
/// 오류 문구는 '필수 필드 없음'과 '값의 형식이 다름'을 구분하고 기대 형식을 적는다.
class _Fields {
  /// 2026-10-20: 원본 [map]과 오류 표시용 [path]로 만든다.
  const _Fields(this.map, this.path);

  final Map<String, Object?> map;
  final String path;

  static final RegExp _businessDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final RegExp _offsetTimestamp = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$',
  );

  /// 2026-10-20: [raw]가 객체인지 확인해 도우미를 반환한다. 아니면 형식 오류.
  static _Fields of(Object? raw, String path) {
    if (raw is! Map) {
      throw SnapshotFormatException(path, 'JSON 객체가 아님(${_kind(raw)})');
    }
    return _Fields(raw.cast<String, Object?>(), path);
  }

  /// 2026-10-20: 오류 문구에 쓸 값 종류 이름을 반환한다.
  static String _kind(Object? v) => switch (v) {
    null => 'null',
    String() => '문자열',
    int() => '정수',
    num() => '소수',
    bool() => '불리언',
    List() => '배열',
    Map() => '객체',
    _ => v.runtimeType.toString(),
  };

  /// 2026-10-20: [key]의 위치 문자열을 반환한다.
  String _at(String key) => '$path.$key';

  /// 2026-10-20: 필수 [key]의 값을 반환한다. 키가 없거나 null이면 형식 오류.
  Object _required(String key, String expected) {
    if (!map.containsKey(key)) {
      throw SnapshotFormatException(_at(key), '필수 필드 없음($expected)');
    }
    final v = map[key];
    if (v == null) {
      throw SnapshotFormatException(_at(key), 'null 불가($expected 필수)');
    }
    return v;
  }

  /// 2026-10-20: 값 [v]가 기대 형식이 아닐 때 던질 예외를 만든다.
  SnapshotFormatException _wrong(String key, Object? v, String expected) =>
      SnapshotFormatException(_at(key), '$expected이어야 함(실제: ${_kind(v)})');

  /// 2026-10-20: 필수 문자열 [key]를 반환한다.
  String string(String key) {
    final v = _required(key, '문자열');
    if (v is String) return v;
    throw _wrong(key, v, '문자열');
  }

  /// 2026-10-20: null 허용 문자열 [key]를 반환한다. null은 값 미확인으로 그대로 둔다.
  String? stringOrNull(String key) {
    final v = map[key];
    if (v == null || v is String) return v as String?;
    throw _wrong(key, v, '문자열 또는 null');
  }

  /// 2026-10-20: 원 단위 정수 [v]를 검사해 반환한다. 소수·문자열·상한 초과·허용하지 않는 음수를 거절한다.
  int _checkKrw(String key, Object v, {required bool allowNegative}) {
    if (v is! int) throw _wrong(key, v, '원 단위 정수');
    if (v.abs() > maxAbsKrw) {
      throw SnapshotFormatException(_at(key), '금액 절댓값 상한 초과($v)');
    }
    if (!allowNegative && v < 0) {
      throw SnapshotFormatException(
        _at(key),
        '음수 불가(방향은 direction으로 표시, 실제: $v)',
      );
    }
    return v;
  }

  /// 2026-10-20: 필수 원 단위 정수 [key]를 반환한다. [allowNegative]가 false면 0 이상만 허용한다.
  int krw(String key, {bool allowNegative = true}) =>
      _checkKrw(key, _required(key, '원 단위 정수'), allowNegative: allowNegative);

  /// 2026-10-20: null 허용 원 단위 정수 [key]를 반환한다. null을 0으로 바꾸지 않으며 잔액 음수는 허용한다.
  int? krwOrNull(String key) {
    final v = map[key];
    if (v == null) return null;
    return _checkKrw(key, v, allowNegative: true);
  }

  /// 2026-10-23: 키 [key]가 있으면 값을 반환한다. 키 생략은 미입력(null)이 아니라 형식 오류다.
  Object? _present(String key, String expected) {
    if (!map.containsKey(key)) {
      throw SnapshotFormatException(_at(key), '필드 없음($expected)');
    }
    return map[key];
  }

  /// 2026-10-22: null 허용 0 이상 원 단위 정수 [key]를 반환한다. null은 미입력이며 0으로 바꾸지 않는다.
  /// 2026-10-23: 키는 반드시 있어야 하며 명시적 null만 미입력으로 받는다.
  int? nonNegativeKrwOrNull(String key) {
    final v = _present(key, '원 단위 정수 또는 null');
    if (v == null) return null;
    return _checkKrw(key, v, allowNegative: false);
  }

  /// 2026-10-22: null 허용 매월 날짜 [key](1~31)를 반환한다. null은 미입력이다.
  /// 2026-10-23: 키는 반드시 있어야 하며 명시적 null만 미입력으로 받는다.
  int? dayOfMonthOrNull(String key) {
    final v = _present(key, '1~31 정수 또는 null');
    if (v == null) return null;
    if (v is! int) throw _wrong(key, v, '1~31 정수 또는 null');
    if (v < 1 || v > 31) {
      throw SnapshotFormatException(_at(key), '1~31 범위가 아님($v)');
    }
    return v;
  }

  /// 2026-10-22: 필수 문자열 [key]가 [allowed] 중 하나인지 검사해 반환한다.
  String oneOf(String key, Set<String> allowed) {
    final v = string(key);
    if (!allowed.contains(v)) {
      throw SnapshotFormatException(_at(key), '허용 값이 아님("$v")');
    }
    return v;
  }

  /// 2026-10-20: 필수 0 이상 개수 [key]를 반환한다.
  int count(String key) {
    final v = _required(key, '0 이상 정수');
    if (v is! int) throw _wrong(key, v, '0 이상 정수');
    if (v < 0) throw SnapshotFormatException(_at(key), '음수 개수 불가($v)');
    return v;
  }

  /// 2026-10-20: 필수 불리언 [key]를 반환한다.
  bool boolean(String key) {
    final v = _required(key, '불리언');
    if (v is bool) return v;
    throw _wrong(key, v, '불리언');
  }

  /// 2026-10-20: 업무 날짜 문자열 [v]가 YYYY-MM-DD 형식의 실제 달력 날짜인지 검사해 원문을 반환한다.
  String _checkBusinessDate(String key, String v) {
    final parsed = _businessDate.hasMatch(v) ? DateTime.tryParse(v) : null;
    final valid =
        parsed != null &&
        '${parsed.year.toString().padLeft(4, '0')}-'
                '${parsed.month.toString().padLeft(2, '0')}-'
                '${parsed.day.toString().padLeft(2, '0')}' ==
            v;
    if (!valid) {
      throw SnapshotFormatException(_at(key), 'YYYY-MM-DD 업무 날짜가 아님("$v")');
    }
    return v;
  }

  /// 2026-10-20: 필수 업무 날짜 [key]를 원문 그대로 반환한다. 시각을 붙이지 않는다.
  String businessDate(String key) => _checkBusinessDate(key, string(key));

  /// 2026-10-20: null 허용 업무 날짜 [key]를 반환한다. null은 날짜 미확인으로 그대로 둔다.
  String? businessDateOrNull(String key) {
    final v = stringOrNull(key);
    return v == null ? null : _checkBusinessDate(key, v);
  }

  /// 2026-10-20: 시각 문자열 [v]가 시간대 오프셋을 포함한 해석 가능한 시각인지 검사해 원문을 반환한다.
  String _checkTimestamp(String key, String v) {
    if (!_offsetTimestamp.hasMatch(v) || DateTime.tryParse(v) == null) {
      throw SnapshotFormatException(_at(key), '시간대 오프셋이 있는 시각이 아님("$v")');
    }
    return v;
  }

  /// 2026-10-20: 필수 시각 [key]를 원문 그대로 반환한다. 다른 시간대로 바꾸지 않는다.
  String timestamp(String key) => _checkTimestamp(key, string(key));

  /// 2026-10-20: null 허용 시각 [key]를 반환한다. null은 시각 미확인으로 그대로 둔다.
  String? timestampOrNull(String key) {
    final v = stringOrNull(key);
    return v == null ? null : _checkTimestamp(key, v);
  }

  /// 2026-10-20: 필수 배열 [key]를 [parse]로 변환해 반환한다.
  List<T> list<T>(String key, T Function(_Fields item) parse) {
    final v = _required(key, '배열');
    if (v is! List) throw _wrong(key, v, '배열');
    return List.unmodifiable([
      for (var i = 0; i < v.length; i++) parse(of(v[i], '$path.$key[$i]')),
    ]);
  }

  /// 2026-10-23: 필수 문자열 배열 [key]를 반환한다. 문자열이 아닌 원소는 형식 오류다.
  List<String> stringList(String key) {
    final v = _required(key, '문자열 배열');
    if (v is! List) throw _wrong(key, v, '문자열 배열');
    for (var i = 0; i < v.length; i++) {
      if (v[i] is! String) {
        throw SnapshotFormatException('$path.$key[$i]', '문자열이어야 함');
      }
    }
    return List.unmodifiable(v.cast<String>());
  }

  /// 2026-10-20: 키가 없으면 null(미노출)을, 있으면 배열로 변환해 반환한다. 빈 배열과 구분한다.
  List<T>? listOrAbsent<T>(String key, T Function(_Fields item) parse) {
    if (!map.containsKey(key)) return null;
    return list(key, parse);
  }
}

/// 2026-10-20: 연결 가능한 기관 한 곳(연결 전에도 제공되는 목록).
class Institution {
  /// 2026-10-20: 기관 코드·종류·이름과 보유 계좌·카드 수로 만든다.
  const Institution({
    required this.code,
    required this.kind,
    required this.name,
    required this.accountCount,
    required this.cardCount,
  });

  final String code;
  final String kind;
  final String name;
  final int accountCount;
  final int cardCount;

  static Institution _parse(_Fields f) => Institution(
    code: f.string('code'),
    kind: f.string('kind'),
    name: f.string('name'),
    accountCount: f.count('accountCount'),
    cardCount: f.count('cardCount'),
  );
}

/// 2026-10-20: 계좌 한 개. 잔액은 원천 값이며 사용자가 수정하지 않는다.
class Account {
  /// 2026-10-20: 원천 필드로 만든다. [balanceKrw]가 null이면 잔액 미확인이다.
  const Account({
    required this.accountId,
    required this.institutionCode,
    required this.productType,
    required this.productName,
    required this.maskedNumber,
    required this.balanceKrw,
    required this.asOf,
    required this.included,
    required this.nickname,
    this.sourceVersion,
  });

  final String accountId;
  final String institutionCode;
  final String productType;
  final String productName;
  final String maskedNumber;
  final int? balanceKrw;
  final String? asOf;
  final bool included;
  final String? nickname;

  /// 2026-10-23: 이 계좌 원천의 자료 버전. 키가 없으면 null이며 같은 버전이라고 추정하지 않는다.
  final String? sourceVersion;

  static Account _parse(_Fields f) => Account(
    accountId: f.string('accountId'),
    institutionCode: f.string('institutionCode'),
    productType: f.string('productType'),
    productName: f.string('productName'),
    maskedNumber: f.string('maskedNumber'),
    balanceKrw: f.krwOrNull('balanceKRW'),
    asOf: f.timestampOrNull('asOf'),
    included: f.boolean('included'),
    nickname: f.stringOrNull('nickname'),
    sourceVersion: f.stringOrNull('sourceVersion'),
  );
}

/// 2026-10-20: 카드 한 장.
class PaymentCard {
  /// 2026-10-20: 원천 필드로 만든다. [withdrawalAccountId]가 null이면 결제 계좌 미확인이다.
  const PaymentCard({
    required this.cardId,
    required this.institutionCode,
    required this.productName,
    required this.maskedNumber,
    required this.cardType,
    required this.withdrawalAccountId,
    this.withdrawalAccountRestricted = false,
    this.scheduleEvidence = const [],
  });

  final String cardId;
  final String institutionCode;
  final String productName;
  final String maskedNumber;
  final String cardType;
  final String? withdrawalAccountId;

  /// 2026-10-22: 출금 계좌가 미연결이라 응답에서 생략됐으면 true다(원래 미확인인 null과 구분).
  final bool withdrawalAccountRestricted;

  /// 2026-10-22: 카드사가 확인한 결제 일정. 빈 목록은 일정 미확보이며 반복 주기를 추정하지 않는다.
  final List<CardSchedule> scheduleEvidence;

  static PaymentCard _parse(_Fields f) => PaymentCard(
    cardId: f.string('cardId'),
    institutionCode: f.string('institutionCode'),
    productName: f.string('productName'),
    maskedNumber: f.string('maskedNumber'),
    cardType: f.string('cardType'),
    withdrawalAccountId: f.stringOrNull('withdrawalAccountId'),
    withdrawalAccountRestricted: !f.map.containsKey('withdrawalAccountId'),
    scheduleEvidence: f.list('scheduleEvidence', CardSchedule._parse),
  );
}

/// 2026-10-22: 카드사가 확인한 결제 일정 하나. 이용기간은 양 끝을 함께 주며, 결제일만 확인되면 기간은 null이다.
class CardSchedule {
  /// 2026-10-22: 이용기간 [periodStart]·[periodEnd], 결제일 [dueDate], 근거 [evidenceRef]로 만든다.
  const CardSchedule({
    required this.periodStart,
    required this.periodEnd,
    required this.dueDate,
    required this.evidenceRef,
  });

  final String? periodStart;
  final String? periodEnd;
  final String? dueDate;
  final String evidenceRef;

  /// 2026-10-22: 일정 하나를 읽는다. 기간 한쪽만 있거나 날짜가 모두 없는 빈 일정은 형식 오류다.
  static CardSchedule _parse(_Fields f) {
    final start = f.businessDateOrNull('periodStart');
    final end = f.businessDateOrNull('periodEnd');
    final due = f.businessDateOrNull('dueDate');
    if ((start == null) != (end == null)) {
      throw SnapshotFormatException(f.path, '이용기간은 시작·끝을 함께 제공해야 함');
    }
    if (start == null && due == null) {
      throw SnapshotFormatException(f.path, '날짜가 모두 없는 빈 일정');
    }
    return CardSchedule(
      periodStart: start,
      periodEnd: end,
      dueDate: due,
      evidenceRef: f.string('evidenceRef'),
    );
  }
}

/// 2026-10-22: 월급 설정. 각 값의 null은 사용자 미입력이며 0이나 임의 계좌로 바꾸지 않는다.
class SalarySetting {
  /// 2026-10-22: 월급일 [salaryDay], 금액 [salaryAmountKrw], 급여 계좌 [salaryAccountId]와
  /// 급여 계좌가 미연결로 숨겨졌는지 [salaryAccountRestricted]로 만든다.
  const SalarySetting({
    required this.salaryDay,
    required this.salaryAmountKrw,
    required this.salaryAccountId,
    this.salaryAccountRestricted = false,
    this.receiptEvidence,
  });

  final int? salaryDay;
  final int? salaryAmountKrw;
  final String? salaryAccountId;

  /// 2026-10-22: 급여 계좌가 미연결이라 응답에서 생략됐으면 true다(미입력 null과 구분).
  final bool salaryAccountRestricted;

  /// 2026-10-23: 월별 급여 입금 근거. null은 키가 생략된 것(접근 제한)이며 []는 확인된 근거 없음이다.
  final List<SalaryReceiptRecord>? receiptEvidence;

  static SalarySetting _parse(_Fields f) {
    return SalarySetting(
      salaryDay: f.dayOfMonthOrNull('salaryDay'),
      salaryAmountKrw: f.nonNegativeKrwOrNull('salaryAmountKRW'),
      salaryAccountId: f.stringOrNull('salaryAccountId'),
      salaryAccountRestricted: !f.map.containsKey('salaryAccountId'),
      receiptEvidence: f.listOrAbsent(
        'receiptEvidence',
        SalaryReceiptRecord._parse,
      ),
    );
  }
}

/// 2026-10-23: 월급 회차 하나의 입금 근거. 확인 상태를 바꾸거나 금액으로 추정하지 않는다.
class SalaryReceiptRecord {
  /// 2026-10-23: 예정일 [expectedPayDate], 근거 거래 [transactionIds], 확인 상태 [confirmation]으로 만든다.
  const SalaryReceiptRecord({
    required this.expectedPayDate,
    required this.transactionIds,
    required this.confirmation,
  });

  final String expectedPayDate;
  final List<String> transactionIds;

  /// 2026-10-23: unknown·partial·confirmed 중 하나다.
  final String confirmation;

  static SalaryReceiptRecord _parse(_Fields f) => SalaryReceiptRecord(
    expectedPayDate: f.businessDate('expectedPayDate'),
    transactionIds: f.stringList('transactionIds'),
    confirmation: f.oneOf('confirmation', const {
      'unknown',
      'partial',
      'confirmed',
    }),
  );
}

/// 2026-10-22: 카드별 사용자 계획 결제일. [plannedPaymentDay]가 null이면 사용자 설정이 없다.
class CardPlan {
  /// 2026-10-22: 카드 [cardId]와 계획 결제일 [plannedPaymentDay]로 만든다.
  const CardPlan({required this.cardId, required this.plannedPaymentDay});

  final String cardId;
  final int? plannedPaymentDay;

  static CardPlan _parse(_Fields f) => CardPlan(
    cardId: f.string('cardId'),
    plannedPaymentDay: f.dayOfMonthOrNull('plannedPaymentDay'),
  );
}

/// 2026-10-22: 확정 사용자 설정(settings). 미연결 카드의 계획은 생략되고 settings 제한 표식으로 알린다.
class FinancialSettings {
  /// 2026-10-22: 월급 설정 [salary]와 카드 계획 [cardPlans]로 만든다.
  const FinancialSettings({required this.salary, required this.cardPlans});

  final SalarySetting salary;
  final List<CardPlan> cardPlans;

  static FinancialSettings _parse(_Fields f) => FinancialSettings(
    salary: SalarySetting._parse(
      _Fields.of(f._required('salary', '객체'), '${f.path}.salary'),
    ),
    cardPlans: f.list('cardPlans', CardPlan._parse),
  );
}

/// 2026-10-22: 모아둘 돈(보호 설정액) 하나. 실제 적립 거래나 매월 적립액이 아니다.
class Reserve {
  /// 2026-10-22: 서버 ID [reserveId], 보호 계좌 [accountId], 이름 [label], 설정액 [amountKrw], 취소 시각 [cancelledAt]으로 만든다.
  const Reserve({
    required this.reserveId,
    required this.accountId,
    required this.label,
    required this.amountKrw,
    required this.cancelledAt,
  });

  final String reserveId;
  final String accountId;
  final String label;
  final int amountKrw;
  final String? cancelledAt;

  static Reserve _parse(_Fields f) => Reserve(
    reserveId: f.string('reserveId'),
    accountId: f.string('accountId'),
    label: f.string('label'),
    amountKrw: f.krw('amountKRW', allowNegative: false),
    cancelledAt: f.timestampOrNull('cancelledAt'),
  );
}

/// 2026-10-22: 예정 지출(의무) 하나. 금액·날짜는 사용자가 확인한 미지급 계획이며 화면에서 계산하지 않는다.
class Obligation {
  /// 2026-10-22: 서버 ID [obligationId], 이름 [label], 출금 계좌 [withdrawalAccountId], 금액 [amountKrw],
  /// 날짜 [dueDate], 상태 [status](active·cancelled)로 만든다.
  const Obligation({
    required this.obligationId,
    required this.label,
    required this.withdrawalAccountId,
    required this.amountKrw,
    required this.dueDate,
    required this.status,
  });

  final String obligationId;
  final String label;
  final String withdrawalAccountId;
  final int amountKrw;
  final String dueDate;
  final String status;

  static Obligation _parse(_Fields f) => Obligation(
    obligationId: f.string('obligationId'),
    label: f.string('label'),
    withdrawalAccountId: f.string('withdrawalAccountId'),
    amountKrw: f.krw('amountKRW', allowNegative: false),
    dueDate: f.businessDate('dueDate'),
    status: f.oneOf('status', const {'active', 'cancelled'}),
  );
}

/// 2026-10-23: 응답에 포함되지 않은 거래 참조의 확보 상태(data-model §9).
/// unavailable은 원거래가 없다는 뜻이 아니라 권한은 있으나 원천을 확보하지 못한 것이다.
class ReferenceResolution {
  /// 2026-10-23: 거래 [transactionId], 상태 [status](resolved·unavailable), 이유 [reason]으로 만든다.
  const ReferenceResolution({
    required this.transactionId,
    required this.status,
    required this.reason,
  });

  final String transactionId;
  final String status;
  final String? reason;

  static ReferenceResolution _parse(_Fields f) => ReferenceResolution(
    transactionId: f.string('transactionId'),
    status: f.oneOf('status', const {'resolved', 'unavailable'}),
    reason: f.stringOrNull('reason'),
  );
}

/// 2026-10-23: 모아둘 돈을 예정 지출에 명시 배정한 기록(O의 근거). 배정은 계좌 이체가 아니다.
class Allocation {
  /// 2026-10-23: [allocationId], [reserveId], [obligationId], 배정 총액 [amountKrw](해제 누계 포함),
  /// 해제 누계 [releasedKrw]로 만든다.
  const Allocation({
    required this.allocationId,
    required this.reserveId,
    required this.obligationId,
    required this.amountKrw,
    required this.releasedKrw,
  });

  final String allocationId;
  final String reserveId;
  final String obligationId;
  final int amountKrw;
  final int releasedKrw;

  static Allocation _parse(_Fields f) => Allocation(
    allocationId: f.string('allocationId'),
    reserveId: f.string('reserveId'),
    obligationId: f.string('obligationId'),
    amountKrw: f.krw('amountKRW', allowNegative: false),
    releasedKrw: f.krw('releasedKRW', allowNegative: false),
  );
}

/// 2026-10-23: 확인된 실제 출금과 예정 지출의 지급 연결. 원천 거래를 고치지 않는다.
class Settlement {
  /// 2026-10-23: [linkId], [obligationId], 출금 거래 [transactionId], 배분액 [allocatedKrw], 방식 [method],
  /// 근거 [evidenceRefs], 무효 시각 [invalidatedAt](null 유효)으로 만든다.
  const Settlement({
    required this.linkId,
    required this.obligationId,
    required this.transactionId,
    required this.allocatedKrw,
    required this.method,
    required this.evidenceRefs,
    required this.invalidatedAt,
  });

  final String linkId;
  final String obligationId;
  final String transactionId;
  final int allocatedKrw;
  final String method;
  final List<String> evidenceRefs;
  final String? invalidatedAt;

  static Settlement _parse(_Fields f) => Settlement(
    linkId: f.string('linkId'),
    obligationId: f.string('obligationId'),
    transactionId: f.string('transactionId'),
    allocatedKrw: f.krw('allocatedKRW', allowNegative: false),
    method: f.oneOf('method', const {'automatic', 'manual'}),
    evidenceRefs: f.stringList('evidenceRefs'),
    invalidatedAt: f.timestampOrNull('invalidatedAt'),
  );
}

/// 2026-10-20: 거래 한 건. [amountKrw]는 비음수 크기이고 방향은 [direction]으로 해석한다.
class SourceTransaction {
  /// 2026-10-20: 원천 필드로 만든다. 날짜 필드의 null은 값 미확인이다.
  const SourceTransaction({
    required this.transactionId,
    required this.accountId,
    required this.cardId,
    required this.recordKind,
    required this.amountKrw,
    required this.direction,
    required this.status,
    required this.merchantName,
    required this.bookingDate,
    required this.purchaseDate,
    required this.withdrawalDate,
    required this.payseTransactionType,
    this.reflectionReason,
    this.sourceVersion,
    this.accountRestricted = false,
    this.cardRestricted = false,
  });

  final String transactionId;
  final String? accountId;
  final String? cardId;

  /// 2026-10-22: 반대쪽 계좌·카드가 미연결이라 응답에서 생략됐으면 true다(원래 미확인인 null과 구분).
  final bool accountRestricted;
  final bool cardRestricted;
  final String recordKind;
  final int amountKrw;
  final String direction;
  final String status;
  final String merchantName;
  final String? bookingDate;
  final String? purchaseDate;
  final String? withdrawalDate;
  final String? payseTransactionType;

  /// 2026-10-23: 같은 sourceVersion·잔액 asOf에 반영됐는지(reflected·not_reflected·not_applicable·unknown).
  /// 키가 없으면 null이며 반영 여부를 추정하지 않는다.
  final String? reflectionReason;

  /// 2026-10-23: 이 거래 원천의 자료 버전. 키가 없으면 null이며 같은 버전이라고 추정하지 않는다.
  final String? sourceVersion;

  /// 2026-10-20: 거래 한 건을 읽는다. 계좌·카드 ID가 모두 null이면 계약 위반(적어도 하나 필요)이다.
  static SourceTransaction _parse(_Fields f) {
    final accountId = f.stringOrNull('accountId');
    final cardId = f.stringOrNull('cardId');
    if (accountId == null && cardId == null) {
      throw SnapshotFormatException(
        '${f.path}.accountId',
        'accountId와 cardId가 모두 null(적어도 하나 필요)',
      );
    }
    return SourceTransaction(
      transactionId: f.string('transactionId'),
      accountId: accountId,
      cardId: cardId,
      recordKind: f.string('recordKind'),
      amountKrw: f.krw('amountKRW', allowNegative: false),
      direction: f.string('direction'),
      status: f.string('status'),
      merchantName: f.string('merchantName'),
      bookingDate: f.businessDateOrNull('bookingDate'),
      purchaseDate: f.businessDateOrNull('purchaseDate'),
      withdrawalDate: f.businessDateOrNull('withdrawalDate'),
      payseTransactionType: f.stringOrNull('payseTransactionType'),
      reflectionReason: f.map.containsKey('reflectionReason')
          ? f.oneOf('reflectionReason', const {
              'reflected',
              'not_reflected',
              'not_applicable',
              'unknown',
            })
          : null,
      sourceVersion: f.stringOrNull('sourceVersion'),
      accountRestricted: !f.map.containsKey('accountId'),
      cardRestricted: !f.map.containsKey('cardId'),
    );
  }
}

/// 2026-10-20: 계좌·카드별 조회 범위와 상태(완전·부분·실패 구분용).
class Coverage {
  /// 2026-10-20: 대상 종류·ID·상태와 요청 기간으로 만든다.
  const Coverage({
    required this.targetKind,
    required this.targetId,
    required this.status,
    required this.requestedStart,
    required this.requestedEnd,
  });

  final String targetKind;
  final String targetId;
  final String status;
  final String requestedStart;
  final String requestedEnd;

  static Coverage _parse(_Fields f) => Coverage(
    targetKind: f.string('targetKind'),
    targetId: f.string('targetId'),
    status: f.string('status'),
    requestedStart: f.businessDate('requestedStart'),
    requestedEnd: f.businessDate('requestedEnd'),
  );
}

/// 2026-10-22: 부분 연결 제한 표식 하나(docs/api-response-models.md §2.1). 숨긴 대상의 ID·개수·금액은 담지 않는다.
class AccessRestriction {
  /// 2026-10-22: 공개 위치 [ownerType]·[ownerId]·[field]와 비공개 자원 종류 [targetKind]로 만든다.
  const AccessRestriction({
    required this.ownerType,
    required this.ownerId,
    required this.field,
    required this.targetKind,
  });

  final String ownerType;
  final String? ownerId;
  final String field;
  final String targetKind;

  /// 2026-10-22: 등록 조합·ownerId 규칙을 검사하며 한 표식을 읽는다. 맞지 않으면 형식 오류다.
  static AccessRestriction _parse(_Fields f) {
    final ownerType = f.string('ownerType');
    final ownerId = f.stringOrNull('ownerId');
    final field = f.string('field');
    final targetKind = f.string('targetKind');
    final valid = isValidRestriction(
      ownerType: ownerType,
      ownerId: ownerId,
      field: field,
      targetKind: targetKind,
      reason: f.string('reason'),
    );
    if (!valid) {
      throw SnapshotFormatException(f.path, '등록되지 않은 제한 조합');
    }
    return AccessRestriction(
      ownerType: ownerType,
      ownerId: ownerId,
      field: field,
      targetKind: targetKind,
    );
  }
}

/// 2026-10-20: 한 사용자의 불변 금융 스냅샷. 원천 값을 그대로 담고 합계·U를 계산하지 않는다.
class FinancialSnapshot {
  /// 2026-10-20: 파싱된 필드로 만든다. [accounts]·[cards]·[transactions]가 null이면 원문에 해당 묶음이 없는 것(미노출)이다.
  const FinancialSnapshot({
    required this.userId,
    required this.schemaVersion,
    required this.currency,
    required this.dataVersion,
    required this.sourceVersion,
    required this.ruleVersion,
    required this.asOf,
    required this.institutions,
    required this.institutionLinkCount,
    required this.coverage,
    required this.accounts,
    required this.cards,
    required this.transactions,
    this.settings,
    this.reserves,
    this.obligations,
    this.allocations,
    this.settlements,
    this.relatedTransactions,
    this.referenceResolutions,
    this.hasMoreTransactions = false,
    this.accessRestrictions = const [],
  });

  /// 2026-10-22: 이 앱이 읽는 형식. 원본(PAYSE-DRAFT-2, 개발용 원본 직접 보기)과 HTTP 표현(PAYSE-API-0.6-2).
  static const Set<String> supportedSchemas = {
    'PAYSE-DRAFT-2',
    'PAYSE-API-0.6-2',
  };

  final String userId;
  final String schemaVersion;
  final String currency;
  final String dataVersion;
  final String sourceVersion;
  final String ruleVersion;

  /// 2026-10-20: 기준 시각 원문(오프셋 포함). 다른 시간대로 바꾸지 않는다.
  final String asOf;
  final List<Institution> institutions;
  final int institutionLinkCount;
  final List<Coverage> coverage;
  final List<Account>? accounts;
  final List<PaymentCard>? cards;
  final List<SourceTransaction>? transactions;

  /// 2026-10-22: 확정 사용자 설정·모아둘 돈·예정 지출. null이면 원문에 해당 묶음이 없는 것(연결 전)이다.
  final FinancialSettings? settings;
  final List<Reserve>? reserves;
  final List<Obligation>? obligations;

  /// 2026-10-23: 보호액 배정·지급 연결. null이면 원문에 해당 묶음이 없는 것(연결 전)이다.
  final List<Allocation>? allocations;
  final List<Settlement>? settlements;

  /// 2026-10-23: 조회 기간 밖 원거래·정산 근거. 분석 대상 거래로 다시 세지 않는다.
  final List<SourceTransaction>? relatedTransactions;

  /// 2026-10-23: 응답에 없는 거래 참조의 확보 상태. 미확보(unavailable)를 계약 위반과 구분하는 데 쓴다.
  final List<ReferenceResolution>? referenceResolutions;

  /// 2026-10-23: 거래 다음 페이지가 남아 있으면 true다. 받지 못한 거래를 '없음'으로 판단하지 않는다.
  final bool hasMoreTransactions;

  /// 2026-10-22: 주 계좌가 미연결이라 일부 모아둘 돈이 응답에서 생략됐으면 true다.
  bool get reservesRestricted => isRestricted('response', null, 'reserves');

  /// 2026-10-22: 주 계좌가 미연결이라 일부 예정 지출이 응답에서 생략됐으면 true다.
  bool get obligationsRestricted =>
      isRestricted('response', null, 'obligations');

  /// 2026-10-22: 미연결 카드의 계획 결제일이 응답에서 생략됐으면 true다.
  bool get cardPlansRestricted => isRestricted('settings', null, 'cardPlans');

  /// 2026-10-22: HTTP 표현(PAYSE-API-0.6-2) 연결 후 응답의 필수 키(docs/api-response-models.md §1).
  /// 연결 전 응답에는 이 키들이 없어야 한다(머리 7개+institutions·institutionLinks·coverage의 10개만).
  static const List<String> connectedApiKeys = [
    'accounts',
    'cards',
    'transactions',
    'statements',
    'settings',
    'obligations',
    'reserves',
    'allocations',
    'settlements',
    'recurringPlans',
    'recurringDecisions',
    'recurringPlanRevisions',
    'occurrenceOverrides',
    'relatedTransactions',
    'referenceResolutions',
    'transactionRelations',
    'occurrenceLinks',
    'page',
    'accessRestrictions',
  ];

  /// 2026-10-22: 제한 표식 ownerType별로 기준 객체가 들어 있는 응답 배열과 ID 필드.
  static const Map<String, List<(String, String)>> _ownerSources = {
    'card': [('cards', 'cardId')],
    'transaction': [
      ('transactions', 'transactionId'),
      ('relatedTransactions', 'transactionId'),
    ],
    'statement': [('statements', 'statementId')],
    'obligation': [('obligations', 'obligationId')],
    'allocation': [('allocations', 'allocationId')],
    'recurringPlan': [('recurringPlans', 'planId')],
    'recurringPlanRevision': [('recurringPlanRevisions', 'revisionId')],
  };

  /// 2026-10-22: 부분 연결 제한 표식. 연결 권한 때문에 숨긴 위치를 '값 없음'과 구분하는 데 쓴다.
  final List<AccessRestriction> accessRestrictions;

  /// 2026-10-22: ([ownerType], [ownerId], [field]) 위치에 연결 제한 표식이 있으면 true를 반환한다.
  bool isRestricted(String ownerType, String? ownerId, String field) =>
      accessRestrictions.any(
        (r) =>
            r.ownerType == ownerType &&
            r.ownerId == ownerId &&
            r.field == field,
      );

  /// 2026-10-20: 디코드된 JSON [json]을 스냅샷으로 바꾼다. 형식이 맞지 않으면 SnapshotFormatException을 던진다.
  /// 화면에 필요한 필드만 읽고 나머지 필드는 무시한다. 값은 보정하지 않는다.
  factory FinancialSnapshot.fromJson(Object? json) {
    final f = _Fields.of(json, r'$');
    final currency = f.string('currency');
    if (currency != 'KRW') {
      throw SnapshotFormatException(r'$.currency', 'KRW만 지원(실제: "$currency")');
    }
    final schema = f.string('schemaVersion');
    if (!supportedSchemas.contains(schema)) {
      throw SnapshotFormatException(r'$.schemaVersion', '지원하지 않는 형식');
    }
    final links = f._required('institutionLinks', '배열');
    if (links is! List) throw f._wrong('institutionLinks', links, '배열');
    if (schema == 'PAYSE-API-0.6-2') _checkApiShape(f, links.isNotEmpty);
    final restrictions =
        f.listOrAbsent('accessRestrictions', AccessRestriction._parse) ??
        const <AccessRestriction>[];
    _checkRestrictionOwners(f, restrictions);
    final cards = f.listOrAbsent('cards', PaymentCard._parse);
    final transactions = f.listOrAbsent(
      'transactions',
      SourceTransaction._parse,
    );
    bool marked(String type, String? id, String field) => restrictions.any(
      (r) => r.ownerType == type && r.ownerId == id && r.field == field,
    );
    for (final c in cards ?? const <PaymentCard>[]) {
      if (c.withdrawalAccountRestricted &&
          !marked('card', c.cardId, 'withdrawalAccountId')) {
        throw SnapshotFormatException(
          r'$.cards',
          'withdrawalAccountId 생략에 제한 표식이 없음',
        );
      }
    }
    final accounts = f.listOrAbsent('accounts', Account._parse);
    final settings = f.map.containsKey('settings')
        ? FinancialSettings._parse(
            _Fields.of(f._required('settings', '객체'), r'$.settings'),
          )
        : null;
    final reserves = f.listOrAbsent('reserves', Reserve._parse);
    final obligations = f.listOrAbsent('obligations', Obligation._parse);
    final allocations = f.listOrAbsent('allocations', Allocation._parse);
    final settlements = f.listOrAbsent('settlements', Settlement._parse);
    _checkLinks(reserves, obligations, allocations, settlements);
    _checkSettingsAndPlans(
      f: f,
      accounts: accounts,
      cards: cards,
      settings: settings,
      reserves: reserves,
      obligations: obligations,
      marked: marked,
    );
    for (final t in transactions ?? const <SourceTransaction>[]) {
      if ((t.accountRestricted &&
              !marked('transaction', t.transactionId, 'accountId')) ||
          (t.cardRestricted &&
              !marked('transaction', t.transactionId, 'cardId'))) {
        throw SnapshotFormatException(
          r'$.transactions',
          '계좌·카드 참조 생략에 제한 표식이 없음',
        );
      }
    }
    return FinancialSnapshot._fromParts(
      f: f,
      schema: schema,
      currency: currency,
      links: links,
      accounts: accounts,
      cards: cards,
      transactions: transactions,
      settings: settings,
      reserves: reserves,
      obligations: obligations,
      allocations: allocations,
      settlements: settlements,
      restrictions: restrictions,
    );
  }

  /// 2026-10-23: 배정·지급 연결이 응답에 공개된 보호액·의무만 가리키는지 검사한다.
  /// 부모가 숨겨지면 자식 행도 숨기는 계약(api-response-models §2.3)이라 고아 참조는 형식 오류다.
  static void _checkLinks(
    List<Reserve>? reserves,
    List<Obligation>? obligations,
    List<Allocation>? allocations,
    List<Settlement>? settlements,
  ) {
    final reserveIds = {
      for (final r in reserves ?? const <Reserve>[]) r.reserveId,
    };
    final obligationIds = {
      for (final o in obligations ?? const <Obligation>[]) o.obligationId,
    };
    for (final a in allocations ?? const <Allocation>[]) {
      if (!reserveIds.contains(a.reserveId) ||
          !obligationIds.contains(a.obligationId)) {
        throw const SnapshotFormatException(
          r'$.allocations',
          '응답에 없는 보호액·의무를 가리킴',
        );
      }
    }
    for (final link in settlements ?? const <Settlement>[]) {
      if (!obligationIds.contains(link.obligationId)) {
        throw const SnapshotFormatException(r'$.settlements', '응답에 없는 의무를 가리킴');
      }
    }
  }

  /// 2026-10-22: 설정·모아둘 돈·예정 지출의 참조와 생략 표식을 검사한다. 참조 대상이 응답에 없거나,
  /// 생략에 제한 표식이 없으면 형식 오류다(숨긴 정보를 다른 값으로 대신하지 않음).
  static void _checkSettingsAndPlans({
    required _Fields f,
    required List<Account>? accounts,
    required List<PaymentCard>? cards,
    required FinancialSettings? settings,
    required List<Reserve>? reserves,
    required List<Obligation>? obligations,
    required bool Function(String type, String? id, String field) marked,
  }) {
    final accountIds = {
      for (final a in accounts ?? const <Account>[]) a.accountId,
    };
    final cardIds = {for (final c in cards ?? const <PaymentCard>[]) c.cardId};
    if (settings != null) {
      final salary = settings.salary;
      if (salary.salaryAccountRestricted &&
          !marked('settings', null, 'salary.salaryAccountId')) {
        throw const SnapshotFormatException(
          r'$.settings.salary',
          'salaryAccountId 생략에 제한 표식이 없음',
        );
      }
      final salaryMap = (f.map['settings']! as Map)['salary']! as Map;
      if (!salaryMap.containsKey('receiptEvidence') &&
          !marked('settings', null, 'salary.receiptEvidence')) {
        throw const SnapshotFormatException(
          r'$.settings.salary',
          'receiptEvidence 생략에 제한 표식이 없음',
        );
      }
      final id = salary.salaryAccountId;
      if (id != null && !accountIds.contains(id)) {
        throw const SnapshotFormatException(
          r'$.settings.salary.salaryAccountId',
          '응답에 없는 계좌',
        );
      }
      for (final plan in settings.cardPlans) {
        if (!cardIds.contains(plan.cardId)) {
          throw const SnapshotFormatException(
            r'$.settings.cardPlans',
            '응답에 없는 카드',
          );
        }
      }
    }
    for (final r in reserves ?? const <Reserve>[]) {
      if (!accountIds.contains(r.accountId)) {
        throw const SnapshotFormatException(r'$.reserves', '응답에 없는 계좌');
      }
    }
    for (final o in obligations ?? const <Obligation>[]) {
      if (!accountIds.contains(o.withdrawalAccountId)) {
        throw const SnapshotFormatException(r'$.obligations', '응답에 없는 계좌');
      }
    }
  }

  /// 2026-10-22: 읽은 부분들로 스냅샷을 만든다. [fromJson]이 검사를 마친 뒤 부른다.
  factory FinancialSnapshot._fromParts({
    required _Fields f,
    required String schema,
    required String currency,
    required List<Object?> links,
    required List<Account>? accounts,
    required List<PaymentCard>? cards,
    required List<SourceTransaction>? transactions,
    required FinancialSettings? settings,
    required List<Reserve>? reserves,
    required List<Obligation>? obligations,
    required List<Allocation>? allocations,
    required List<Settlement>? settlements,
    required List<AccessRestriction> restrictions,
  }) {
    final page = f.map['page'];
    return FinancialSnapshot(
      userId: f.string('userId'),
      schemaVersion: schema,
      currency: currency,
      dataVersion: f.string('dataVersion'),
      sourceVersion: f.string('sourceVersion'),
      ruleVersion: f.string('ruleVersion'),
      asOf: f.timestamp('asOf'),
      institutions: f.list('institutions', Institution._parse),
      institutionLinkCount: links.length,
      coverage: f.list('coverage', Coverage._parse),
      accounts: accounts,
      cards: cards,
      transactions: transactions,
      settings: settings,
      reserves: reserves,
      obligations: obligations,
      allocations: allocations,
      settlements: settlements,
      relatedTransactions: f.listOrAbsent(
        'relatedTransactions',
        SourceTransaction._parse,
      ),
      referenceResolutions: f.listOrAbsent(
        'referenceResolutions',
        ReferenceResolution._parse,
      ),
      hasMoreTransactions: page is Map && page['nextCursor'] != null,
      accessRestrictions: restrictions,
    );
  }

  /// 2026-10-22: HTTP 응답의 연결 전·후 키 구성을 검사한다. 연결 후([connected])에는 필수 배열·settings·page·
  /// accessRestrictions가 모두 있어야 하고(누락을 '해당 없음'으로 받지 않음), 연결 전에는 금융 키가 없어야 한다.
  /// 연결 후 settings·page는 객체, 나머지는 배열이어야 하며 null을 허용하지 않는다.
  static void _checkApiShape(_Fields f, bool connected) {
    for (final key in connectedApiKeys) {
      final present = f.map.containsKey(key);
      if (connected && !present) {
        throw SnapshotFormatException('\$.$key', '연결 후 응답의 필수 키 없음');
      }
      if (connected) {
        final value = f.map[key];
        final ok = key == 'settings' || key == 'page'
            ? value is Map
            : value is List;
        if (!ok) {
          throw SnapshotFormatException('\$.$key', '연결 후 응답의 필수 키 형식이 다름');
        }
      }
      if (!connected && present) {
        throw SnapshotFormatException('\$.$key', '연결 전 응답에 금융 키가 있음');
      }
    }
  }

  /// 2026-10-22: 일반 객체 제한 표식의 ownerId가 이 응답에 실제로 공개된 객체인지 검사한다(§2.1).
  /// 다음 페이지가 남은 응답(page.nextCursor가 있음)에서는 아직 받지 않은 거래를 기준으로 한 표식을 허용한다.
  static void _checkRestrictionOwners(
    _Fields f,
    List<AccessRestriction> restrictions,
  ) {
    final page = f.map['page'];
    final morePages = page is Map && page['nextCursor'] != null;
    for (final r in restrictions) {
      final sources = _ownerSources[r.ownerType];
      if (sources == null) continue;
      final found = sources.any((source) {
        final rows = f.map[source.$1];
        return rows is List &&
            rows.any((row) => row is Map && row[source.$2] == r.ownerId);
      });
      if (!found && !(r.ownerType == 'transaction' && morePages)) {
        throw SnapshotFormatException(
          r'$.accessRestrictions',
          '제한 표식의 기준 객체가 응답에 공개되지 않음',
        );
      }
    }
  }
}
