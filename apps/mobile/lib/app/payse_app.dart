import 'package:flutter/material.dart';

import 'bootstrap_screen.dart';

/// 2026-10-19: key로 위젯을 식별하는 PAYSE 루트. 금융 상태를 전역에 보관하지 않는다.
class PayseApp extends StatelessWidget {
  /// 2026-10-19: 선택적 key를 전달받아 앱 루트 인스턴스를 초기화한다.
  const PayseApp({super.key});

  /// 2026-10-19: context의 위젯 트리에 앱 시작 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'PAYSE',
      debugShowCheckedModeBanner: false,
      home: BootstrapScreen(),
    );
  }
}
