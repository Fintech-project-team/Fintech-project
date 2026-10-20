import 'package:flutter/material.dart';

import 'placeholder_screens.dart';

/// 2026-10-20: 하단 탭(홈·계좌·계획·내 정보) 골격. 각 탭은 기능 화면이 들어갈 자리다.
/// 앱이 이 화면으로 바로 시작하는 것은 인증 구현 전 개발 단계의 임시 구조다(docs/fake-repository.md 결정 기록).
class AppShell extends StatefulWidget {
  /// 2026-10-20: [devEntry]는 개발 환경에서만 내 정보 탭 아래에 붙는 진입 위젯이며 릴리스에서는 null이다.
  const AppShell({super.key, this.devEntry});

  final Widget? devEntry;

  static const List<String> tabTitles = ['홈', '계좌', '계획', '내 정보'];

  /// 2026-10-20: 선택 탭 상태 객체를 반환한다.
  @override
  State<AppShell> createState() => _AppShellState();
}

/// 2026-10-20: 현재 탭 번호를 보관한다. 탭을 바꿔도 각 탭 상태는 유지한다.
class _AppShellState extends State<AppShell> {
  int _index = 0;

  /// 2026-10-20: 탭 내용과 하단 탭 막대를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          const TabPlaceholder(title: '홈'),
          const TabPlaceholder(title: '계좌'),
          const TabPlaceholder(title: '계획'),
          TabPlaceholder(title: '내 정보', footer: widget.devEntry),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '홈'),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            label: '계좌',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_note_outlined),
            label: '계획',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: '내 정보',
          ),
        ],
      ),
    );
  }
}
