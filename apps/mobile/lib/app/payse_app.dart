import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/auth/auth_repository.dart';
import '../data/auth/credential_stores.dart';
import '../data/auth/fake_auth_repository.dart';
import '../data/auth/session_cleanup.dart';
import '../data/financial_snapshot_repository.dart';
import '../data/fixture_scenario.dart';
import '../data/snapshot_source.dart';
import '../features/auth/auth_flows.dart';
import '../features/auth/auth_services.dart';
import '../shared/design/font_licenses.dart';
import '../shared/design/payse_theme.dart';
import 'dev/dev_demo_accounts.dart';
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
  });

  final SnapshotSource? snapshotSource;
  final bool enableDevTools;
  final AuthRepository? authRepository;
  final SessionStore? sessionStore;
  final LocalPinStore? pinStore;
  final ConsentStore? consentStore;
  final DateTime Function()? now;
  final Duration lockTimeout;

  /// 2026-10-20: 앱 루트 상태 객체를 반환한다. 인자 없음.
  @override
  State<PayseApp> createState() => _PayseAppState();
}

/// 2026-10-20: 앱 수명 동안 필요한 등록과 Repository 생성, 개발용 스냅샷 선택을 맡는다.
/// 2026-10-21: 인증 의존성 생성, 진입 판단, 10분 무입력·백그라운드 복귀 잠금도 맡는다.
/// 2026-10-22: 인증 의존성에서 설치 식별값 생성을 제거했다.
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
  late final LocalLockController _lock = LocalLockController(
    now: _now,
    timeout: widget.lockTimeout,
  );
  FixtureScenario _scenario = FixtureScenario.defaultScenario;
  _EntryStage _stage = _EntryStage.checking;
  bool _freshSignup = false;
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

  /// 2026-10-21: 가입·PIN 설정을 마쳤다. 금융사 연결 자리부터 보이고 잠금 판정을 켠다.
  void _onSignedUp() {
    setState(() {
      _stage = _EntryStage.active;
      _freshSignup = true;
      _signInAgain = false;
    });
    _lock.enable();
  }

  /// 2026-10-21: 재실행 11-1 확인을 마쳤다. 스냅샷을 다시 조회하는 첫 화면으로 가고 잠금 판정을 켠다.
  void _onUnlockedAtLaunch() {
    setState(() {
      _stage = _EntryStage.active;
      _freshSignup = false;
    });
    _lock.enable();
  }

  /// 2026-10-21: 복구 중 저장된 세션이 이미 무효로 확인됐다(09-13). 기기 세션·PIN은 10-3에서 이미 지웠으므로
  /// 그 세션에서 위에 쌓아 둔 화면(예: 개발용 더미 확인 화면)을 모두 닫고, 잠금을 끄고,
  /// 10-2 식별 입력부터 신규 로그인 흐름을 연다. 금융 화면 상태는 함께 폐기된다.
  void _onSessionInvalid() {
    _rootNavigator.currentState?.popUntil((route) => route.isFirst);
    _lock.disable();
    setState(() {
      _stage = _EntryStage.signedOut;
      _signInAgain = true;
      _freshSignup = false;
    });
  }

  /// 2026-10-20: [scenario] 스냅샷을 읽는 Repository를 만든다. 화면은 이 계약만 사용한다.
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
        scenario: _scenario,
        repositoryFor: _repositoryFor,
        showConnectionFirst: _freshSignup,
        devEntryBuilder: _devEntryOrNull,
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
  Widget _devEntry(BuildContext context) {
    return Column(
      key: const ValueKey('dev-entry'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FixtureDebugScreen(
                initial: _scenario,
                repositoryFor: _repositoryFor,
                onScenarioChanged: (s) => setState(() => _scenario = s),
              ),
            ),
          ),
          child: const Text('개발용: 더미 스냅샷 확인'),
        ),
      ],
    );
  }
}
