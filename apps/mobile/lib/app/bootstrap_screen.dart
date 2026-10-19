import 'package:flutter/material.dart';

/// 2026-10-19: key를 받는 초기 실행 확인 화면. 제품의 홈 화면을 구현하지 않는다.
class BootstrapScreen extends StatelessWidget {
  /// 2026-10-19: 선택적 key로 실행 확인 위젯 인스턴스를 초기화한다.
  const BootstrapScreen({super.key});

  /// 2026-10-19: context 아래에 앱 이름을 표시하는 실행 확인 UI를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PAYSE')),
      body: const SafeArea(child: Center(child: Text('개발 환경이 준비되었습니다.'))),
    );
  }
}
