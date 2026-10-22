import 'package:flutter/material.dart';

import '../data/financial_snapshot_repository.dart';
import '../data/fixture_scenario.dart';
import '../shared/design/payse_tokens.dart';
import '../shared/design/primary_button.dart';
import 'app_shell.dart';
import 'placeholder_screens.dart';

/// 2026-10-21: PIN 확인 뒤 들어오는 첫 화면. 스냅샷을 다시 조회해 금융사 미연결이면 연결 자리(#26),
/// 연결됨이면 하단 탭 홈을 보인다. 첫 가입 직후에는 [showConnectionFirst]로 연결 자리부터 보인다.
class MainEntry extends StatefulWidget {
  /// 2026-10-21: 현재 스냅샷 [scenario], Repository 생성 [repositoryFor], 첫 가입 여부 [showConnectionFirst],
  /// 개발 진입 위젯 생성 [devEntryBuilder](릴리스에서는 null 반환)로 만든다.
  const MainEntry({
    super.key,
    required this.scenario,
    required this.repositoryFor,
    required this.showConnectionFirst,
    required this.devEntryBuilder,
  });

  final FixtureScenario scenario;
  final FinancialSnapshotRepository Function(FixtureScenario) repositoryFor;
  final bool showConnectionFirst;
  final Widget? Function(BuildContext) devEntryBuilder;

  /// 2026-10-21: 조회 상태 객체를 반환한다.
  @override
  State<MainEntry> createState() => _MainEntryState();
}

/// 2026-10-21: 스냅샷 조회 결과와 연결 자리 통과 여부를 보관한다.
class _MainEntryState extends State<MainEntry> {
  late Future<SnapshotLoadResult> _result = _load();
  late bool _connectionPending = widget.showConnectionFirst;
  bool _connectionSkipped = false;

  /// 2026-10-21: 현재 스냅샷을 조회한다.
  Future<SnapshotLoadResult> _load() =>
      widget.repositoryFor(widget.scenario).loadSnapshot();

  /// 2026-10-21: 스냅샷 선택이 바뀌면 다시 조회한다.
  @override
  void didUpdateWidget(covariant MainEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scenario != widget.scenario) {
      _result = _load();
      _connectionPending = false;
      _connectionSkipped = false;
    }
  }

  /// 2026-10-21: 조회 중·실패·미연결·연결됨에 맞는 화면을 반환한다. 실패를 빈 자료로 바꾸지 않는다.
  @override
  Widget build(BuildContext context) {
    if (_connectionPending) {
      return ConnectionPlaceholderScreen(
        onContinue: () => setState(() {
          _connectionPending = false;
          _connectionSkipped = true;
        }),
      );
    }
    return FutureBuilder<SnapshotLoadResult>(
      future: _result,
      builder: (context, snapshot) {
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
          SnapshotLoadFailed() || SnapshotFormatInvalid() => _LoadError(
            onRetry: () => setState(() => _result = _load()),
          ),
        };
      },
    );
  }
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
