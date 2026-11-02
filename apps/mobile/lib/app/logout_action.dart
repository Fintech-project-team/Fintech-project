import 'package:flutter/material.dart';

import '../features/auth/auth_screens.dart';

/// 2026-11-02: 내 정보 탭의 로그아웃 버튼(최소안). 확인 창에서 '네'를 고르면 [onLogout]을 부르고, 실패 안내가 오면 알림으로 보인다.
/// 로그아웃이 끝나면 앱이 첫 화면으로 바꾸므로 성공 처리는 하지 않는다. 요청 중에는 다시 누를 수 없다.
class LogoutAction extends StatefulWidget {
  /// 2026-11-02: 로그아웃 실행 [onLogout](성공이면 null, 실패면 안내 문구 반환)으로 만든다.
  const LogoutAction({super.key, required this.onLogout});

  final Future<String?> Function() onLogout;

  /// 2026-11-02: 요청 중 상태를 갖는 객체를 반환한다.
  @override
  State<LogoutAction> createState() => _LogoutActionState();
}

/// 2026-11-02: 확인 창과 요청 중 상태를 다룬다.
class _LogoutActionState extends State<LogoutAction> {
  bool _busy = false;

  /// 2026-11-02: 확인 뒤 로그아웃을 요청하고 실패하면 안내를 보인다.
  Future<void> _logout() async {
    final confirmed = await confirmChoice(
      context,
      message: '로그아웃 하시겠습니까?',
      cancelLabel: '아니오',
      confirmLabel: '네',
      confirmKey: const ValueKey('logout-confirm'),
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final failure = await widget.onLogout();
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure)));
    }
  }

  /// 2026-11-02: 로그아웃 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      key: const ValueKey('logout-button'),
      onPressed: _busy ? null : _logout,
      child: Text(_busy ? '로그아웃하는 중' : '로그아웃'),
    );
  }
}
