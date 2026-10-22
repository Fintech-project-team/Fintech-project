import 'package:flutter/material.dart';

import '../data/connection/user_snapshot_repository.dart';
import '../data/financial_snapshot_repository.dart';
import '../shared/design/payse_tokens.dart';
import '../shared/design/primary_button.dart';
import 'app_shell.dart';
import 'placeholder_screens.dart';

/// 2026-10-21: PIN 확인 뒤 들어오는 첫 화면. 스냅샷을 다시 조회해 금융사 미연결이면 연결 자리(#26),
/// 연결됨이면 하단 탭 홈을 보인다.
/// 2026-10-22: 스냅샷은 로그인한 사용자의 저장 상태를 따른다(첫 가입 여부로 고정하지 않음).
class MainEntry extends StatefulWidget {
  /// 2026-10-21: 개발 진입 위젯 생성 [devEntryBuilder](릴리스에서는 null 반환)로 만든다.
  /// 2026-10-22: 스냅샷 조회 [repository], 바뀌면 다시 조회할 [reloadKey], 세션 무효 콜백 [onSessionInvalid]를 받는다.
  const MainEntry({
    super.key,
    required this.repository,
    required this.reloadKey,
    required this.devEntryBuilder,
    required this.onSessionInvalid,
  });

  final FinancialSnapshotRepository repository;
  final Object reloadKey;
  final Widget? Function(BuildContext) devEntryBuilder;
  final VoidCallback onSessionInvalid;

  /// 2026-10-21: 조회 상태 객체를 반환한다.
  @override
  State<MainEntry> createState() => _MainEntryState();
}

/// 2026-10-21: 스냅샷 조회 결과와 연결 자리 통과 여부를 보관한다.
/// 2026-10-22: 연결 자리의 '홈으로 가기'는 화면 이동만 기록하며 연결·계좌 선택·버전을 바꾸지 않는다.
class _MainEntryState extends State<MainEntry> {
  late Future<SnapshotLoadResult> _result = _load();
  bool _connectionSkipped = false;

  /// 2026-10-21: 현재 스냅샷을 조회한다.
  /// 2026-10-22: 예상하지 못한 예외는 Flutter 오류로 보고한 뒤 다시 던져 다시 시도 화면을 보인다.
  Future<SnapshotLoadResult> _load() async {
    try {
      return await widget.repository.loadSnapshot();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack, library: 'payse'),
      );
      rethrow;
    }
  }

  /// 2026-10-21: 스냅샷 출처가 바뀌면 다시 조회한다.
  @override
  void didUpdateWidget(covariant MainEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadKey != widget.reloadKey) {
      _result = _load();
      _connectionSkipped = false;
    }
  }

  /// 2026-10-21: 조회 중·실패·미연결·연결됨에 맞는 화면을 반환한다. 실패를 빈 자료로 바꾸지 않는다.
  /// 2026-10-22: 조회가 예외로 끝나도 계속 로딩하지 않고 다시 시도 화면을 보인다.
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SnapshotLoadResult>(
      future: _result,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _LoadError(onRetry: () => setState(() => _result = _load()));
        }
        final result = snapshot.data;
        if (result == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return switch (result) {
          SnapshotLoaded(:final snapshot)
              when snapshot.institutionLinkCount == 0 && !_connectionSkipped =>
            ConnectionPlaceholderScreen(
              onContinue: () => setState(() => _connectionSkipped = true),
            ),
          SnapshotLoaded() => Builder(
            builder: (context) =>
                AppShell(devEntry: widget.devEntryBuilder(context)),
          ),
          SnapshotLoadFailed(:final error)
              when error is FinancialLoadError && error.sessionInvalid =>
            _SessionEnded(onContinue: widget.onSessionInvalid),
          SnapshotLoadFailed() || SnapshotFormatInvalid() => _LoadError(
            onRetry: () => setState(() => _result = _load()),
          ),
        };
      },
    );
  }
}

/// 2026-10-22: 금융 조회에서 세션 무효(401)를 받았다. 로컬 PIN으로 우회하지 않고 신규 로그인으로 보낸다.
class _SessionEnded extends StatefulWidget {
  /// 2026-10-22: 신규 로그인으로 넘기는 [onContinue]로 만든다.
  const _SessionEnded({required this.onContinue});

  final VoidCallback onContinue;

  /// 2026-10-22: 화면이 그려진 뒤 한 번만 넘기는 상태 객체를 반환한다.
  @override
  State<_SessionEnded> createState() => _SessionEndedState();
}

/// 2026-10-22: 첫 프레임 뒤 [_SessionEnded.onContinue]를 한 번 부른다.
class _SessionEndedState extends State<_SessionEnded> {
  /// 2026-10-22: 빌드 중 상위 상태를 바꾸지 않도록 다음 프레임에 넘긴다.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onContinue();
    });
  }

  /// 2026-10-22: 넘어가기 전 빈 화면을 반환한다.
  @override
  Widget build(BuildContext context) => const Scaffold();
}

/// 2026-10-21: 금융 원본 조회 실패(09-3). 0원·빈 목록으로 대체하지 않고 다시 시도를 준다.
class _LoadError extends StatelessWidget {
  /// 2026-10-21: 다시 시도 [onRetry]로 만든다.
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  /// 2026-10-21: 실패 안내와 다시 시도 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Expanded(
              child: Padding(
                padding: EdgeInsets.all(PayseSpace.screenHorizontal),
                child: Text('금융 정보를 불러오지 못했어요.'),
              ),
            ),
            PrimaryButton(label: '다시 시도', onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
