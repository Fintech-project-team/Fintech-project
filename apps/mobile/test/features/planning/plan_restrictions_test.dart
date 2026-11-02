import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/snapshot_projector.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/overview_links.dart';
import 'package:payse/features/planning/plan_screen.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../../data/connection/connection_test_utils.dart';

const _all = {
  'bank.kb',
  'bank.shinhan',
  'bank.hana',
  'bank.ibk',
  'bank.kakao',
  'card.hyundai',
  'card.samsung',
  'card.woori',
  'card.kb',
};

/// 2026-11-03: beta 원본(수정 [patch] 적용)을 [codes] 기관만 연결한 응답으로 투영해 읽는다.
FinancialSnapshot _projected(
  Set<String> codes, {
  void Function(Map<String, Object?> source)? patch,
}) {
  final source = readSource('beta-ready');
  patch?.call(source);
  return FinancialSnapshot.fromJson(
    SnapshotProjector.project(
      source,
      ProjectionState(
        institutionLinks: [
          for (final code in codes)
            {
              'userId': source['userId'],
              'linkId': 'link-$code',
              'institutionCode': code,
              'consentedAt': '2026-10-22T10:00:00Z',
              'disconnectedAt': null,
            },
        ],
        selectedAccountIds: null,
        dataVersion: '3',
      ),
    ),
  );
}

/// 2026-11-03: 수리비(남겨둘 돈에 배정된 예정 지출)의 출금 계좌를 하나은행 계좌로 옮긴다.
void _repairToHana(Map<String, Object?> source) {
  final hana = rows(
    source,
    'accounts',
  ).firstWhere((a) => a['institutionCode'] == 'bank.hana')['accountId'];
  rows(
    source,
    'obligations',
  ).firstWhere((o) => o['label'] == '수리비')['withdrawalAccountId'] = hana;
}

/// 2026-11-03: [snapshot]으로 계산한 계획 탭을 띄운다.
Future<void> _pump(WidgetTester tester, FinancialSnapshot snapshot) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = ValueNotifier<OverviewState>((
    calculation: computeHomeCalculation(snapshot),
    history: null,
  ));
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: Scaffold(
        body: PlanScreen(links: OverviewLinks(state: state)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('예정 지출이 모두 접근 제한이면 없다고 단정하지 않고 제한 안내', (tester) async {
    final s = _projected(_all.difference({'bank.kb'}));
    expect(s.obligationsRestricted, isTrue);
    await _pump(tester, s);
    expect(
      find.byKey(const ValueKey('plan-obligations-restricted')),
      findsOneWidget,
    );
    expect(find.text('이 기간에 보여 드릴 수 있는 예정 지출이 없어요'), findsOneWidget);
    expect(find.text('이 기간에 예정된 지출이 없어요'), findsNothing);
  });

  testWidgets('일부만 접근 제한이면 공개된 항목은 그대로, 제한 안내를 함께', (tester) async {
    final s = _projected(_all.difference({'bank.hana'}), patch: _repairToHana);
    await _pump(tester, s);
    expect(
      find.byKey(const ValueKey('plan-obligations-restricted')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('plan-fold-excluded')));
    await tester.pump();
    expect(find.text('월세'), findsOneWidget, reason: '공개된 항목은 그대로');
    expect(find.text('수리비'), findsNothing, reason: '숨겨진 항목은 추정하지 않음');
  });

  testWidgets('제한이 없으면 제한 안내 없음', (tester) async {
    await _pump(tester, _projected(_all));
    expect(
      find.byKey(const ValueKey('plan-obligations-restricted')),
      findsNothing,
    );
  });

  group('남겨둘 돈의 연결', () {
    Future<void> openReserves(WidgetTester tester, FinancialSnapshot s) async {
      await _pump(tester, s);
      await tester.tap(find.byKey(const ValueKey('plan-tab-reserves')));
      await tester.pump();
    }

    String linkText(WidgetTester tester, FinancialSnapshot s) => tester
        .widget<Text>(
          find.byKey(
            ValueKey('plan-reserve-links-${s.reserves!.single.reserveId}'),
          ),
        )
        .data!;

    testWidgets('연결된 예정 지출이 숨겨지면 배정도 생략, 없다고 단정하지 않는다', (tester) async {
      final s = _projected(
        _all.difference({'bank.hana'}),
        patch: _repairToHana,
      );
      expect(s.reserves, hasLength(1));
      expect(s.isRestricted('response', null, 'allocations'), isTrue);
      await openReserves(tester, s);
      expect(
        find.byKey(const ValueKey('plan-allocations-restricted')),
        findsOneWidget,
      );
      expect(linkText(tester, s), '보여 드릴 수 있는 연결이 없어요');
    });

    testWidgets('배정 정보를 받지 못하면 받지 못했다고, 제한 없는 빈 연결은 없다고', (tester) async {
      final json = readSource('beta-ready')..remove('allocations');
      final missing = FinancialSnapshot.fromJson(json);
      expect(missing.allocations, isNull);
      await openReserves(tester, missing);
      expect(linkText(tester, missing), '연결 정보를 받지 못했어요');

      final none = readSource('beta-ready')..['allocations'] = <Object?>[];
      final empty = FinancialSnapshot.fromJson(none);
      await openReserves(tester, empty);
      expect(linkText(tester, empty), '연결한 예정 지출이 없어요');
      expect(
        find.byKey(const ValueKey('plan-allocations-restricted')),
        findsNothing,
      );
    });
  });
}
