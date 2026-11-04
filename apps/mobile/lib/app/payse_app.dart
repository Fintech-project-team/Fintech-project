import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/auth/auth_repository.dart';
import '../data/auth/credential_stores.dart';
import '../data/auth/fake_auth_repository.dart';
import '../data/auth/http_auth_repository.dart';
import '../data/auth/session_cleanup.dart';
import '../data/connection/fake_financial_server.dart';
import '../data/connection/financial_api.dart';
import '../data/connection/http_financial_repository.dart';
import '../data/connection/snapshot_assembly.dart';
import '../data/financial_snapshot_repository.dart';
import '../data/coachmark_record_store.dart';
import '../data/first_calc_record_store.dart';
import '../data/fixture_scenario.dart';
import '../data/http/api_config.dart';
import '../data/http/api_transport.dart';
import '../data/salary_notice_api.dart';
import '../data/snapshot_source.dart';
import '../features/auth/auth_flows.dart';
import '../features/auth/pin_change_flow.dart';
import '../features/auth/auth_screens.dart';
import '../features/auth/auth_services.dart';
import '../features/auth/auth_view_models.dart';
import '../features/connection/connection_presentation_policy.dart';
import '../features/my_info/my_info_screen.dart' show AppVersionReader;
import '../shared/design/font_licenses.dart';
import '../shared/design/payse_theme.dart';
import 'dev/dev_demo_accounts.dart';
import 'dev/dev_user_fixtures.dart';
import 'dev/fixture_debug_screen.dart';
import 'local_lock_controller.dart';
import 'main_entry.dart';

/// 2026-10-21: 앱 진입 단계(00-1 진입 판단). 세션·PIN 유무로 정하고 금융 상태는 담지 않는다.
/// 2026-11-01: [storageFailed]는 기기 보안 저장소를 읽거나 쓰지 못한 상태다(세션 없음으로 바꾸지 않음).
enum _EntryStage {
  checking,
  signedOut,
  needsPin,
  locked,
  active,
  storageFailed,
}

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
  /// 2026-10-28: [coachmarkRecords]는 02-1a 코치마크 기록 저장소다. 기본은 없음이며 코치마크를 띄우지 않는다.
  /// 2026-11-01: [server]는 실제 서버 연결(빌드 설정 주소·통신)이다. 있으면 빌드 모드와 무관하게 실제 인증·금융·급여 안내
  /// 저장소를 쓰고, 가짜 서버·개발용 실패 연출·개발 설정 진입점을 쓰지 않는다. 없으면 기존처럼 개발 빌드는 가짜, 릴리스는
  /// 서비스 불가다.
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
    this.coachmarkRecords,
    this.server,
    this.appVersion,
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
  final CoachmarkRecordStore? coachmarkRecords;
  final ({ApiConfig config, ApiTransport transport})? server;

  /// 2026-11-03: 설치된 앱 버전 읽기(앱 시작 지점이 넘김). 없으면 내 정보 탭에 버전 줄을 두지 않는다.
  final AppVersionReader? appVersion;

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
  late final FakeSalaryNoticeServer? _salaryNoticeServer =
      _defaultSalaryNoticeServer();
  late final FirstCalcRecordStore _firstCalcRecords =
      widget.firstCalcRecords ?? MemoryFirstCalcRecordStore();
  UserFinancialRepository _financial =
      const UnavailableUserFinancialRepository();
  SalaryNoticeApi _salaryNoticeApi = const UnavailableSalaryNoticeApi();
  int _financialSession = 0;
  String? _userName;
  late final ValueNotifier<bool> _failurePresentation = ValueNotifier(
    widget.server == null,
  );
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
  /// 2026-11-01: 실제 서버 연결이 있으면 빌드 모드와 무관하게 실제 서버 인증을 쓴다.
  AuthRepository _defaultAuthRepository() {
    final server = widget.server;
    if (server != null) {
      return HttpAuthRepository(
        config: server.config,
        transport: server.transport,
      );
    }
    if (kReleaseMode) {
      return const UnavailableAuthRepository();
    } else {
      return FakeAuthRepository(accounts: devDemoAccounts, now: _now);
    }
  }

  /// 2026-10-22: 기본 가짜 금융 서버를 반환한다. 릴리스 빌드는 실제 서버가 없으므로 null(서비스 불가),
  /// 개발 빌드는 인증 저장소가 세션을 판정할 수 있을 때 사용자별 원본 에셋을 읽는 가짜 서버를 만든다.
  /// 2026-11-01: 실제 서버 연결이 있으면 가짜 서버를 만들지 않는다.
  FakeFinancialServer? _defaultFinancialServer() {
    if (kReleaseMode || widget.server != null) {
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

  /// 2026-11-01: 개발 빌드의 가짜 급여 안내 서버를 반환한다. 실제 서버 연결이 있거나 릴리스면 null이다.
  FakeSalaryNoticeServer? _defaultSalaryNoticeServer() {
    if (kReleaseMode || widget.server != null) {
      return null;
    } else {
      final sessions = _authRepository;
      return sessions is SessionResolver
          ? FakeSalaryNoticeServer(
              sessions: sessions as SessionResolver,
              now: _now,
            )
          : null;
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
  /// 2026-11-01: 실제 서버 연결이 있으면 실제 서버 저장소를, 아니면 가짜 서버 저장소를 쓴다. 어느 쪽이든 거래 페이지를 끝까지
  /// 받아 합친 Snapshot만 화면에 넘긴다. 급여 안내 API도 같은 세션 토큰으로 새로 만든다.
  Future<void> _openFinancialSession() async {
    final stored = await _auth.sessionStore.read();
    final real = widget.server;
    final fake = _financialServer;
    final notices = _salaryNoticeServer;
    _financial.close();
    _userName = stored?.name;
    if (stored == null) {
      _financial = const UnavailableUserFinancialRepository();
      _salaryNoticeApi = const UnavailableSalaryNoticeApi();
    } else if (real != null) {
      _financial = AssembledFinancialRepository(
        HttpUserFinancialRepository(
          config: real.config,
          transport: real.transport,
          accessToken: stored.accessToken,
        ),
      );
      _salaryNoticeApi = HttpSalaryNoticeApi(
        config: real.config,
        transport: real.transport,
        accessToken: stored.accessToken,
      );
    } else {
      _financial = fake == null
          ? const UnavailableUserFinancialRepository()
          : AssembledFinancialRepository(
              FakeUserFinancialRepository(
                server: fake,
                accessToken: stored.accessToken,
              ),
            );
      _salaryNoticeApi = notices == null
          ? const UnavailableSalaryNoticeApi()
          : FakeSalaryNoticeApi(
              server: notices,
              accessToken: stored.accessToken,
            );
    }
    _financialSession++;
  }

  /// 2026-11-01: 금융 세션을 연다. 기기 저장소를 읽지 못하면 저장소 실패 화면으로 바꾸고 false를 반환한다.
  Future<bool> _openFinancialSessionOrFail() async {
    try {
      await _openFinancialSession();
      return true;
    } on Exception {
      if (mounted) setState(() => _stage = _EntryStage.storageFailed);
      return false;
    }
  }

  /// 2026-10-21: 저장된 세션·PIN 유무로 진입 단계를 정한다. 세션 없음 → 00-1, PIN 없음 → 10-4, 둘 다 있음 → 11-1.
  /// 2026-11-01: 기기 저장소를 읽지 못하면 세션 없음으로 보지 않고 저장소 실패 화면을 보인다.
  Future<void> _decideEntry() async {
    final StoredSession? session;
    final bool hasPin;
    try {
      session = await _auth.sessionStore.read();
      hasPin = await _auth.pinStore.hasPin();
    } on Exception {
      if (mounted) setState(() => _stage = _EntryStage.storageFailed);
      return;
    }
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
    if (!await _openFinancialSessionOrFail()) return;
    if (!mounted) return;
    setState(() {
      _stage = _EntryStage.active;
      _signInAgain = false;
    });
    _lock.enable();
  }

  /// 2026-10-21: 재실행 11-1 확인을 마쳤다. 스냅샷을 다시 조회하는 첫 화면으로 가고 잠금 판정을 켠다.
  Future<void> _onUnlockedAtLaunch() async {
    if (!await _openFinancialSessionOrFail()) return;
    if (!mounted) return;
    setState(() => _stage = _EntryStage.active);
    _lock.enable();
  }

  /// 2026-11-02: 내 정보의 로그아웃. 서버 세션 종료가 확인(성공 또는 이미 무효)된 뒤에만 기기의 세션·PIN을 지우고 첫 화면으로 간다.
  /// 종료 요청이 실패하면 토큰을 그대로 두고 안내 문구를 반환한다(api-contract §2). 약관 동의와 기기 인증서(mTLS) 키·인증서는 지우지 않는다.
  Future<String?> _logout() async {
    final StoredSession? stored;
    try {
      stored = await _auth.sessionStore.read();
    } on Exception {
      return storageReadFailedMessage;
    }
    if (stored != null) {
      final result = await _auth.repository.endSession(stored.accessToken);
      switch (result) {
        case AuthOk() || AuthSessionInvalid():
          break;
        case AuthNetworkFailure(:final error)
            when connectionProblemOf(error) ==
                ConnectionProblem.secureConnection:
          return secureConnectionMessage;
        default:
          return connectionFailedMessage;
      }
    }
    try {
      await _auth.sessionStore.clear();
      await _auth.pinStore.clear();
    } on Exception {
      return storageWriteFailedMessage;
    }
    if (!mounted) return null;
    _signOut(again: false);
    return null;
  }

  /// 2026-11-02: 저장 정보 읽기 실패 화면의 '이 기기의 로그인 정보 지우기'. 기기의 세션·PIN만 지우고 첫 화면으로 간다.
  /// 서버 세션은 끝내지 않으며(토큰을 읽을 수 없음) 우회하지도 않는다. 약관 동의와 기기 인증서(mTLS) 키·인증서는 지우지 않는다.
  /// 지우지 못하면 안내 문구를 반환한다.
  Future<String?> _clearDeviceLogin() async {
    try {
      await _auth.sessionStore.clear();
      await _auth.pinStore.clear();
    } on Exception {
      return storageWriteFailedMessage;
    }
    if (!mounted) return null;
    _signOut(again: false);
    return null;
  }

  /// 2026-10-21: 복구 중 저장된 세션이 이미 무효로 확인됐다(09-13). 기기 세션·PIN은 10-3에서 이미 지웠으므로
  /// 그 세션에서 위에 쌓아 둔 화면(예: 개발용 더미 확인 화면)을 모두 닫고, 잠금을 끄고,
  /// 10-2 식별 입력부터 신규 로그인 흐름을 연다. 금융 화면 상태는 함께 폐기된다.
  void _onSessionInvalid() => _signOut(again: true);

  /// 2026-11-02: 위에 쌓인 화면을 닫고 잠금·금융 세션을 끝낸 뒤 로그인 전 화면으로 간다. [again]이면 신규 로그인(10-2)부터,
  /// 아니면 첫 화면(00-1)부터다.
  void _signOut({required bool again}) {
    _rootNavigator.currentState?.popUntil((route) => route.isFirst);
    _lock.disable();
    _financial.close();
    _financial = const UnavailableUserFinancialRepository();
    _salaryNoticeApi = const UnavailableSalaryNoticeApi();
    _financialSession++;
    _userName = null;
    setState(() {
      _stage = _EntryStage.signedOut;
      _signInAgain = again;
    });
  }

  /// 2026-10-22: 금융 조회에서 세션 무효(401)를 받았다(09-13). 기기 세션·PIN을 지운 뒤 신규 로그인으로 보낸다.
  /// 2026-11-01: 기기 정보를 지우지 못하면 저장소 실패 화면으로 바꾼다(남은 토큰으로 계속 조회하지 않음).
  Future<void> _onFinancialSessionInvalid() async {
    try {
      await _auth.sessionStore.clear();
      await _auth.pinStore.clear();
    } on Exception {
      if (!mounted) return;
      _onSessionInvalid();
      setState(() => _stage = _EntryStage.storageFailed);
      return;
    }
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
      _EntryStage.storageFailed => _StorageFailed(
        onRetry: () {
          setState(() => _stage = _EntryStage.checking);
          _decideEntry();
        },
        onClear: _clearDeviceLogin,
      ),
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
        coachmarkRecords: widget.coachmarkRecords,
        salaryNoticeApi: _salaryNoticeApi,
        devEntryBuilder: _devEntryOrNull,
        onLogout: _logout,
        appVersion: widget.appVersion,
        onChangePin: (context) => openPinChange(
          context,
          services: _auth,
          onSessionInvalid: _onSessionInvalid,
        ),
        onSessionInvalid: _onFinancialSessionInvalid,
      ),
    };
  }

  /// 2026-10-20: 개발용 진입점을 반환한다. 컴파일 시점 상수 kReleaseMode로 갈라 두어 릴리스 빌드에서는
  /// null만 남고 개발용 확인 화면 코드가 트리 셰이킹으로 빠진다.
  /// 2026-11-01: 실제 서버 연결이 있으면 가짜 원본 미리보기·실패 연출 토글이 섞이지 않게 진입점을 두지 않는다.
  Widget? _devEntryOrNull(BuildContext context) {
    if (kReleaseMode || widget.server != null) {
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

/// 2026-11-01: 기기에 저장된 로그인 정보를 읽거나 지우지 못했다. 저장된 세션이 없는 것으로 바꾸지 않고 다시 시도를 준다.
/// 2026-11-02: 다시 시도해도 안 되는 경우를 위해 이 기기의 로그인 정보만 지우는 복구 경로를 둔다. 지우기 전에 서버 로그인 상태는
/// 유지되어 다시 로그인이 제한될 수 있음을 알린다(그때는 담당자의 세션 종료가 필요할 수 있음).
class _StorageFailed extends StatefulWidget {
  /// 2026-11-01: 다시 시도 [onRetry]로 만든다.
  /// 2026-11-02: [onClear]는 기기 로그인 정보 지우기(성공이면 null, 실패면 안내 문구)다.
  const _StorageFailed({required this.onRetry, required this.onClear});

  final VoidCallback onRetry;
  final Future<String?> Function() onClear;

  /// 2026-11-02: 지우는 중 상태를 갖는 객체를 반환한다.
  @override
  State<_StorageFailed> createState() => _StorageFailedState();
}

/// 2026-11-02: 지우기 확인 창과 지우는 중 상태를 다룬다.
class _StorageFailedState extends State<_StorageFailed> {
  bool _clearing = false;

  /// 2026-11-02: 확인 뒤 기기 로그인 정보를 지우고, 실패하면 안내를 보인다.
  Future<void> _clear() async {
    final confirmed = await confirmChoice(
      context,
      message: '이 기기에 저장된 로그인 정보만 지워져요. 서버의 로그인 상태는 유지되어 다시 로그인이 제한될 수 있어요.',
      cancelLabel: '취소',
      confirmLabel: '지우기',
      confirmKey: const ValueKey('storage-clear-confirm'),
    );
    if (!confirmed || !mounted) return;
    setState(() => _clearing = true);
    final failure = await widget.onClear();
    if (!mounted) return;
    setState(() => _clearing = false);
    if (failure != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure)));
    }
  }

  /// 2026-11-01: 안내 문장과 다시 시도 버튼을 반환한다.
  /// 2026-11-02: 이 기기의 로그인 정보 지우기 버튼을 더한다.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('storage-failed'),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '기기에 저장된 로그인 정보를 읽지 못했어요',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text('다시 시도해 주세요. 문제가 계속되면 이 기기의 로그인 정보를 지울 수 있어요.'),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: _clearing ? null : widget.onRetry,
                child: const Text('다시 시도'),
              ),
              const SizedBox(height: 12),
              TextButton(
                key: const ValueKey('storage-clear'),
                onPressed: _clearing ? null : _clear,
                child: const Text('이 기기의 로그인 정보 지우기'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
