import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';

import 'connection_test_utils.dart';

const _sources = {
  'f0a4be6c-01d7-53eb-ab2c-74675b22fd8c': 'alpha-ready',
  '87f7bbf9-2355-5210-9325-f25d83a8ff35': 'beta-ready',
  'd04073fd-f7ab-518d-8938-f2920d593db2': 'gamma-month-end',
};

/// 2026-10-22: 데모 계정 가짜 인증과 사용자별 원본을 쓰는 가짜 서버 묶음.
class _World {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  late final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (userId) async => readSource(_sources[userId]!),
  );

  /// 2026-10-22: [index]번째 데모 계정으로 로그인해 토큰을 반환한다.
  Future<String> login(int index) async {
    final a = devDemoAccounts[index];
    final r = await auth.createSession(
      DemoCredentials(name: a.name, phone: a.phone, code: a.code),
    );
    return (r as AuthOk<DemoSession>).value.accessToken;
  }
}

/// 2026-10-22: 기대 버전 [version]·작업 키 [key]의 쓰기 공통 필드를 만든다.
WriteContext w(String version, String key, {String rule = 'PAYSE-CALC-1'}) =>
    WriteContext(
      expectedDataVersion: version,
      ruleVersion: rule,
      idempotencyKey: key,
    );

/// 2026-10-22: 성공 결과의 값을 꺼낸다. 실패면 테스트를 실패시킨다.
T ok<T>(FinancialOutcome<T> outcome) {
  expect(outcome, isA<FinancialOk<T>>());
  return (outcome as FinancialOk<T>).value;
}

const _kb = 'bank.kb';
const _allAlpha = [
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

void main() {
  test(
    'first snapshot is the pre-connection state; unknown token is 401',
    () async {
      final world = _World();
      final token = await world.login(0);

      final snap = ok(await world.server.getSnapshot(token));
      expect(snap['institutionLinks'], isEmpty);
      expect(snap.containsKey('accounts'), isFalse);
      expect(snap['dataVersion'], '1');
      expect(
        await world.server.getSnapshot('nope'),
        isA<FinancialSessionInvalid<Map<String, Object?>>>(),
      );
    },
  );

  test('link validation: 422 for empty, duplicate, cards only; 403 for not offered', () async {
    final world = _World();
    final token = await world.login(0);
    final s = world.server;

    expect(
      await s.postInstitutionLinks(token, [], w('1', 'k1')),
      isA<FinancialInvalid<WriteSuccess>>(),
    );
    expect(
      await s.postInstitutionLinks(token, [_kb, _kb], w('1', 'k2')),
      isA<FinancialInvalid<WriteSuccess>>(),
    );
    expect(
      await s.postInstitutionLinks(token, [
        'card.hyundai',
        'card.kb',
      ], w('1', 'k3')),
      isA<FinancialInvalid<WriteSuccess>>(),
      reason: '계좌를 제공할 은행 최소 1곳',
    );
    expect(
      await s.postInstitutionLinks(token, [_kb, 'bank.unknown'], w('1', 'k4')),
      isA<FinancialForbidden<WriteSuccess>>(),
    );
    expect(
      await s.postInstitutionLinks(token, [_kb], w('1', 'bad key!')),
      isA<FinancialInvalid<WriteSuccess>>(),
    );
    expect(
      ok(await s.getSnapshot(token))['dataVersion'],
      '1',
      reason: '실패는 버전을 바꾸지 않음',
    );
  });

  test('409 kinds are distinct: stale data vs rule version', () async {
    final world = _World();
    final token = await world.login(0);

    expect(
      await world.server.postInstitutionLinks(token, [_kb], w('7', 'k1')),
      isA<FinancialStaleData<WriteSuccess>>(),
    );
    expect(
      await world.server.postInstitutionLinks(token, [
        _kb,
      ], w('1', 'k2', rule: 'PAYSE-CALC-0')),
      isA<FinancialRuleVersionMismatch<WriteSuccess>>(),
    );
  });

  test(
    'link success: version up, links set, accounts not auto-selected',
    () async {
      final world = _World();
      final token = await world.login(0);

      final result = ok(
        await world.server.postInstitutionLinks(
          token,
          _allAlpha,
          w('1', 'link-1'),
        ),
      );
      expect(result.replayed, isFalse);
      expect(result.receipt.resultVersion, '2');
      expect(result.snapshot['dataVersion'], '2');
      expect(rows(result.snapshot, 'institutionLinks'), hasLength(9));
      expect(
        rows(result.snapshot, 'accounts').every((a) => a['included'] == false),
        isTrue,
      );
      expect(
        result.receipt.changedRefs.every(
          (r) => r.resource == 'institutionLink',
        ),
        isTrue,
      );
    },
  );

  test('replay returns the stored receipt with the latest snapshot; different request is 409', () async {
    final world = _World();
    final token = await world.login(0);
    final s = world.server;

    final first = ok(
      await s.postInstitutionLinks(token, [
        _kb,
        'card.hyundai',
      ], w('1', 'link-1')),
    );
    final account =
        rows(first.snapshot, 'accounts').first['accountId'] as String;
    ok(await s.patchAccountSelection(token, [account], w('2', 'sel-1')));

    final replay = ok(
      await s.postInstitutionLinks(token, [
        _kb,
        'card.hyundai',
      ], w('1', 'link-1')),
    );
    expect(replay.replayed, isTrue);
    expect(replay.receipt.receiptId, first.receipt.receiptId);
    expect(replay.snapshot['dataVersion'], '3', reason: '과거 스냅샷으로 되돌리지 않음');

    expect(
      await s.postInstitutionLinks(token, [
        'card.hyundai',
        _kb,
      ], w('1', 'link-1')),
      isA<FinancialIdempotencyConflict<WriteSuccess>>(),
      reason: '배열 순서도 같은 요청 판정에 포함',
    );
    expect(
      await s.postInstitutionLinks(token, [_kb], w('1', 'link-1')),
      isA<FinancialIdempotencyConflict<WriteSuccess>>(),
    );
  });

  test('two writes on the same version: exactly one wins', () async {
    final world = _World();
    final token = await world.login(0);

    final results = await Future.wait([
      world.server.postInstitutionLinks(token, [_kb], w('1', 'a')),
      world.server.postInstitutionLinks(token, [_kb, 'bank.hana'], w('1', 'b')),
    ]);
    expect(results.whereType<FinancialOk<WriteSuccess>>(), hasLength(1));
    expect(results.whereType<FinancialStaleData<WriteSuccess>>(), hasLength(1));
    expect(ok(await world.server.getSnapshot(token))['dataVersion'], '2');
  });

  test('selection: 403 for unconnected or other user accounts, 422 for empty; state unchanged on failure', () async {
    final world = _World();
    final alpha = await world.login(0);
    final s = world.server;
    final linked = ok(await s.postInstitutionLinks(alpha, [_kb], w('1', 'l')));
    final kbAccount =
        rows(linked.snapshot, 'accounts').first['accountId'] as String;
    final shinhan =
        rows(readSource('alpha-ready'), 'accounts').firstWhere(
              (a) => a['institutionCode'] == 'bank.shinhan',
            )['accountId']
            as String;
    final betaAccount =
        rows(readSource('beta-ready'), 'accounts').first['accountId'] as String;

    expect(
      await s.patchAccountSelection(alpha, [shinhan], w('2', 's1')),
      isA<FinancialForbidden<WriteSuccess>>(),
    );
    expect(
      await s.patchAccountSelection(alpha, [betaAccount], w('2', 's2')),
      isA<FinancialForbidden<WriteSuccess>>(),
    );
    expect(
      await s.patchAccountSelection(alpha, [], w('2', 's3')),
      isA<FinancialInvalid<WriteSuccess>>(),
    );
    expect(ok(await s.getSnapshot(alpha))['dataVersion'], '2');

    final retry = ok(
      await s.patchAccountSelection(alpha, [kbAccount], w('2', 's1')),
    );
    expect(retry.replayed, isFalse, reason: '실패한 키에는 영수증이 남지 않음');
    final included = {
      for (final a in rows(retry.snapshot, 'accounts'))
        a['accountId']: a['included'],
    };
    expect(included[kbAccount], isTrue);
    expect(included.values.where((v) => v == true), hasLength(1));
  });

  test('state survives re-login; accounts stay isolated', () async {
    final world = _World();
    final first = await world.login(0);
    ok(await world.server.postInstitutionLinks(first, [_kb], w('1', 'l')));
    await world.auth.endSession(first);

    final second = await world.login(0);
    final again = ok(await world.server.getSnapshot(second));
    expect(
      rows(again, 'institutionLinks'),
      hasLength(1),
      reason: '재로그인해도 저장 상태 복원',
    );
    expect(again['dataVersion'], '2');
    expect(
      await world.server.getSnapshot(first),
      isA<FinancialSessionInvalid<Map<String, Object?>>>(),
    );

    final beta = await world.login(1);
    final betaSnap = ok(await world.server.getSnapshot(beta));
    expect(betaSnap['institutionLinks'], isEmpty, reason: '다른 계정 상태와 섞이지 않음');
    expect(betaSnap['userId'], '87f7bbf9-2355-5210-9325-f25d83a8ff35');
  });

  test(
    're-linking a subset keeps only selections that are still reachable',
    () async {
      final world = _World();
      final token = await world.login(0);
      final s = world.server;
      final linked = ok(
        await s.postInstitutionLinks(token, [_kb, 'bank.hana'], w('1', 'l1')),
      );
      final ids = [
        for (final a in rows(linked.snapshot, 'accounts'))
          a['accountId'] as String,
      ];
      ok(await s.patchAccountSelection(token, ids, w('2', 's1')));

      final narrowed = ok(
        await s.postInstitutionLinks(token, [_kb], w('3', 'l2')),
      );
      final accounts = rows(narrowed.snapshot, 'accounts');
      expect(accounts.every((a) => a['institutionCode'] == _kb), isTrue);
      expect(accounts.every((a) => a['included'] == true), isTrue);
    },
  );

  group('review fixes', () {
    test('① a session ended while the request waits is refused and nothing is saved', () async {
      final world = _SlowWorld();
      final a = devDemoAccounts.first;
      final issued = await world.auth.createSession(
        DemoCredentials(name: a.name, phone: a.phone, code: a.code),
      );
      final token = (issued as AuthOk<DemoSession>).value.accessToken;

      final write = world.server.postInstitutionLinks(token, [
        _kb,
      ], w('1', 'l'));
      final read = world.server.getSnapshot(token);
      await world.auth.endSession(token);
      world.gate.complete();

      expect(await write, isA<FinancialSessionInvalid<WriteSuccess>>());
      expect(await read, isA<FinancialSessionInvalid<Map<String, Object?>>>());
      final again = await world.auth.createSession(
        DemoCredentials(name: a.name, phone: a.phone, code: a.code),
      );
      final next = (again as AuthOk<DemoSession>).value.accessToken;
      final snap = ok(await world.server.getSnapshot(next));
      expect(snap['dataVersion'], '1', reason: '종료된 세션의 저장은 반영되지 않음');
      expect(snap['institutionLinks'], isEmpty);
    });

    test('① a closed session repository drops a late response', () async {
      final world = _SlowWorld();
      final a = devDemoAccounts.first;
      final issued = await world.auth.createSession(
        DemoCredentials(name: a.name, phone: a.phone, code: a.code),
      );
      final repo = FakeUserFinancialRepository(
        server: world.server,
        accessToken: (issued as AuthOk<DemoSession>).value.accessToken,
      );
      final pending = repo.loadSnapshot();
      repo.close();
      world.gate.complete();
      expect(
        await pending,
        isA<FinancialSessionInvalid<Map<String, Object?>>>(),
      );
      expect(
        await repo.loadSnapshot(),
        isA<FinancialSessionInvalid<Map<String, Object?>>>(),
      );
    });

    test(
      '② replayed receipt hides changedRefs the user can no longer see',
      () async {
        final world = _World();
        final token = await world.login(0);
        final s = world.server;
        final linked = ok(
          await s.postInstitutionLinks(token, [_kb, 'bank.hana'], w('1', 'l1')),
        );
        final hana =
            rows(linked.snapshot, 'accounts').firstWhere(
                  (a) => a['institutionCode'] == 'bank.hana',
                )['accountId']
                as String;
        final picked = ok(
          await s.patchAccountSelection(token, [hana], w('2', 's1')),
        );
        expect(picked.receipt.changedRefs.map((r) => r.id), contains(hana));

        ok(await s.postInstitutionLinks(token, [_kb], w('3', 'l2')));
        final replay = ok(
          await s.patchAccountSelection(token, [hana], w('2', 's1')),
        );
        expect(replay.replayed, isTrue);
        expect(
          replay.receipt.receiptId,
          picked.receipt.receiptId,
          reason: '영수증 식별은 유지',
        );
        expect(
          rows(replay.snapshot, 'accounts').any((a) => a['accountId'] == hana),
          isFalse,
        );
        expect(
          replay.receipt.changedRefs.any((r) => r.id == hana),
          isFalse,
          reason: '현재 권한 밖 changedRefs 제외',
        );
      },
    );

    test(
      '③ another user\'s row or a missing parent in the source is refused',
      () async {
        final (otherOwner, t1) = await _serverWith((src) {
          ((src['accounts'] as List).first as Map)['userId'] = 'someone-else';
        });
        expect(
          await otherOwner.getSnapshot(t1),
          isA<FinancialUnavailable<Map<String, Object?>>>(),
        );

        final (orphan, t2) = await _serverWith((src) {
          ((src['recurringPlanRevisions'] as List).first as Map)['planId'] =
              'missing-plan';
        });
        expect(
          await orphan.getSnapshot(t2),
          isA<FinancialUnavailable<Map<String, Object?>>>(),
        );
        expect(
          await orphan.postInstitutionLinks(t2, [_kb], w('1', 'l')),
          isA<FinancialUnavailable<WriteSuccess>>(),
          reason: '모순된 원본으로는 저장도 확정하지 않음',
        );
      },
    );

    test('1·2 contradictory sources make writes unavailable with no version or receipt change', () async {
      final (oldPlanField, t1) = await _serverWith((src) {
        ((src['recurringPlans'] as List).first as Map)['amountKRW'] = 1;
      });
      expect(
        await oldPlanField.postInstitutionLinks(t1, [_kb], w('1', 'l')),
        isA<FinancialUnavailable<WriteSuccess>>(),
      );

      final (ghostAccount, t2) = await _serverWith((src) {
        final purchase = (src['transactions'] as List).cast<Map>().firstWhere(
          (t) => t['recordKind'] == 'card_purchase',
        );
        purchase['accountId'] = 'aaaaaaaa-0000-4000-8000-000000000002';
      });
      expect(
        await ghostAccount.postInstitutionLinks(t2, _allAlpha, w('1', 'l')),
        isA<FinancialUnavailable<WriteSuccess>>(),
        reason: '원본에 없는 참조를 미연결로 바꿔 저장하지 않음',
      );
      expect(
        await ghostAccount.getSnapshot(t2),
        isA<FinancialUnavailable<Map<String, Object?>>>(),
      );
      expect(
        await ghostAccount.postInstitutionLinks(t2, _allAlpha, w('1', 'l')),
        isA<FinancialUnavailable<WriteSuccess>>(),
        reason: '같은 키 재시도도 replay가 아닌 같은 거절(영수증이 남지 않음)',
      );
    });

    test(
      '⑤ malformed source fields become service-unavailable, not exceptions',
      () async {
        final (nullVersion, t1) = await _serverWith(
          (src) => src['dataVersion'] = null,
        );
        expect(
          await nullVersion.getSnapshot(t1),
          isA<FinancialUnavailable<Map<String, Object?>>>(),
        );

        final (badCount, t2) = await _serverWith((src) {
          ((src['institutions'] as List).first as Map)['accountCount'] = 'bad';
        });
        expect(
          await badCount.postInstitutionLinks(t2, ['bank.kb'], w('1', 'l')),
          isA<FinancialUnavailable<WriteSuccess>>(),
        );
        expect(
          await badCount.getSnapshot(t2),
          isA<FinancialUnavailable<Map<String, Object?>>>(),
          reason: '원본을 열 때 타입을 검사하므로 조회도 서비스 불가',
        );

        final (badRow, t3) = await _serverWith(
          (src) => (src['accounts'] as List).add(42),
        );
        expect(
          await badRow.getSnapshot(t3),
          isA<FinancialUnavailable<Map<String, Object?>>>(),
        );
      },
    );
  });

  group('required source values and version range', () {
    test('null settings or missing institutions make reads and writes unavailable without a receipt', () async {
      final cases = <String, void Function(Map<String, Object?>)>{
        'settings null': (src) => src['settings'] = null,
        'institutions missing': (src) => src.remove('institutions'),
        'page missing': (src) => src.remove('page'),
      };
      for (final MapEntry(key: name, value: mutate) in cases.entries) {
        final (server, t) = await _serverWith(mutate);
        expect(
          await server.getSnapshot(t),
          isA<FinancialUnavailable<Map<String, Object?>>>(),
          reason: name,
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          expect(
            await server.postInstitutionLinks(t, ['bank.kb'], w('1', 'k')),
            isA<FinancialUnavailable<WriteSuccess>>(),
            reason: '$name: 같은 키 재시도도 replay가 아닌 서비스 불가',
          );
        }
        expect(
          await server.getSnapshot(t),
          isA<FinancialUnavailable<Map<String, Object?>>>(),
          reason: name,
        );
      }
    });

    test('versions outside bigint or at its limit do not throw', () async {
      final (tooLarge, t1) = await _serverWith(
        (src) => src['dataVersion'] = '9999999999999999999',
      );
      expect(
        await tooLarge.getSnapshot(t1),
        isA<FinancialUnavailable<Map<String, Object?>>>(),
      );

      final (normal, t2) = await _serverWith((_) {});
      expect(
        await normal.postInstitutionLinks(t2, [
          'bank.kb',
        ], w('9999999999999999999', 'k')),
        isA<FinancialInvalid<WriteSuccess>>(),
      );
      expect(ok(await normal.getSnapshot(t2))['dataVersion'], '1');

      const max = '9223372036854775807';
      final (atLimit, t3) = await _serverWith(
        (src) => src['dataVersion'] = max,
      );
      expect(ok(await atLimit.getSnapshot(t3))['dataVersion'], max);
      for (var attempt = 0; attempt < 2; attempt++) {
        expect(
          await atLimit.postInstitutionLinks(t3, ['bank.kb'], w(max, 'k')),
          isA<FinancialUnavailable<WriteSuccess>>(),
          reason: '더 증가할 수 없는 버전은 확정하지 않음(영수증 없음)',
        );
      }
      final after = ok(await atLimit.getSnapshot(t3));
      expect(after['dataVersion'], max);
      expect(after['institutionLinks'], isEmpty);
    });
  });

  group('session repository', () {
    test(
      'ignores a response older than one already seen in this session',
      () async {
        final world = _World();
        final token = await world.login(0);
        final repo = FakeUserFinancialRepository(
          server: world.server,
          accessToken: token,
        );
        ok(await repo.linkInstitutions([_kb], w('1', 'l')));

        final stale = _StaleServer(world);
        final staleRepo = FakeUserFinancialRepository(
          server: stale,
          accessToken: token,
        );
        ok(await staleRepo.linkInstitutions([_kb], w('1', 'l')));
        expect(
          await staleRepo.loadSnapshot(),
          isA<FinancialUnavailable<Map<String, Object?>>>(),
          reason: '낮은 버전은 반영하지 않음',
        );
      },
    );

    test('a repository of an ended session cannot read any more', () async {
      final world = _World();
      final token = await world.login(0);
      final repo = FakeUserFinancialRepository(
        server: world.server,
        accessToken: token,
      );
      ok(await repo.loadSnapshot());
      await world.auth.endSession(token);
      expect(
        await repo.loadSnapshot(),
        isA<FinancialSessionInvalid<Map<String, Object?>>>(),
      );
    });
  });

  group('PATCH /settings salary', () {
    const kbDemand = '6069b37a-abf5-56fc-8bf0-153f5301fd1c';
    const hanaDemand = '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc';
    const kbDeposit = '2c56e23d-2e82-59ed-8fce-21459e226167';

    /// 2026-10-28: 알파 전체 연결 뒤 국민·하나 입출금을 고른 토큰을 반환한다(자료 버전 3).
    Future<String> connected(_World world) async {
      final token = await world.login(0);
      ok(
        await world.server.postInstitutionLinks(token, _allAlpha, w('1', 'l')),
      );
      ok(
        await world.server.patchAccountSelection(token, [
          kbDemand,
          hanaDemand,
        ], w('2', 's')),
      );
      return token;
    }

    /// 2026-10-28: Snapshot의 settings.salary를 반환한다.
    Map<String, Object?> salaryOf(Map<String, Object?> snapshot) =>
        ((snapshot['settings']! as Map)['salary']! as Map)
            .cast<String, Object?>();

    test(
      'saves only the sent fields, bumps the version and reports settings',
      () async {
        final world = _World();
        final token = await connected(world);
        final before = ok(await world.server.getSnapshot(token));

        final saved = ok(
          await world.server.patchSettings(
            token,
            const SalaryPatch(
              salaryDay: (value: 10),
              salaryAccountId: (value: hanaDemand),
            ),
            w('3', 'p'),
          ),
        );
        expect(saved.replayed, isFalse);
        expect(saved.receipt.resultVersion, '4');
        expect(saved.snapshot['dataVersion'], '4');
        expect(saved.receipt.changedRefs.map((r) => (r.resource, r.id)), [
          ('settings', 'f0a4be6c-01d7-53eb-ab2c-74675b22fd8c'),
        ]);
        final salary = salaryOf(saved.snapshot);
        expect(salary['salaryDay'], 10);
        expect(salary['salaryAccountId'], hanaDemand);
        expect(salary['salaryAmountKRW'], 3000000, reason: '보내지 않은 필드는 그대로');
        expect(salary['receiptEvidence'], salaryOf(before)['receiptEvidence']);
        expect(saved.snapshot['sourceVersion'], before['sourceVersion']);
        expect(saved.snapshot['asOf'], before['asOf']);
        expect(
          saved.snapshot['accounts'],
          before['accounts'],
          reason: '잔액·원천 불변',
        );
      },
    );

    test('null clears a field while omission keeps it', () async {
      final world = _World();
      final token = await connected(world);
      final saved = ok(
        await world.server.patchSettings(
          token,
          const SalaryPatch(salaryAmountKrw: (value: null)),
          w('3', 'p'),
        ),
      );
      final salary = salaryOf(saved.snapshot);
      expect(salary.containsKey('salaryAmountKRW'), isTrue);
      expect(salary['salaryAmountKRW'], isNull);
      expect(salary['salaryDay'], 25);
    });

    test(
      'same key and body replays; same key with another body is 409',
      () async {
        final world = _World();
        final token = await connected(world);
        const patch = SalaryPatch(salaryAmountKrw: (value: 3100000));
        final first = ok(
          await world.server.patchSettings(token, patch, w('3', 'p')),
        );
        final again = ok(
          await world.server.patchSettings(token, patch, w('3', 'p')),
        );
        expect(again.replayed, isTrue);
        expect(again.receipt.receiptId, first.receipt.receiptId);
        expect(again.snapshot['dataVersion'], '4', reason: '다시 저장하지 않음');
        expect(
          await world.server.patchSettings(
            token,
            const SalaryPatch(salaryAmountKrw: (value: 3200000)),
            w('3', 'p'),
          ),
          isA<FinancialIdempotencyConflict<WriteSuccess>>(),
        );
        expect(
          await world.server.patchSettings(
            token,
            const SalaryPatch(salaryAmountKrw: (value: null)),
            w('3', 'p'),
          ),
          isA<FinancialIdempotencyConflict<WriteSuccess>>(),
          reason: 'null과 다른 값은 다른 요청',
        );
      },
    );

    test(
      'stale data and rule versions are 409 kinds and change nothing',
      () async {
        final world = _World();
        final token = await connected(world);
        const patch = SalaryPatch(salaryDay: (value: 1));
        expect(
          await world.server.patchSettings(token, patch, w('2', 'a')),
          isA<FinancialStaleData<WriteSuccess>>(),
        );
        expect(
          await world.server.patchSettings(
            token,
            patch,
            w('3', 'b', rule: 'X'),
          ),
          isA<FinancialRuleVersionMismatch<WriteSuccess>>(),
        );
        final now = ok(await world.server.getSnapshot(token));
        expect(now['dataVersion'], '3');
        expect(salaryOf(now)['salaryDay'], 25);
      },
    );

    test('422 for empty or out of range values and unselected accounts; 403 for unreachable', () async {
      final world = _World();
      final token = await connected(world);
      final cases = <(SalaryPatch, Type)>[
        (const SalaryPatch(), FinancialInvalid<WriteSuccess>),
        (
          const SalaryPatch(salaryDay: (value: 0)),
          FinancialInvalid<WriteSuccess>,
        ),
        (
          const SalaryPatch(salaryDay: (value: 32)),
          FinancialInvalid<WriteSuccess>,
        ),
        (
          const SalaryPatch(salaryAmountKrw: (value: -1)),
          FinancialInvalid<WriteSuccess>,
        ),
        (
          const SalaryPatch(salaryAmountKrw: (value: 9000000000001)),
          FinancialInvalid<WriteSuccess>,
        ),
        (
          const SalaryPatch(salaryAccountId: (value: kbDeposit)),
          FinancialInvalid<WriteSuccess>,
        ),
        (
          const SalaryPatch(salaryAccountId: (value: 'no-such-account')),
          FinancialForbidden<WriteSuccess>,
        ),
      ];
      var i = 0;
      for (final (patch, type) in cases) {
        final result = await world.server.patchSettings(
          token,
          patch,
          w('3', 'k${i++}'),
        );
        expect(result.runtimeType, type, reason: patch.toJson().toString());
      }
      final now = ok(await world.server.getSnapshot(token));
      expect(now['dataVersion'], '3', reason: '실패는 아무것도 바꾸지 않음');
    });

    test('an account of an unlinked institution is 403', () async {
      final world = _World();
      final token = await world.login(0);
      ok(await world.server.postInstitutionLinks(token, [_kb], w('1', 'l')));
      ok(
        await world.server.patchAccountSelection(token, [
          kbDemand,
        ], w('2', 's')),
      );
      expect(
        await world.server.patchSettings(
          token,
          const SalaryPatch(salaryAccountId: (value: hanaDemand)),
          w('3', 'p'),
        ),
        isA<FinancialForbidden<WriteSuccess>>(),
      );
    });

    test('saved settings survive re-login and later writes; other users are untouched', () async {
      final world = _World();
      final token = await connected(world);
      ok(
        await world.server.patchSettings(
          token,
          const SalaryPatch(salaryDay: (value: 5)),
          w('3', 'p'),
        ),
      );
      ok(
        await world.server.patchAccountSelection(token, [
          kbDemand,
        ], w('4', 's2')),
      );
      await world.auth.endSession(token);
      final second = await world.login(0);
      final again = ok(await world.server.getSnapshot(second));
      expect(salaryOf(again)['salaryDay'], 5);
      expect(again['dataVersion'], '5');

      final beta = await world.login(1);
      final betaToken = beta;
      ok(
        await world.server.postInstitutionLinks(betaToken, const [
          'bank.kb',
        ], w('1', 'bl')),
      );
      final betaSnap = ok(await world.server.getSnapshot(betaToken));
      expect(salaryOf(betaSnap)['salaryDay'], isNot(5));
    });

    test('the session repository sends the patch and drops late responses after close', () async {
      final world = _World();
      final token = await connected(world);
      final repo = FakeUserFinancialRepository(
        server: world.server,
        accessToken: token,
      );
      final saved = ok(
        await repo.updateSalarySettings(
          const SalaryPatch(salaryDay: (value: 7)),
          w('3', 'p'),
        ),
      );
      expect(salaryOf(saved.snapshot)['salaryDay'], 7);
      repo.close();
      expect(
        await repo.updateSalarySettings(
          const SalaryPatch(salaryDay: (value: 8)),
          w('4', 'q'),
        ),
        isA<FinancialSessionInvalid<WriteSuccess>>(),
      );
    });
  });
}

/// 2026-10-22: 조회에서 버전 1의 옛 스냅샷을 돌려주는 서버(늦게 도착한 응답 흉내).
class _StaleServer extends FakeFinancialServer {
  /// 2026-10-22: [world]의 인증·원본으로 만든다.
  _StaleServer(_World world)
    : super(
        sessions: world.auth,
        loadSource: (userId) async => readSource(_sources[userId]!),
      );

  /// 2026-10-22: 항상 연결 전 버전 1 스냅샷을 돌려준다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> getSnapshot(
    String accessToken,
  ) async => FinancialOk({...readSource('alpha-ready'), 'dataVersion': '1'});
}

/// 2026-10-22: 원본 로딩을 [gate]가 열릴 때까지 늦추는 가짜 서버 묶음.
class _SlowWorld {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final Completer<void> gate = Completer<void>();
  late final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (userId) async {
      await gate.future;
      return readSource(_sources[userId]!);
    },
  );
}

/// 2026-10-22: 원본을 [mutate]로 바꾼 사본을 쓰는 가짜 서버와 alpha 토큰을 만든다.
Future<(FakeFinancialServer, String)> _serverWith(
  void Function(Map<String, Object?> source) mutate,
) async {
  final auth = FakeAuthRepository(accounts: devDemoAccounts);
  final server = FakeFinancialServer(
    sessions: auth,
    loadSource: (userId) async => readSource(_sources[userId]!)..apply(mutate),
  );
  final a = devDemoAccounts.first;
  final r = await auth.createSession(
    DemoCredentials(name: a.name, phone: a.phone, code: a.code),
  );
  return (server, (r as AuthOk<DemoSession>).value.accessToken);
}

extension on Map<String, Object?> {
  /// 2026-10-22: [mutate]를 적용하고 자신을 반환한다.
  Map<String, Object?> apply(void Function(Map<String, Object?>) mutate) {
    mutate(this);
    return this;
  }
}
