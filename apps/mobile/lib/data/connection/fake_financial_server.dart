import 'dart:convert';
import 'dart:math';

import '../auth/auth_repository.dart';
import '../auth/random_id.dart';
import 'financial_api.dart';
import 'snapshot_projector.dart';

/// 2026-10-22: 사용자 ID에 해당하는 불변 원본(PAYSE-DRAFT-2) JSON을 읽는 경계. 실제 API 도입 시 서버 쪽 책임이다.
typedef UserSourceLoader = Future<Map<String, Object?>> Function(String userId);

/// 2026-10-22: 금융 조회·연결 쓰기를 흉내 내는 앱 수명 가짜 서버(서버 장부 역할). 사용자별 불변 원본과 가변 상태
/// (연결 기록·계좌 선택·자료 버전·작업 영수증)를 분리해 재로그인까지 상태를 유지한다. 메모리 구현이며 실제 서버 영속화가 아니다.
class FakeFinancialServer {
  /// 2026-10-22: 토큰→사용자 [sessions], 원본 [loadSource], 시각 [now], 난수 [random]으로 만든다.
  FakeFinancialServer({
    required this.sessions,
    required this.loadSource,
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  final SessionResolver sessions;
  final UserSourceLoader loadSource;
  final DateTime Function() _now;
  final Random _random;
  final Map<String, Map<String, Object?>> _sources = {};
  final Map<String, _UserLedger> _ledgers = {};

  static final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
  static final RegExp _versionPattern = RegExp(r'^[1-9][0-9]{0,18}$');

  /// 2026-10-22: data_version(bigint) 상한. 이 값의 자료 버전은 더 증가할 수 없다.
  static const int _maxVersion = 9223372036854775807;

  /// 2026-10-22: [value]가 1 이상 bigint 범위의 10진 자료 버전이면 true를 반환한다.
  static bool _isVersion(Object? value) =>
      value is String &&
      _versionPattern.hasMatch(value) &&
      int.tryParse(value) != null;

  /// 2026-10-22: GET /snapshot. 토큰의 사용자 원본과 현재 상태로 투영한 Snapshot을 반환한다.
  Future<FinancialOutcome<Map<String, Object?>>> getSnapshot(
    String accessToken,
  ) async {
    final userId = sessions.userIdForToken(accessToken);
    if (userId == null) return const FinancialSessionInvalid();
    final opened = await _open(userId);
    if (opened == null) return const FinancialUnavailable();
    if (sessions.userIdForToken(accessToken) != userId) {
      return const FinancialSessionInvalid();
    }
    final (source, ledger) = opened;
    return _project(source, ledger.state);
  }

  /// 2026-10-22: POST /institution-links. 제공 기관만·중복 없음·계좌를 제공하는 은행 최소 1곳을 검사한다.
  Future<FinancialOutcome<WriteSuccess>> postInstitutionLinks(
    String accessToken,
    List<String> institutionCodes,
    WriteContext write,
  ) => _write(
    accessToken: accessToken,
    method: 'POST',
    path: '/institution-links',
    body: institutionCodes,
    write: write,
    apply: (source, state) {
      if (institutionCodes.isEmpty ||
          institutionCodes.toSet().length != institutionCodes.length) {
        return const FinancialInvalid();
      }
      final offered = {
        for (final i in source['institutions'] as List)
          (i as Map)['code'] as String: i,
      };
      if (institutionCodes.any((c) => !offered.containsKey(c))) {
        return const FinancialForbidden();
      }
      final hasBankWithAccounts = institutionCodes.any((c) {
        final inst = offered[c] as Map;
        return inst['kind'] == 'bank' && (inst['accountCount'] as int) > 0;
      });
      if (!hasBankWithAccounts) return const FinancialInvalid();
      final previous = {
        for (final l in state.institutionLinks)
          l['institutionCode'] as String: l,
      };
      final links = [
        for (final code in institutionCodes)
          previous[code] ??
              {
                'userId': source['userId'],
                'linkId': randomUuidV4(_random),
                'institutionCode': code,
                'consentedAt': _now().toUtc().toIso8601String(),
                'disconnectedAt': null,
              },
      ];
      final connected = institutionCodes.toSet();
      final keptSelection = state.selectedAccountIds?.where((id) {
        final account = (source['accounts'] as List?)?.cast<Map>().where(
          (a) => a['accountId'] == id,
        );
        return account != null &&
            account.isNotEmpty &&
            connected.contains(account.first['institutionCode']);
      }).toSet();
      return FinancialOk((
        institutionLinks: links,
        selectedAccountIds: keptSelection,
        changed: [
          for (final l in links)
            ChangedRef(resource: 'institutionLink', id: l['linkId'] as String),
        ],
      ));
    },
  );

  /// 2026-10-22: PATCH /account-selection. 연결·조회 가능한 계좌 1개 이상의 전체 집합으로 교체한다.
  Future<FinancialOutcome<WriteSuccess>> patchAccountSelection(
    String accessToken,
    List<String> accountIds,
    WriteContext write,
  ) => _write(
    accessToken: accessToken,
    method: 'PATCH',
    path: '/account-selection',
    body: accountIds,
    write: write,
    apply: (source, state) {
      if (accountIds.isEmpty ||
          accountIds.toSet().length != accountIds.length) {
        return const FinancialInvalid();
      }
      final connected = state.connectedCodes;
      final reachable = {
        for (final a in (source['accounts'] as List?) ?? const [])
          if (connected.contains((a as Map)['institutionCode']))
            a['accountId'] as String,
      };
      if (accountIds.any((id) => !reachable.contains(id))) {
        return const FinancialForbidden();
      }
      final next = accountIds.toSet();
      final before = state.selectedAccountIds ?? const <String>{};
      return FinancialOk((
        institutionLinks: state.institutionLinks,
        selectedAccountIds: next,
        changed: [
          for (final id in {...next, ...before})
            if (next.contains(id) != before.contains(id))
              ChangedRef(resource: 'account', id: id),
        ],
      ));
    },
  );

  /// 2026-10-22: 금융 쓰기 공통 절차(§5). 형식 → 같은 키 replay/충돌 → 규칙·자료 버전 → 소유권·제약 → 상태·영수증·버전을
  /// 한 번에 확정한다. 중간 실패는 아무것도 바꾸지 않는다.
  Future<FinancialOutcome<WriteSuccess>> _write({
    required String accessToken,
    required String method,
    required String path,
    required List<String> body,
    required WriteContext write,
    required FinancialOutcome<_Change> Function(
      Map<String, Object?> source,
      ProjectionState state,
    )
    apply,
  }) async {
    final userId = sessions.userIdForToken(accessToken);
    if (userId == null) return const FinancialSessionInvalid();
    if (!_keyPattern.hasMatch(write.idempotencyKey) ||
        !_isVersion(write.expectedDataVersion) ||
        write.ruleVersion.isEmpty) {
      return const FinancialInvalid();
    }
    final opened = await _open(userId);
    if (opened == null) return const FinancialUnavailable();
    if (sessions.userIdForToken(accessToken) != userId) {
      return const FinancialSessionInvalid();
    }
    final (source, ledger) = opened;
    return _commit(source, ledger, method, path, body, write, apply);
  }

  /// 2026-10-22: 대기 없이 한 번에 판정·확정한다(세션 재확인 뒤 중간에 다른 작업이 끼지 않음).
  FinancialOutcome<WriteSuccess> _commit(
    Map<String, Object?> source,
    _UserLedger ledger,
    String method,
    String path,
    List<String> body,
    WriteContext write,
    FinancialOutcome<_Change> Function(
      Map<String, Object?> source,
      ProjectionState state,
    )
    apply,
  ) {
    final fingerprint = jsonEncode([
      method,
      path,
      write.expectedDataVersion,
      write.ruleVersion,
      body,
    ]);
    final previous = ledger.receipts[write.idempotencyKey];
    if (previous != null) {
      if (previous.fingerprint != fingerprint) {
        return const FinancialIdempotencyConflict();
      }
      return _success(source, ledger.state, previous.receipt, replayed: true);
    }
    if (write.ruleVersion != source['ruleVersion']) {
      return const FinancialRuleVersionMismatch();
    }
    if (write.expectedDataVersion != ledger.state.dataVersion) {
      return const FinancialStaleData();
    }
    final change = apply(source, ledger.state);
    if (change is! FinancialOk<_Change>) {
      return switch (change) {
        FinancialForbidden() => const FinancialForbidden(),
        _ => const FinancialInvalid(),
      };
    }
    final current = int.parse(ledger.state.dataVersion);
    if (current == _maxVersion) return const FinancialUnavailable();
    final nextVersion = (current + 1).toString();
    final nextState = ProjectionState(
      institutionLinks: change.value.institutionLinks,
      selectedAccountIds: change.value.selectedAccountIds,
      dataVersion: nextVersion,
    );
    final projected = _project(source, nextState);
    if (projected is! FinancialOk<Map<String, Object?>>) {
      return const FinancialUnavailable();
    }
    final receipt = WriteReceipt(
      receiptId: randomUuidV4(_random),
      operationKey: write.idempotencyKey,
      resultVersion: nextVersion,
      createdAt: _now(),
      changedRefs: change.value.changed,
    );
    ledger.state = nextState;
    ledger.receipts[write.idempotencyKey] = _StoredReceipt(
      fingerprint,
      receipt,
    );
    return FinancialOk(
      WriteSuccess(
        receipt: _publicReceipt(receipt, nextState, projected.value),
        replayed: false,
        snapshot: projected.value,
      ),
    );
  }

  /// 2026-10-22: 응답용 영수증을 만든다. 내부 영수증은 그대로 두고, changedRefs는 현재 조회 권한으로 보이는 자원만 남긴다
  /// (api-contract §5: 조회 권한이 제한된 changedRefs 제외). replay에서도 현재 권한 기준이다.
  WriteReceipt _publicReceipt(
    WriteReceipt receipt,
    ProjectionState state,
    Map<String, Object?> snapshot,
  ) {
    final links = {
      for (final l in state.institutionLinks) l['linkId'] as String,
    };
    final accounts = {
      for (final a in (snapshot['accounts'] as List?) ?? const [])
        (a as Map)['accountId'] as String,
    };
    return WriteReceipt(
      receiptId: receipt.receiptId,
      operationKey: receipt.operationKey,
      resultVersion: receipt.resultVersion,
      createdAt: receipt.createdAt,
      changedRefs: [
        for (final ref in receipt.changedRefs)
          if ((ref.resource == 'institutionLink' && links.contains(ref.id)) ||
              (ref.resource == 'account' && accounts.contains(ref.id)))
            ref,
      ],
    );
  }

  /// 2026-10-22: 영수증 [receipt]와 현재 상태의 최신 Snapshot으로 성공 결과를 만든다(replay도 최신 상태).
  FinancialOutcome<WriteSuccess> _success(
    Map<String, Object?> source,
    ProjectionState state,
    WriteReceipt receipt, {
    required bool replayed,
  }) {
    final projected = _project(source, state);
    if (projected is! FinancialOk<Map<String, Object?>>) {
      return const FinancialUnavailable();
    }
    return FinancialOk(
      WriteSuccess(
        receipt: _publicReceipt(receipt, state, projected.value),
        replayed: replayed,
        snapshot: projected.value,
      ),
    );
  }

  /// 2026-10-22: 투영 결과를 반환한다. 공개 권한을 판정할 수 없는 계약 오류는 예외 대신 서비스 불가로 바꾼다.
  FinancialOutcome<Map<String, Object?>> _project(
    Map<String, Object?> source,
    ProjectionState state,
  ) {
    try {
      return FinancialOk(SnapshotProjector.project(source, state));
    } on SnapshotContractException {
      return const FinancialUnavailable();
    }
  }

  /// 2026-10-22: [userId]의 원본과 장부를 반환한다. 처음이면 원본의 자료 버전으로 연결 전 상태를 만든다.
  /// 원본을 읽지 못하거나, 원본의 사용자가 다르거나, 자료 버전 형식이 맞지 않거나, 타입·소유자·참조가 계약과 맞지 않으면
  /// null이다. 열린 원본은 이후 형변환이 실패하지 않는다.
  Future<(Map<String, Object?>, _UserLedger)?> _open(String userId) async {
    var source = _sources[userId];
    if (source == null) {
      try {
        source = await loadSource(userId);
      } catch (_) {
        return null;
      }
      if (source['userId'] != userId) return null;
      if (!_isVersion(source['dataVersion'])) return null;
      try {
        SnapshotProjector.validate(source);
      } on SnapshotContractException {
        return null;
      }
      _sources[userId] = source;
    }
    final ledger = _ledgers.putIfAbsent(
      userId,
      () => _UserLedger(
        ProjectionState(
          institutionLinks: const [],
          selectedAccountIds: null,
          dataVersion: source!['dataVersion'] as String,
        ),
      ),
    );
    return (source, ledger);
  }
}

/// 2026-10-22: 쓰기 한 건이 만들 다음 상태와 바뀐 자원.
typedef _Change = ({
  List<Map<String, Object?>> institutionLinks,
  Set<String>? selectedAccountIds,
  List<ChangedRef> changed,
});

/// 2026-10-22: 사용자 한 명의 서버 장부. 상태는 쓰기 성공 때만 통째로 바꾼다.
class _UserLedger {
  /// 2026-10-22: 처음 상태 [state]로 만든다.
  _UserLedger(this.state);

  ProjectionState state;
  final Map<String, _StoredReceipt> receipts = {};
}

/// 2026-10-22: 작업 키별 저장 영수증과 같은 요청 판정용 지문.
class _StoredReceipt {
  /// 2026-10-22: 요청 지문 [fingerprint]와 [receipt]로 만든다.
  const _StoredReceipt(this.fingerprint, this.receipt);

  final String fingerprint;
  final WriteReceipt receipt;
}

/// 2026-10-22: 한 세션의 [UserFinancialRepository] 가짜 구현. 토큰으로만 서버에 묻고, 이 세션에서 받은 응답 중
/// 현재보다 낮은 자료 버전은 버린다. 세션이 끝나면 인스턴스를 버린다(서버 장부는 남음).
class FakeUserFinancialRepository implements UserFinancialRepository {
  /// 2026-10-22: 가짜 서버 [server]와 세션 토큰 [accessToken]으로 만든다.
  FakeUserFinancialRepository({
    required this.server,
    required this.accessToken,
  });

  final FakeFinancialServer server;
  final String accessToken;
  int _latestVersion = 0;
  bool _closed = false;

  /// 2026-10-22: 세션이 끝났다. 이후 요청과 진행 중이던 요청의 늦은 응답을 모두 세션 무효로 돌려 반영하지 않게 한다.
  @override
  void close() => _closed = true;

  /// 2026-10-22: 받은 Snapshot의 버전이 이 세션에서 본 것보다 낮지 않으면 받아들이고 true를 반환한다.
  bool _accept(Map<String, Object?> snapshot) {
    final version = int.parse(snapshot['dataVersion'] as String);
    if (version < _latestVersion) return false;
    _latestVersion = version;
    return true;
  }

  /// 2026-10-22: 현재 Snapshot을 조회한다. 이 세션에서 이미 더 새 버전을 봤다면 서비스 불가로 돌려 다시 읽게 한다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() async {
    if (_closed) return const FinancialSessionInvalid();
    final result = await server.getSnapshot(accessToken);
    if (_closed) return const FinancialSessionInvalid();
    if (result case FinancialOk(:final value) when !_accept(value)) {
      return const FinancialUnavailable();
    }
    return result;
  }

  /// 2026-10-22: 연결 기관을 저장한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> institutionCodes,
    WriteContext write,
  ) async => _closed
      ? const FinancialSessionInvalid()
      : _accepted(
          await server.postInstitutionLinks(
            accessToken,
            institutionCodes,
            write,
          ),
        );

  /// 2026-10-22: 계좌 선택을 저장한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> selectAccounts(
    List<String> accountIds,
    WriteContext write,
  ) async => _closed
      ? const FinancialSessionInvalid()
      : _accepted(
          await server.patchAccountSelection(accessToken, accountIds, write),
        );

  /// 2026-10-22: 쓰기 성공의 Snapshot 버전을 기록한다. 닫힌 세션의 늦은 응답은 세션 무효, 낮은 버전 응답은 서비스 불가로 바꿔 반영하지 않게 한다.
  FinancialOutcome<WriteSuccess> _accepted(
    FinancialOutcome<WriteSuccess> result,
  ) {
    if (_closed) return const FinancialSessionInvalid();
    if (result case FinancialOk(:final value) when !_accept(value.snapshot)) {
      return const FinancialUnavailable();
    }
    return result;
  }
}
