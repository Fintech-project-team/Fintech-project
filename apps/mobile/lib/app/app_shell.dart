import 'package:flutter/material.dart';

import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../data/coachmark_record_store.dart';
import '../data/salary_notice_api.dart';
import '../data/connection/transaction_history.dart';
import '../data/financial_snapshot.dart';
import '../data/first_calc_record_store.dart';
import '../features/overview/accounts_cards_screen.dart';
import '../features/overview/accounts_screen.dart';
import '../features/overview/first_calc_screen.dart';
import '../features/overview/home_calculation.dart';
import '../features/overview/home_coachmark.dart';
import '../features/overview/home_screen.dart';
import '../features/overview/overview_links.dart';
import '../features/overview/pull_refresh.dart';
import '../features/overview/salary_notice.dart';
import '../features/overview/slide_switch.dart';
import '../features/planning/plan_screen.dart';
import '../shared/design/payse_tokens.dart';
import 'logout_action.dart';
import 'placeholder_screens.dart';

/// 2026-10-20: 하단 탭(홈·계좌·계획·내 정보) 골격. 각 탭은 기능 화면이 들어갈 자리다.
/// 2026-10-29: 계좌 탭은 02-3 계좌 관리다(29-1).
/// 2026-11-02: 계획 탭은 예정 지출·남겨둘 돈 조회다(29-3).
/// 2026-10-21: PIN 확인 뒤 금융사 연결을 마친 사용자의 첫 화면으로 쓴다(main_entry.dart).
/// 2026-10-23: 진입 조회에 성공한 [snapshot]으로 홈 계산을 한 번 수행해 탭들이 같은 결과를 쓰게 한다.
class AppShell extends StatefulWidget {
  /// 2026-10-20: [devEntry]는 개발 환경에서만 내 정보 탭 아래에 붙는 진입 위젯이며 릴리스에서는 null이다.
  /// 2026-10-23: [snapshot]은 진입 조회에 성공한 스냅샷, [onReload]는 진입 조회를 다시 실행한다.
  /// 2026-10-26: [refresh]는 홈 새로고침 진행 상태이며 앱 진입 화면이 정한다.
  /// 2026-10-27: [firstCalcRecord]는 이 사용자의 01-3 기록, [onFirstCalcRecord]는 기록을 남기는 콜백이다.
  /// 콜백이 없으면 01-3을 자동으로 띄우지 않는다.
  /// 2026-10-28: [coachmarkRecord]는 이 사용자의 02-1a 코치마크 기록, [onCoachmarkRecord]는 기록을 남기는 콜백이다.
  /// 콜백이 없으면 코치마크를 띄우지 않는다.
  /// 2026-10-29: [accountsWriter]는 계좌 탭의 저장 연결(세션 저장소·세션 무효·저장 뒤 Snapshot 반영)이며 없으면 계좌 탭에서
  /// 저장할 수 없다.
  /// 2026-11-01: [salaryNotices]는 이 세션의 월급 입금 확인 안내 접힘 상태(서버 회차 기록·세션 접기)다. 없으면 안내를 펼친 채
  /// 보인다. 홈 안내의 '월급 정보 확인'은 [accountsWriter]로 저장한다.
  const AppShell({
    super.key,
    required this.snapshot,
    required this.onReload,
    this.devEntry,
    this.refresh = HomeRefresh.idle,
    this.firstCalcRecord,
    this.onFirstCalcRecord,
    this.coachmarkRecord,
    this.onCoachmarkRecord,
    this.accountsWriter,
    this.salaryNotices,
    this.onLogout,
    this.onPullRefresh,
    this.history,
  });

  final FinancialSnapshot snapshot;
  final VoidCallback onReload;
  final Widget? devEntry;
  final HomeRefresh refresh;
  final FirstCalcRecord? firstCalcRecord;
  final ValueChanged<FirstCalcRecord>? onFirstCalcRecord;
  final CoachmarkRecord? coachmarkRecord;
  final ValueChanged<CoachmarkRecord>? onCoachmarkRecord;
  final AccountsWriter? accountsWriter;

  /// 2026-10-30: 계좌·카드 탭의 아래로 당겨 새로고침(없으면 당겨도 새로고침하지 않음)과, 그 새로고침으로 받은 거래 전체
  /// [history](현재 [snapshot]과 자료 버전이 같을 때만 거래 내역이 그대로 쓴다).
  final PullRefresh? onPullRefresh;
  final TransactionHistoryReady? history;
  final SalaryNoticeController? salaryNotices;

  /// 2026-11-02: 내 정보 탭의 로그아웃(성공이면 null, 실패면 안내 문구). 없으면 버튼을 두지 않는다.
  final Future<String?> Function()? onLogout;

  static const List<String> tabTitles = ['홈', '계좌·카드', '계획', '내 정보'];

  /// 2026-10-20: 선택 탭 상태 객체를 반환한다.
  @override
  State<AppShell> createState() => _AppShellState();
}

/// 2026-10-20: 현재 탭 번호를 보관한다. 탭을 바꿔도 각 탭 상태는 유지한다.
/// 2026-10-23: 스냅샷이 바뀔 때만 다시 계산해 홈·계산 내역·첫 계산이 같은 입력 버전의 결과를 공유한다.
/// 2026-10-27: 기록이 없고 U가 계산되면 홈보다 먼저 01-3을 한 번 보인다. 데이터 오류·예상하지 못한 오류·정보 부족이면
/// 띄우지도 기록하지도 않는다. 홈에서 고른 다시 보기([_replay])는 지금 결과로 보이고 기록을 바꾸지 않는다.
/// 2026-10-28: 다시 보기 1/4에서 뒤로 가면 홈으로 돌아가고, 처음 안내 1/4에서는 머문다('홈으로 가기'로 건너뜀).
/// 2026-10-28: 01-3이 끝난 뒤 홈 탭이 계산 결과로 그려지고 코치마크 기록이 없으면 02-1a를 한 번 덮어 보인다.
class _AppShellState extends State<AppShell> {
  int _index = 0;
  late HomeCalculation _calculation = computeHomeCalculation(widget.snapshot);
  late bool _firstCalc =
      widget.onFirstCalcRecord != null &&
      widget.firstCalcRecord == null &&
      _explainable(_calculation) != null;
  bool _replay = false;
  bool _coachClosed = false;
  final HomeCoachTargets _coachTargets = HomeCoachTargets();
  final GlobalKey _navKey = GlobalKey(debugLabel: 'coach-nav');
  String? _salaryNoticePeek;

  /// 2026-10-31: 홈·계좌·카드 탭과 그 위에 쌓인 화면이 함께 보는 현재 상태와 고른 안쪽 탭(#163).
  late final ValueNotifier<OverviewState> _state = ValueNotifier((
    calculation: _calculation,
    history: widget.history,
  ));
  final ValueNotifier<AccountsCardsTab> _accountsTab = ValueNotifier(
    AccountsCardsTab.period,
  );

  /// 2026-10-31: 화면 사이 연결. 저장 연결·새로고침이 바뀔 수 있어 그릴 때마다 만든다.
  OverviewLinks get _links => OverviewLinks(
    state: _state,
    writer: widget.accountsWriter,
    onRefresh: widget.onPullRefresh,
    onShowPeriod: _showPeriod,
  );

  /// 2026-10-31: 계좌·카드 탭의 이번 기간 내역으로 간다.
  void _showPeriod() {
    _accountsTab.value = AccountsCardsTab.period;
    _select(1);
  }

  /// 2026-11-01: 탭 [index]로 바꾼다. 홈을 떠나면 잠시 다시 펼친 월급 안내를 접힌 상태로 되돌린다.
  void _select(int index) {
    setState(() {
      if (index != _index) _salaryNoticePeek = null;
      _index = index;
    });
  }

  /// 2026-10-31: 공통 상태를 폐기한다.
  @override
  void dispose() {
    widget.salaryNotices?.removeListener(_onSalaryNotices);
    _state.dispose();
    _accountsTab.dispose();
    super.dispose();
  }

  /// 2026-11-02: 내 정보 탭 아래쪽의 로그아웃 버튼과 개발 진입점을 반환한다. 둘 다 없으면 null이다.
  Widget? _accountFooter() {
    final logout = widget.onLogout;
    final dev = widget.devEntry;
    if (logout == null && dev == null) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (logout != null) LogoutAction(onLogout: logout),
        if (logout != null && dev != null) const SizedBox(height: 12),
        ?dev,
      ],
    );
  }

  /// 2026-11-01: 월급 입금 확인 안내 [notice]를 접는다(회차를 알면 서버 저장, 모르면 이 세션 동안만).
  void _foldSalaryNotice(SalaryNotice notice) {
    setState(() => _salaryNoticePeek = null);
    widget.salaryNotices?.fold(notice.payMonth, notice.key);
  }

  /// 2026-11-01: 접힌 안내 [notice]를 이 화면에서만 잠시 다시 펼친다. 서버 닫기 기록은 그대로 둔다.
  void _peekSalaryNotice(SalaryNotice notice) {
    setState(() => _salaryNoticePeek = notice.key);
  }

  /// 2026-11-01: 안내 [notice]가 지금 접혀 보여야 하면 true를 반환한다.
  bool _salaryNoticeFolded(SalaryNotice notice) =>
      _salaryNoticePeek != notice.key &&
      (widget.salaryNotices?.isFolded(notice.payMonth, notice.key) ?? false);

  /// 2026-10-29: 홈 안내에서 월급 정보 편집 화면을 연다.
  void _editSalary(BuildContext context, AccountsWriter writer) {
    openSalaryEditor(
      context,
      snapshot: widget.snapshot,
      repository: writer.repository,
      onSessionInvalid: writer.onSessionInvalid,
      onSnapshot: writer.onSnapshot,
    );
  }

  /// 2026-10-27: U가 계산된 결과면 반환한다. 아니면 null이다.
  static HomeCalculationReady? _explainable(HomeCalculation calculation) =>
      calculation is HomeCalculationReady && calculation.result.u != null
      ? calculation
      : null;

  /// 2026-10-27: 01-3을 닫는다. 처음 안내면 [record]를 남기고, 다시 보기면 기록을 바꾸지 않는다.
  void _closeFirstCalc(FirstCalcRecord record) {
    if (_firstCalc) widget.onFirstCalcRecord?.call(record);
    setState(() {
      _firstCalc = false;
      _replay = false;
    });
  }

  /// 2026-10-28: 코치마크를 보일 차례면 1단계 문구 종류를 반환한다. 기록이 있거나 닫았거나, 홈 탭이 아니거나,
  /// 새로고침 중이거나, 데이터 오류·예상하지 못한 오류면 null이다.
  CoachmarkVariant? _coachmark() {
    final calculation = _calculation;
    if (widget.onCoachmarkRecord == null ||
        widget.coachmarkRecord != null ||
        _coachClosed ||
        _index != 0 ||
        widget.refresh == HomeRefresh.loading ||
        calculation is! HomeCalculationReady) {
      return null;
    }
    final result = calculation.result;
    if (result.u != null) return CoachmarkVariant.computed;
    return result.insufficient.contains(
          calc.InsufficientReason.receiptEvidenceAbsent,
        )
        ? CoachmarkVariant.receiptAbsent
        : CoachmarkVariant.otherInsufficient;
  }

  /// 2026-10-28: 코치마크를 닫고 [record]를 남긴다.
  void _closeCoachmark(CoachmarkRecord record) {
    widget.onCoachmarkRecord?.call(record);
    setState(() => _coachClosed = true);
  }

  /// 2026-10-28: 키 [key]가 붙은 위젯의 전역 위치를 반환한다. 아직 그려지지 않았으면 null이다.
  static Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 2026-10-28: 금액 라벨부터 구성 바(또는 '월급 입금 확인하기')까지의 내용 영역을 반환한다(화면 좌우 여백 제외).
  Rect? _amountRect() {
    final top = _rectOf(_coachTargets.amountTop);
    if (top == null) return null;
    final bottom = _rectOf(_coachTargets.amountBottom);
    final area = bottom == null ? top : top.expandToInclude(bottom);
    return Rect.fromLTRB(
      area.left + PayseSpace.screenHorizontal,
      area.top,
      area.right - PayseSpace.screenHorizontal,
      area.bottom,
    );
  }

  /// 2026-10-28: 하단 계획 탭의 아이콘·글자를 감싸는 64×58 영역을 반환한다. 탭바 높이에서 아래 안전 영역을 뺀
  /// 가운데에 두고 탭바 밖으로 나가지 않게 한다.
  Rect? _planRect() {
    final nav = _rectOf(_navKey);
    if (nav == null) return null;
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    final content = nav.height - inset;
    final width = nav.width / AppShell.tabTitles.length;
    final center = Offset(nav.left + width * 2.5, nav.top + content / 2);
    final box = Rect.fromCenter(center: center, width: 64, height: 58);
    return box.top < nav.top ? box.shift(Offset(0, nav.top - box.top)) : box;
  }

  /// 2026-11-01: 급여 안내 상태가 바뀌면(서버 응답 도착) 다시 그린다.
  @override
  void initState() {
    super.initState();
    widget.salaryNotices?.addListener(_onSalaryNotices);
  }

  /// 2026-11-01: 급여 안내 상태 변화를 화면에 반영한다.
  void _onSalaryNotices() {
    if (mounted) setState(() {});
  }

  /// 2026-10-23: 다른 스냅샷이 오면 그 스냅샷으로 다시 계산한다.
  /// 2026-10-31: 공통 상태도 같은 계산·거래로 바꾼다.
  /// 2026-11-01: 급여 안내 상태 객체가 바뀌면 듣는 대상을 바꾼다.
  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.salaryNotices, widget.salaryNotices)) {
      oldWidget.salaryNotices?.removeListener(_onSalaryNotices);
      widget.salaryNotices?.addListener(_onSalaryNotices);
    }
    if (!identical(oldWidget.snapshot, widget.snapshot)) {
      _calculation = computeHomeCalculation(widget.snapshot);
    }
    final next = (calculation: _calculation, history: widget.history);
    if (!identical(_state.value.calculation, next.calculation) ||
        !identical(_state.value.history, next.history)) {
      // 위에 쌓인 화면은 이 탭 트리 밖이라 그리는 중에 알리면 안 된다. 이 프레임이 끝난 뒤 한 번에 바꾼다.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _state.value = next;
      });
    }
  }

  /// 2026-10-20: 탭 내용과 하단 탭 막대를 반환한다.
  /// 2026-10-27: 01-3을 보일 차례면 탭 대신 01-3을 반환한다.
  /// 2026-10-28: 01-3과 홈 탭은 [_transition]으로 바꿔 끼운다.
  @override
  Widget build(BuildContext context) {
    final explainable = _explainable(_calculation);
    if ((_firstCalc || _replay) && explainable != null) {
      return _transition(
        FirstCalcFlow(
          key: ValueKey(_replay ? 'first-calc-replay' : 'first-calc'),
          calculation: explainable,
          outro: !_replay,
          onBackAtFirst: _replay ? () => setState(() => _replay = false) : null,
          onExplained: () => _closeFirstCalc(FirstCalcRecord.explained),
          onSkipped: () => _closeFirstCalc(FirstCalcRecord.skipped),
        ),
      );
    }
    final resolved =
        widget.firstCalcRecord == FirstCalcRecord.deferred &&
        explainable != null;
    final coachmark = _coachmark();
    final links = _links;
    final tabs = Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(
            calculation: _calculation,
            onReload: widget.onReload,
            refresh: widget.refresh,
            record: resolved
                ? HomeSalaryRecord.resolvedAfterFirstCalc
                : HomeSalaryRecord.none,
            onShowFirstCalc: () => setState(() => _replay = true),
            coachTargets: _coachTargets,
            salaryNotice: (
              isFolded: _salaryNoticeFolded,
              onFold: _foldSalaryNotice,
              onOpen: _peekSalaryNotice,
              onEdit: switch (widget.accountsWriter) {
                final writer? => () => _editSalary(context, writer),
                null => null,
              },
            ),
            links: links,
          ),
          AccountsCardsScreen(
            links: links,
            tab: _accountsTab,
            history: widget.history,
            snapshot: widget.snapshot,
            calculation: _calculation,
            writer: widget.accountsWriter,
          ),
          PlanScreen(links: links),
          TabPlaceholder(title: '내 정보', footer: _accountFooter()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        key: _navKey,
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '홈'),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            label: '계좌·카드',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_note_outlined),
            label: '계획',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: '내 정보',
          ),
        ],
      ),
    );
    return _transition(
      Stack(
        key: const ValueKey('app-tabs'),
        children: [
          Positioned.fill(child: tabs),
          if (coachmark != null)
            Positioned.fill(
              child: HomeCoachmark(
                key: const ValueKey('home-coachmark'),
                variant: coachmark,
                amountRect: _amountRect,
                detailRect: () =>
                    _rectOf(_coachTargets.detail)?.inflate(PayseSpace.x2),
                planRect: _planRect,
                onDone: _closeCoachmark,
              ),
            ),
        ],
      ),
    );
  }

  /// 2026-10-28: 01-3과 홈 탭 사이 전환([slideSwitch]).
  Widget _transition(Widget child) => slideSwitch(context, child);
}
