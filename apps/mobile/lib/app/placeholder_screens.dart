import 'package:flutter/material.dart';

import '../shared/design/primary_button.dart';
import '../shared/design/payse_tokens.dart';

/// 2026-10-20: 기능 화면이 들어갈 탭 자리. 제품 기능을 구현하지 않는다.
class TabPlaceholder extends StatelessWidget {
  /// 2026-10-20: 탭 이름 [title]과 아래에 둘 선택 위젯 [footer]로 만든다.
  const TabPlaceholder({super.key, required this.title, this.footer});

  final String title;
  final Widget? footer;

  /// 2026-10-20: 탭 이름과 '준비 중' 안내를 반환한다.
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('이 화면은 준비 중이에요.'),
            if (footer != null) ...[const Spacer(), footer!],
          ],
        ),
      ),
    );
  }
}

/// 2026-10-21: 금융사 연결 흐름(12-1 → 12-2 → 12-3 → 01-1 → 01-2, GitHub #26)이 들어갈 자리. 연결을 구현하지 않는다.
class ConnectionPlaceholderScreen extends StatelessWidget {
  /// 2026-10-21: 연결 화면이 생기기 전 홈으로 넘어가는 [onContinue]로 만든다.
  const ConnectionPlaceholderScreen({super.key, required this.onContinue});

  final VoidCallback onContinue;

  /// 2026-10-21: 자리 안내와 홈으로 가기 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(PayseSpace.screenHorizontal),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '금융사 연결',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text('금융사 연결 화면이 들어갈 자리예요.'),
                  ],
                ),
              ),
            ),
            PrimaryButton(label: '홈으로 가기', onPressed: onContinue),
          ],
        ),
      ),
    );
  }
}
