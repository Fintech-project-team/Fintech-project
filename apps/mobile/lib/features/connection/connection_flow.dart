import 'dart:math';

import 'package:flutter/material.dart';

import '../../data/connection/financial_api.dart';
import '../../data/connection/user_snapshot_repository.dart';
import '../../data/financial_snapshot.dart';
import '../../data/financial_snapshot_repository.dart';
import '../overview/home_calculation.dart';
import 'connection_flow_controller.dart';
import 'connection_presentation_policy.dart';
import 'connection_screens.dart';

/// 2026-10-22: 금융사 연결 흐름(12-1 → 12-2 → 12-3 → 01-1 → 01-2). 자체 Navigator로 단계를 쌓는다.
/// 시작 Snapshot이 연결 전이면 12-1, 연결은 저장됐지만 고른 계좌가 없으면 01-1에서 시작한다.
/// 흐름을 떠나면 동의·연출·고른 상태가 사라진다.
class ConnectionFlow extends StatefulWidget {
  /// 2026-10-22: 세션 저장소 [repository], 시작 Snapshot [snapshot], 표시 정책 [policy],
  /// 01-2 확인 뒤 [onFinished], 세션 무효 [onSessionInvalid], 작업 키 난수 [random]으로 만든다.
  /// 2026-10-23: [devEntry]는 12-1·01-1 목록 끝에 붙는 개발 설정 진입이며 릴리스에서는 null이다.
  /// [userName]은 진입 로딩 제목에 쓰는 사용자 이름(없으면 이름 없이)이다.
  /// 2026-10-27: [onFinished]는 01-2가 보여 준 스냅샷과 '나중에 확인하고 홈으로'를 골랐는지(deferred)를 받는다.
  const ConnectionFlow({
    super.key,
    required this.repository,
    required this.snapshot,
    required this.policy,
    required this.onFinished,
    required this.onSessionInvalid,
    this.random,
    this.devEntry,
    this.userName,
  });

  final UserFinancialRepository repository;
  final FinancialSnapshot snapshot;
  final ConnectionPresentationPolicy policy;
  final void Function(FinancialSnapshot snapshot, {required bool deferred})
  onFinished;
  final VoidCallback onSessionInvalid;
  final Random? random;
  final Widget? devEntry;
  final String? userName;

  /// 2026-10-22: 흐름 상태 객체를 반환한다.
  @override
  State<ConnectionFlow> createState() => _ConnectionFlowState();
}

/// 2026-10-22: 흐름 Navigator와 흐름 상태 소유자를 보관한다.
class _ConnectionFlowState extends State<ConnectionFlow> {
  final GlobalKey<NavigatorState> _nav = GlobalKey<NavigatorState>();
  final ValueNotifier<EntryLoadingPhase> _entryPhase = ValueNotifier(
    EntryLoadingPhase.banks,
  );
  late final ConnectionFlowController _controller = ConnectionFlowController(
    repository: widget.repository,
    snapshot: widget.snapshot,
    policy: widget.policy,
    onSessionInvalid: widget.onSessionInvalid,
    random: widget.random,
  );

  /// 2026-10-22: 연결 전이면 진입 로딩 뒤 12-1로 넘긴다.
  @override
  void initState() {
    super.initState();
    if (widget.snapshot.institutionLinkCount == 0) _showSelectAfterEntry();
  }

  /// 2026-10-22: 흐름 상태를 폐기한다. 늦게 끝난 연출·저장 결과는 반영되지 않는다.
  @override
  void dispose() {
    _controller.dispose();
    _entryPhase.dispose();
    super.dispose();
  }

  /// 2026-10-22: 흐름 Navigator를 반환한다.
  NavigatorState get _navigator => _nav.currentState!;

  /// 2026-10-22: [page]를 새 화면 경로로 감싸 반환한다.
  Route<void> _route(Widget page) =>
      MaterialPageRoute<void>(builder: (_) => page);

  /// 2026-10-22: 12-1 진입 로딩(2~3초)이 끝나면 12-1로 바꾼다.
  /// 2026-10-23: 은행 → 카드사 단계를 차례로 끝내고 다 찾은 화면에서 멈춘다. 12-1로는 '다음'을 눌러야 간다.
  Future<void> _showSelectAfterEntry() async {
    await widget.policy.entryStepDelay();
    if (!mounted) return;
    _entryPhase.value = EntryLoadingPhase.cards;
    await widget.policy.entryStepDelay();
    if (!mounted) return;
    _entryPhase.value = EntryLoadingPhase.done;
  }

  /// 2026-10-23: 진입 로딩 화면을 반환한다. 은행·카드사 수는 시작 Snapshot의 기관 목록에서 센다.
  Widget _entryLoading() {
    final institutions = widget.snapshot.institutions;
    final banks = institutions.where((i) => i.kind == 'bank').length;
    return InstitutionEntryLoadingScreen(
      phase: _entryPhase,
      bankCount: banks,
      cardCount: institutions.length - banks,
      userName: widget.userName,
      onNext: () => _navigator.pushReplacement(_route(_select())),
    );
  }

  /// 2026-10-22: 12-1 화면을 반환한다.
  Widget _select() => InstitutionSelectScreen(
    controller: _controller,
    devEntry: widget.devEntry,
    onNext: () {
      _controller.enterConsent();
      _navigator.push(_route(_consent()));
    },
  );

  /// 2026-10-22: 12-2 화면을 반환한다. 진행하면 12-3으로 가며 불러오기 연출을 시작한다.
  Widget _consent() => ConsentScreen(
    controller: _controller,
    onBack: () => _navigator.pop(),
    onViewItems: (i) =>
        _navigator.push(_route(ConsentItemsScreen(institution: i))),
    onNext: () {
      _navigator.push(_route(_loading()));
      _controller.startLoading();
    },
  );

  /// 2026-10-22: 12-3 화면을 반환한다. 저장 성공 뒤 01-1, 거절되면 12-1로 돌아간다.
  Widget _loading() => InstitutionLoadingScreen(
    controller: _controller,
    onBack: () => _navigator.pop(),
    onSaved: () => _navigator.push(_route(_accounts(canGoBack: true))),
    onRestart: () => _navigator.popUntil((r) => r.isFirst),
  );

  /// 2026-10-22: 01-1 화면을 반환한다. 가입 흐름에서는 뒤로 가기로 12-3 결과에 돌아간다.
  Widget _accounts({required bool canGoBack}) => AccountSelectScreen(
    controller: _controller,
    devEntry: widget.devEntry,
    onBack: canGoBack ? () => _navigator.pop() : null,
    onSaved: () => _navigator.push(_route(_review())),
  );

  /// 2026-10-22: 01-2 화면을 반환한다. 계좌 선택 저장 응답의 최신 Snapshot을 보인다.
  /// 2026-10-27: 다시 불러오기와 같은 스냅샷 계산을 맡는 [_ReviewHost]로 감싼다.
  Widget _review() => _ReviewHost(
    repository: widget.repository,
    snapshot: _controller.snapshot,
    onBack: () => _navigator.pop(),
    onFinished: widget.onFinished,
    onSessionInvalid: widget.onSessionInvalid,
  );

  /// 2026-10-22: 시스템 뒤로 가기를 흐름 Navigator로 넘기는 흐름 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    final resume = widget.snapshot.institutionLinkCount > 0;
    return NavigatorPopHandler<void>(
      onPopWithResult: (_) => _nav.currentState?.maybePop(),
      child: HeroControllerScope.none(
        child: Navigator(
          key: _nav,
          onGenerateInitialRoutes: (_, _) => [
            _route(resume ? _accounts(canGoBack: false) : _entryLoading()),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-27: 01-2 상태 소유자. 보이는 스냅샷과 그 홈 계산 결과, 다시 불러오기 진행 상태를 보관한다.
/// 2026-10-28: 계산 자체가 오류(데이터 오류·예상하지 못한 오류)인 채 홈으로 가면 보완 미룸을 기록하지 않는다.
class _ReviewHost extends StatefulWidget {
  /// 2026-10-27: 세션 저장소 [repository], 처음 보일 [snapshot], 뒤로 [onBack], 끝 [onFinished],
  /// 세션 무효 [onSessionInvalid]로 만든다.
  const _ReviewHost({
    required this.repository,
    required this.snapshot,
    required this.onBack,
    required this.onFinished,
    required this.onSessionInvalid,
  });

  final UserFinancialRepository repository;
  final FinancialSnapshot snapshot;
  final VoidCallback onBack;
  final void Function(FinancialSnapshot snapshot, {required bool deferred})
  onFinished;
  final VoidCallback onSessionInvalid;

  /// 2026-10-27: 01-2 상태 객체를 반환한다.
  @override
  State<_ReviewHost> createState() => _ReviewHostState();
}

/// 2026-10-27: 다시 불러오기에 성공하면 새 스냅샷으로 다시 계산하고, 실패하면 이전 화면을 유지하고 알린다.
class _ReviewHostState extends State<_ReviewHost> {
  late FinancialSnapshot _snapshot = widget.snapshot;
  late HomeCalculation _calculation = computeHomeCalculation(_snapshot);
  ReviewReload _reload = ReviewReload.idle;

  /// 2026-10-27: 스냅샷을 다시 조회한다. 진행 중이면 다시 요청하지 않는다. 계좌 묶음이 없거나 형식이 맞지 않는
  /// 응답은 실패로 보고 이전 스냅샷을 유지한다. 세션 무효면 신규 로그인으로 넘긴다.
  Future<void> _reloadSnapshot() async {
    if (_reload == ReviewReload.loading) return;
    setState(() => _reload = ReviewReload.loading);
    SnapshotLoadResult result;
    try {
      result = await UserSnapshotRepository(widget.repository).loadSnapshot();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack, library: 'payse'),
      );
      result = SnapshotLoadFailed(error);
    }
    if (!mounted) return;
    switch (result) {
      case SnapshotLoaded(:final snapshot) when snapshot.accounts != null:
        setState(() {
          _snapshot = snapshot;
          _calculation = computeHomeCalculation(snapshot);
          _reload = ReviewReload.idle;
        });
      case SnapshotLoadFailed(:final error)
          when error is FinancialLoadError && error.sessionInvalid:
        widget.onSessionInvalid();
      case _:
        setState(() => _reload = ReviewReload.failed);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('정보를 다시 불러오지 못했어요. 이전에 불러온 정보를 보여드려요.')),
        );
    }
  }

  /// 2026-10-27: 01-2 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ConnectionReviewScreen(
      snapshot: _snapshot,
      calculation: _calculation,
      reload: _reload,
      onBack: widget.onBack,
      onReload: _reloadSnapshot,
      onCalculate: () => widget.onFinished(_snapshot, deferred: false),
      onDefer: () => widget.onFinished(
        _snapshot,
        deferred: _calculation is HomeCalculationReady,
      ),
    );
  }
}
