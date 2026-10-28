import 'package:flutter/material.dart';

import '../data/financial_snapshot.dart';
import '../data/first_calc_record_store.dart';
import '../features/overview/first_calc_screen.dart';
import '../features/overview/home_calculation.dart';
import '../features/overview/home_screen.dart';
import '../features/overview/slide_switch.dart';
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
  const AppShell({
    super.key,
    required this.snapshot,
    required this.onReload,
    this.devEntry,
    this.refresh = HomeRefresh.idle,
    this.firstCalcRecord,
    this.onFirstCalcRecord,
  });

  final FinancialSnapshot snapshot;
  final VoidCallback onReload;
  final Widget? devEntry;
  final HomeRefresh refresh;
  final FirstCalcRecord? firstCalcRecord;
  final ValueChanged<FirstCalcRecord>? onFirstCalcRecord;

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
class _AppShellState extends State<AppShell> {
  int _index = 0;
  late HomeCalculation _calculation = computeHomeCalculation(widget.snapshot);
  late bool _firstCalc =
      widget.onFirstCalcRecord != null &&
      widget.firstCalcRecord == null &&
      _explainable(_calculation) != null;
  bool _replay = false;

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
    return _transition(
      Scaffold(
        key: const ValueKey('app-tabs'),
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
            ),
            const TabPlaceholder(title: '계좌'),
            const TabPlaceholder(title: '계획'),
            TabPlaceholder(title: '내 정보', footer: widget.devEntry),
          ],
        ),
        bottomNavigationBar: NavigationBar(
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
      ),
    );
  }

  /// 2026-10-28: 01-3과 홈 탭 사이 전환([slideSwitch]).
  Widget _transition(Widget child) => slideSwitch(context, child);
}
