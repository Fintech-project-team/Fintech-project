import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/app/main_entry.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/first_calc_record_store.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../data/connection/connection_test_utils.dart';
import '../features/connection/connection_test_support.dart';

const _codes = [
  'bank.kb',
  'bank.shinhan',
  'bank.hana',
  'bank.ibk',
  'bank.kakao',
  'card.hyundai',
  'card.samsung',
  'card.woori',
  'card.kb',
];

/// 2026-10-30: 데모알파를 모두 연결하고 입출금 4개를 계산에 포함한 가짜 서버 저장소. [pageSize]가 있으면 거래를 나눈다.
Future<FakeUserFinancialRepository> _connected({int? pageSize}) async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (_) async => readSource('demo-ready'),
    transactionPageSize: pageSize,
  );
  final a = devDemoAccounts.first;
  final session = await auth.createSession(
    DemoCredentials(name: a.name, phone: a.phone, code: a.code),
  );
  final repo = FakeUserFinancialRepository(
    server: server,
    accessToken: (session as AuthOk<DemoSession>).value.accessToken,
  );
  WriteContext w(String v, String k) => WriteContext(
    expectedDataVersion: v,
    ruleVersion: 'PAYSE-CALC-1',
    idempotencyKey: k,
  );
  await repo.linkInstitutions(_codes, w('1', 'l'));
  await repo.selectAccounts(const [
    '6069b37a-abf5-56fc-8bf0-153f5301fd1c',
    '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc',
    '4021635f-1b2c-534d-b5b6-9680b3c8d5f2',
    '1ce9128d-d667-5bfc-bed0-949a571c78f5',
  ], w('2', 's'));
  return repo;
}

Future<Map<String, Object?>> _json(UserFinancialRepository repo) async =>
    ((await repo.loadSnapshot()) as FinancialOk<Map<String, Object?>>).value;

/// 2026-10-30: [repo]로 앱 진입을 띄우고 하단 '계좌·카드' 탭으로 간다.
Future<void> _openTab(WidgetTester tester, UserFinancialRepository repo) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final records = MemoryFirstCalcRecordStore();
  await records.save(devDemoAccounts.first.userId, FirstCalcRecord.explained);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: MainEntry(
        financial: repo,
        policy: instantPolicy(),
        reloadKey: 0,
        devEntryBuilder: (_) => null,
        onSessionInvalid: () {},
        firstCalcRecords: records,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('계좌·카드'),
    ),
  );
  await tester.pumpAndSettle();
}

/// 2026-10-30: [list] 목록 위에서 손가락을 대고 [dy]만큼 나눠 끈다. 손은 떼지 않는다.
Future<TestGesture> _drag(WidgetTester tester, Finder list, double dy) async {
  final gesture = await tester.startGesture(
    tester.getTopLeft(list) + const Offset(200, 40),
  );
  await _move(tester, gesture, dy);
  return gesture;
}

/// 2026-10-30: 손가락 [gesture]를 [dy]만큼 40dp씩(마지막은 남은 만큼) 옮긴다.
Future<void> _move(WidgetTester tester, TestGesture gesture, double dy) async {
  var left = dy.abs();
  while (left > 0) {
    final step = left < 40 ? left : 40.0;
    await gesture.moveBy(Offset(0, dy.sign * step));
    await tester.pump(const Duration(milliseconds: 16));
    left -= step;
  }
}

/// 2026-10-30: 손을 떼고 1초 동안 프레임을 돌린다.
Future<void> _up(WidgetTester tester, TestGesture gesture) async {
  await gesture.up();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 2026-10-30: [list] 목록을 충분히 당겨 놓는다. 놓기 직전 표시 문구를 돌려준다.
Future<String?> _pull(WidgetTester tester, Finder list) async {
  final gesture = await _drag(tester, list, 600);
  final armed = find.byKey(const ValueKey('pull-armed')).evaluate().isNotEmpty
      ? 'armed'
      : null;
  await _up(tester, gesture);
  return armed;
}

/// 2026-10-30: 스크린리더 알림 문구 목록.
List<String> _said(WidgetTester tester) => [
  for (final a in tester.takeAnnouncements()) a.message,
];

/// 2026-10-30: 성공 표시가 접힐 때까지 기다린다.
Future<void> _settleDone(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// 2026-10-30: 첫 조회는 [first], 이후 조회는 [loadResults], 거래 페이지는 [pageResults]로 답하는 저장소.
class _Gate extends ScriptedRepository {
  /// 2026-10-30: 다음 조회를 이 completer가 끝날 때까지 붙잡는다.
  Completer<void>? hold;

  /// 2026-10-30: Snapshot 조회 횟수.
  int loads = 0;

  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() async {
    loads++;
    final h = hold;
    if (h != null) await h.future;
    return super.loadSnapshot();
  }
}

/// 2026-10-30: 연결·계좌 선택을 마친 Snapshot JSON(페이지 없음·100건 페이지). 테스트마다 다시 만들지 않도록 한 번만 만든다.
late Map<String, Object?> _plain;
late Map<String, Object?> _pagedJson;

void main() {
  setUpAll(() async {
    _plain = await _json(await _connected());
    _pagedJson = await _json(await _connected(pageSize: 100));
  });

  testWidgets('빠른 성공: 문구 없이 회전 → 체크와 문구로 전환, 1.5초 뒤 접힘, 늦은 진행 문구 없음, 조건 유지', (
    tester,
  ) async {
    final json = _plain;
    final repo = _Gate()
      ..loadResults.add(FinancialOk(json))
      ..loadResults.add(FinancialOk(json));
    await _openTab(tester, repo);
    await tester.tap(find.byKey(const ValueKey('period-prev')));
    await tester.pumpAndSettle();
    tester.takeAnnouncements();
    final list = find.byKey(const ValueKey('transactions-list'));
    expect(await _pull(tester, list), 'armed', reason: '기준 거리 도달은 아이콘으로');
    expect(find.text('놓으면 새로고침해요'), findsNothing);
    expect(repo.loads, 2);
    expect(find.text('최신 정보를 확인했어요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('refresh-done')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing, reason: '하단 알림 중복 없음');
    expect(find.text('2026년 9월'), findsOneWidget, reason: '기간 유지');
    expect(_said(tester), ['새로고침 중', '최신 정보를 확인했어요']);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('새로고침 중…'),
        findsNothing,
        reason: '끝난 요청의 진행 문구가 뒤늦게 나타나지 않음',
      );
    }
    await _settleDone(tester);
    expect(find.text('최신 정보를 확인했어요.'), findsNothing, reason: '잠깐 뒤 접힘');
    expect(find.text('2026년 9월'), findsOneWidget);
  });

  testWidgets('느린 성공: 1초 전에는 회전만, 1초가 지나면 새로고침 중… 페이드인, 끝나면 체크로 전환', (
    tester,
  ) async {
    final json = _plain;
    final repo = _Gate()
      ..loadResults.add(FinancialOk(json))
      ..loadResults.add(FinancialOk(json));
    await _openTab(tester, repo);
    repo.hold = Completer<void>();
    final list = find.byKey(const ValueKey('transactions-list'));
    final gesture = await _drag(tester, list, 600);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('refresh-spin')), findsOneWidget);
    expect(find.text('새로고침 중…'), findsNothing, reason: '1초 전에는 문구 없음');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));
    final label = find.text('새로고침 중…');
    expect(label, findsOneWidget);
    expect(
      tester.getRect(label).height,
      greaterThan(0),
      reason: '문구가 실제 크기로 그려짐',
    );
    expect(
      find.byKey(const ValueKey('tx-loading')),
      findsNothing,
      reason: '로딩 틀 없음',
    );
    expect(find.text('10월 17일 토요일'), findsOneWidget, reason: '기존 목록 유지');

    await _pull(tester, list);
    expect(repo.loads, 2, reason: '진입 1회 + 새로고침 1회. 진행 중에는 새 요청 없음');

    repo.hold!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('최신 정보를 확인했어요.'), findsOneWidget);
    expect(find.text('새로고침 중…'), findsNothing);
    await _settleDone(tester);
  });

  testWidgets('놓는 순간·문구 유무로 목록과 아이콘 위치가 바뀌지 않는다', (tester) async {
    final json = _plain;
    final repo = _Gate()
      ..loadResults.add(FinancialOk(json))
      ..loadResults.add(FinancialOk(json));
    await _openTab(tester, repo);
    repo.hold = Completer<void>();
    final list = find.byKey(const ValueKey('transactions-list'));
    final gesture = await _drag(tester, list, 600);
    final day = find.text('10월 17일 토요일');
    final before = tester.getRect(day).top;
    final armed = tester
        .getRect(find.byKey(const ValueKey('pull-armed')))
        .center
        .dy;
    await gesture.up();
    await tester.pump();
    expect(
      tester.getRect(day).top,
      lessThanOrEqualTo(before),
      reason: '놓은 첫 장면에 목록이 밀리지 않음',
    );
    double spin() =>
        tester.getRect(find.byKey(const ValueKey('refresh-spin'))).center.dy;
    expect((spin() - armed).abs(), lessThan(2), reason: '당김 표시와 회전 표시가 같은 자리');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final settled = spin();
    final listTop = tester.getRect(day).top;
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('새로고침 중…'), findsOneWidget);
    expect(spin(), settled, reason: '문구가 나타나도 아이콘 위치 그대로');
    expect(tester.getRect(day).top, listTop, reason: '문구가 나타나도 목록 위치 그대로');
    repo.hold!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.getRect(find.byKey(const ValueKey('refresh-done'))).center.dy,
      closeTo(settled, 1),
      reason: '체크도 같은 자리',
    );
    await _settleDone(tester);
  });

  testWidgets('당긴 채 유지: 기준을 넘겨도 손을 떼기 전에는 요청하지 않고, 뗄 때 한 번 요청', (tester) async {
    final json = _plain;
    final repo = _Gate()
      ..loadResults.add(FinancialOk(json))
      ..loadResults.add(FinancialOk(json));
    await _openTab(tester, repo);
    final list = find.byKey(const ValueKey('transactions-list'));
    final gesture = await _drag(tester, list, 600);
    expect(find.byKey(const ValueKey('pull-armed')), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(repo.loads, 1, reason: '3초 동안 당긴 채 유지해도 요청 없음');
    expect(find.byKey(const ValueKey('refresh-spin')), findsNothing);
    await _up(tester, gesture);
    expect(repo.loads, 2);
    await _settleDone(tester);
  });

  testWidgets('당겼다 되돌리기: 기준 아래로 되돌린 뒤 놓으면 취소', (tester) async {
    final json = _plain;
    final repo = _Gate()..loadResults.add(FinancialOk(json));
    await _openTab(tester, repo);
    final list = find.byKey(const ValueKey('transactions-list'));
    final gesture = await _drag(tester, list, 120);
    expect(
      find.byKey(const ValueKey('pull-arc')),
      findsOneWidget,
      reason: '당긴 만큼만 찬 원',
    );
    expect(find.byKey(const ValueKey('pull-armed')), findsNothing);
    await _move(tester, gesture, 480);
    expect(find.byKey(const ValueKey('pull-armed')), findsOneWidget);
    await _move(tester, gesture, -570);
    expect(find.byKey(const ValueKey('pull-armed')), findsNothing);
    await _up(tester, gesture);
    await tester.pumpAndSettle();
    expect(repo.loads, 1, reason: '요청 없음');
    expect(find.byKey(const ValueKey('refresh-spin')), findsNothing);
    expect(find.text('10월 17일 토요일'), findsOneWidget);
  });

  testWidgets('실패: 성공 표시 없이 접히고 이전 정보 유지 + 띠, 스크린리더에 실패 알림, 다시 시도 성공', (
    tester,
  ) async {
    final json = _plain;
    final next = Map<String, Object?>.of(json)
      ..['asOf'] = '2026-10-20T09:00:00+09:00'
      ..['dataVersion'] = '99';
    final repo = _Gate()
      ..loadResults.add(FinancialOk(json))
      ..loadResults.add(const FinancialUnavailable())
      ..loadResults.add(FinancialOk(next));
    await _openTab(tester, repo);
    await tester.tap(find.byKey(const ValueKey('period-prev')));
    await tester.pumpAndSettle();
    tester.takeAnnouncements();
    final list = find.byKey(const ValueKey('transactions-list'));
    await _pull(tester, list);
    await tester.pumpAndSettle();
    expect(find.text('새로고침하지 못했어요'), findsOneWidget);
    expect(find.text('이전 정보를 보여드려요.'), findsOneWidget);
    expect(find.text('최신 정보를 확인했어요.'), findsNothing);
    expect(
      find.byKey(const ValueKey('refresh-indicator')),
      findsNothing,
      reason: '표시 접힘',
    );
    expect(_said(tester), ['새로고침 중', '새로고침하지 못했어요. 이전 정보를 보여드려요.']);
    expect(
      find.textContaining('10월 19일 12:00 기준'),
      findsOneWidget,
      reason: '이전 기준 시각',
    );
    expect(find.text('2026년 9월'), findsOneWidget, reason: '조건 유지');

    repo.hold = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('refresh-retry')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final spin = find.byKey(const ValueKey('refresh-spin'));
    expect(spin, findsOneWidget);
    expect(
      tester.getRect(spin).top,
      greaterThanOrEqualTo(tester.getRect(list).top),
      reason: '다시 시도로 시작해도 표시 자리가 보이게 올림',
    );
    repo.hold!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('새로고침하지 못했어요'), findsNothing);
    expect(find.text('최신 정보를 확인했어요.'), findsOneWidget);
    expect(
      find.textContaining('10월 20일 09:00 기준'),
      findsOneWidget,
      reason: '기준 시각은 응답값',
    );
    await _settleDone(tester);
  });

  testWidgets('성공 표시 중에도 목록을 스크롤하고 거래를 누를 수 있다', (tester) async {
    final json = _plain;
    final repo = _Gate()
      ..loadResults.add(FinancialOk(json))
      ..loadResults.add(FinancialOk(json));
    await _openTab(tester, repo);
    final list = find.byKey(const ValueKey('transactions-list'));
    await _pull(tester, list);
    expect(find.text('최신 정보를 확인했어요.'), findsOneWidget);
    final row = find.textContaining('다솜결수리');
    await tester.tap(row.first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('detail-title')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('detail-close')));
    await _settleDone(tester);
  });

  testWidgets('Snapshot은 받았지만 거래 페이지가 실패하면 새 Snapshot을 어디에도 반영하지 않는다', (
    tester,
  ) async {
    final json = _plain;
    final next = Map<String, Object?>.of(_pagedJson)
      ..['asOf'] = '2026-10-20T09:00:00+09:00';
    final repo = _Gate()
      ..loadResults.add(FinancialOk(json))
      ..loadResults.add(FinancialOk(next))
      ..pageResults.add(const FinancialUnavailable());
    await _openTab(tester, repo);
    await tester.tap(find.byKey(const ValueKey('inner-tab-accounts')));
    await tester.pumpAndSettle();
    await _pull(tester, find.byKey(const ValueKey('accounts-list')));
    await tester.pumpAndSettle();
    expect(repo.pageCalls, hasLength(1));
    expect(find.text('새로고침하지 못했어요'), findsOneWidget);
    expect(
      find.text('계산에 포함한 계좌 4개 · 10월 19일 12:00 기준'),
      findsOneWidget,
      reason: '계좌 관리도 이전 Snapshot',
    );
    await tester.tap(
      find.descendant(of: find.byType(NavigationBar), matching: find.text('홈')),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('10월 20일'),
      findsNothing,
      reason: '홈도 이전 Snapshot',
    );
  });

  testWidgets('계좌별 거래 화면도 당겨서 새로고침하고 응답 기준 시각으로 바뀐다', (tester) async {
    final json = _plain;
    final next = Map<String, Object?>.of(json)
      ..['asOf'] = '2026-10-20T09:00:00+09:00'
      ..['dataVersion'] = '99';
    final repo = _Gate()
      ..loadResults.add(FinancialOk(json))
      ..loadResults.add(FinancialOk(next));
    await _openTab(tester, repo);
    await tester.tap(find.byKey(const ValueKey('inner-tab-accounts')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('account-open-6069b37a-abf5-56fc-8bf0-153f5301fd1c'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('10월 19일 12:00 기준'), findsOneWidget);
    await _pull(tester, find.byKey(const ValueKey('transactions-list')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('최신 정보를 확인했어요.'), findsOneWidget);
    expect(find.text('10월 20일 09:00 기준'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-tx-title')), findsOneWidget);
    await _settleDone(tester);
  });
}
