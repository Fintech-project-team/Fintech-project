import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/features/connection/connection_illustration.dart';

import '../../shared/design/design_test_utils.dart';

/// 2026-10-23: [state] 그림을 띄운다. [reduceMotion]이면 기기의 움직임 줄이기를 켠다.
Future<void> _pump(
  WidgetTester tester,
  ConnectionIllustrationState state, {
  bool reduceMotion = false,
}) => tester.pumpWidget(
  themed(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Center(child: ConnectionIllustration(state: state)),
    ),
  ),
);

void main() {
  testWidgets('searching floats; reduced motion keeps it still', (
    tester,
  ) async {
    await _pump(tester, ConnectionIllustrationState.searching);
    expect(tester.hasRunningAnimations, isTrue);
    expect(
      tester.getSize(find.byType(ConnectionIllustration)),
      const Size(200, 150),
    );

    await _pump(
      tester,
      ConnectionIllustrationState.searching,
      reduceMotion: true,
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('each state has its own mark and the picture is decorative', (
    tester,
  ) async {
    await _pump(tester, ConnectionIllustrationState.found);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await _pump(tester, ConnectionIllustrationState.offline);
    expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);

    await _pump(tester, ConnectionIllustrationState.unavailable);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);

    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp('.')),
      findsNothing,
      reason: '장식 그림은 읽지 않음',
    );
    semantics.dispose();
  });
}
