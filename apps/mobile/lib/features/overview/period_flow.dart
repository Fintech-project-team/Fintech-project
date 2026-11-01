import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../data/financial_snapshot.dart';
import 'transaction_rules.dart';

/// 2026-10-31: 이번 기간 내역의 조회 대상(#163). 계산에 포함한 계좌와 출금 계좌가 그 계좌인 카드다. 출금 계좌가 null이거나
/// 연결 제한으로 빠진 카드는 [unknownCards]로 따로 두고 대상에 넣지 않는다. 출금 계좌가 계산 제외 계좌인 카드는 대상도
/// 미확인도 아니다. 조회 범위일 뿐 계산 설정·카드 연결을 바꾸지 않는다.
class FlowScope {
  /// 2026-10-31: 대상 계좌 [accounts], 대상 카드 [cards], 출금 계좌 미확인 카드 [unknownCards]로 만든다.
  const FlowScope({
    required this.accounts,
    required this.cards,
    required this.unknownCards,
  });

  /// 2026-10-31: [snapshot]의 계산 포함 여부(Account.included)와 카드 출금 계좌(PaymentCard.withdrawalAccountId)로 만든다.
  factory FlowScope.of(FinancialSnapshot snapshot) {
    final accounts = [
      for (final a in snapshot.accounts ?? const <Account>[])
        if (a.included) a,
    ];
    final ids = {for (final a in accounts) a.accountId};
    final cards = <PaymentCard>[];
    final unknown = <PaymentCard>[];
    for (final c in snapshot.cards ?? const <PaymentCard>[]) {
      final withdrawal = c.withdrawalAccountId;
      if (c.withdrawalAccountRestricted || withdrawal == null) {
        unknown.add(c);
      } else if (ids.contains(withdrawal)) {
        cards.add(c);
      }
    }
    return FlowScope(accounts: accounts, cards: cards, unknownCards: unknown);
  }

  final List<Account> accounts;
  final List<PaymentCard> cards;
  final List<PaymentCard> unknownCards;

  /// 2026-10-31: 대상 계좌 ID.
  Set<String> get accountIds => {for (final a in accounts) a.accountId};

  /// 2026-10-31: 대상 카드 ID.
  Set<String> get cardIds => {for (final c in cards) c.cardId};

  /// 2026-10-31: 거래 [t]가 대상 계좌의 내역이거나 대상 카드의 기록이면 true다.
  bool covers(SourceTransaction t) => isAccountEntry(t)
      ? accountIds.contains(t.accountId)
      : cardIds.contains(t.cardId);
}

/// 2026-10-31: 이번 기간 내역의 조회 기간. 기존 계산 결과의 월급 주기를 그대로 쓰며 화면에서 다시 정하지 않는다.
sealed class FlowPeriod {
  const FlowPeriod();

  /// 2026-10-31: 계산 결과 [result]의 월급 주기에서 만든다. 정상·입금 대기이고 시작·끝을 모두 알 때만 기간이 있다.
  /// 입금 대기면 계산 내역이 쓰는 이전 계산 기간이며 [FlowPeriodKnown.previous]가 true다. 그 밖에는 기간 미상이다.
  factory FlowPeriod.of(calc.CurrentAmountResult? result) {
    final cycle = result?.salaryCycle;
    final start = cycle?.periodStart;
    final end = cycle?.periodEnd;
    final state = cycle?.state;
    if (start == null ||
        end == null ||
        (state != calc.SalaryCycleState.normal &&
            state != calc.SalaryCycleState.awaitingDeposit)) {
      return const FlowPeriodUnknown();
    }
    return FlowPeriodKnown(
      start: start,
      end: end,
      previous: state == calc.SalaryCycleState.awaitingDeposit,
    );
  }
}

/// 2026-10-31: 확인된 기간 [start] 이상 [end] 미만(다음 월급일 당일 제외). [previous]면 이미 끝난 이전 계산 기간이다.
final class FlowPeriodKnown extends FlowPeriod {
  /// 2026-10-31: 시작 [start], 끝(미포함) [end], 이전 기간 여부 [previous]로 만든다.
  const FlowPeriodKnown({
    required this.start,
    required this.end,
    required this.previous,
  });

  final calc.BusinessDate start;
  final calc.BusinessDate end;
  final bool previous;

  /// 2026-10-31: 'YYYY-MM-DD' 날짜 [date]가 기간 안이면 true다.
  bool contains(String date) =>
      date.compareTo(start.toString()) >= 0 &&
      date.compareTo(end.toString()) < 0;
}

/// 2026-10-31: 월급 주기를 알 수 없다. 기간을 만들지 않는다.
final class FlowPeriodUnknown extends FlowPeriod {
  /// 2026-10-31: 기간 미상을 만든다.
  const FlowPeriodUnknown();
}

/// 2026-10-31: 이번 기간 내역의 거래 종류 선택.
enum FlowKind {
  all('모든 내역'),
  account('계좌 입출금'),
  transfer('내 계좌 이체'),
  card('카드 사용·환불');

  const FlowKind(this.label);

  final String label;
}

/// 2026-10-31: 근거가 있는 내 계좌 이체가 계산 계좌 잔액에 주는 방향. 금액을 다시 계산하지 않는다.
enum TransferEffect {
  /// 2026-10-31: 보낸·받은 계좌가 모두 계산 포함이라 합계 잔액은 그대로다.
  inside,

  /// 2026-10-31: 계산에서 제외한 계좌에서 계산 계좌로 들어왔다.
  intoScope,

  /// 2026-10-31: 계산 계좌에서 계산에서 제외한 계좌로 나갔다.
  outOfScope,
}

/// 2026-10-31: 이번 기간 내역의 한 줄. 날짜 [date](YYYY-MM-DD)로 묶는다.
sealed class FlowItem {
  const FlowItem(this.date);

  final String date;
}

/// 2026-10-31: 원본 거래 한 건.
final class FlowRecord extends FlowItem {
  /// 2026-10-31: 거래 [transaction]과 그 날짜 [date]로 만든다.
  const FlowRecord(this.transaction, String date) : super(date);

  final SourceTransaction transaction;
}

/// 2026-10-31: transactionRelations(internal_transfer)로 확인된 내 계좌 이체 한 건. 원본 출금 [from]·입금 [to]를 그대로 둔다.
final class FlowTransfer extends FlowItem {
  /// 2026-10-31: 출금 [from], 입금 [to], 계산 계좌 잔액에 주는 방향 [effect], 날짜 [date]로 만든다.
  const FlowTransfer({
    required this.from,
    required this.to,
    required this.effect,
    required String date,
  }) : super(date);

  final SourceTransaction from;
  final SourceTransaction to;
  final TransferEffect effect;
}

/// 2026-10-31: 근거 관계 [relations]로 [transactions] 안의 내 계좌 이체 짝을 찾는다. 출금(out)·입금(in) 계좌 내역이고 두
/// 계좌가 다르며 금액이 같을 때만 짝으로 보고, 한 거래는 한 짝에만 쓴다. 날짜·금액·이름만으로는 짝을 만들지 않는다.
List<(SourceTransaction, SourceTransaction)> transferPairs(
  Iterable<SourceTransaction> transactions,
  Iterable<TransactionRelation> relations,
) {
  final byId = {for (final t in transactions) t.transactionId: t};
  final used = <String>{};
  final out = <(SourceTransaction, SourceTransaction)>[];
  for (final r in relations) {
    if (r.kind != 'internal_transfer') continue;
    final from = byId[r.fromId];
    final to = byId[r.toId];
    if (from == null || to == null) continue;
    final valid =
        isAccountEntry(from) &&
        isAccountEntry(to) &&
        from.direction == 'out' &&
        to.direction == 'in' &&
        from.accountId != null &&
        to.accountId != null &&
        from.accountId != to.accountId &&
        from.amountKrw == to.amountKrw;
    if (!valid ||
        used.contains(from.transactionId) ||
        used.contains(to.transactionId)) {
      continue;
    }
    used
      ..add(from.transactionId)
      ..add(to.transactionId);
    out.add((from, to));
  }
  return out;
}

/// 2026-10-31: [transactions] 중 대상 [scope]·기간 [period] 안의 기록을 날짜 최신순 [FlowItem]으로 만든다. 근거 있는 이체
/// 짝은 한 줄로 묶고(어느 쪽이든 대상·기간 안이면 보임), 그 밖의 거래는 한 건씩 둔다. 같은 원본 거래를 두 번 보이지 않는다.
/// [kind]로 거르며, 계좌 입출금에는 묶은 이체도 들어간다. 내 계좌 이체에는 근거 있는 짝과 데이터가 이체로 분류한 계좌 내역이
/// 들어간다.
List<FlowItem> flowItems({
  required Iterable<SourceTransaction> transactions,
  required Iterable<TransactionRelation> relations,
  required FlowScope scope,
  required FlowPeriodKnown period,
  FlowKind kind = FlowKind.all,
}) {
  final all = transactions.toList();
  bool inside(SourceTransaction t) {
    final date = recordDate(t);
    return date != null && period.contains(date) && scope.covers(t);
  }

  final paired = <String>{};
  final items = <FlowItem>[];
  final accounts = scope.accountIds;
  for (final (from, to) in transferPairs(all, relations)) {
    paired
      ..add(from.transactionId)
      ..add(to.transactionId);
    final fromIn = inside(from);
    final toIn = inside(to);
    if (!fromIn && !toIn) continue;
    final fromScoped = accounts.contains(from.accountId);
    final toScoped = accounts.contains(to.accountId);
    final effect = fromScoped && toScoped
        ? TransferEffect.inside
        : toScoped
        ? TransferEffect.intoScope
        : TransferEffect.outOfScope;
    if (kind == FlowKind.card) continue;
    items.add(
      FlowTransfer(
        from: from,
        to: to,
        effect: effect,
        date: recordDate(fromIn ? from : to)!,
      ),
    );
  }
  for (final t in all) {
    if (paired.contains(t.transactionId) || !inside(t)) continue;
    final card = !isAccountEntry(t);
    final keep = switch (kind) {
      FlowKind.all => true,
      FlowKind.account => !card,
      FlowKind.transfer =>
        !card && t.payseTransactionType == 'internal_transfer',
      FlowKind.card => card,
    };
    if (keep) items.add(FlowRecord(t, recordDate(t)!));
  }
  items.sort((a, b) {
    final byDate = b.date.compareTo(a.date);
    if (byDate != 0) return byDate;
    return _sortKey(a).compareTo(_sortKey(b));
  });
  return items;
}

/// 2026-10-31: 같은 날 안의 순서 키(원본 거래 ID). 묶은 이체는 출금 거래 ID를 쓴다.
String _sortKey(FlowItem item) => switch (item) {
  FlowRecord(:final transaction) => transaction.transactionId,
  FlowTransfer(:final from) => from.transactionId,
};
