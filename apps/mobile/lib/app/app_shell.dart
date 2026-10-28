import 'package:flutter/material.dart';

import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../data/coachmark_record_store.dart';
import '../data/financial_snapshot.dart';
import '../data/first_calc_record_store.dart';
import '../features/overview/first_calc_screen.dart';
import '../features/overview/home_calculation.dart';
import '../features/overview/home_coachmark.dart';
import '../features/overview/home_screen.dart';
import '../features/overview/slide_switch.dart';
import '../shared/design/payse_tokens.dart';
import 'placeholder_screens.dart';

/// 2026-10-20: 하단 탭(홈·계좌·계획·내 정보) 골격. 각 탭은 기능 화면이 들어갈 자리다.
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
  });

  final FinancialSnapshot snapshot;
  final VoidCallback onReload;
  final Widget? devEntry;
  final HomeRefresh refresh;
  final FirstCalcRecord? firstCalcRecord;
  final ValueChanged<FirstCalcRecord>? onFirstCalcRecord;
  final CoachmarkRecord? coachmarkRecord;
  final ValueChanged<CoachmarkRecord>? onCoachmarkRecord;

  static const List<String> tabTitles = ['홈', '계좌', '계획', '내 정보'];

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

  /// 2026-10-23: 다른 스냅샷이 오면 그 스냅샷으로 다시 계산한다.
  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.snapshot, widget.snapshot)) {
      _calculation = computeHomeCalculation(widget.snapshot);
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
          ),
          const TabPlaceholder(title: '계좌'),
          const TabPlaceholder(title: '계획'),
          TabPlaceholder(title: '내 정보', footer: widget.devEntry),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        key: _navKey,
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '홈'),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            label: '계좌',
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
                detailRect: () => _rectOf(_coachTargets.detail),
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
