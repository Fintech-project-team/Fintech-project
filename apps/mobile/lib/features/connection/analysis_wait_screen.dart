import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/analysis/analysis_wait_session.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_tokens.dart';
import '../../shared/design/primary_button.dart';
import '../../shared/design/secondary_button.dart';
import 'analysis_illustration.dart';
import 'connection_page.dart';

/// 2026-11-04: 기다리는 동안 번갈아 보일 그림과 문구. 서버 진행 단계가 아니라 앱 시계로 바꾸는 연출이다.
const List<(AnalysisArt, String)> _waitCycle = [
  (AnalysisArt.sorting, '거래 내역을 정리하고 있어요'),
  (AnalysisArt.finding, '반복되는 지출과 수입을 찾고 있어요'),
  (AnalysisArt.preparing, '첫 계산을 준비하고 있어요'),
];

/// 2026-11-04: 그림·문구 한 쌍을 보이는 시간(시안 v2 확정값).
const Duration _cycleStep = Duration(seconds: 10);

/// 2026-11-04: 기다리기 시작해 이 시간이 지나면 오래 걸린다는 설명으로 바꾼다(보통 3~5분 안내의 끝).
const Duration _slowAfter = Duration(minutes: 5);

/// 2026-11-04: 결과 줄이 하나씩 올라오는 간격과 한 줄의 움직임 시간, 마지막 줄 뒤 '다음'까지의 간격.
const int _rowGapMs = 180;
const int _rowRiseMs = 360;
const int _bandDelayMs = 120;
const int _bandRiseMs = 320;

/// 2026-11-04: 01-2 다음, 01-3 전에 첫 분석을 기다리는 화면(시안 v2, E-1 제외).
/// 기다리는 동안에는 완료 표시·건수 없이 그림·문구 세 쌍을 10초씩 바꾸고, 끝나면 결과 세 줄과 '다음'을 보인다.
/// 자동으로 넘어가지 않는다. 기기의 움직임 줄이기 설정이 켜져 있으면 그림·줄·버튼이 움직이지 않는다.
class AnalysisWaitScreen extends StatefulWidget {
  /// 2026-11-04: 분석 상태 [state], 사용자가 누른 '다시 시도' [onRetry], 끝난 뒤 '다음' [onNext],
  /// 제목의 사용자 이름 [userName](없으면 이름 없이)으로 만든다.
  const AnalysisWaitScreen({
    super.key,
    required this.state,
    required this.onRetry,
    required this.onNext,
    this.userName,
  });

  final ValueListenable<AnalysisWaitState> state;
  final VoidCallback onRetry;
  final VoidCallback onNext;
  final String? userName;

  /// 2026-11-04: 순환·결과 등장 상태 객체를 반환한다.
  @override
  State<AnalysisWaitScreen> createState() => _AnalysisWaitScreenState();
}

/// 2026-11-04: 기다리는 동안의 순환 위치·5분 경과 여부와 결과 등장 움직임을 보관한다.
/// 다시 시도로 기다리는 상태에 돌아오면 순환과 5분 기준을 처음부터 다시 센다.
class _AnalysisWaitScreenState extends State<AnalysisWaitScreen>
    with SingleTickerProviderStateMixin {
  static const int _revealMs =
      2 * _rowGapMs + _rowRiseMs + _bandDelayMs + _bandRiseMs;

  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _revealMs),
  );
  Timer? _cycleTimer;
  Timer? _slowTimer;
  int _step = 0;
  bool _slow = false;
  late AnalysisWaitState _current = widget.state.value;

  /// 2026-11-04: 상태 알림을 구독하고 현재 상태에 맞춰 시작한다.
  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    if (_current is AnalysisRunning) _startWaiting();
  }

  /// 2026-11-04: 상태 알림 대상이 바뀌면 구독을 옮긴다.
  @override
  void didUpdateWidget(covariant AnalysisWaitScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onState);
      widget.state.addListener(_onState);
      _onState();
    }
  }

  /// 2026-11-04: 끝난 상태로 처음 그릴 때 움직임 줄이기 설정을 반영한다.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_current is AnalysisFinished &&
        _reveal.value == 0 &&
        !_reveal.isAnimating) {
      _showResult();
    }
  }

  /// 2026-11-04: 구독·타이머·움직임을 정리한다.
  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _stopWaiting();
    _reveal.dispose();
    super.dispose();
  }

  /// 2026-11-04: 새 상태를 반영한다. 기다리는 중으로 바뀌면 순환을 처음부터, 끝나면 결과 등장을 시작한다.
  void _onState() {
    final next = widget.state.value;
    final wasRunning = _current is AnalysisRunning;
    setState(() => _current = next);
    switch (next) {
      case AnalysisRunning() when !wasRunning:
        _startWaiting();
      case AnalysisRunning():
        break;
      case AnalysisFinished():
        _stopWaiting();
        _showResult();
    }
  }

  /// 2026-11-04: 순환 위치·5분 기준을 처음으로 두고 타이머를 건다. 결과 줄·버튼은 숨긴다.
  void _startWaiting() {
    _stopWaiting();
    _step = 0;
    _slow = false;
    _reveal.value = 0;
    _cycleTimer = Timer.periodic(_cycleStep, (_) {
      if (mounted) setState(() => _step = (_step + 1) % _waitCycle.length);
    });
    _slowTimer = Timer(_slowAfter, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  /// 2026-11-04: 기다리는 동안의 타이머를 멈춘다.
  void _stopWaiting() {
    _cycleTimer?.cancel();
    _slowTimer?.cancel();
    _cycleTimer = null;
    _slowTimer = null;
  }

  /// 2026-11-04: 결과 줄·'다음'을 차례로 올린다. 움직임 줄이기가 켜져 있으면 바로 보인다.
  void _showResult() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _reveal.value = 1;
    } else {
      _reveal.forward(from: 0);
    }
  }

  /// 2026-11-04: 결과 줄 [index]가 올라온 정도(0~1)를 반환한다.
  double _rowShown(int index) => Interval(
    index * _rowGapMs / _revealMs,
    (index * _rowGapMs + _rowRiseMs) / _revealMs,
    curve: Curves.easeOutCubic,
  ).transform(_reveal.value);

  /// 2026-11-04: 기다리는 중·끝난 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final fade = still ? Duration.zero : const Duration(milliseconds: 300);
    final current = _current;
    final finished = current is AnalysisFinished ? current : null;
    final (art, waitText) = _waitCycle[_step];
    final who = widget.userName == null ? '' : '${widget.userName}님의 ';
    return ConnectionPage(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConnectionHeading(
            finished != null ? '첫 계산 준비를\n마쳤어요' : '$who거래를\n살펴보고 있어요',
            subtitle: finished != null
                ? '이제 쓸 수 있는 돈을 확인해 보세요.'
                : _slow
                ? '생각보다 오래 걸리고 있어요.\n조금만 더 기다려주세요.'
                : '보통 3~5분 걸려요.\n앱을 나가도 분석은 계속돼요.',
          ),
          Expanded(
            child: Center(
              child: AnimatedSwitcher(
                duration: fade,
                child: AnalysisIllustration(
                  key: ValueKey(
                    finished == null ? art : _finishedArt(finished),
                  ),
                  art: finished == null ? art : _finishedArt(finished),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              0,
              PayseSpace.screenHorizontal,
              40,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 192),
              child: finished == null
                  ? _WaitLine(text: waitText, fade: fade)
                  : _results(finished),
            ),
          ),
        ],
      ),
      bottom: AnimatedBuilder(
        animation: _reveal,
        builder: (context, child) {
          final shown = finished != null && _reveal.isCompleted;
          final v = finished == null
              ? 0.0
              : const Interval(
                  (2 * _rowGapMs + _rowRiseMs + _bandDelayMs) / _revealMs,
                  1,
                  curve: Curves.easeOutCubic,
                ).transform(_reveal.value);
          return IgnorePointer(
            ignoring: !shown,
            child: ExcludeSemantics(
              excluding: finished == null,
              child: ClipRect(
                child: FractionalTranslation(
                  translation: Offset(0, 1 - v),
                  child: Opacity(opacity: v, child: child),
                ),
              ),
            ),
          );
        },
        child: PrimaryButton(
          key: const ValueKey('analysis-next'),
          label: '다음',
          onPressed: widget.onNext,
        ),
      ),
    );
  }

  /// 2026-11-04: 끝난 결과 [result]의 그림 장면을 반환한다.
  static AnalysisArt _finishedArt(AnalysisFinished result) {
    if (result.candidateCount == 0) return AnalysisArt.empty;
    return result.interpreted ? AnalysisArt.done : AnalysisArt.unfinished;
  }

  /// 2026-11-04: 결과 세 줄을 반환한다. 후보 0개(F)와 분석을 마치지 못함(G)을 다른 줄로 보인다.
  Widget _results(AnalysisFinished result) {
    final count = result.candidateCount;
    final candidate = count == 0
        ? const _ResultRow(
            key: ValueKey('analysis-row-candidates'),
            kind: AnalysisMarkKind.lens,
            title: '이번에는 반복 후보를 찾지 못했어요',
            detail: '나중에 홈 화면에서 안내해드릴게요.',
          )
        : _ResultRow(
            key: const ValueKey('analysis-row-candidates'),
            kind: AnalysisMarkKind.lens,
            title: '반복 후보 ${formatKrwDigits(count)}개를 찾았어요',
            detail: result.interpreted ? null : '내용 분석은 마치지 못했어요.',
            trailing: result.interpreted
                ? null
                : SecondaryButton(
                    key: const ValueKey('analysis-retry'),
                    label: '다시 시도',
                    onPressed: widget.onRetry,
                  ),
          );
    final rows = [
      _ResultRow(
        key: const ValueKey('analysis-row-transactions'),
        kind: AnalysisMarkKind.sheet,
        title: '거래 ${formatKrwDigits(result.transactionCount)}건을 확인했어요',
      ),
      candidate,
      const _ResultRow(
        key: ValueKey('analysis-row-calculation'),
        kind: AnalysisMarkKind.calculation,
        title: '첫 계산이 준비되었어요',
      ),
    ];
    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, _) => Column(
        children: [
          for (final (i, row) in rows.indexed)
            Opacity(
              opacity: _rowShown(i),
              child: Transform.translate(
                offset: Offset(0, 14 * (1 - _rowShown(i))),
                child: row,
              ),
            ),
        ],
      ),
    );
  }
}

/// 2026-11-04: 기다리는 동안 그림 아래의 돌아가는 표시와 문구. 문구는 0.3초 겹쳐 바뀐다.
class _WaitLine extends StatelessWidget {
  /// 2026-11-04: 지금 문구 [text]와 바뀌는 시간 [fade]로 만든다.
  const _WaitLine({required this.text, required this.fade});

  final String text;
  final Duration fade;

  /// 2026-11-04: 가운데 정렬한 한 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: PayseColors.charcoal,
                backgroundColor: PayseColors.surfaceMuted,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: AnimatedSwitcher(
              duration: fade,
              child: Text(
                text,
                key: ValueKey(text),
                style: const TextStyle(
                  fontSize: 15,
                  height: 22 / 15,
                  fontWeight: FontWeight.w600,
                  color: PayseColors.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 2026-11-04: 분석 결과 한 줄(높이 64 이상). 체크 표시 없이 표시·문장·보조 설명·줄 끝 버튼 순서다.
class _ResultRow extends StatelessWidget {
  /// 2026-11-04: 표시 [kind], 문장 [title], 보조 설명 [detail](없으면 생략), 줄 끝 [trailing]으로 만든다.
  const _ResultRow({
    super.key,
    required this.kind,
    required this.title,
    this.detail,
    this.trailing,
  });

  final AnalysisMarkKind kind;
  final String title;
  final String? detail;
  final Widget? trailing;

  /// 2026-11-04: 결과 줄을 반환한다. 문장과 설명은 한 번에 읽히고 버튼은 따로 누를 수 있다.
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
      ),
      child: Row(
        children: [
          AnalysisMark(kind: kind),
          const SizedBox(width: PayseSpace.x3),
          Expanded(
            child: MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: PayseTypography.ledgerName.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (detail != null)
                    Text(detail!, style: PayseTypography.caption),
                ],
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
