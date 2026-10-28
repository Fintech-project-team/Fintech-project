import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/auth/auth_repository.dart';
import '../data/auth/credential_stores.dart';
import '../data/auth/fake_auth_repository.dart';
import '../data/auth/session_cleanup.dart';
import '../data/connection/fake_financial_server.dart';
import '../data/connection/financial_api.dart';
import '../data/financial_snapshot_repository.dart';
import '../data/first_calc_record_store.dart';
import '../data/fixture_scenario.dart';
import '../data/snapshot_source.dart';
import '../features/auth/auth_flows.dart';
import '../features/auth/auth_services.dart';
import '../features/connection/connection_presentation_policy.dart';
import '../shared/design/font_licenses.dart';
import '../shared/design/payse_theme.dart';
import 'dev/dev_demo_accounts.dart';
import 'dev/dev_user_fixtures.dart';
import 'dev/fixture_debug_screen.dart';
import 'local_lock_controller.dart';
import 'main_entry.dart';

/// 2026-10-21: 앱 진입 단계(00-1 진입 판단). 세션·PIN 유무로 정하고 금융 상태는 담지 않는다.
enum _EntryStage { checking, signedOut, needsPin, locked, active }

/// 2026-10-19: key로 위젯을 식별하는 PAYSE 루트. 금융 상태를 전역에 보관하지 않는다.
class PayseApp extends StatefulWidget {
  /// 2026-10-19: 선택적 key를 전달받아 앱 루트 인스턴스를 초기화한다.
  /// 2026-10-20: [snapshotSource]는 더미 원문 출처(기본 앱 에셋), [enableDevTools]는 개발 빌드에서 진입점을 끌 때 쓴다.
  /// 릴리스 빌드에서는 [enableDevTools] 값과 무관하게 개발용 진입점이 없다(컴파일 시점 상수 kReleaseMode로 제거).
  /// 2026-10-21: [authRepository]·[sessionStore]·[pinStore]·[consentStore]는 인증 경계(기본은 메모리 가짜 구현),
  /// [now]는 잠금·타이머 시각, [lockTimeout]은 무입력 잠금 시간이다. 테스트에서 바꿔 끼운다.
  /// 2026-10-22: [userFixtures]는 사용자별 금융 원본 대응이다.
  /// 2026-10-23: [presentationPolicy]는 실패 연출 사용 여부(개발 설정 토글의 현재 값)를 받아 연결 표시 정책을
  /// 만든다. 생략하면 실제 난수·시간을 쓴다(테스트에서 바꿔 끼움).
  /// 2026-10-27: [firstCalcRecords]는 01-3 첫 계산 기록 저장소다(기본은 앱 실행 동안 유지되는 메모리 구현).
  const PayseApp({
    super.key,
    this.snapshotSource,
    this.enableDevTools = true,
    this.authRepository,
    this.sessionStore,
    this.pinStore,
    this.consentStore,
    this.now,
    this.lockTimeout = const Duration(minutes: 10),
    this.userFixtures,
    this.presentationPolicy,
    this.firstCalcRecords,
  });

  final SnapshotSource? snapshotSource;
  final bool enableDevTools;
  final AuthRepository? authRepository;
  final SessionStore? sessionStore;
  final LocalPinStore? pinStore;
  final ConsentStore? consentStore;
  final DateTime Function()? now;
  final Duration lockTimeout;

  /// 2026-10-22: 사용자 ID → 불변 금융 원본. 생략하면 개발 데모 계정 원본을 쓴다(테스트에서 바꿔 끼움).
  final Map<String, FixtureScenario>? userFixtures;

  final ConnectionPresentationPolicy Function(bool Function() failuresEnabled)?
  presentationPolicy;

  final FirstCalcRecordStore? firstCalcRecords;

  /// 2026-10-20: 앱 루트 상태 객체를 반환한다. 인자 없음.
  @override
  State<PayseApp> createState() => _PayseAppState();
}

/// 2026-10-20: 앱 수명 동안 필요한 등록과 Repository 생성, 개발용 스냅샷 선택을 맡는다.
/// 2026-10-21: 인증 의존성 생성, 진입 판단, 10분 무입력·백그라운드 복귀 잠금도 맡는다.
/// 2026-10-23: 개발용 스냅샷은 미리보기로만 두고, 실패 연출 토글을 앱 프로세스 동안 보관한다(세션이 바뀌어도 유지).
class _PayseAppState extends State<PayseApp> with WidgetsBindingObserver {
  late final SnapshotSource _source =
      widget.snapshotSource ?? AssetSnapshotSource(rootBundle);
  late final DateTime Function() _now = widget.now ?? DateTime.now;
  late final AuthRepository _authRepository =
      widget.authRepository ?? _defaultAuthRepository();
  late final AuthServices _auth = AuthServices(
    repository: _authRepository,
    cleanup: PendingSessionCleanup(_authRepository),
    sessionStore: widget.sessionStore ?? MemorySessionStore(),
    pinStore: widget.pinStore ?? MemoryLocalPinStore(),
    consentStore: widget.consentStore ?? MemoryConsentStore(),
    now: _now,
  );
  late final FakeFinancialServer? _financialServer = _defaultFinancialServer();
  late final FirstCalcRecordStore _firstCalcRecords =
      widget.firstCalcRecords ?? MemoryFirstCalcRecordStore();
  UserFinancialRepository _financial =
      const UnavailableUserFinancialRepository();
  int _financialSession = 0;
  String? _userName;
  final ValueNotifier<bool> _failurePresentation = ValueNotifier(true);
  late final ConnectionPresentationPolicy _presentation = _presentationPolicy();
  late final LocalLockController _lock = LocalLockController(
    now: _now,
    timeout: widget.lockTimeout,
  );
  _EntryStage _stage = _EntryStage.checking;
  bool _signInAgain = false;
  final GlobalKey<NavigatorState> _rootNavigator = GlobalKey<NavigatorState>();

  /// 2026-10-20: 글꼴 라이선스를 라이선스 목록에 등록한다. 반환값 없음(중복 등록 없음).
  /// 2026-10-21: 앱 수명 감시를 시작하고 진입 단계를 정한다.
  @override
  void initState() {
    super.initState();
    registerPayseFontLicenses();
    WidgetsBinding.instance.addObserver(this);
    _decideEntry();
  }

  /// 2026-10-21: 수명 감시를 해제하고 잠금 컨트롤러를 폐기한다.
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lock.dispose();
    _failurePresentation.dispose();
    super.dispose();
  }

  /// 2026-10-21: 백그라운드로 가면 잠금 타이머를 멈추고, 돌아오면 경과 시간을 다시 판정한다.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _lock.onBackground();
      case AppLifecycleState.resumed:
        _lock.onForeground();
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// 2026-10-21: 기본 인증 저장소를 반환한다. 릴리스 빌드는 실제 서버가 없으므로 서비스 불가 구현,
  /// 개발 빌드는 개발용 데모 계정을 쓰는 가짜 구현이다(kReleaseMode로 갈라 개발 계정이 릴리스에서 빠진다).
  AuthRepository _defaultAuthRepository() {
    if (kReleaseMode) {
      return const UnavailableAuthRepository();
    } else {
      return FakeAuthRepository(accounts: devDemoAccounts, now: _now);
    }
  }

  /// 2026-10-22: 기본 가짜 금융 서버를 반환한다. 릴리스 빌드는 실제 서버가 없으므로 null(서비스 불가),
  /// 개발 빌드는 인증 저장소가 세션을 판정할 수 있을 때 사용자별 원본 에셋을 읽는 가짜 서버를 만든다.
  FakeFinancialServer? _defaultFinancialServer() {
    if (kReleaseMode) {
      return null;
    } else {
      final sessions = _authRepository;
      if (sessions is! SessionResolver) return null;
      final fixtures = widget.userFixtures ?? devUserFixtures;
      return FakeFinancialServer(
        sessions: sessions as SessionResolver,
        now: _now,
        loadSource: (userId) async {
          final scenario = fixtures[userId];
          if (scenario == null) throw StateError('원본이 없는 사용자');
          final raw = await _source.load(scenario);
          return (jsonDecode(raw) as Map).cast<String, Object?>();
        },
      );
    }
  }

  /// 2026-10-23: 연결 표시 정책을 만든다. 실패 연출 사용 여부는 개발 설정 토글의 현재 값을 추첨 때마다 읽는다.
  ConnectionPresentationPolicy _presentationPolicy() {
    bool enabled() => _failurePresentation.value;
    return widget.presentationPolicy?.call(enabled) ??
        ConnectionPresentationPolicy(failuresEnabled: enabled);
  }

  /// 2026-10-22: 저장된 세션으로 이번 세션의 금융 저장소를 새로 만든다. 이전 세션 저장소는 닫아 늦은 응답을 버린다
  /// (서버 장부는 남음).
  Future<void> _openFinancialSession() async {
    final stored = await _auth.sessionStore.read();
    final server = _financialServer;
    _financial.close();
    _userName = stored?.name;
    _financial = stored == null || server == null
        ? const UnavailableUserFinancialRepository()
        : FakeUserFinancialRepository(
            server: server,
            accessToken: stored.accessToken,
          );
    _financialSession++;
  }

  /// 2026-10-21: 저장된 세션·PIN 유무로 진입 단계를 정한다. 세션 없음 → 00-1, PIN 없음 → 10-4, 둘 다 있음 → 11-1.
  Future<void> _decideEntry() async {
    final session = await _auth.sessionStore.read();
    final hasPin = await _auth.pinStore.hasPin();
    if (!mounted) return;
    setState(() {
      _stage = session == null
          ? _EntryStage.signedOut
          : hasPin
          ? _EntryStage.locked
          : _EntryStage.needsPin;
    });
  }

  /// 2026-10-21: 가입·PIN 설정을 마쳤다. 잠금 판정을 켠다.
  /// 2026-10-22: 이번 세션의 금융 저장소를 열고, 첫 화면은 사용자 저장 상태(연결 전이면 연결 자리)를 따른다.
  Future<void> _onSignedUp() async {
    await _openFinancialSession();
    if (!mounted) return;
    setState(() {
      _stage = _EntryStage.active;
      _signInAgain = false;
    });
    _lock.enable();
  }

  /// 2026-10-21: 재실행 11-1 확인을 마쳤다. 스냅샷을 다시 조회하는 첫 화면으로 가고 잠금 판정을 켠다.
  Future<void> _onUnlockedAtLaunch() async {
    await _openFinancialSession();
    if (!mounted) return;
    setState(() => _stage = _EntryStage.active);
    _lock.enable();
  }

  /// 2026-10-21: 복구 중 저장된 세션이 이미 무효로 확인됐다(09-13). 기기 세션·PIN은 10-3에서 이미 지웠으므로
  /// 그 세션에서 위에 쌓아 둔 화면(예: 개발용 더미 확인 화면)을 모두 닫고, 잠금을 끄고,
  /// 10-2 식별 입력부터 신규 로그인 흐름을 연다. 금융 화면 상태는 함께 폐기된다.
  void _onSessionInvalid() {
    _rootNavigator.currentState?.popUntil((route) => route.isFirst);
    _lock.disable();
    _financial.close();
    _financial = const UnavailableUserFinancialRepository();
    _financialSession++;
    _userName = null;
    setState(() {
      _stage = _EntryStage.signedOut;
      _signInAgain = true;
    });
  }

  /// 2026-10-22: 금융 조회에서 세션 무효(401)를 받았다(09-13). 기기 세션·PIN을 지운 뒤 신규 로그인으로 보낸다.
  Future<void> _onFinancialSessionInvalid() async {
    await _auth.sessionStore.clear();
    await _auth.pinStore.clear();
    if (!mounted) return;
    _onSessionInvalid();
  }

  /// 2026-10-20: [scenario] 스냅샷을 읽는 Repository를 만든다. 화면은 이 계약만 사용한다.
  /// 2026-10-23: 개발 설정의 읽기 전용 미리보기에만 쓰며 첫 화면 판단·저장에는 쓰지 않는다.
  FinancialSnapshotRepository _repositoryFor(FixtureScenario scenario) =>
      FakeFinancialSnapshotRepository(source: _source, scenario: scenario);

  /// 2026-10-19: context의 위젯 트리에 앱 시작 화면을 반환한다.
  /// 2026-10-21: 진입 단계별 화면과, 잠금 중이면 아래 화면 상태를 보존한 채 가린 11-1 잠금을 반환한다.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PAYSE',
      navigatorKey: _rootNavigator,
      debugShowCheckedModeBanner: false,
      theme: buildPayseTheme(),
      themeMode: ThemeMode.light,
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _lock.recordActivity(),
        child: ListenableBuilder(
          listenable: _lock,
          builder: (context, _) => Stack(
            children: [
              Offstage(
                offstage: _lock.locked,
                child: TickerMode(enabled: !_lock.locked, child: child!),
              ),
              if (_lock.locked)
                UnlockFlow(
                  key: const ValueKey('lock-overlay'),
                  services: _auth,
                  onUnlocked: _lock.unlock,
                  onSessionInvalid: _onSessionInvalid,
                ),
            ],
          ),
        ),
      ),
      home: _home(),
    );
  }

  /// 2026-10-21: 진입 단계에 맞는 첫 화면을 반환한다.
  Widget _home() {
    return switch (_stage) {
      _EntryStage.checking => const Scaffold(),
      _EntryStage.signedOut => SignupFlow(
        key: ValueKey(_signInAgain ? 'signup-flow-again' : 'signup-flow'),
        services: _auth,
        onCompleted: _onSignedUp,
        startAtIdentity: _signInAgain,
      ),
      _EntryStage.needsPin => SignupFlow(
        key: const ValueKey('signup-flow-pin'),
        services: _auth,
        onCompleted: _onSignedUp,
        startAtPin: true,
      ),
      _EntryStage.locked => UnlockFlow(
        key: const ValueKey('launch-unlock'),
        services: _auth,
        onUnlocked: _onUnlockedAtLaunch,
        onSessionInvalid: _onSessionInvalid,
      ),
      _EntryStage.active => MainEntry(
        financial: _financial,
        policy: _presentation,
        reloadKey: _financialSession,
        userName: _userName,
        firstCalcRecords: _firstCalcRecords,
        devEntryBuilder: _devEntryOrNull,
        onSessionInvalid: _onFinancialSessionInvalid,
      ),
    };
  }

  /// 2026-10-20: 개발용 진입점을 반환한다. 컴파일 시점 상수 kReleaseMode로 갈라 두어 릴리스 빌드에서는
  /// null만 남고 개발용 확인 화면 코드가 트리 셰이킹으로 빠진다.
  Widget? _devEntryOrNull(BuildContext context) {
    if (kReleaseMode) {
      return null;
    } else {
      return widget.enableDevTools ? _devEntry(context) : null;
    }
  }

  /// 2026-10-20: 개발 환경 전용 진입 버튼을 반환한다. 릴리스 빌드에서는 호출되지 않는다.
  /// 2026-10-23: 홈과 연결 흐름(12-1·01-1)에서 같은 개발 설정을 연다.
  Widget _devEntry(BuildContext context) {
    return Column(
      key: const ValueKey('dev-entry'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FixtureDebugScreen(
                repositoryFor: _repositoryFor,
                failurePresentation: _failurePresentation,
              ),
            ),
          ),
          child: const Text('개발 설정'),
        ),
      ],
    );
  }
}
