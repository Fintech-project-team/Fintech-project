import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../data/connection/transaction_history.dart';
import '../../shared/design/payse_tokens.dart';

/// 2026-10-30: 아래로 당겨 새로고침 한 번의 결과(29-2 명세 '새로고침 반영 기준').
sealed class PullRefreshResult {
  const PullRefreshResult();
}

/// 2026-10-30: Snapshot과 그 자료 버전의 거래 전체를 받아 앱에 반영했다. [history]는 반영한 Snapshot·거래·조회 범위다.
final class PullRefreshDone extends PullRefreshResult {
  /// 2026-10-30: 반영한 [history]로 만든다.
  const PullRefreshDone(this.history);

  final TransactionHistoryReady history;
}

/// 2026-10-30: 받지 못했다. 아무것도 반영하지 않았고 이전 정보가 그대로다.
final class PullRefreshFailed extends PullRefreshResult {
  /// 2026-10-30: 실패를 만든다.
  const PullRefreshFailed();
}

/// 2026-10-30: 세션 무효·연결 상태 변경 등으로 앱 진입 처리가 화면을 바꿨거나, 더 새로운 저장 결과가 있어 이 응답을 버렸다.
/// 이 화면에서는 알림·띠를 보이지 않는다.
final class PullRefreshSkipped extends PullRefreshResult {
  /// 2026-10-30: 건너뜀을 만든다.
  const PullRefreshSkipped();
}

/// 2026-10-30: 공통 금융 정보를 다시 받는 함수. 진행 중에 다시 부르면 같은 요청의 결과를 기다린다.
typedef PullRefresh = Future<PullRefreshResult> Function();

/// 2026-10-30: 홈 새로고침 실패 띠와 같은 면의 안내 띠. 높이는 내용에 맞추고 위아래 16dp, 제목-설명 4dp, 설명-'다시 시도'
/// 8dp다. [onRetry]가 있을 때만 '다시 시도'를 두며, 터치 영역(48dp)은 글자 위아래로 겹쳐 놓아 아래 여백을 더하지 않는다.
class NoticeBand extends StatelessWidget {
  /// 2026-10-30: 제목 [title], 설명 [body], 다시 시도 [onRetry], 다시 시도 키 [retryKey]로 만든다.
  const NoticeBand({
    required this.title,
    required this.body,
    this.onRetry,
    this.retryKey = const ValueKey('tx-retry'),
    super.key,
  });

  final String title;
  final String body;
  final VoidCallback? onRetry;
  final Key retryKey;

  static const double _vertical = PayseSpace.x4;
  static const TextStyle _retryStyle = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w700,
    decoration: TextDecoration.underline,
  );

  /// 2026-10-30: 띠를 반환한다.
  @override
  Widget build(BuildContext context) {
    final retry = onRetry;
    final lineHeight = MediaQuery.textScalerOf(context).scale(14) * 20 / 14;
    final touch = lineHeight > PayseSize.touchMin
        ? lineHeight
        : PayseSize.touchMin;
    final overflow = (touch - lineHeight) / 2;
    final content = Padding(
      padding: const EdgeInsets.only(bottom: _vertical),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              height: 20 / 14,
              fontWeight: FontWeight.w600,
              color: PayseColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: const TextStyle(
              fontSize: 13,
              height: 19 / 13,
              color: PayseColors.textSecondary,
            ),
          ),
          if (retry != null) ...[
            const SizedBox(height: PayseSpace.x2),
            SizedBox(height: lineHeight),
          ],
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        _vertical,
        PayseSpace.screenHorizontal,
        0,
      ),
      decoration: const BoxDecoration(
        color: PayseColors.insufficientNoticeSurface,
        border: Border(bottom: BorderSide(color: PayseColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.error_outline,
              size: 18,
              color: PayseColors.error,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: retry == null
                ? content
                : Stack(
                    children: [
                      content,
                      Positioned(
                        left: 0,
                        bottom: _vertical - overflow,
                        height: touch,
                        child: TextButton(
                          key: retryKey,
                          onPressed: retry,
                          style: TextButton.styleFrom(
                            minimumSize: Size(44, touch),
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: PayseColors.textPrimary,
                            textStyle: _retryStyle,
                          ),
                          child: const Text('다시 시도'),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 2026-10-30: 아래로 당겨 새로고침하는 목록(시안 R-1~R-6, 실기기 확인 반영). [onRefresh]가 있으면 목록 위로 당길 수 있다.
/// 당기는 동안은 문구 없이 원형 표시가 당긴 만큼 차오르고, 기준 거리([triggerDistance])에 닿으면 진하게 바뀐다. 손을 뗄 때만
/// 요청하고, 놓기 전에 기준 아래로 되돌리면 취소다. 요청 중에는 같은 자리에서 회전하며 [slowAfter]가 지나도 끝나지 않을 때만
/// '새로고침 중…'을 페이드인한다. 성공하면 즉시 반영하고 같은 자리에서 체크와 '최신 정보를 확인했어요.'로 바꿔 [doneHold] 뒤
/// 접는다. 실패하면 접고 [slivers] 위에 '새로고침하지 못했어요' 띠와 다시 시도를 둔다. 표시 자리는 목록 위쪽 바깥에 생겨
/// 목록을 밀지 않으며, 아이콘 자리와 한 줄 문구 자리를 늘 확보해 문구 유무로 위치가 바뀌지 않는다. 최소 대기는 두지 않는다.
/// 시각 문구와 별도로 스크린리더에 시작·완료·실패를 알린다.
class PullRefreshScrollView extends StatefulWidget {
  /// 2026-10-30: 목록 [slivers], 새로고침 [onRefresh], 성공 뒤 처리 [onDone], 스크롤 [controller], 목록 키 [scrollKey]로 만든다.
  const PullRefreshScrollView({
    required this.slivers,
    this.onRefresh,
    this.onDone,
    this.controller,
    this.scrollKey,
    super.key,
  });

  final List<Widget> slivers;
  final PullRefresh? onRefresh;
  final ValueChanged<TransactionHistoryReady>? onDone;
  final ScrollController? controller;
  final Key? scrollKey;

  /// 2026-10-30: 진행·완료 표시 자리 높이. 아이콘 자리와 문구 자리 묶음을 가운데에 둔다.
  static const double indicatorExtent = 84;

  /// 2026-10-30: 이만큼 당긴 채 놓으면 새로고침한다.
  static const double triggerDistance = 96;

  /// 2026-10-30: 요청이 이보다 오래 걸릴 때만 '새로고침 중…'을 보인다.
  static const Duration slowAfter = Duration(seconds: 1);

  /// 2026-10-30: 성공 표시를 보이는 시간. 응답 반영을 늦추지 않으며 반영 뒤 표시만 남긴다.
  static const Duration doneHold = Duration(milliseconds: 1500);

  /// 2026-10-30: 문구·아이콘 전환 시간.
  static const Duration fade = Duration(milliseconds: 180);

  /// 2026-10-30: 표시 자리를 접는 시간.
  static const Duration collapse = Duration(milliseconds: 250);

  /// 2026-10-30: 상태 객체를 반환한다.
  @override
  State<PullRefreshScrollView> createState() => _PullRefreshScrollViewState();
}

/// 2026-10-30: 새로고침 단계. 진행·완료·접는 중에는 다시 당겨도 요청하지 않는다.
enum _Phase { idle, refreshing, done, closing }

/// 2026-10-30: 목록의 기준점. 새로고침 표시 자리는 이 앞(위쪽 바깥)에 붙어 생겨도 목록을 밀지 않는다.
const Key _center = ValueKey('pull-refresh-center');

/// 2026-10-30: 당긴 거리·손가락 접촉·단계·느린 요청 여부·실패 띠를 가진다.
class _PullRefreshScrollViewState extends State<PullRefreshScrollView> {
  ScrollController? _own;
  double _pull = 0;
  bool _dragging = false;

  /// 2026-10-30: 이번 넘침이 손으로 당겨 생긴 것인지. 표시를 접으며 되돌아갈 때는 당김 표시를 보이지 않는다.
  bool _byHand = false;
  _Phase _phase = _Phase.idle;
  bool _slow = false;
  bool _failed = false;
  Timer? _slowTimer;
  Timer? _doneTimer;
  int _run = 0;

  ScrollController get _controller =>
      widget.controller ?? (_own ??= ScrollController());

  bool get _armed => _pull >= PullRefreshScrollView.triggerDistance;

  /// 2026-10-30: 타이머와 직접 만든 컨트롤러를 폐기한다.
  @override
  void dispose() {
    _slowTimer?.cancel();
    _doneTimer?.cancel();
    _own?.dispose();
    super.dispose();
  }

  /// 2026-10-30: 스크린리더에 [message]를 알린다.
  void _announce(String message) {
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  /// 2026-10-30: 맨 위 넘침 거리와 손가락 접촉을 따른다. 손을 뗀 순간에만 판단한다(손가락을 떼는 입력을 먼저 받고, 놓친
  /// 경우 끌기가 관성·되돌아감으로 바뀌는 알림으로 받는다). 기준 거리에 처음 닿으면 가벼운 진동으로도 알린다.
  bool _onScroll(ScrollNotification n) {
    if (widget.onRefresh == null || n.depth != 0) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _dragging = true;
      _byHand = true;
    } else if (n is ScrollUpdateNotification && n.dragDetails == null ||
        n is ScrollEndNotification ||
        n is UserScrollNotification && n.direction == ScrollDirection.idle) {
      _release();
    }
    if (n is ScrollUpdateNotification || n is OverscrollNotification) {
      final over = math.max(0.0, n.metrics.minScrollExtent - n.metrics.pixels);
      if (over != _pull) {
        final wasArmed = _armed;
        setState(() {
          _pull = over;
          if (over == 0 && !_dragging) _byHand = false;
        });
        if (_dragging && !wasArmed && _armed && _phase == _Phase.idle) {
          HapticFeedback.selectionClick();
        }
      }
    }
    return false;
  }

  /// 2026-10-30: 손을 뗐다. 기준 거리 이상이었으면 새로고침한다.
  void _release() {
    if (!_dragging) return;
    _dragging = false;
    if (_phase == _Phase.idle && _armed) {
      _start();
    } else {
      setState(() {});
    }
  }

  /// 2026-10-30: 새로고침을 시작한다. 표시 자리는 목록 위쪽 바깥(기준점 위)에 생기므로 목록은 밀리지 않고, 당겨 둔 만큼
  /// 되돌아가다 그 자리에서 멈춘다. '다시 시도'로 시작하면([reveal]) 표시 자리가 보이도록 맨 위로 올린다.
  Future<void> _start({bool reveal = false}) async {
    final refresh = widget.onRefresh;
    if (refresh == null || _phase != _Phase.idle) return;
    final run = ++_run;
    _doneTimer?.cancel();
    setState(() {
      _phase = _Phase.refreshing;
      _slow = false;
      _byHand = false;
    });
    _announce('새로고침 중');
    _slowTimer?.cancel();
    _slowTimer = Timer(PullRefreshScrollView.slowAfter, () {
      if (mounted && run == _run && _phase == _Phase.refreshing) {
        setState(() => _slow = true);
      }
    });
    if (reveal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        final position = _controller.position;
        position.animateTo(
          position.minScrollExtent,
          duration: PullRefreshScrollView.collapse,
          curve: Curves.easeOut,
        );
      });
    }
    PullRefreshResult result;
    try {
      result = await refresh();
    } catch (_) {
      result = const PullRefreshFailed();
    }
    _slowTimer?.cancel();
    if (!mounted || run != _run) return;
    switch (result) {
      case PullRefreshDone(:final history):
        setState(() {
          _phase = _Phase.done;
          _failed = false;
        });
        widget.onDone?.call(history);
        _announce('최신 정보를 확인했어요');
        _doneTimer = Timer(PullRefreshScrollView.doneHold, _close);
      case PullRefreshFailed():
        setState(() => _failed = true);
        _announce('새로고침하지 못했어요. 이전 정보를 보여드려요.');
        _close();
      case PullRefreshSkipped():
        _close();
    }
  }

  /// 2026-10-30: 표시 자리를 접는다. 보이고 있으면 목록을 맨 위로 부드럽게 올린 뒤 거두며, 사용자가 만지고 있으면 기다리지
  /// 않고 거둔다(화면 사용을 막지 않음).
  Future<void> _close() async {
    if (!mounted || _phase == _Phase.idle || _phase == _Phase.closing) return;
    setState(() => _phase = _Phase.closing);
    if (_controller.hasClients && !_dragging) {
      final position = _controller.position;
      if (position.pixels < 0) {
        await position.animateTo(
          0,
          duration: PullRefreshScrollView.collapse,
          curve: Curves.easeInOut,
        );
      }
    }
    if (mounted && _phase == _Phase.closing) {
      setState(() => _phase = _Phase.idle);
    }
  }

  /// 2026-10-30: 목록을 반환한다.
  @override
  Widget build(BuildContext context) {
    final refreshable = widget.onRefresh != null;
    final shown = switch (_phase) {
      _Phase.idle => null,
      _Phase.refreshing => _slow ? _Mode.slow : _Mode.refreshing,
      _Phase.done || _Phase.closing => _Mode.done,
    };
    final view = CustomScrollView(
      key: widget.scrollKey,
      controller: _controller,
      center: refreshable ? _center : null,
      physics: refreshable ? const _PullPhysics() : null,
      slivers: [
        if (refreshable)
          SliverToBoxAdapter(
            child: shown == null
                ? const SizedBox.shrink()
                : SizedBox(
                    height: PullRefreshScrollView.indicatorExtent,
                    child: _Indicator(
                      key: const ValueKey('refresh-indicator'),
                      mode: shown,
                    ),
                  ),
          ),
        if (refreshable) const SliverToBoxAdapter(key: _center),
        if (_failed)
          SliverToBoxAdapter(
            child: NoticeBand(
              key: const ValueKey('refresh-failed'),
              title: '새로고침하지 못했어요',
              body: '이전 정보를 보여드려요.',
              retryKey: const ValueKey('refresh-retry'),
              onRetry: () => _start(reveal: true),
            ),
          ),
        ...widget.slivers,
      ],
    );
    if (!refreshable) return view;
    final pulling = _byHand && _phase == _Phase.idle && _pull > 0;
    return Listener(
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Stack(
          children: [
            view,
            if (pulling)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: _pull,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.bottomCenter,
                    minHeight: PullRefreshScrollView.indicatorExtent,
                    maxHeight: PullRefreshScrollView.indicatorExtent,
                    child: _Indicator(
                      key: const ValueKey('pull-indicator'),
                      mode: _armed ? _Mode.armed : _Mode.pulling,
                      progress: _pull / PullRefreshScrollView.triggerDistance,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-30: 위로 넘칠 때 저항을 기본 바운스보다 조금 크게 둔 스크롤. 당긴 영역이 과하게 커지지 않게 한다.
class _PullPhysics extends BouncingScrollPhysics {
  const _PullPhysics({super.parent = const AlwaysScrollableScrollPhysics()});

  @override
  _PullPhysics applyTo(ScrollPhysics? ancestor) =>
      _PullPhysics(parent: buildParent(ancestor));

  @override
  double frictionFactor(double overscrollFraction) =>
      0.4 * math.pow(1 - overscrollFraction, 2);
}

/// 2026-10-30: 새로고침 표시 단계. [slow]는 요청이 오래 걸려 '새로고침 중…'을 보이는 단계다.
enum _Mode { pulling, armed, refreshing, slow, done }

/// 2026-10-30: 새로고침 표시. 아이콘 자리(24)와 4dp 아래 한 줄 문구 자리(13/19)를 늘 확보해 가운데에 둔다. 당기는 중에는
/// 원형 선이 당긴 만큼 차오르고(textSecondary), 기준에 닿으면 다 찬 진한 원(textPrimary)으로 조금 커진다. 진행 중에는 같은
/// 자리에서 회전하고, 완료는 체크로 바뀐다. 아이콘·문구 전환은 [PullRefreshScrollView.fade]로 겹쳐 바꾼다. 상태는
/// 스크린리더 알림으로 따로 전하므로 표시 자체는 읽지 않는다.
class _Indicator extends StatelessWidget {
  /// 2026-10-30: 단계 [mode]와 기준 거리 대비 당긴 비율 [progress]로 만든다.
  const _Indicator({required this.mode, this.progress = 1, super.key});

  final _Mode mode;
  final double progress;

  /// 2026-10-30: 표시를 반환한다.
  @override
  Widget build(BuildContext context) {
    final text = switch (mode) {
      _Mode.slow => '새로고침 중…',
      _Mode.done => '최신 정보를 확인했어요.',
      _ => '',
    };
    final Widget icon = switch (mode) {
      _Mode.pulling => CircularProgressIndicator(
        key: const ValueKey('pull-arc'),
        value: progress.clamp(0.0, 1.0),
        strokeWidth: 2,
        color: PayseColors.textSecondary,
        backgroundColor: PayseColors.dividerRow,
      ),
      _Mode.armed => const CircularProgressIndicator(
        key: ValueKey('pull-armed'),
        value: 1,
        strokeWidth: 2.5,
        color: PayseColors.textPrimary,
      ),
      _Mode.refreshing || _Mode.slow => const CircularProgressIndicator(
        key: ValueKey('refresh-spin'),
        strokeWidth: 2.5,
        color: PayseColors.textPrimary,
      ),
      _Mode.done => const Icon(
        Icons.check_circle_outline,
        key: ValueKey('refresh-done'),
        size: 24,
        color: PayseColors.textPrimary,
      ),
    };
    final lineHeight = MediaQuery.textScalerOf(context).scale(13) * 19 / 13;
    return ExcludeSemantics(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 24,
              child: Center(
                child: AnimatedSwitcher(
                  duration: PullRefreshScrollView.fade,
                  child: AnimatedScale(
                    key: ValueKey(icon.key),
                    scale: mode == _Mode.armed ? 1.1 : 1,
                    duration: PullRefreshScrollView.fade,
                    child: SizedBox.square(
                      dimension: mode == _Mode.done ? 24 : 20,
                      child: icon,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: lineHeight,
              child: AnimatedSwitcher(
                duration: PullRefreshScrollView.fade,
                child: Text(
                  text,
                  key: ValueKey(text),
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 19 / 13,
                    color: PayseColors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
