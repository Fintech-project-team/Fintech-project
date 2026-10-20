import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/financial_snapshot_repository.dart';
import '../data/fixture_scenario.dart';
import '../data/snapshot_source.dart';
import '../shared/design/font_licenses.dart';
import '../shared/design/payse_theme.dart';
import 'app_shell.dart';
import 'dev/fixture_debug_screen.dart';
import 'placeholder_screens.dart';

/// 2026-10-19: key로 위젯을 식별하는 PAYSE 루트. 금융 상태를 전역에 보관하지 않는다.
class PayseApp extends StatefulWidget {
  /// 2026-10-19: 선택적 key를 전달받아 앱 루트 인스턴스를 초기화한다.
  /// 2026-10-20: [snapshotSource]는 더미 원문 출처(기본 앱 에셋), [enableDevTools]는 개발 빌드에서 진입점을 끌 때 쓴다.
  /// 릴리스 빌드에서는 [enableDevTools] 값과 무관하게 개발용 진입점이 없다(컴파일 시점 상수 kReleaseMode로 제거).
  const PayseApp({super.key, this.snapshotSource, this.enableDevTools = true});

  final SnapshotSource? snapshotSource;
  final bool enableDevTools;

  /// 2026-10-20: 앱 루트 상태 객체를 반환한다. 인자 없음.
  @override
  State<PayseApp> createState() => _PayseAppState();
}

/// 2026-10-20: 앱 수명 동안 필요한 등록과 Repository 생성, 개발용 스냅샷 선택을 맡는다.
class _PayseAppState extends State<PayseApp> {
  late final SnapshotSource _source =
      widget.snapshotSource ?? AssetSnapshotSource(rootBundle);
  FixtureScenario _scenario = FixtureScenario.defaultScenario;

  /// 2026-10-20: 글꼴 라이선스를 라이선스 목록에 등록한다. 반환값 없음(중복 등록 없음).
  @override
  void initState() {
    super.initState();
    registerPayseFontLicenses();
  }

  /// 2026-10-20: [scenario] 스냅샷을 읽는 Repository를 만든다. 화면은 이 계약만 사용한다.
  FinancialSnapshotRepository _repositoryFor(FixtureScenario scenario) =>
      FakeFinancialSnapshotRepository(source: _source, scenario: scenario);

  /// 2026-10-19: context의 위젯 트리에 앱 시작 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PAYSE',
      debugShowCheckedModeBanner: false,
      theme: buildPayseTheme(),
      themeMode: ThemeMode.light,
      // 개발 단계 임시: 인증 구현 전이라 하단 탭으로 바로 시작한다. 실제 진입(온보딩·PIN 후 홈)은 별도 구현.
      home: Builder(
        builder: (context) => AppShell(devEntry: _devEntryOrNull(context)),
      ),
      routes: {
        OnboardingPlaceholderScreen.routeName: (_) =>
            const OnboardingPlaceholderScreen(),
      },
    );
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

  /// 2026-10-20: 개발 환경 전용 진입 버튼들을 반환한다. 릴리스 빌드에서는 호출되지 않는다.
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
        TextButton(
          onPressed: () =>
              Navigator.of(context)
                  .pushNamed(OnboardingPlaceholderScreen.routeName),
          child: const Text('개발용: 온보딩 자리 보기'),
        ),
      ],
    );
  }
}
