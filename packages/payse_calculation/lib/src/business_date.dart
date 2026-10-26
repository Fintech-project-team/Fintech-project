import 'money.dart';

/// 2026-10-23: Asia/Seoul 업무 날짜(시각 없음). 서울은 일광절약이 없어 항상 +09:00으로 변환한다.
class BusinessDate implements Comparable<BusinessDate> {
  const BusinessDate._(this.year, this.month, this.day);

  /// 2026-10-23: 실제 달력에 있는 [year]-[month]-[day]로 만든다. 없는 날짜는 invalidDate 오류다.
  factory BusinessDate(int year, int month, int day) {
    if (year < 1 ||
        year > 9999 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > daysInMonth(year, month)) {
      throw CalculationInputException(
        InputErrorCode.invalidDate,
        'BusinessDate',
        '없는 날짜($year-$month-$day)',
      );
    }
    return BusinessDate._(year, month, day);
  }

  final int year;
  final int month;
  final int day;

  static final RegExp _pattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  /// 2026-10-23: YYYY-MM-DD [text]를 엄격히 읽는다. 형식·달력 오류는 [path] 위치의 invalidDate 오류다.
  static BusinessDate parse(String text, String path) {
    final m = _pattern.firstMatch(text);
    if (m == null) {
      throw CalculationInputException(
        InputErrorCode.invalidDate,
        path,
        'YYYY-MM-DD 형식이 아님($text)',
      );
    }
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)) {
      throw CalculationInputException(
        InputErrorCode.invalidDate,
        path,
        '없는 날짜($text)',
      );
    }
    return BusinessDate._(year, month, day);
  }

  /// 2026-10-23: 시각 [instant]의 서울 업무 날짜를 반환한다.
  static BusinessDate inSeoul(DateTime instant) {
    final seoul = instant.toUtc().add(const Duration(hours: 9));
    return BusinessDate._(seoul.year, seoul.month, seoul.day);
  }

  /// 2026-10-23: [year]년 [month]월의 날짜 수를 반환한다(윤년 반영).
  static int daysInMonth(int year, int month) =>
      DateTime.utc(year, month + 1, 0).day;

  /// 2026-10-23: [year]년 [month]월의 [dayOfMonth]일을 반환한다. 없는 날이면 말일과 보정 여부 true를 반환한다.
  static ({BusinessDate date, bool monthEndAdjusted}) monthly(
    int year,
    int month,
    int dayOfMonth,
  ) {
    final last = daysInMonth(year, month);
    final adjusted = dayOfMonth > last;
    return (
      date: BusinessDate._(year, month, adjusted ? last : dayOfMonth),
      monthEndAdjusted: adjusted,
    );
  }

  /// 2026-10-23: [days]일 뒤(음수면 앞) 날짜를 반환한다.
  BusinessDate addDays(int days) {
    final d = DateTime.utc(year, month, day + days);
    return BusinessDate._(d.year, d.month, d.day);
  }

  /// 2026-10-23: 이 날짜에서 달력 [months]개월을 한 번에 더한 날짜를 반환한다. 없는 날은 말일로 보정한다.
  /// 매번 원래 기준일에서 더하므로 2/28 같은 보정 결과가 다음 달 계산에 누적되지 않는다.
  BusinessDate addMonthsClamped(int months) {
    final index = year * 12 + (month - 1) + months;
    final y = index ~/ 12;
    final m = index % 12 + 1;
    final last = daysInMonth(y, m);
    return BusinessDate._(y, m, day > last ? last : day);
  }

  /// 2026-10-23: 이 달의 앞(음수)·뒤 [months]번째 달의 (연, 월)을 반환한다.
  (int, int) shiftMonth(int months) {
    final index = year * 12 + (month - 1) + months;
    return (index ~/ 12, index % 12 + 1);
  }

  /// 2026-10-23: [other]가 같은 날짜보다 앞이면 true를 반환한다.
  bool isBefore(BusinessDate other) => compareTo(other) < 0;

  /// 2026-10-23: [other]가 같은 날짜보다 뒤면 true를 반환한다.
  bool isAfter(BusinessDate other) => compareTo(other) > 0;

  /// 2026-10-23: 날짜 순서를 비교한다.
  @override
  int compareTo(BusinessDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) =>
      other is BusinessDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  /// 2026-10-23: YYYY-MM-DD 문자열을 반환한다.
  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

final RegExp _offsetTimestamp = RegExp(
  r'^(\d{4}-\d{2}-\d{2})T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d(\.\d+)?)?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)$',
);

/// 2026-10-23: 오프셋이 있는 시각 [text]를 UTC 시각으로 읽는다. 오프셋 없는 시각·없는 날짜는 [path]의 invalidDate 오류다.
DateTime parseOffsetTimestamp(String text, String path) {
  final m = _offsetTimestamp.firstMatch(text);
  if (m == null) {
    throw CalculationInputException(
      InputErrorCode.invalidDate,
      path,
      '오프셋 포함 시각이 아님($text)',
    );
  }
  BusinessDate.parse(m.group(1)!, path);
  return DateTime.parse(text).toUtc();
}

/// 2026-10-26: 명목 급여 회차(YYYY-MM). '몇 월분 월급'이며 입금월이 아니다.
class PayMonth implements Comparable<PayMonth> {
  const PayMonth._(this.year, this.month);

  /// 2026-10-26: [year](1~9999)년 [month](1~12)월 회차로 만든다. 범위 밖은 invalidValue 오류다.
  factory PayMonth(int year, int month) {
    if (year < 1 || year > 9999 || month < 1 || month > 12) {
      throw CalculationInputException(
        InputErrorCode.invalidValue,
        'PayMonth',
        '없는 회차($year-$month)',
      );
    }
    return PayMonth._(year, month);
  }

  final int year;
  final int month;

  static final RegExp _pattern = RegExp(r'^(\d{4})-(\d{2})$');

  /// 2026-10-26: 정확한 YYYY-MM [text]를 읽는다. 형식·범위 오류는 [path] 위치의 invalidValue 오류다.
  static PayMonth parse(String text, String path) {
    final m = _pattern.firstMatch(text);
    final year = m == null ? 0 : int.parse(m.group(1)!);
    final month = m == null ? 0 : int.parse(m.group(2)!);
    if (year < 1 || month < 1 || month > 12) {
      throw CalculationInputException(
        InputErrorCode.invalidValue,
        path,
        'YYYY-MM 회차가 아님($text)',
      );
    }
    return PayMonth._(year, month);
  }

  /// 2026-10-26: 앞(음수)·뒤 [months]번째 회차를 반환한다.
  PayMonth shift(int months) {
    final index = year * 12 + (month - 1) + months;
    return PayMonth(index ~/ 12, index % 12 + 1);
  }

  /// 2026-10-26: 회차 순서를 비교한다.
  @override
  int compareTo(PayMonth other) => year != other.year
      ? year.compareTo(other.year)
      : month.compareTo(other.month);

  @override
  bool operator ==(Object other) =>
      other is PayMonth && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);

  /// 2026-10-26: YYYY-MM 문자열을 반환한다.
  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
}
