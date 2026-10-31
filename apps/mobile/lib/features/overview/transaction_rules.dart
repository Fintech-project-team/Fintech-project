import '../../data/financial_snapshot.dart';
import '../../shared/design/amount_format.dart';
import '../connection/connection_review.dart';

/// 2026-10-30: 거래 종류 필터 값. 원천 recordKind·direction만으로 나누며 이름·금액으로 추정하지 않는다
/// (docs/data-model.md). 카드 사용을 계좌 출금으로 취급하지 않는다.
enum TxType {
  accountIn('계좌 입금'),
  accountOut('계좌 출금'),
  cardPurchase('카드 사용'),
  cardRefund('카드 환불'),
  cardCancellation('승인 취소');

  const TxType(this.label);

  final String label;

  /// 2026-10-30: 거래 [t]의 종류를 반환한다.
  static TxType of(SourceTransaction t) => switch (t.recordKind) {
    'account_entry' => t.direction == 'in' ? accountIn : accountOut,
    'card_purchase' => cardPurchase,
    'card_refund' => cardRefund,
    _ => cardCancellation,
  };

  /// 2026-10-30: 계좌 내역 종류면 true다.
  bool get isAccount => this == accountIn || this == accountOut;
}

/// 2026-10-30: 거래 [t]가 계좌 내역이면 true다.
bool isAccountEntry(SourceTransaction t) => t.recordKind == 'account_entry';

/// 2026-10-30: 목록·상세의 거래 종류 문구. 계좌 내역은 데이터가 준 분류(payseTransactionType)가 있을 때만 '내 계좌 이체'·
/// '카드대금 납부'이고, 그 밖에는 방향에 따라 '입금'·'출금'이다.
String kindLabel(SourceTransaction t) {
  if (isAccountEntry(t)) {
    return switch (t.payseTransactionType) {
      'internal_transfer' => '내 계좌 이체',
      'card_payment' => '카드대금 납부',
      _ => t.direction == 'in' ? '입금' : '출금',
    };
  }
  return switch (t.recordKind) {
    'card_purchase' => '카드 사용',
    'card_refund' => '카드 환불',
    _ => '승인 취소',
  };
}

/// 2026-10-30: 금액 문구. 부호는 거래 종류명이 아니라 direction을 따른다(in '+', out '−' U+2212).
String amountText(SourceTransaction t) =>
    '${t.direction == 'in' ? '+' : '−'}${formatKrw(t.amountKrw)}';

/// 2026-10-30: 이 기록의 날짜(YYYY-MM-DD). 계좌 내역은 bookingDate, 카드 사용은 purchaseDate, 환불은 refundDate,
/// 승인 취소는 cancellationDate(없으면 같은 기록의 확인 시각의 한국 날짜)다. 다른 날짜를 복사하지 않으며 없으면 null이다.
String? recordDate(SourceTransaction t) {
  final date = switch (t.recordKind) {
    'account_entry' => t.bookingDate,
    'card_purchase' => t.purchaseDate,
    'card_refund' => t.refundDate,
    _ => t.cancellationDate,
  };
  if (date != null) return date;
  if (t.occurredAt != null && t.occurredAtBasis == _basis(t)) {
    return t.occurredAt!.substring(0, 10);
  }
  return null;
}

/// 2026-10-30: 이 기록의 날짜에 해당하는 occurredAtBasis.
String _basis(SourceTransaction t) => switch (t.recordKind) {
  'account_entry' => 'booking',
  'card_purchase' => 'purchase',
  'card_refund' => 'refund',
  _ => 'cancellation',
};

/// 2026-10-30: 이 기록의 확인 시각 'HH:mm'. 같은 날짜 기준의 시각일 때만이며 없으면 null이다(00:00으로 채우지 않음).
String? recordTime(SourceTransaction t) {
  final at = t.occurredAt;
  if (at == null || t.occurredAtBasis != _basis(t)) return null;
  return at.substring(11, 16);
}

/// 2026-10-30: 처리 상태 라벨. posted는 없음. 카드 기록은 approved '승인', cancelled '승인 취소'(거래 종류가 이미 승인 취소면
/// 다시 붙이지 않음), unknown은 '처리 상태 미확인'. 계좌 내역의 approved·cancelled는 의미가 정해지지 않아 A 답변 전까지
/// 표시가 미완료이며 카드 문구나 '처리 상태 미확인'으로 바꾸지 않는다(PAYSE-MOBILE-TRANSACTIONS-29-2 명세).
String? statusLabel(SourceTransaction t) {
  if (t.status == 'unknown') return '처리 상태 미확인';
  if (isAccountEntry(t)) return null;
  return switch (t.status) {
    'approved' => '승인',
    'cancelled' when t.recordKind != 'card_cancellation' => '승인 취소',
    _ => null,
  };
}

/// 2026-10-30: 잔액 반영 라벨. 계좌 내역의 not_reflected만 '잔액 미반영'이다.
String? reflectionLabel(SourceTransaction t) =>
    isAccountEntry(t) && t.reflectionReason == 'not_reflected'
    ? '잔액 미반영'
    : null;

/// 2026-10-30: 거래 수단 문구('은행명 계좌 이름 ····끝 4자리' 또는 '카드 상품명 ····끝 4자리'). 찾지 못하면 null이다.
String? meansLabel(FinancialSnapshot snapshot, SourceTransaction t) {
  if (isAccountEntry(t)) {
    final id = t.accountId;
    final a = id == null ? null : accountById(snapshot, id);
    if (a == null) return null;
    return '${institutionName(snapshot, a.institutionCode)} '
        '${a.nickname ?? a.productName} ····${lastFour(a.maskedNumber)}';
  }
  final c = cardById(snapshot, t.cardId);
  return c == null ? null : '${c.productName} ····${lastFour(c.maskedNumber)}';
}

/// 2026-10-30: [snapshot]에서 카드 [cardId]를 찾는다. 없으면 null이다.
PaymentCard? cardById(FinancialSnapshot snapshot, String? cardId) {
  for (final c in snapshot.cards ?? const <PaymentCard>[]) {
    if (c.cardId == cardId) return c;
  }
  return null;
}

/// 2026-10-30: 목록 둘째 줄('거래 종류 · 거래 수단 · 할부 n/m'). [withMeans]가 false면 거래 수단을 생략한다(계좌별 화면).
String subtitle(
  FinancialSnapshot snapshot,
  SourceTransaction t, {
  bool withMeans = true,
}) {
  final means = withMeans ? meansLabel(snapshot, t) : null;
  final inst = t.installmentCurrent != null && t.installmentTotal != null
      ? '할부 ${t.installmentCurrent}/${t.installmentTotal}'
      : null;
  return [kindLabel(t), ?means, ?inst].join(' · ');
}

/// 2026-10-30: 'YYYY-MM-DD' [date]를 '2026년 10월 16일 (금)'으로 쓴다.
String longDate(String date) {
  final d = DateTime.utc(
    int.parse(date.substring(0, 4)),
    int.parse(date.substring(5, 7)),
    int.parse(date.substring(8, 10)),
  );
  const days = ['월', '화', '수', '목', '금', '토', '일'];
  return '${d.year}년 ${d.month}월 ${d.day}일 (${days[d.weekday - 1]})';
}

/// 2026-10-30: 'YYYY-MM-DD' [date]를 날짜 머리 'M월 D일 요일'로 쓴다.
String dayHeader(String date) {
  final d = DateTime.utc(
    int.parse(date.substring(0, 4)),
    int.parse(date.substring(5, 7)),
    int.parse(date.substring(8, 10)),
  );
  const days = ['월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'];
  return '${d.month}월 ${d.day}일 ${days[d.weekday - 1]}';
}

/// 2026-10-30: 상세 시트의 정보 줄(라벨·값). 기본 정보(거래 종류·거래처·거래 수단·거래 일시 또는 취소일) 다음에 처리 상태·
/// 원래 결제·할부·잔액 반영을 잇는다. 거래처가 거래명과 같으면, 거래 내용이 거래 종류와 같은 뜻이면 생략한다.
/// [original]은 originalTransactionId로 실제 확보한 원거래이며 없으면 원래 결제 줄을 생략한다(추정해 연결하지 않음).
List<(String, String, String?)> detailRows(
  FinancialSnapshot snapshot,
  SourceTransaction t, {
  SourceTransaction? original,
}) {
  final rows = <(String, String, String?)>[('거래 종류', kindLabel(t), null)];
  final means = meansLabel(snapshot, t);
  if (means != null) rows.add(('거래 수단', means, null));
  final date = recordDate(t);
  final time = recordTime(t);
  final dateLabel = t.recordKind == 'card_cancellation' ? '취소일' : '거래 일시';
  rows.add((
    dateLabel,
    date == null
        ? '날짜 미확인'
        : '${longDate(date)}${time == null ? '' : ' $time'}',
    null,
  ));
  final status = statusLabel(t);
  if (status == '처리 상태 미확인') {
    rows.add(('처리 상태', status!, '이 거래의 처리 상태를 확인할 수 없어요.'));
  } else if (status != null) {
    rows.add(('처리 상태', status, null));
  }
  if (original != null) {
    final od = recordDate(original);
    rows.add((
      '원래 결제',
      '${od == null ? '' : '${int.parse(od.substring(5, 7))}월 ${int.parse(od.substring(8, 10))}일 · '}'
          '${formatKrw(original.amountKrw)} ${kindLabel(original)}',
      null,
    ));
  }
  if (t.installmentCurrent != null && t.installmentTotal != null) {
    rows.add((
      '할부',
      '${t.installmentTotal}개월 중 ${t.installmentCurrent}회차',
      null,
    ));
  }
  final reflection = reflectionLabel(t);
  if (reflection != null) {
    rows.add(('잔액 반영', reflection, '이 거래는 계좌 잔액에 아직 반영되지 않았어요.'));
  } else if (isAccountEntry(t) && t.reflectionReason == 'unknown') {
    rows.add(('잔액 반영', '잔액 반영 여부를 확인할 수 없어요.', null));
  }
  final description = t.description;
  if (description != null &&
      description.trim().isNotEmpty &&
      description != t.merchantName &&
      _normalized(description) != _normalized(kindLabel(t))) {
    rows.add(('거래 내용', description, null));
  }
  return rows;
}

/// 2026-10-30: 공백을 뺀 문자열(같은 뜻 비교용, 예: '승인취소'와 '승인 취소').
String _normalized(String text) => text.replaceAll(' ', '');
