import 'package:flutter/material.dart';

import '../data/connection/financial_api.dart';
import '../data/connection/user_snapshot_repository.dart';
import '../data/financial_snapshot.dart';
import '../data/financial_snapshot_repository.dart';
import '../features/connection/connection_flow.dart';
import '../features/connection/connection_illustration.dart';
import '../features/connection/connection_page.dart';
import '../features/connection/connection_presentation_policy.dart';
import '../shared/design/payse_tokens.dart';
import '../shared/design/primary_button.dart';
import 'app_shell.dart';

/// 2026-10-21: PIN 확인 뒤 들어오는 첫 화면. 스냅샷을 다시 조회해 금융사 미연결이면 연결 자리(#26),
/// 연결됨이면 하단 탭 홈을 보인다.
/// 2026-10-22: 스냅샷은 로그인한 사용자의 저장 상태를 따른다(첫 가입 여부로 고정하지 않음).
/// 2026-10-23: 연결 자리 대신 금융사 연결 흐름(12-1~01-2)을 띄운다. 진입 판단·흐름 저장·완료 후 재조회는
/// 모두 같은 세션 저장소를 쓴다.
class MainEntry extends StatefulWidget {
  /// 2026-10-21: 개발 진입 위젯 생성 [devEntryBuilder](릴리스에서는 null 반환)로 만든다.
  /// 2026-10-22: 바뀌면 다시 조회할 [reloadKey], 세션 무효 콜백 [onSessionInvalid]를 받는다.
  /// 2026-10-23: 세션 금융 저장소 [financial]과 연결 표시 정책 [policy], 진입 로딩 제목의 사용자 이름 [userName]을 받는다.
  const MainEntry({
    super.key,
    required this.financial,
    required this.policy,
    required this.reloadKey,
    required this.devEntryBuilder,
    required this.onSessionInvalid,
    this.userName,
  });

  final UserFinancialRepository financial;
  final ConnectionPresentationPolicy policy;
  final Object reloadKey;
  final Widget? Function(BuildContext) devEntryBuilder;
  final VoidCallback onSessionInvalid;
  final String? userName;

  /// 2026-10-21: 조회 상태 객체를 반환한다.
  @override
  State<MainEntry> createState() => _MainEntryState();
}

/// 2026-10-23: 조회에 성공한 Snapshot으로 정한 첫 화면. [unreadable]은 연결됐는데 계좌 묶음이 없는 응답이다.
enum EntryDestination { connect, chooseAccounts, home, unreadable }

/// 2026-10-23: [snapshot]의 첫 화면을 반환한다. 연결 기관 0곳 → 12-1, 연결 기관이 있고 포함 계좌 0개 → 01-1,
/// 포함 계좌가 있으면 홈이다. 계좌 묶음 누락은 0개로 보지 않고 [EntryDestination.unreadable]로 돌려준다.
EntryDestination entryDestination(FinancialSnapshot snapshot) {
  if (snapshot.institutionLinkCount == 0) return EntryDestination.connect;
  final accounts = snapshot.accounts;
  if (accounts == null) return EntryDestination.unreadable;
  return accounts.any((a) => a.included)
      ? EntryDestination.home
      : EntryDestination.chooseAccounts;
}

/// 2026-10-21: 스냅샷 조회 결과를 보관한다.
/// 2026-10-23: 조회할 때마다 연결 흐름을 새로 만들어 이전 흐름의 상태·늦은 응답을 버린다.
class _MainEntryState extends State<MainEntry> {
  late Future<SnapshotLoadResult> _result = _load();
  int _loads = 0;

  /// 2026-10-21: 현재 스냅샷을 조회한다.
  /// 2026-10-22: 예상하지 못한 예외는 Flutter 오류로 보고한 뒤 다시 던져 다시 시도 화면을 보인다.
  /// 2026-10-23: 세션 저장소에서 읽는다. 개발용 미리보기 스냅샷은 쓰지 않는다.
  Future<SnapshotLoadResult> _load() async {
    _loads++;
    try {
      return await UserSnapshotRepository(widget.financial).loadSnapshot();
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
    if (oldWidget.reloadKey != widget.reloadKey) _result = _load();
  }

  /// 2026-10-23: 다시 조회한다. 다시 시도와 01-2 확인 뒤 재조회에 쓴다.
  void _reload() {
    setState(() {
      _result = _load();
    });
  }

  /// 2026-10-21: 조회 중·실패·미연결·연결됨에 맞는 화면을 반환한다. 실패를 빈 자료로 바꾸지 않는다.
  /// 2026-10-22: 조회가 예외로 끝나도 계속 로딩하지 않고 다시 시도 화면을 보인다.
  /// 2026-10-23: 성공한 Snapshot만 [entryDestination]으로 나눈다. 01-2 확인 뒤에는 응답 Snapshot을 쓰지 않고
  /// 다시 조회해 판단하며, 재조회가 실패하면 홈 대신 다시 시도 화면을 보인다. 다시 조회하는 동안에는 이전 결과
  /// (이전 세션 Snapshot 포함)로 화면을 만들지 않고 로딩을 보인다.
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SnapshotLoadResult>(
      future: _result,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) return _LoadError(onRetry: _reload);
        return switch (snapshot.requireData) {
          SnapshotLoaded(:final snapshot) => switch (entryDestination(
            snapshot,
          )) {
            EntryDestination.home => Builder(
              builder: (context) => AppShell(
                snapshot: snapshot,
                onReload: _reload,
                devEntry: widget.devEntryBuilder(context),
              ),
            ),
            EntryDestination.connect ||
            EntryDestination.chooseAccounts => Builder(
              builder: (context) => ConnectionFlow(
                key: ValueKey(('connection-flow', _loads)),
                repository: widget.financial,
                snapshot: snapshot,
                policy: widget.policy,
                onFinished: _reload,
                onSessionInvalid: widget.onSessionInvalid,
                devEntry: widget.devEntryBuilder(context),
                userName: widget.userName,
              ),
            ),
            EntryDestination.unreadable => _LoadError(onRetry: _reload),
          },
          SnapshotLoadFailed(:final error)
              when error is FinancialLoadError && error.sessionInvalid =>
            _SessionEnded(onContinue: widget.onSessionInvalid),
          SnapshotLoadFailed(:final error) => _LoadError(
            onRetry: _reload,
            offline:
                error is FinancialLoadError &&
                error.outcome is FinancialNetworkFailure,
          ),
          SnapshotFormatInvalid() => _LoadError(onRetry: _reload),
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
/// 2026-10-23: 시안 C·D. 인터넷 연결 실패([offline])와 그 밖의 실패·형식 오류를 나눠 할 수 있는 일을 안내하고,
/// 고른 금융사나 저장된 정보가 바뀌지 않았음을 알린다.
class _LoadError extends StatelessWidget {
  /// 2026-10-21: 다시 시도 [onRetry]로 만든다.
  /// 2026-10-23: 인터넷 연결 실패면 [offline]이 true다.
  const _LoadError({required this.onRetry, this.offline = false});

  final VoidCallback onRetry;
  final bool offline;

  /// 2026-10-21: 실패 안내와 다시 시도 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ConnectionPage(
      key: ValueKey(offline ? 'load-error-offline' : 'load-error-unavailable'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConnectionHeading(
            offline ? '금융사 목록을\n불러오지 못했어요' : '지금은 금융사 정보를\n받을 수 없어요',
            subtitle: offline ? '인터넷 연결을 확인한 뒤 다시 시도해주세요.' : '잠시 후 다시 시도해주세요.',
          ),
          Expanded(
            child: Center(
              child: ConnectionIllustration(
                state: offline
                    ? ConnectionIllustrationState.offline
                    : ConnectionIllustrationState.unavailable,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              0,
              PayseSpace.screenHorizontal,
              PayseSpace.x6,
            ),
            child: Text(
              offline
                  ? '고른 금융사나 저장된 정보는 바뀌지 않았어요.'
                  : '고른 금융사나 저장된 정보는 바뀌지 않았어요. 계속 안 되면 앱을 닫았다가 다시 열어주세요.',
              style: const TextStyle(
                fontSize: 13,
                height: 19 / 13,
                color: PayseColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
      bottom: PrimaryButton(label: '다시 시도', onPressed: onRetry),
    );
  }
}
