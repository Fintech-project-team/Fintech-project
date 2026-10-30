import 'package:flutter/material.dart';

import '../../data/connection/financial_api.dart';
import '../../data/financial_snapshot.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_flow_controller.dart';
import '../connection/connection_page.dart';
import '../connection/connection_presentation_policy.dart';
import '../connection/connection_review.dart';
import '../connection/connection_screens.dart';
import 'account_rename_sheet.dart';
import 'home_calculation.dart';
import 'home_screen.dart' show asOfLabel;
import 'salary_notice.dart';

/// 2026-10-29: 계좌 탭에서 저장에 쓰는 세션 연결. 세션 저장소 [repository], 01-1 재사용에 쓰는 표시 정책 [policy],
/// 세션 무효 처리 [onSessionInvalid], 저장 뒤 최신 Snapshot을 앱에 반영하는 [onSnapshot]이다.
typedef AccountsWriter = ({
  UserFinancialRepository repository,
  ConnectionPresentationPolicy policy,
  VoidCallback onSessionInvalid,
  ValueChanged<FinancialSnapshot> onSnapshot,
});

/// 2026-10-29: 02-3 계좌 관리(29-1 단독). 계산에 포함한 계좌 잔액·계좌 수·기준 시각 → '계산에 포함할 계좌 바꾸기' →
/// 금융사별 계좌 목록(이름·끝 4자리·보조 정보·잔액·연필). 계산에서 제외한 계좌도 보이되 흐리게 두고 표시를 붙인다.
/// 잔액 합계는 홈 계산 결과(B)를 그대로 쓰고 화면에서 더하지 않는다. 계좌 행은 이 단계에서 누를 수 없다.
class AccountsScreen extends StatelessWidget {
  /// 2026-10-29: 현재 Snapshot [snapshot], 홈 계산 [calculation], 저장 연결 [writer](없으면 연필·바꾸기 비활성)로 만든다.
  const AccountsScreen({
    super.key,
    required this.snapshot,
    required this.calculation,
    this.writer,
  });

  final FinancialSnapshot snapshot;
  final HomeCalculation calculation;
  final AccountsWriter? writer;

  /// 2026-10-29: 계좌 [account]의 이름 바꾸기 시트를 열고, 저장되면 앱에 반영한 뒤 알림을 보인다.
  Future<void> _rename(BuildContext context, Account account) async {
    final w = writer;
    if (w == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar();
    final result = await showAccountRenameSheet(
      context,
      repository: w.repository,
      snapshot: snapshot,
      accountId: account.accountId,
      onSessionInvalid: w.onSessionInvalid,
      onSnapshot: w.onSnapshot,
    );
    if (result == null) return;
    w.onSnapshot(result.snapshot);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('rename-saved'),
          content: Text(result.reverted ? '원래 이름으로 되돌렸어요.' : '계좌 이름을 바꿨어요.'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(
            PayseSpace.x4,
            0,
            PayseSpace.x4,
            PayseSpace.x3,
          ),
        ),
      );
  }

  /// 2026-10-29: 01-1을 현재 계산 포함 계좌가 고른 상태로 열고, 저장되면 앱에 반영한다. 떠 있는 알림은 닫아 다음 화면의
  /// 아래 버튼을 가리지 않게 한다.
  Future<void> _changeSelection(BuildContext context) async {
    final w = writer;
    if (w == null) return;
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    final next = await Navigator.of(context).push<FinancialSnapshot>(
      MaterialPageRoute(
        builder: (_) => AccountSelectionPage(snapshot: snapshot, writer: w),
      ),
    );
    if (next != null) w.onSnapshot(next);
  }

  /// 2026-10-29: 월급 정보 줄 설명. 저장된 값만 '매월 D일 · 금액 · 기관 ····끝 4자리'로 잇는다.
  String _salaryText(SalarySetting salary) {
    final id = salary.salaryAccountId;
    final account = id == null ? null : accountById(snapshot, id);
    return [
      if (salary.salaryDay case final day?) '매월 $day일' else '월급일 미입력',
      if (salary.salaryAmountKrw case final amount?)
        formatKrw(amount)
      else
        '금액 미입력',
      if (salary.salaryAccountRestricted)
        '월급 계좌 정보를 볼 수 없어요'
      else if (account != null)
        '${institutionName(snapshot, account.institutionCode)} '
            '····${lastFour(account.maskedNumber)}',
    ].join(' · ');
  }

  /// 2026-10-29: 월급 정보 편집 화면을 연다. 저장하면 응답 Snapshot으로 앱을 다시 계산한다.
  void _editSalary(BuildContext context) {
    final w = writer;
    if (w == null) return;
    openSalaryEditor(
      context,
      snapshot: snapshot,
      repository: w.repository,
      onSessionInvalid: w.onSessionInvalid,
      onSnapshot: w.onSnapshot,
    );
  }

  /// 2026-10-29: 잔액 요약·버튼·금융사별 계좌 목록을 반환한다. 계산 포함 계좌가 있는 금융사를 먼저, 묶음 안에서는
  /// 포함 계좌를 먼저 두고 나머지는 데이터 순서를 따른다.
  @override
  Widget build(BuildContext context) {
    final accounts = snapshot.accounts ?? const <Account>[];
    final included = accounts.where((a) => a.included).length;
    final ready = calculation;
    final b = ready is HomeCalculationReady ? ready.result.b : null;
    final groups = [
      for (final i in snapshot.institutions)
        (
          name: i.name,
          accounts: [
            for (final included in [true, false])
              for (final a in accounts)
                if (a.institutionCode == i.code && a.included == included) a,
          ],
        ),
    ].where((g) => g.accounts.isNotEmpty);
    final ordered = [
      ...groups.where((g) => g.accounts.first.included),
      ...groups.where((g) => !g.accounts.first.included),
    ];
    return SafeArea(
      bottom: false,
      child: ListView(
        key: const ValueKey('accounts-list'),
        padding: const EdgeInsets.fromLTRB(
          PayseSpace.screenHorizontal,
          PayseSpace.x6,
          PayseSpace.screenHorizontal,
          PayseSpace.x6,
        ),
        children: [
          const Text(
            '계좌',
            style: TextStyle(
              fontSize: 24,
              height: 1.42,
              fontWeight: FontWeight.w700,
              color: PayseColors.textPrimary,
            ),
          ),
          const SizedBox(height: PayseSpace.x5),
          const Text(
            '계산에 포함한 계좌 잔액',
            style: TextStyle(
              fontSize: 16,
              height: 1.5,
              fontWeight: FontWeight.w600,
              color: PayseColors.textPrimary,
            ),
          ),
          const SizedBox(height: PayseSpace.x1),
          b == null
              ? const Text(
                  '확인할 수 없어요',
                  key: ValueKey('accounts-total-unknown'),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: PayseColors.textSecondary,
                  ),
                )
              : FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: Text.rich(
                    key: const ValueKey('accounts-total'),
                    semanticsLabel: spokenKrw(b),
                    TextSpan(
                      text: formatKrwDigits(b),
                      children: const [
                        TextSpan(
                          text: '원',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.36,
                          ),
                        ),
                      ],
                    ),
                    style: const TextStyle(
                      fontSize: 32,
                      height: 1.2,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.28,
                      color: PayseColors.textPrimary,
                      fontFeatures: PayseTypography.tabular,
                    ),
                  ),
                ),
          const SizedBox(height: PayseSpace.x2),
          Text(
            '계산에 포함한 계좌 $included개 · ${asOfLabel(snapshot.asOf)}',
            key: const ValueKey('accounts-meta'),
            style: PayseTypography.caption,
          ),
          const SizedBox(height: PayseSpace.x4),
          SizedBox(
            height: PayseSize.touchMin,
            child: OutlinedButton(
              key: const ValueKey('accounts-change-selection'),
              onPressed: writer == null
                  ? null
                  : () => _changeSelection(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: PayseColors.textPrimary,
                side: const BorderSide(color: PayseColors.borderStrong),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(PayseRadius.sm),
                ),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: const Text('계산에 포함할 계좌 바꾸기'),
            ),
          ),
          const SizedBox(height: PayseSpace.x6),
          const Divider(height: 1, color: PayseColors.dividerSection),
          if (snapshot.settings?.salary case final salary?)
            _SalaryRow(
              text: _salaryText(salary),
              onTap: writer == null ? null : () => _editSalary(context),
            ),
          for (final (i, g) in ordered.indexed) ...[
            const SizedBox(height: PayseSpace.x6),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                g.name,
                style: const TextStyle(
                  fontSize: 15,
                  height: 22 / 15,
                  fontWeight: FontWeight.w700,
                  color: PayseColors.textPrimary,
                ),
              ),
            ),
            for (final (j, a) in g.accounts.indexed)
              _AccountRow(
                key: ValueKey('account-row-${a.accountId}'),
                snapshot: snapshot,
                account: a,
                divider: j == g.accounts.length - 1 && i < ordered.length - 1
                    ? PayseColors.dividerSection
                    : PayseColors.dividerRow,
                onRename: writer == null ? null : () => _rename(context, a),
              ),
          ],
        ],
      ),
    );
  }
}

/// 2026-10-29: 계좌 한 줄. 이름(별명이 있으면 별명)·월급 계좌·계산에서 제외 라벨 → 보조 줄(별명이면 원래 이름, 끝 4자리,
/// 모아둘 돈, 결제 카드) … 잔액 · 연필(48×48). 아래 선은 [divider](은행 끝이면 진한 선). 행 자체는 누를 수 없다.
class _AccountRow extends StatelessWidget {
  /// 2026-10-29: Snapshot [snapshot]의 계좌 [account], 이름 바꾸기 [onRename]으로 만든다.
  const _AccountRow({
    super.key,
    required this.snapshot,
    required this.account,
    required this.divider,
    required this.onRename,
  });

  final FinancialSnapshot snapshot;
  final Account account;
  final Color divider;
  final VoidCallback? onRename;

  /// 2026-10-29: 보조 줄 조각을 반환한다. 데이터로 확인되는 정보만 쓴다.
  List<String> _details() {
    final a = account;
    final reserves = [
      for (final r in snapshot.reserves ?? const <Reserve>[])
        if (r.accountId == a.accountId && r.cancelledAt == null) r,
    ];
    final cards = [
      for (final c in snapshot.cards ?? const <PaymentCard>[])
        if (c.withdrawalAccountId == a.accountId) c,
    ];
    return [
      '${a.nickname != null ? '${a.productName} ' : ''}····${lastFour(a.maskedNumber)}',
      if (reserves.length == 1) '모아둘 돈 ${formatKrw(reserves.single.amountKrw)}',
      if (reserves.length > 1) '모아둘 돈 ${reserves.length}건',
      if (cards.isNotEmpty) '카드 ${cards.length}장 결제',
    ];
  }

  /// 2026-10-29: 계좌 한 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final a = account;
    final excluded = !a.included;
    final color = excluded
        ? PayseColors.textSecondary
        : PayseColors.textPrimary;
    final name = a.nickname ?? a.productName;
    final balance = a.balanceKrw;
    final salary = snapshot.settings?.salary.salaryAccountId == a.accountId;
    final details = _details();
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(vertical: PayseSpace.x3),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: PayseSpace.x2,
                  runSpacing: PayseSpace.x1,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.47,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                    if (salary)
                      _Tag(
                        '월급 계좌',
                        key: ValueKey('account-salary-${a.accountId}'),
                        background: PayseColors.moonYellowSoft,
                        color: PayseColors.textPrimary,
                      ),
                    if (excluded)
                      _Tag(
                        '계산에서 제외',
                        key: ValueKey('account-excluded-${a.accountId}'),
                        background: PayseColors.surfaceMuted,
                        color: PayseColors.textSecondary,
                      ),
                  ],
                ),
                _Details(
                  key: ValueKey('account-detail-${a.accountId}'),
                  parts: details,
                ),
              ],
            ),
          ),
          const SizedBox(width: PayseSpace.x2),
          Text(
            balance == null ? '잔액 미확인' : formatKrw(balance),
            semanticsLabel: balance == null ? '잔액 미확인' : spokenKrw(balance),
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: balance == null ? PayseColors.textSecondary : color,
              fontFeatures: PayseTypography.tabular,
            ),
          ),
          const SizedBox(width: PayseSpace.x1),
          IconButton(
            key: ValueKey('account-rename-${a.accountId}'),
            tooltip: '$name 이름 바꾸기',
            constraints: const BoxConstraints.tightFor(
              width: PayseSize.touchMin,
              height: PayseSize.touchMin,
            ),
            color: PayseColors.textSecondary,
            onPressed: onRename,
            icon: const Icon(Icons.edit_outlined, size: 20),
          ),
        ],
      ),
    );
  }
}

/// 2026-10-29: 계좌 보조 줄. 한 줄에 다 들어가면 ' · '로 이어 한 줄, 아니면 첫 조각(계좌 번호) 다음에서 줄을 바꿔
/// 나머지를 둘째 줄에 잇는다.
class _Details extends StatelessWidget {
  /// 2026-10-29: 조각 [parts]로 만든다. 첫 조각은 계좌 번호다.
  const _Details({super.key, required this.parts});

  final List<String> parts;

  /// 2026-10-29: 보조 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style
        .merge(PayseTypography.caption);
    return LayoutBuilder(
      builder: (context, constraints) {
        final full = parts.join(' · ');
        final painter = TextPainter(
          text: TextSpan(text: full, style: style),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(maxWidth: constraints.maxWidth);
        final fits = !painter.didExceedMaxLines;
        painter.dispose();
        if (fits || parts.length == 1) {
          return Text(full, style: PayseTypography.caption);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(parts.first, style: PayseTypography.caption),
            Text(parts.skip(1).join(' · '), style: PayseTypography.caption),
          ],
        );
      },
    );
  }
}

/// 2026-10-29: 계좌 목록 위 '월급 정보' 줄. 누르면 월급 정보 편집 화면을 연다. 위아래 여백은 24dp로 같고, 아래는 은행 묶음과
/// 나누는 진한 선이다.
class _SalaryRow extends StatelessWidget {
  /// 2026-10-29: 설명 [text]와 누르기 [onTap]으로 만든다.
  const _SalaryRow({required this.text, required this.onTap});

  final String text;
  final VoidCallback? onTap;

  /// 2026-10-29: 월급 정보 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        key: const ValueKey('accounts-salary'),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(vertical: PayseSpace.x6),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: PayseColors.dividerSection),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '월급 정보',
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.47,
                        fontWeight: FontWeight.w600,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    Text(text, style: PayseTypography.caption),
                  ],
                ),
              ),
              const SizedBox(width: PayseSpace.x2),
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: PayseColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-10-29: 계좌 줄에 붙는 상태 라벨(높이 22·좌우 8·반경 8, 13/500). 글자 폭만큼만 차지한다.
class _Tag extends StatelessWidget {
  /// 2026-10-29: 글자 [text], 바탕 [background], 글자색 [color]로 만든다.
  const _Tag(
    this.text, {
    super.key,
    required this.background,
    required this.color,
  });

  final String text;
  final Color background;
  final Color color;

  /// 2026-10-29: 라벨을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: PayseSpace.x2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(PayseRadius.sm),
      ),
      child: Align(
        widthFactor: 1,
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// 2026-10-29: 계좌 탭에서 여는 '계산에 포함할 계좌 바꾸기'(01-1 재사용). 현재 계산 포함 계좌가 고른 상태로 시작한다.
/// 저장하면 응답 Snapshot을, 바꾸지 않고 누르거나 나가면 null을 돌려준다. 바꾼 상태로 나가려 하면 한 번 묻는다.
class AccountSelectionPage extends StatefulWidget {
  /// 2026-10-29: 시작 Snapshot [snapshot]과 저장 연결 [writer]로 만든다.
  const AccountSelectionPage({
    super.key,
    required this.snapshot,
    required this.writer,
  });

  final FinancialSnapshot snapshot;
  final AccountsWriter writer;

  /// 2026-10-29: 선택 상태 객체를 반환한다.
  @override
  State<AccountSelectionPage> createState() => _AccountSelectionPageState();
}

/// 2026-10-29: 01-1 흐름 상태를 이 화면 동안만 가진다.
class _AccountSelectionPageState extends State<AccountSelectionPage> {
  late final ConnectionFlowController _c = ConnectionFlowController(
    repository: widget.writer.repository,
    snapshot: widget.snapshot,
    policy: widget.writer.policy,
    onSessionInvalid: widget.writer.onSessionInvalid,
  );

  /// 2026-10-29: 흐름 상태를 폐기한다.
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// 2026-10-29: 나간다. 저장 중이면 막고, 선택을 바꿨으면 확인 창을 띄워 '저장 안 하고 나가기'를 고를 때만 나간다.
  Future<void> _leave() async {
    if (_c.selectionSave is SaveInProgress) return;
    if (_c.selectionChanged) {
      final stay = await showConnectionConfirm(
        context,
        key: const ValueKey('selection-leave-dialog'),
        title: '저장하지 않은 변경이 있어요',
        body: '나가면 바꾼 계좌 선택이 저장되지 않아요.',
        secondaryLabel: '저장 안 하고 나가기',
        secondaryKey: const ValueKey('selection-leave'),
        primaryLabel: '계속 고르기',
        primaryKey: const ValueKey('selection-keep'),
      );
      if (stay != false || !mounted) return;
    }
    Navigator.of(context).pop();
  }

  /// 2026-10-29: 01-1 화면을 반환한다. 시스템 뒤로 가기도 [_leave]로 보낸다.
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: AccountSelectScreen(
        controller: _c,
        onBack: _leave,
        onUnchanged: () => Navigator.of(context).pop(),
        onSaved: () => Navigator.of(context).pop(_c.snapshot),
      ),
    );
  }
}
