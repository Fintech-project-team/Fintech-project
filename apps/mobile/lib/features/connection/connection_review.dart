import '../../data/financial_snapshot.dart';

/// 2026-10-22: 01-1·01-2에서 계좌를 부르는 이름(예: "국민 입출금 ····0001"). 계좌 번호는 끝 4자리만 쓴다.
String accountLabel(FinancialSnapshot snapshot, Account account) {
  final masked = account.maskedNumber;
  final last4 = masked.length <= 4
      ? masked
      : masked.substring(masked.length - 4);
  return '${institutionName(snapshot, account.institutionCode)} '
      '${productTypeLabel(account.productType)} ····$last4';
}

/// 2026-10-22: 기관 코드 [code]의 이름을 반환한다. 목록에 없으면 코드를 그대로 쓴다.
String institutionName(FinancialSnapshot snapshot, String code) {
  for (final i in snapshot.institutions) {
    if (i.code == code) return i.name;
  }
  return code;
}

/// 2026-10-22: 계좌 상품 종류 이름(입출금·적금·예금·기타).
String productTypeLabel(String productType) => switch (productType) {
  'demand' => '입출금',
  'savings' => '적금',
  'time_deposit' => '예금',
  _ => '기타',
};

/// 2026-10-22: 01-2 카드 결제일 표시. 사용자 설정·다음 확인 일정·예정 일정 없음을 구분한다.
sealed class CardPaymentDay {
  /// 2026-10-22: 하위 값만 만든다.
  const CardPaymentDay();
}

/// 2026-10-22: 사용자가 정한 계획 결제일(매월 [day]일).
final class PlannedPaymentDay extends CardPaymentDay {
  /// 2026-10-22: 매월 날짜 [day]로 만든다.
  const PlannedPaymentDay(this.day);

  final int day;
}

/// 2026-10-22: 기준일 이후 가장 이른 카드사 확인 결제일 [date](YYYY-MM-DD).
final class NextConfirmedDue extends CardPaymentDay {
  /// 2026-10-22: 업무 날짜 [date]로 만든다.
  const NextConfirmedDue(this.date);

  final String date;
}

/// 2026-10-22: 사용자 설정도, 기준일 이후 확인 일정도 없다. 지난 날짜로 대신하지 않는다.
final class NoUpcomingDue extends CardPaymentDay {
  /// 2026-10-22: 일정 없음 값을 만든다.
  const NoUpcomingDue();
}

/// 2026-10-22: 카드 [card]의 결제일 표시를 고른다. 사용자 설정(plannedPaymentDay)이 있으면 그것을,
/// 없으면 Snapshot asOf의 날짜(기기 날짜가 아님) 이상인 확인 dueDate 중 가장 이른 날짜를 쓴다.
/// 반복 주기를 추정하지 않는다. 현재 계약에는 결제 완료 일정 표시가 없어 제외할 일정이 없다.
CardPaymentDay cardPaymentDay(FinancialSnapshot snapshot, PaymentCard card) {
  for (final plan in snapshot.settings?.cardPlans ?? const <CardPlan>[]) {
    if (plan.cardId == card.cardId && plan.plannedPaymentDay != null) {
      return PlannedPaymentDay(plan.plannedPaymentDay!);
    }
  }
  final basis = snapshot.asOf.substring(0, 10);
  final upcoming = [
    for (final s in card.scheduleEvidence)
      if (s.dueDate != null && s.dueDate!.compareTo(basis) >= 0) s.dueDate!,
  ]..sort();
  return upcoming.isEmpty
      ? const NoUpcomingDue()
      : NextConfirmedDue(upcoming.first);
}

/// 2026-10-22: 업무 날짜 [date]를 "11월 10일"로 바꾼다. 기준일 [basis]와 해가 다르면 "2027년 1월 10일"로 쓴다.
String formatBusinessDate(String date, String basis) {
  final year = int.parse(date.substring(0, 4));
  final month = int.parse(date.substring(5, 7));
  final day = int.parse(date.substring(8, 10));
  final sameYear = date.substring(0, 4) == basis.substring(0, 4);
  return sameYear ? '$month월 $day일' : '$year년 $month월 $day일';
}

/// 2026-10-22: 계좌 ID [accountId]의 계좌를 찾는다. 응답에 없으면 null이다.
Account? accountById(FinancialSnapshot snapshot, String accountId) {
  for (final a in snapshot.accounts ?? const <Account>[]) {
    if (a.accountId == accountId) return a;
  }
  return null;
}

/// 2026-10-22: 01-2에 보일 유효한 모아둘 돈(취소되지 않은 것)을 응답 순서대로 반환한다.
List<Reserve> activeReserves(FinancialSnapshot snapshot) => [
  for (final r in snapshot.reserves ?? const <Reserve>[])
    if (r.cancelledAt == null) r,
];

/// 2026-10-22: 01-2에 보일 유효한 예정 지출(active)을 날짜순으로 반환한다. 금액은 바꾸지 않는다.
List<Obligation> activeObligations(FinancialSnapshot snapshot) => [
  for (final o in snapshot.obligations ?? const <Obligation>[])
    if (o.status == 'active') o,
]..sort((a, b) => a.dueDate.compareTo(b.dueDate));
