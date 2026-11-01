import 'package:flutter/foundation.dart';

import '../../data/connection/transaction_history.dart';
import '../../data/financial_snapshot.dart';
import 'accounts_screen.dart';
import 'home_calculation.dart';
import 'pull_refresh.dart';

/// 2026-10-31: 홈과 계좌·카드 탭이 함께 보는 현재 앱 상태. 계산 [calculation]과 새로고침으로 받은 거래 전체 [history]다.
/// 앱 셸이 Snapshot이 바뀔 때마다 새 값으로 바꾸며, 위에 쌓인 화면(계산 내역·계좌·카드별 조회)도 이 값을 따라 다시 그린다.
typedef OverviewState = ({
  HomeCalculation calculation,
  TransactionHistoryReady? history,
});

/// 2026-10-31: 계산 내역에서 펼쳐 둘 항목.
enum CalcSection { balance, reserve, scheduled }

/// 2026-10-31: 계좌·카드 탭의 안쪽 탭. 이 순서로 보인다.
enum AccountsCardsTab { period, all, accounts }

/// 2026-10-31: 계좌·카드별 조회 대상. 계좌 [accountId] 또는 카드 [cardId] 중 하나다.
sealed class Instrument {
  const Instrument();

  /// 2026-10-31: 대상 ID.
  String get id;
}

/// 2026-10-31: 계좌 하나.
final class AccountInstrument extends Instrument {
  /// 2026-10-31: 계좌 [accountId]로 만든다.
  const AccountInstrument(this.accountId);

  final String accountId;

  @override
  String get id => accountId;

  @override
  bool operator ==(Object other) =>
      other is AccountInstrument && other.accountId == accountId;

  @override
  int get hashCode => accountId.hashCode;
}

/// 2026-10-31: 카드 하나.
final class CardInstrument extends Instrument {
  /// 2026-10-31: 카드 [cardId]로 만든다.
  const CardInstrument(this.cardId);

  final String cardId;

  @override
  String get id => cardId;

  @override
  bool operator ==(Object other) =>
      other is CardInstrument && other.cardId == cardId;

  @override
  int get hashCode => cardId.hashCode;
}

/// 2026-10-31: 계좌·카드별 조회의 '바꾸기' 범위. 이번 기간 내역에서 들어왔으면 그 조회 대상, 그 밖에는 연결한 전체다.
enum InstrumentScope { period, connected }

/// 2026-10-31: 화면 사이 연결에 쓰는 공통 의존성. 현재 상태 [state], 저장 연결 [writer], 아래로 당겨 새로고침 [onRefresh],
/// 홈에서 이번 기간 내역으로 가기 [onShowPeriod]다. 화면 열기는 overview_pages.dart가 맡는다.
class OverviewLinks {
  /// 2026-10-31: 각 의존성으로 만든다.
  const OverviewLinks({
    required this.state,
    this.writer,
    this.onRefresh,
    this.onShowPeriod,
  });

  final ValueListenable<OverviewState> state;
  final AccountsWriter? writer;
  final PullRefresh? onRefresh;
  final VoidCallback? onShowPeriod;

  /// 2026-10-31: 지금 Snapshot.
  FinancialSnapshot get snapshot => state.value.calculation.snapshot;
}
