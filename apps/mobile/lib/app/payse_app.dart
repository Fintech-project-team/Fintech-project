import 'package:flutter/material.dart';

import '../shared/design/font_licenses.dart';
import '../shared/design/payse_theme.dart';
import 'bootstrap_screen.dart';

/// 2026-10-19: key로 위젯을 식별하는 PAYSE 루트. 금융 상태를 전역에 보관하지 않는다.
class PayseApp extends StatefulWidget {
  /// 2026-10-19: 선택적 key를 전달받아 앱 루트 인스턴스를 초기화한다.
  const PayseApp({super.key});

  /// 2026-10-20: 앱 루트 상태 객체를 반환한다. 인자 없음.
  @override
  State<PayseApp> createState() => _PayseAppState();
}

/// 2026-10-20: 앱 시작 시 한 번 필요한 등록(글꼴 라이선스)을 수행하고 루트 화면을 구성한다.
class _PayseAppState extends State<PayseApp> {
  /// 2026-10-20: 글꼴 라이선스를 라이선스 목록에 등록한다. 반환값 없음(중복 등록 없음).
  @override
  void initState() {
    super.initState();
    registerPayseFontLicenses();
  }

  /// 2026-10-19: context의 위젯 트리에 앱 시작 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PAYSE',
      debugShowCheckedModeBanner: false,
      theme: buildPayseTheme(),
      themeMode: ThemeMode.light,
      home: const BootstrapScreen(),
    );
  }
}
