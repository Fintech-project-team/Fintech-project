import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/dev_demo_accounts.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/connection/fake_financial_server.dart';
import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/connection/connection_flow_controller.dart';
import 'package:payse/features/connection/connection_presentation_policy.dart';

import '../../data/connection/connection_test_utils.dart';
import 'connection_test_support.dart';

/// 2026-10-22: 연결 전 beta Snapshot으로 흐름 상태를 만든다.
ConnectionFlowController _controller(
  UserFinancialRepository repo, {
  ConnectionPresentationPolicy? policy,
  void Function()? onSessionInvalid,
  FinancialSnapshot? snapshot,
}) => ConnectionFlowController(
  repository: repo,
  snapshot: snapshot ?? betaSnapshot(const {}),
  policy: policy ?? instantPolicy(),
  onSessionInvalid: onSessionInvalid ?? () {},
  random: Random(7),
);

/// 2026-10-22: [codes]를 고르고 모두 동의한 뒤 불러오기 연출을 끝낸다.
Future<void> _loadAll(ConnectionFlowController c, Set<String> codes) async {
  for (final code in codes) {
    c.toggleChosen(code);
  }
  c.enterConsent();
  c.setAllConsent(true);
  await c.startLoading();
}

void main() {
  group('choosing and consenting', () {
    test(
      'nothing is chosen at first and card-only is flagged only after choosing',
      () {
        final c = _controller(ScriptedRepository());
        expect(c.chosenInstitutions, isEmpty);
        expect(c.chosenCardOnly, isFalse, reason: '처음에는 경고 없음');
        expect(c.hasChosenBank, isFalse);
        c.toggleChosen('card.hyundai');
        expect(c.chosenCardOnly, isTrue);
        expect(c.hasChosenBank, isFalse);
        c.toggleChosen('bank.kb');
        expect(c.chosenCardOnly, isFalse);
        expect(c.hasChosenBank, isTrue);
      },
    );

    test(
      'consent starts empty, keeps only chosen institutions and needs a bank',
      () {
        final c = _controller(ScriptedRepository());
        c
          ..toggleChosen('bank.kb')
          ..toggleChosen('card.hyundai')
          ..enterConsent();
        expect(c.isConsented('bank.kb'), isFalse);
        c.toggleConsent('card.hyundai');
        expect(c.consentedCardOnly, isTrue);
        expect(c.hasConsentedBank, isFalse);
        c.setAllConsent(true);
        expect(c.allConsented, isTrue);
        c
          ..toggleChosen('bank.kb')
          ..enterConsent();
        expect(c.isConsented('bank.kb'), isFalse, reason: '고르지 않은 기관 동의는 지움');
      },
    );
  });

  group('loading presentation', () {
    test(
      'the toggle is read just before the first draw and fixed for that flow',
      () async {
        var enabled = true;
        var reads = 0;
        final policy = ConnectionPresentationPolicy(
          failuresEnabled: () {
            reads++;
            return enabled;
          },
          random: SequenceRandom(doubles: [0.05]),
          wait: (_) async {},
        );

        final before = _controller(ScriptedRepository(), policy: policy);
        enabled = false;
        await _loadAll(before, {'bank.kb', 'bank.shinhan'});
        expect(
          before.failedInstitutions,
          isEmpty,
          reason: '추첨 전 변경은 현재 흐름에 적용',
        );
        expect(reads, 1);

        enabled = true;
        final drawn = _controller(ScriptedRepository(), policy: policy);
        await _loadAll(drawn, {'bank.kb', 'bank.shinhan'});
        expect(drawn.failedInstitutions.map((i) => i.code), [
          'bank.kb',
          'bank.shinhan',
        ]);
        enabled = false;
        drawn.toggleChosen('bank.shinhan');
        drawn.enterConsent();
        await drawn.startLoading();
        expect(drawn.failedInstitutions.map((i) => i.code), [
          'bank.kb',
        ], reason: '추첨 후 변경·뒤로 갔다 다시 진행해도 재추첨 없음');
        await drawn.retry('bank.kb');
        expect(drawn.failedInstitutions, isEmpty);
        expect(reads, 2, reason: '다시 진행·다시 시도에서 토글을 다시 읽지 않음');

        final next = _controller(ScriptedRepository(), policy: policy);
        await _loadAll(next, {'bank.kb', 'bank.shinhan'});
        expect(next.failedInstitutions, isEmpty, reason: '다음 새 흐름부터 적용');
        expect(reads, 3);
      },
    );

    test(
      'failures are drawn once per flow and a retry never fails again',
      () async {
        final draws = <List<String>>[];
        final policy = _CountingPolicy(draws, {'bank.shinhan'});
        final c = _controller(ScriptedRepository(), policy: policy);
        await _loadAll(c, {'bank.kb', 'bank.shinhan', 'card.hyundai'});
        expect(c.loadStatusOf('bank.shinhan'), InstitutionLoadStatus.failed);
        expect(c.finalCodes, ['bank.kb', 'card.hyundai']);
        expect(c.loadInProgress, isFalse);
        await c.retry('bank.shinhan');
        expect(c.loadStatusOf('bank.shinhan'), InstitutionLoadStatus.done);
        await c.startLoading();
        expect(c.finalCodes, ['bank.kb', 'bank.shinhan', 'card.hyundai']);
        c.toggleConsent('card.hyundai');
        await c.startLoading();
        expect(c.finalCodes, [
          'bank.kb',
          'bank.shinhan',
        ], reason: '동의가 바뀌면 다시 불러옴');
        expect(draws, hasLength(1), reason: '같은 흐름에서 다시 추첨하지 않음');
        expect(
          c.loadStatusOf('bank.shinhan'),
          InstitutionLoadStatus.done,
          reason: '다시 시도로 완료한 기관은 재실패하지 않음',
        );
      },
    );

    test('when every bank fails the flow cannot save', () async {
      final repo = ScriptedRepository();
      final c = _controller(repo, policy: _CountingPolicy([], {'bank.kb'}));
      await _loadAll(c, {'bank.kb', 'card.hyundai'});
      expect(c.finalHasBank, isFalse);
      expect(await c.saveLinks(), isFalse);
      expect(repo.linkCalls, isEmpty);
    });
  });

  group('saving the connection', () {
    test(
      'a lost response retries with the same key; a new action gets a new key',
      () async {
        final repo = ScriptedRepository()
          ..linkResults.addAll([
            const FinancialUnavailable(),
            written(betaJson({'bank.kb', 'card.hyundai'}, version: '2')),
            written(betaJson({'bank.kb', 'card.hyundai'}, version: '3')),
          ]);
        final c = _controller(repo);
        await _loadAll(c, {'bank.kb', 'card.hyundai'});
        expect(await c.saveLinks(), isFalse);
        expect(
          (c.linkSave as SaveFailed).failure,
          ConnectionSaveFailure.retryable,
        );
        expect(await c.saveLinks(), isTrue);
        expect(c.snapshot.dataVersion, '2');
        expect(await c.saveLinks(), isTrue, reason: '01-1에서 돌아와 다시 계속하기');
        final keys = [
          for (final call in repo.linkCalls) call.$2.idempotencyKey,
        ];
        expect(keys[0], keys[1]);
        expect(keys[2], isNot(keys[1]));
        expect(repo.linkCalls[2].$2.expectedDataVersion, '2');
        expect(repo.linkCalls.first.$1, ['bank.kb', 'card.hyundai']);
      },
    );

    test(
      'rejected, outdated and session-ended results are told apart',
      () async {
        var ended = 0;
        final repo = ScriptedRepository()
          ..linkResults.addAll([
            const FinancialInvalid(),
            const FinancialStaleData(),
            const FinancialRuleVersionMismatch(),
            const FinancialSessionInvalid(),
          ])
          ..loadResults.add(FinancialOk(betaJson(const {}, version: '5')));
        final c = _controller(repo, onSessionInvalid: () => ended++);
        await _loadAll(c, {'bank.kb'});
        await c.saveLinks();
        expect(
          (c.linkSave as SaveFailed).failure,
          ConnectionSaveFailure.rejected,
        );
        await c.saveLinks();
        expect(
          (c.linkSave as SaveFailed).failure,
          ConnectionSaveFailure.outdated,
        );
        expect(
          repo.linkCalls[1].$2.idempotencyKey,
          isNot(repo.linkCalls[0].$2.idempotencyKey),
        );
        await c.saveLinks();
        expect(
          (c.linkSave as SaveFailed).failure,
          ConnectionSaveFailure.outdated,
        );
        await c.reload();
        expect(c.snapshot.dataVersion, '5');
        expect(c.linkSave, isA<SaveIdle>());
        await c.saveLinks();
        expect(ended, 1);
        expect(repo.linkCalls.last.$2.expectedDataVersion, '5');
      },
    );

    test('a response that arrives after leaving the flow is ignored', () async {
      final pending = Completer<FinancialOutcome<WriteSuccess>>();
      final repo = _PendingRepository(pending.future);
      final c = _controller(repo);
      await _loadAll(c, {'bank.kb'});
      final saving = c.saveLinks();
      expect(c.linkSave, isA<SaveInProgress>());
      expect(await _secondSave(c), isFalse, reason: '저장 중 중복 요청 없음');
      c.dispose();
      pending.complete(written(betaJson({'bank.kb'}, version: '2')));
      expect(await saving, isFalse);
      expect(repo.calls, 1);
    });

    test(
      'a failed row cannot be retried while the connection is saving',
      () async {
        final pending = Completer<FinancialOutcome<WriteSuccess>>();
        final repo = _PendingRepository(pending.future);
        final c = _controller(repo, policy: instantPolicy(draws: [0.5, 0.05]));
        await _loadAll(c, {'bank.kb', 'bank.shinhan'});
        expect(c.finalCodes, ['bank.kb']);
        final saving = c.saveLinks();
        await c.retry('bank.shinhan');
        expect(
          c.loadStatusOf('bank.shinhan'),
          InstitutionLoadStatus.failed,
          reason: '저장 중인 목록(국민)과 표시가 어긋나지 않음',
        );
        pending.complete(written(betaJson({'bank.kb'}, version: '2')));
        expect(await saving, isTrue);
        await c.retry('bank.shinhan');
        expect(c.loadStatusOf('bank.shinhan'), InstitutionLoadStatus.done);
      },
    );

    test(
      'reloading shows progress, ignores repeats and keeps failures visible',
      () async {
        final repo = _PendingLoadRepository()
          ..linkResults.addAll([
            const FinancialStaleData(),
            written(betaJson({'bank.kb'}, version: '5')),
          ]);
        final c = _controller(repo);
        await _loadAll(c, {'bank.kb'});
        await c.saveLinks();
        expect(c.reloadStatus, ReloadStatus.idle);

        final first = c.reload();
        expect(c.reloadStatus, ReloadStatus.loading);
        await c.reload();
        expect(repo.loads, 1, reason: '읽는 중 중복 요청 없음');
        expect(await c.saveLinks(), isFalse, reason: '읽는 중 저장 없음');
        expect(repo.linkCalls, hasLength(1));
        repo.pending.removeFirst().complete(const FinancialUnavailable());
        await first;
        expect(c.reloadStatus, ReloadStatus.failed);
        expect(
          (c.linkSave as SaveFailed).failure,
          ConnectionSaveFailure.outdated,
        );

        final malformed = c.reload();
        repo.pending.removeFirst().complete(const FinancialOk({}));
        await malformed;
        expect(c.reloadStatus, ReloadStatus.failed, reason: '형식 오류도 실패');

        final ok = c.reload();
        repo.pending.removeFirst().complete(
          FinancialOk(betaJson(const {}, version: '4')),
        );
        await ok;
        expect(c.reloadStatus, ReloadStatus.idle);
        expect(c.linkSave, isA<SaveIdle>());
        expect(await c.saveLinks(), isTrue);
        expect(repo.linkCalls.last.$2.expectedDataVersion, '4');
      },
    );
  });

  group('choosing accounts', () {
    test('demand accounts start selected, deposits and savings do not', () {
      final c = _controller(
        ScriptedRepository(),
        snapshot: betaSnapshot({...betaBanks}),
      );
      for (final a in c.accounts) {
        expect(
          c.isAccountSelected(a.accountId),
          a.productType == 'demand',
          reason: a.productName,
        );
      }
    });

    test('unchecking an account with a reserve warns every time', () {
      final c = _controller(
        ScriptedRepository(),
        snapshot: betaSnapshot({...betaBanks}),
      );
      final kb = c.accounts.first.accountId;
      expect(c.reservesOf(kb).single.label, '현재 비상금');
      c.toggleAccount(kb);
      expect(c.reserveNoticeAccount, kb);
      c.toggleAccount(kb);
      expect(c.reserveNoticeAccount, isNull);
      c.toggleAccount(kb);
      expect(c.reserveNoticeAccount, kb, reason: '해제할 때마다 안내');
      final plain = c.accounts[2].accountId;
      c.toggleAccount(plain);
      expect(c.reserveNoticeAccount, isNull, reason: '모아둘 돈이 없는 계좌는 안내 없음');
    });

    test(
      'zero accounts cannot be saved and the saved set keeps list order',
      () async {
        final repo = ScriptedRepository()
          ..selectResults.add(
            written(betaJson({...betaBanks}, selected: {}, version: '3')),
          );
        final c = _controller(repo, snapshot: betaSnapshot({...betaBanks}));
        for (final a in c.accounts) {
          if (c.isAccountSelected(a.accountId)) c.toggleAccount(a.accountId);
        }
        expect(c.canSaveSelection, isFalse);
        expect(await c.saveSelection(), isFalse);
        c
          ..toggleAccount(c.accounts[4].accountId)
          ..toggleAccount(c.accounts[0].accountId);
        expect(await c.saveSelection(), isTrue);
        expect(repo.selectCalls.single.$1, [
          c.accounts[0].accountId,
          c.accounts[4].accountId,
        ]);
      },
    );
  });

  test('works end to end against the fake financial server', () async {
    final auth = FakeAuthRepository(accounts: devDemoAccounts);
    final server = FakeFinancialServer(
      sessions: auth,
      loadSource: (userId) async => readSource('beta-ready'),
    );
    final beta = devDemoAccounts[1];
    final session = (await auth.createSession(
      DemoCredentials(name: beta.name, phone: beta.phone, code: beta.code),
    ) as AuthOk<DemoSession>).value;
    final repo = FakeUserFinancialRepository(
      server: server,
      accessToken: session.accessToken,
    );
    final first = await repo.loadSnapshot();
    final c = _controller(
      repo,
      snapshot: FinancialSnapshot.fromJson(
        (first as FinancialOk<Map<String, Object?>>).value,
      ),
    );
    await _loadAll(c, {'bank.kb', 'card.hyundai'});
    expect(await c.saveLinks(), isTrue);
    expect(c.snapshot.institutionLinkCount, 2);
    expect(
      c.snapshot.accounts!.every((a) => !a.included),
      isTrue,
      reason: '연결만으로 계좌 선택을 확정하지 않음',
    );
    expect(await c.saveSelection(), isTrue);
    expect(
      c.snapshot.accounts!.where((a) => a.included).map((a) => a.productType),
      ['demand'],
    );
  });
}

/// 2026-10-22: 저장 중 상태에서 다시 저장을 누른 결과를 반환한다.
Future<bool> _secondSave(ConnectionFlowController c) => c.saveLinks();

/// 2026-10-22: 추첨 횟수를 기록하고 정해 둔 기관을 실패시키는 표시 정책.
class _CountingPolicy extends ConnectionPresentationPolicy {
  /// 2026-10-22: 추첨 기록 [draws]와 실패 기관 [failing]으로 만든다.
  _CountingPolicy(this.draws, this.failing)
    : super(failuresEnabled: () => true, wait: (_) async {});

  final List<List<String>> draws;
  final Set<String> failing;

  /// 2026-10-22: 추첨을 기록하고 [failing] 중 대상에 있는 기관을 반환한다.
  @override
  Set<String> drawFailures(List<String> codes) {
    draws.add(codes);
    return {
      for (final c in codes)
        if (failing.contains(c)) c,
    };
  }
}

/// 2026-10-22: 연결 저장 응답이 [result]가 끝날 때까지 오지 않는 저장소.
class _PendingRepository extends ScriptedRepository {
  /// 2026-10-22: 늦게 끝날 응답 [result]로 만든다.
  _PendingRepository(this.result);

  final Future<FinancialOutcome<WriteSuccess>> result;
  int calls = 0;

  /// 2026-10-22: 호출 수를 세고 늦게 끝날 응답을 반환한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> institutionCodes,
    WriteContext write,
  ) {
    calls++;
    return result;
  }
}

/// 2026-10-23: 조회 응답을 테스트가 끝낼 때까지 기다리게 하고 조회 수를 세는 저장소.
class _PendingLoadRepository extends ScriptedRepository {
  final Queue<Completer<FinancialOutcome<Map<String, Object?>>>> pending =
      Queue();
  int loads = 0;

  /// 2026-10-23: 조회 수를 세고 테스트가 끝낼 응답을 반환한다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() {
    loads++;
    final completer = Completer<FinancialOutcome<Map<String, Object?>>>();
    pending.add(completer);
    return completer.future;
  }
}
