import '../../data/financial_snapshot.dart';
import 'transaction_rules.dart';

/// 2026-10-30: 날짜 'YYYY-MM-DD'를 UTC 자정 DateTime으로 읽는다(달력 계산용, 시간대 변환 없음).
DateTime _day(String date) => DateTime.utc(
  int.parse(date.substring(0, 4)),
  int.parse(date.substring(5, 7)),
  int.parse(date.substring(8, 10)),
);

/// 2026-10-30: UTC 날짜 [d]를 'YYYY-MM-DD'로 쓴다.
String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 2026-10-30: 조회 기간 종류.
enum PeriodKind { thisMonth, recent3, recent1y, month }

/// 2026-10-30: 조회 기간 선택. [month]는 [PeriodKind.month]일 때의 'YYYY-MM'이다.
class PeriodSelection {
  /// 2026-10-30: 종류 [kind]와 달 [month]로 만든다.
  const PeriodSelection(this.kind, {this.month});

  static const PeriodSelection thisMonth = PeriodSelection(
    PeriodKind.thisMonth,
  );

  final PeriodKind kind;
  final String? month;

  /// 2026-10-30: 선택지 이름.
  String get name => switch (kind) {
    PeriodKind.thisMonth => '이번 달',
    PeriodKind.recent3 => '최근 3개월',
    PeriodKind.recent1y => '최근 1년',
    PeriodKind.month => '월 선택',
  };

  @override
  bool operator ==(Object other) =>
      other is PeriodSelection && other.kind == kind && other.month == month;

  @override
  int get hashCode => Object.hash(kind, month);
}

/// 2026-10-30: 조회 가능한 범위. [first]는 조회 시작일(coverage requestedStart 중 가장 이른 값), [last]는 기준일(asOf의 날짜)이다.
class QueryBounds {
  /// 2026-10-30: 시작일 [first]와 기준일 [last]로 만든다.
  const QueryBounds(this.first, this.last);

  final String first;
  final String last;

  /// 2026-10-30: [snapshot]의 조회 범위. coverage가 있으면 requestedStart의 가장 이른 값, 없으면 기준일 1년 전 다음 날이다.
  factory QueryBounds.of(FinancialSnapshot snapshot, List<Coverage> coverage) {
    final last = snapshot.asOf.substring(0, 10);
    final starts = [for (final c in coverage) c.requestedStart]..sort();
    if (starts.isNotEmpty) return QueryBounds(starts.first, last);
    final d = _day(last);
    return QueryBounds(
      _iso(DateTime.utc(d.year - 1, d.month, d.day + 1)),
      last,
    );
  }

  /// 2026-10-30: 조회 범위 안의 달('YYYY-MM') 목록(오래된 달부터).
  List<String> get months {
    final out = <String>[];
    var d = DateTime.utc(_day(first).year, _day(first).month);
    final end = DateTime.utc(_day(last).year, _day(last).month);
    while (!d.isAfter(end)) {
      out.add(_iso(d).substring(0, 7));
      d = DateTime.utc(d.year, d.month + 1);
    }
    return out;
  }

  /// 2026-10-30: [selection]의 실제 날짜 범위(양 끝 포함). 조회 범위를 벗어나지 않는다.
  (String, String) range(PeriodSelection selection) {
    final end = _day(last);
    switch (selection.kind) {
      case PeriodKind.thisMonth:
        return _clip(_iso(DateTime.utc(end.year, end.month)), last);
      case PeriodKind.recent3:
        return _clip(
          _iso(DateTime.utc(end.year, end.month - 3, end.day + 1)),
          last,
        );
      case PeriodKind.recent1y:
        return (first, last);
      case PeriodKind.month:
        final m = _day('${selection.month}-01');
        final monthEnd = DateTime.utc(m.year, m.month + 1, 0);
        return _clip(_iso(m), _iso(monthEnd));
    }
  }

  /// 2026-10-30: [start]~[end]를 조회 범위로 자른다.
  (String, String) _clip(String start, String end) => (
    start.compareTo(first) < 0 ? first : start,
    end.compareTo(last) > 0 ? last : end,
  );

  /// 2026-10-30: 달 [month]가 조회 범위의 일부 날짜만 포함하면 '20일부터'·'19일까지'를, 전체면 null을 반환한다.
  String? partialNote(String month) {
    final (s, e) = range(PeriodSelection(PeriodKind.month, month: month));
    final m = _day('$month-01');
    final full = _iso(DateTime.utc(m.year, m.month + 1, 0));
    if (s != '$month-01') return '${int.parse(s.substring(8))}일부터';
    if (e != full) return '${int.parse(e.substring(8))}일까지';
    return null;
  }

  /// 2026-10-30: 화면의 기간 제목. 이번 달·월 선택은 '2026년 10월', 그 밖은 선택지 이름이다.
  String title(PeriodSelection selection) => switch (selection.kind) {
    PeriodKind.thisMonth => _monthTitle(last.substring(0, 7)),
    PeriodKind.month => _monthTitle(selection.month!),
    _ => selection.name,
  };

  /// 2026-10-30: [selection]의 범위 문구('2026년 7월 20일 ~ 10월 19일', 해가 다르면 둘 다 연도).
  String rangeText(PeriodSelection selection) {
    final (s, e) = range(selection);
    final a = _day(s);
    final b = _day(e);
    final left = '${a.year}년 ${a.month}월 ${a.day}일';
    final right = a.year == b.year
        ? '${b.month}월 ${b.day}일'
        : '${b.year}년 ${b.month}월 ${b.day}일';
    return '$left ~ $right';
  }

  /// 2026-10-30: [selection]이 달 단위(월 이동 화살표를 보일 기간)면 그 달 'YYYY-MM'을, 아니면 null을 반환한다.
  String? monthOf(PeriodSelection selection) => switch (selection.kind) {
    PeriodKind.thisMonth => last.substring(0, 7),
    PeriodKind.month => selection.month,
    _ => null,
  };

  /// 2026-10-30: 달 [month]의 앞·뒤 달 선택(조회 범위 밖이면 null).
  PeriodSelection? shift(String month, int delta) {
    final m = _day('$month-01');
    final next = _iso(DateTime.utc(m.year, m.month + delta)).substring(0, 7);
    if (!months.contains(next)) return null;
    return next == last.substring(0, 7)
        ? PeriodSelection.thisMonth
        : PeriodSelection(PeriodKind.month, month: next);
  }

  static String _monthTitle(String month) =>
      '${month.substring(0, 4)}년 ${int.parse(month.substring(5))}월';
}

/// 2026-10-30: 거래 내역 조회 조건. [accountIds]·[cardIds]가 null이면 해당 묶음 전체, 빈 집합이면 그 묶음을 고르지 않은 것이다.
/// [type]이 null이면 거래 종류 전체다. 조회 조건은 화면 안에서만 쓰며 홈 계산 포함 계좌를 바꾸지 않는다.
class TransactionQuery {
  /// 2026-10-30: 기간 [period], 계좌 [accountIds], 카드 [cardIds], 거래 종류 [type]으로 만든다.
  const TransactionQuery({
    this.period = PeriodSelection.thisMonth,
    this.accountIds,
    this.cardIds,
    this.type,
  });

  final PeriodSelection period;
  final Set<String>? accountIds;
  final Set<String>? cardIds;
  final TxType? type;

  /// 2026-10-30: 계좌 내역을 고를 수 있으면 true다.
  bool get hasAccounts => accountIds == null || accountIds!.isNotEmpty;

  /// 2026-10-30: 카드 기록을 고를 수 있으면 true다.
  bool get hasCards => cardIds == null || cardIds!.isNotEmpty;

  /// 2026-10-30: 선택한 거래 수단에 맞는 거래 종류(전체 제외).
  List<TxType> get availableTypes => [
    if (hasAccounts) ...[TxType.accountIn, TxType.accountOut],
    if (hasCards) ...[
      TxType.cardPurchase,
      TxType.cardRefund,
      TxType.cardCancellation,
    ],
  ];

  /// 2026-10-30: 기간만 바꾼 조건. 거래 수단·거래 종류는 유지한다.
  TransactionQuery withPeriod(PeriodSelection period) => TransactionQuery(
    period: period,
    accountIds: accountIds,
    cardIds: cardIds,
    type: type,
  );

  /// 2026-10-30: 거래 수단을 바꾼 조건. 기존 거래 종류가 새 수단에 맞지 않으면 전체로 되돌린다. 기간은 유지한다.
  TransactionQuery withMeans(Set<String>? accountIds, Set<String>? cardIds) {
    final next = TransactionQuery(
      period: period,
      accountIds: accountIds,
      cardIds: cardIds,
    );
    final keep = type != null && next.availableTypes.contains(type);
    return TransactionQuery(
      period: period,
      accountIds: accountIds,
      cardIds: cardIds,
      type: keep ? type : null,
    );
  }

  /// 2026-10-30: 거래 종류를 바꾼 조건.
  TransactionQuery withType(TxType? type) => TransactionQuery(
    period: period,
    accountIds: accountIds,
    cardIds: cardIds,
    type: type,
  );

  /// 2026-10-30: 기본 조건(이번 달·전체 거래 수단·거래 종류 전체)이면 true다.
  bool get isDefault =>
      period == PeriodSelection.thisMonth &&
      accountIds == null &&
      cardIds == null &&
      type == null;

  /// 2026-10-30: [t]가 이 조건(기간 [bounds] 기준)에 맞으면 true다. 날짜가 없는 기록은 기간 조회에서 빠진다.
  bool matches(SourceTransaction t, QueryBounds bounds) {
    final date = recordDate(t);
    if (date == null) return false;
    final (s, e) = bounds.range(period);
    if (date.compareTo(s) < 0 || date.compareTo(e) > 0) return false;
    if (isAccountEntry(t)) {
      if (!hasAccounts) return false;
      if (accountIds != null && !accountIds!.contains(t.accountId)) {
        return false;
      }
    } else {
      if (!hasCards) return false;
      if (cardIds != null && !cardIds!.contains(t.cardId)) return false;
    }
    return type == null || TxType.of(t) == type;
  }
}

/// 2026-10-30: [transactions]를 [query]로 거르고 날짜 최신순(같은 날은 확인 시각 늦은 순, 그다음 transactionId)으로 정렬한다.
List<SourceTransaction> filterAndSort(
  Iterable<SourceTransaction> transactions,
  TransactionQuery query,
  QueryBounds bounds,
) {
  final out = [
    for (final t in transactions)
      if (query.matches(t, bounds)) t,
  ];
  out.sort((a, b) {
    final byDate = recordDate(b)!.compareTo(recordDate(a)!);
    if (byDate != 0) return byDate;
    final ta = recordTime(a);
    final tb = recordTime(b);
    if (ta != null && tb != null && ta != tb) return tb.compareTo(ta);
    return a.transactionId.compareTo(b.transactionId);
  });
  return out;
}
