import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart' show StringCharacters;

import '../auth/auth_repository.dart';
import '../auth/random_id.dart';
import '../financial_snapshot.dart' show maxAbsKrw;
import 'financial_api.dart';
import 'snapshot_projector.dart';

/// 2026-10-22: 사용자 ID에 해당하는 불변 원본(PAYSE-DRAFT-3·4) JSON을 읽는 경계. 실제 API 도입 시 서버 쪽 책임이다.
typedef UserSourceLoader = Future<Map<String, Object?>> Function(String userId);

/// 2026-10-22: 금융 조회·연결 쓰기를 흉내 내는 앱 수명 가짜 서버(서버 장부 역할). 사용자별 불변 원본과 가변 상태
/// (연결 기록·계좌 선택·월급 설정·계좌 이름·예정 지출·배정·자료 버전·작업 영수증)를 분리해 재로그인까지 상태를 유지한다. 메모리 구현이며 실제 서버 영속화가 아니다.
class FakeFinancialServer {
  /// 2026-10-22: 토큰→사용자 [sessions], 원본 [loadSource], 시각 [now], 난수 [random]으로 만든다.
  FakeFinancialServer({
    required this.sessions,
    required this.loadSource,
    DateTime Function()? now,
    Random? random,
    this.transactionPageSize,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  /// 2026-10-30: 거래 페이지 크기(계약 최대 100). null이면 Snapshot에 거래를 모두 담고 nextCursor는 null이다(기본, 홈 계산이
  /// 모든 근거 거래를 한 번에 받는 현재 앱 흐름 유지). 값이 있으면 transactionId 오름차순으로 나눠 GET /transactions로 넘긴다.
  final int? transactionPageSize;

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
    final projected = _project(source, ledger.state);
    if (projected case FinancialOk(:final value)) {
      return FinancialOk(_firstPage(value, userId));
    }
    return projected;
  }

  /// 2026-10-30: GET /transactions?cursor. cursor는 'tx1|userId|dataVersion|마지막 transactionId'이며 앱은 해석하지 않는다.
  /// 형식이 틀리면 400, 다른 사용자 cursor는 403, 그 사이 자료 버전이 바뀌었으면 409다. 같은 투영에서 다음 페이지를 자른다.
  Future<FinancialOutcome<Map<String, Object?>>> getTransactionPage(
    String accessToken,
    String cursor,
  ) async {
    final userId = sessions.userIdForToken(accessToken);
    if (userId == null) return const FinancialSessionInvalid();
    final parts = cursor.split('|');
    if (parts.length != 4 || parts[0] != 'tx1' || parts[3].isEmpty) {
      return const FinancialInvalid();
    }
    if (parts[1] != userId) return const FinancialForbidden();
    final opened = await _open(userId);
    if (opened == null) return const FinancialUnavailable();
    final (source, ledger) = opened;
    if (parts[2] != ledger.state.dataVersion) return const FinancialStaleData();
    final projected = _project(source, ledger.state);
    if (projected is! FinancialOk<Map<String, Object?>>) return projected;
    final all = _sortedTransactions(projected.value);
    final start = all.indexWhere(
      (t) => (t['transactionId']! as String).compareTo(parts[3]) > 0,
    );
    final rest = start < 0
        ? const <Map<String, Object?>>[]
        : all.sublist(start);
    final size = transactionPageSize ?? rest.length;
    final page = rest.take(size).toList();
    final more = rest.length > size;
    final v = projected.value;
    return FinancialOk({
      for (final key in const [
        'userId',
        'schemaVersion',
        'currency',
        'dataVersion',
        'sourceVersion',
        'ruleVersion',
        'asOf',
      ])
        key: v[key],
      'transactions': page,
      'relatedTransactions': const <Object?>[],
      'referenceResolutions': const <Object?>[],
      'transactionRelations': const <Object?>[],
      'occurrenceLinks': const <Object?>[],
      'coverage': v['coverage'],
      'page': {
        'nextCursor': more
            ? _cursor(userId, ledger.state.dataVersion, page.last)
            : null,
        'dataVersion': ledger.state.dataVersion,
        'sourceVersion': v['sourceVersion'],
      },
      'accessRestrictions': const <Object?>[],
    });
  }

  /// 2026-10-30: [snapshot]의 거래를 transactionId 오름차순으로 반환한다.
  static List<Map<String, Object?>> _sortedTransactions(
    Map<String, Object?> snapshot,
  ) =>
      [
        for (final t in (snapshot['transactions'] as List?) ?? const [])
          (t as Map).cast<String, Object?>(),
      ]..sort(
        (a, b) => (a['transactionId']! as String).compareTo(
          b['transactionId']! as String,
        ),
      );

  /// 2026-10-30: 사용자 [userId]·자료 버전 [version]·마지막 거래 [last]로 다음 페이지 cursor를 만든다.
  static String _cursor(
    String userId,
    String version,
    Map<String, Object?> last,
  ) => 'tx1|$userId|$version|${last['transactionId']}';

  /// 2026-10-30: 페이지 크기가 정해졌으면 Snapshot에 첫 페이지 거래만 남기고 nextCursor를 붙인다. 연결 전 Snapshot은 그대로다.
  Map<String, Object?> _firstPage(
    Map<String, Object?> snapshot,
    String userId,
  ) {
    final size = transactionPageSize;
    if (size == null || snapshot['transactions'] is! List) return snapshot;
    final all = _sortedTransactions(snapshot);
    if (all.length <= size) return snapshot;
    final page = all.take(size).toList();
    final version = snapshot['dataVersion']! as String;
    return {
      ...snapshot,
      'transactions': page,
      'page': {
        ...(snapshot['page']! as Map).cast<String, Object?>(),
        'nextCursor': _cursor(userId, version, page.last),
      },
    };
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
        salarySettings: state.salarySettings,
        accountNicknames: state.accountNicknames,
        plan: null,
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
        salarySettings: state.salarySettings,
        accountNicknames: state.accountNicknames,
        plan: null,
        changed: [
          for (final id in {...next, ...before})
            if (next.contains(id) != before.contains(id))
              ChangedRef(resource: 'account', id: id),
        ],
      ));
    },
  );

  /// 2026-10-28: PATCH /settings의 월급 설정([salary]만, 카드 계획은 보내지 않음). 빈 patch·범위 밖 값은 422,
  /// 연결 밖·없는 계좌는 403, 연결됐지만 계산에 고르지 않은 계좌는 422다. 바꾼 필드만 덮고 입금 근거는 그대로 둔다.
  Future<FinancialOutcome<WriteSuccess>> patchSettings(
    String accessToken,
    SalaryPatch salary,
    WriteContext write,
  ) {
    final fields = salary.toJson();
    return _write(
      accessToken: accessToken,
      method: 'PATCH',
      path: '/settings',
      body: {'salary': fields},
      write: write,
      apply: (source, state) {
        if (fields.isEmpty) return const FinancialInvalid();
        final day = salary.salaryDay?.value;
        if (day != null && (day < 1 || day > 31)) {
          return const FinancialInvalid();
        }
        final amount = salary.salaryAmountKrw?.value;
        if (amount != null && (amount < 0 || amount > maxAbsKrw)) {
          return const FinancialInvalid();
        }
        final accountId = salary.salaryAccountId?.value;
        if (accountId != null) {
          final reachable = {
            for (final a in (source['accounts'] as List?) ?? const [])
              if (state.connectedCodes.contains((a as Map)['institutionCode']))
                a['accountId'] as String,
          };
          if (!reachable.contains(accountId)) return const FinancialForbidden();
          if (!(state.selectedAccountIds ?? const {}).contains(accountId)) {
            return const FinancialInvalid();
          }
        }
        return FinancialOk((
          institutionLinks: state.institutionLinks,
          selectedAccountIds: state.selectedAccountIds,
          salarySettings: {...state.salarySettings, ...fields},
          accountNicknames: state.accountNicknames,
          plan: null,
          changed: [
            ChangedRef(resource: 'settings', id: source['userId'] as String),
          ],
        ));
      },
    );
  }

  /// 2026-10-28: PATCH /accounts/{accountId}. 연결 범위의 계좌 이름만 바꾼다(계산 제외 계좌 포함). 앞뒤 공백을 지운 이름이
  /// [AccountNicknameRule]에 맞지 않으면 422, 연결 밖·없는 계좌는 403이다. null은 이름 해제이며 잔액·상품명은 그대로 둔다.
  Future<FinancialOutcome<WriteSuccess>> patchAccount(
    String accessToken,
    String accountId,
    String? nickname,
    WriteContext write,
  ) => _write(
    accessToken: accessToken,
    method: 'PATCH',
    path: '/accounts/$accountId',
    body: {'nickname': nickname},
    write: write,
    apply: (source, state) {
      final reachable = {
        for (final a in (source['accounts'] as List?) ?? const [])
          if (state.connectedCodes.contains((a as Map)['institutionCode']))
            a['accountId'] as String,
      };
      if (!reachable.contains(accountId)) return const FinancialForbidden();
      if (nickname != null && !AccountNicknameRule.isValid(nickname)) {
        return const FinancialInvalid();
      }
      return FinancialOk((
        institutionLinks: state.institutionLinks,
        selectedAccountIds: state.selectedAccountIds,
        salarySettings: state.salarySettings,
        accountNicknames: {
          ...state.accountNicknames,
          accountId: nickname?.trim(),
        },
        plan: null,
        changed: [ChangedRef(resource: 'account', id: accountId)],
      ));
    },
  );

  /// 2026-11-03: POST /obligations. 이름(앞뒤 공백 제외 1~80자)·금액(0~상한)·날짜 형식이 틀리면 422, 연결 밖·없는 계좌는
  /// 403이다. 사용자 단건 예정 지출(status=active, 청구·반복 연결 없음)을 만든다.
  Future<FinancialOutcome<WriteSuccess>> postObligation(
    String accessToken,
    ObligationInput obligation,
    WriteContext write,
  ) => _write(
    accessToken: accessToken,
    method: 'POST',
    path: '/obligations',
    body: obligation.toJson(),
    write: write,
    apply: (source, state) {
      if (!_validLabel(obligation.label) ||
          !_validMoney(obligation.amountKrw) ||
          !_validDate(obligation.dueDate)) {
        return const FinancialInvalid(status: 422, code: 'VALIDATION_FAILED');
      }
      if (!_reachable(source, state).contains(obligation.withdrawalAccountId)) {
        return const FinancialForbidden();
      }
      final id = randomUuidV4(_random);
      final obligations = [
        ..._rows(source, 'obligations'),
        {
          'userId': source['userId'],
          'obligationId': id,
          'label': obligation.label.trim(),
          'withdrawalAccountId': obligation.withdrawalAccountId,
          'amountKRW': obligation.amountKrw,
          'dueDate': obligation.dueDate,
          'status': 'active',
          'statementId': null,
          'recurringPlanId': null,
          'recurrenceKey': null,
          'planRevisionId': null,
        },
      ];
      return _planChange(
        source,
        state,
        obligations,
        _rows(source, 'allocations'),
        [ChangedRef(resource: 'obligation', id: id)],
      );
    },
  );

  /// 2026-11-03: PATCH /obligations/{id}. 보이지 않거나 없는 예정 지출·계좌는 403, 빈 patch·형식 오류는 422다. 카드 청구 예정
  /// 지출의 금액·날짜·계좌, 정산액보다 작은 금액, 정산이 있는데 계좌 변경은 409 HISTORY_LOCKED, 취소된 예정 지출은 409
  /// RELATION_CONFLICT, 바꾼 뒤 미해제 배정이 한도를 넘으면 422 LIMIT_EXCEEDED다(apps/api PlanWrites.obligation과 같은 순서).
  Future<FinancialOutcome<WriteSuccess>> patchObligation(
    String accessToken,
    String obligationId,
    ObligationPatch patch,
    WriteContext write,
  ) => _write(
    accessToken: accessToken,
    method: 'PATCH',
    path: '/obligations/$obligationId',
    body: patch.toJson(),
    write: write,
    apply: (source, state) {
      if (patch.isEmpty ||
          (patch.label != null && !_validLabel(patch.label!)) ||
          (patch.amountKrw != null && !_validMoney(patch.amountKrw!)) ||
          (patch.dueDate != null && !_validDate(patch.dueDate!))) {
        return const FinancialInvalid(status: 422, code: 'VALIDATION_FAILED');
      }
      final reachable = _reachable(source, state);
      final obligations = _rows(source, 'obligations');
      final index = obligations.indexWhere(
        (o) =>
            o['obligationId'] == obligationId &&
            reachable.contains(o['withdrawalAccountId']),
      );
      if (index < 0) return const FinancialForbidden();
      final before = obligations[index];
      if (before['statementId'] != null &&
          (patch.amountKrw != null ||
              patch.dueDate != null ||
              patch.withdrawalAccountId != null)) {
        return _historyLocked;
      }
      if (before['status'] != 'active') return _relationConflict;
      final account =
          patch.withdrawalAccountId ?? before['withdrawalAccountId']! as String;
      if (!reachable.contains(account)) return const FinancialForbidden();
      final amount = patch.amountKrw ?? before['amountKRW']! as int;
      final paid = _paid(source, obligationId);
      if (amount < paid ||
          (paid > 0 && account != before['withdrawalAccountId'])) {
        return _historyLocked;
      }
      final next = [...obligations];
      next[index] = {
        ...before,
        if (patch.label != null) 'label': patch.label!.trim(),
        if (before['statementId'] == null) ...{
          'withdrawalAccountId': account,
          'amountKRW': amount,
          'dueDate': patch.dueDate ?? before['dueDate'],
        },
      };
      return _planChange(source, state, next, _rows(source, 'allocations'), [
        ChangedRef(resource: 'obligation', id: obligationId),
      ]);
    },
  );

  /// 2026-11-03: POST /obligations/{id}/cancel. 지금 미해제 배정을 [detach]에 정확한 ID·금액으로 모두 담아야 한다. 중복 ID는 422,
  /// 없거나 보이지 않는 배정·예정 지출은 403, 카드 청구 또는 정산이 있는 예정 지출은 409 HISTORY_LOCKED, 다른 대상의 배정·누락·
  /// 금액 불일치는 409 RELATION_CONFLICT다. 해제 이력 없는 배정은 지우고, 있으면 금액을 해제 누계까지 줄인다(보호 설정액은 그대로).
  Future<FinancialOutcome<WriteSuccess>> postObligationCancel(
    String accessToken,
    String obligationId,
    List<DetachAllocation> detach,
    WriteContext write,
  ) => _write(
    accessToken: accessToken,
    method: 'POST',
    path: '/obligations/$obligationId/cancel',
    body: {
      'detachAllocations': [for (final d in detach) d.toJson()],
    },
    write: write,
    apply: (source, state) {
      final ids = [for (final d in detach) d.allocationId];
      if (ids.toSet().length != ids.length ||
          detach.any(
            (d) => !_validMoney(d.unreleasedKrw) || d.unreleasedKrw < 1,
          )) {
        return const FinancialInvalid(status: 422, code: 'VALIDATION_FAILED');
      }
      final reachable = _reachable(source, state);
      final obligations = _rows(source, 'obligations');
      final index = obligations.indexWhere(
        (o) =>
            o['obligationId'] == obligationId &&
            reachable.contains(o['withdrawalAccountId']),
      );
      if (index < 0) return const FinancialForbidden();
      final before = obligations[index];
      if (before['statementId'] != null || _paid(source, obligationId) > 0) {
        return _historyLocked;
      }
      final allocations = _rows(source, 'allocations');
      final visible = {
        for (final a in allocations)
          if (_allocationVisible(source, reachable, a))
            a['allocationId']! as String: a,
      };
      if (ids.any((id) => !visible.containsKey(id))) {
        return const FinancialForbidden();
      }
      final open = {
        for (final a in allocations)
          if (a['obligationId'] == obligationId &&
              (a['amountKRW']! as int) > (a['releasedKRW']! as int))
            a['allocationId']! as String:
                (a['amountKRW']! as int) - (a['releasedKRW']! as int),
      };
      final asked = {for (final d in detach) d.allocationId: d.unreleasedKrw};
      if (asked.length != open.length ||
          asked.entries.any((e) => open[e.key] != e.value)) {
        return _relationConflict;
      }
      final nextAllocations = [
        for (final a in allocations)
          if (!asked.containsKey(a['allocationId']))
            a
          else if ((a['releasedKRW']! as int) > 0)
            {...a, 'amountKRW': a['releasedKRW']},
      ];
      final next = [...obligations];
      next[index] = {...before, 'status': 'cancelled'};
      return _planChange(source, state, next, nextAllocations, [
        ChangedRef(resource: 'obligation', id: obligationId),
        for (final id in asked.keys) ChangedRef(resource: 'allocation', id: id),
      ]);
    },
  );

  /// 2026-11-03: POST /reserves. 형식 오류(이름 1~80자, 금액 0~상한, allocationChanges 세 빈 배열 필수)는 422, 연결 밖·없는
  /// 계좌는 403, 계산에 포함하지 않은 계좌면 422 VALIDATION_FAILED, 계좌별·선택 계좌 전체 상한(M5)을 넘으면 422 LIMIT_EXCEEDED다
  /// (apps/api PlanWrites.reserve와 같은 순서). 29-5b 앱은 연결을 만들지 않으므로 빈 allocationChanges만 받는다.
  Future<FinancialOutcome<WriteSuccess>> postReserve(
    String accessToken,
    ReserveInput reserve,
    WriteContext write,
  ) => _write(
    accessToken: accessToken,
    method: 'POST',
    path: '/reserves',
    body: reserve.toJson(),
    write: write,
    apply: (source, state) {
      if (!_validLabel(reserve.label) || !_validMoney(reserve.amountKrw)) {
        return const FinancialInvalid(status: 422, code: 'VALIDATION_FAILED');
      }
      return _reserveChange(
        source,
        state,
        null,
        label: reserve.label,
        accountId: reserve.accountId,
        amountKrw: reserve.amountKrw,
      );
    },
  );

  /// 2026-11-03: PATCH /reserves/{id}. 빈 patch·형식 오류는 422, 보이지 않거나 없는 남겨둘 돈·계좌는 403, 취소된 남겨둘 돈은 409
  /// RELATION_CONFLICT다. 새 계좌·증액이면 계산 포함 계좌와 M5 상한을 검사하고, 미해제 배정 합계보다 작으면 422 LIMIT_EXCEEDED다.
  Future<FinancialOutcome<WriteSuccess>> patchReserve(
    String accessToken,
    String reserveId,
    ReservePatch patch,
    WriteContext write,
  ) => _write(
    accessToken: accessToken,
    method: 'PATCH',
    path: '/reserves/$reserveId',
    body: patch.toJson(),
    write: write,
    apply: (source, state) {
      if (patch.isEmpty ||
          (patch.label != null && !_validLabel(patch.label!)) ||
          (patch.amountKrw != null && !_validMoney(patch.amountKrw!))) {
        return const FinancialInvalid(status: 422, code: 'VALIDATION_FAILED');
      }
      return _reserveChange(
        source,
        state,
        reserveId,
        label: patch.label,
        accountId: patch.accountId,
        amountKrw: patch.amountKrw,
      );
    },
  );

  /// 2026-11-03: POST /reserves/{id}/cancel. 지금 미해제 배정을 [detach]에 정확한 ID·금액으로 모두 담아야 한다. 중복 ID는 422,
  /// 없거나 보이지 않는 배정·남겨둘 돈은 403, 다른 대상의 배정·누락·금액 불일치는 409 RELATION_CONFLICT다. 해제 이력 없는 배정은
  /// 지우고, 있으면 금액을 해제 누계까지 줄인다. 예정 지출은 그대로다.
  Future<FinancialOutcome<WriteSuccess>> postReserveCancel(
    String accessToken,
    String reserveId,
    List<DetachAllocation> detach,
    WriteContext write,
  ) => _write(
    accessToken: accessToken,
    method: 'POST',
    path: '/reserves/$reserveId/cancel',
    body: {
      'detachAllocations': [for (final d in detach) d.toJson()],
    },
    write: write,
    apply: (source, state) {
      final ids = [for (final d in detach) d.allocationId];
      if (ids.toSet().length != ids.length ||
          detach.any(
            (d) => !_validMoney(d.unreleasedKrw) || d.unreleasedKrw < 1,
          )) {
        return const FinancialInvalid(status: 422, code: 'VALIDATION_FAILED');
      }
      final reachable = _reachable(source, state);
      final reserves = _rows(source, 'reserves');
      final index = reserves.indexWhere(
        (r) =>
            r['reserveId'] == reserveId && reachable.contains(r['accountId']),
      );
      if (index < 0) return const FinancialForbidden();
      final allocations = _rows(source, 'allocations');
      final visible = {
        for (final a in allocations)
          if (_allocationVisible(source, reachable, a))
            a['allocationId']! as String: a,
      };
      if (ids.any((id) => !visible.containsKey(id))) {
        return const FinancialForbidden();
      }
      final open = {
        for (final a in allocations)
          if (a['reserveId'] == reserveId &&
              (a['amountKRW']! as int) > (a['releasedKRW']! as int))
            a['allocationId']! as String:
                (a['amountKRW']! as int) - (a['releasedKRW']! as int),
      };
      final asked = {for (final d in detach) d.allocationId: d.unreleasedKrw};
      if (asked.length != open.length ||
          asked.entries.any((e) => open[e.key] != e.value)) {
        return _relationConflict;
      }
      final nextAllocations = [
        for (final a in allocations)
          if (!asked.containsKey(a['allocationId']))
            a
          else if ((a['releasedKRW']! as int) > 0)
            {...a, 'amountKRW': a['releasedKRW']},
      ];
      final before = reserves[index];
      final next = [...reserves];
      if (before['cancelledAt'] == null) {
        next[index] = {
          ...before,
          'cancelledAt': _now().toUtc().toIso8601String(),
        };
      }
      return _planChange(
        source,
        state,
        _rows(source, 'obligations'),
        nextAllocations,
        [
          ChangedRef(resource: 'reserve', id: reserveId),
          for (final id in asked.keys)
            ChangedRef(resource: 'allocation', id: id),
        ],
        reserves: next,
      );
    },
  );

  /// 2026-11-03: 남겨둘 돈 [reserveId](null이면 새로 만듦)를 이름 [label]·계좌 [accountId]·금액 [amountKrw](null이면 그대로)로
  /// 바꾼 변경을 만든다. 순서는 apps/api PlanWrites.reserve와 같다: 취소된 대상 409 → 계좌 403 → 새 계좌·증액인데 계산 제외 계좌면
  /// 422 → 미해제 배정 한도 422 LIMIT_EXCEEDED → 새 계좌·증액이면 계좌별(잔액)·선택 계좌 전체(선택 잔액 합) 상한 422 LIMIT_EXCEEDED.
  FinancialOutcome<_Change> _reserveChange(
    Map<String, Object?> source,
    ProjectionState state,
    String? reserveId, {
    String? label,
    String? accountId,
    int? amountKrw,
  }) {
    final reachable = _reachable(source, state);
    final reserves = _rows(source, 'reserves');
    final index = reserveId == null
        ? -1
        : reserves.indexWhere(
            (r) =>
                r['reserveId'] == reserveId &&
                reachable.contains(r['accountId']),
          );
    if (reserveId != null && index < 0) return const FinancialForbidden();
    final before = index < 0 ? null : reserves[index];
    if (before != null && before['cancelledAt'] != null) {
      return _relationConflict;
    }
    final account = accountId ?? before!['accountId']! as String;
    if (!reachable.contains(account)) return const FinancialForbidden();
    final amount = amountKrw ?? before!['amountKRW']! as int;
    final included = state.selectedAccountIds ?? const <String>{};
    final increased =
        before == null ||
        account != before['accountId'] ||
        amount > (before['amountKRW']! as int);
    if (increased && !included.contains(account)) {
      return const FinancialInvalid(status: 422, code: 'VALIDATION_FAILED');
    }
    final id = reserveId ?? randomUuidV4(_random);
    final row = {
      ...?before,
      'userId': source['userId'],
      'reserveId': id,
      'accountId': account,
      'label': (label ?? before!['label']! as String).trim(),
      'amountKRW': amount,
      'cancelledAt': null,
    };
    final next = before == null
        ? [...reserves, row]
        : ([...reserves]..[index] = row);
    if (increased && _overReserveLimit(source, included, next, account)) {
      return const FinancialInvalid(status: 422, code: 'LIMIT_EXCEEDED');
    }
    return _planChange(
      source,
      state,
      _rows(source, 'obligations'),
      _rows(source, 'allocations'),
      [ChangedRef(resource: 'reserve', id: id)],
      reserves: next,
    );
  }

  /// 2026-11-03: M5. 계좌 [account]의 취소되지 않은 남겨둘 돈 합계가 그 계좌 잔액(음수면 0)을 넘거나, 계산 포함 계좌 전체의 합계가
  /// 포함 계좌 잔액 합(음수면 0)을 넘으면 true다(apps/api PlanWrites.reserveLimits).
  static bool _overReserveLimit(
    Map<String, Object?> source,
    Set<String> included,
    List<Map<String, Object?>> reserves,
    String account,
  ) {
    final balance = {
      for (final a in _rows(source, 'accounts'))
        a['accountId']! as String: (a['balanceKRW'] as int?) ?? 0,
    };
    var perAccount = 0;
    var selectedReserve = 0;
    for (final r in reserves) {
      if (r['cancelledAt'] != null) continue;
      final amount = r['amountKRW']! as int;
      if (r['accountId'] == account) perAccount += amount;
      if (included.contains(r['accountId'])) selectedReserve += amount;
    }
    var selectedBalance = 0;
    for (final id in included) {
      selectedBalance += balance[id] ?? 0;
    }
    return perAccount > max(0, balance[account] ?? 0) ||
        selectedReserve > max(0, selectedBalance);
  }

  static const FinancialOutcome<_Change> _historyLocked = FinancialInvalid(
    status: 409,
    code: 'HISTORY_LOCKED',
  );
  static const FinancialOutcome<_Change> _relationConflict = FinancialInvalid(
    status: 409,
    code: 'RELATION_CONFLICT',
  );

  /// 2026-11-03: 예정 지출·배정·남겨둘 돈을 [obligations]·[allocations]·[reserves](없으면 원본 그대로)로 바꾸는 변경을 만든다. 바꾼 뒤 미해제 배정이 예정 지출 잔여(금액 −
  /// 유효 정산)나 보호 설정액을 넘거나, 활성이 아닌 대상에 남으면 422 LIMIT_EXCEEDED다(apps/api AllocationWrites.limits).
  FinancialOutcome<_Change> _planChange(
    Map<String, Object?> source,
    ProjectionState state,
    List<Map<String, Object?>> obligations,
    List<Map<String, Object?>> allocations,
    List<ChangedRef> changed, {
    List<Map<String, Object?>>? reserves,
  }) {
    reserves ??= _rows(source, 'reserves');
    final byObligation = <String, int>{};
    final byReserve = <String, int>{};
    for (final a in allocations) {
      final open = (a['amountKRW']! as int) - (a['releasedKRW']! as int);
      byObligation.update(
        a['obligationId']! as String,
        (v) => v + open,
        ifAbsent: () => open,
      );
      byReserve.update(
        a['reserveId']! as String,
        (v) => v + open,
        ifAbsent: () => open,
      );
    }
    for (final o in obligations) {
      final open = byObligation[o['obligationId']] ?? 0;
      final room = o['status'] == 'active'
          ? (o['amountKRW']! as int) -
                _paid(source, o['obligationId']! as String)
          : 0;
      if (open > room) {
        return const FinancialInvalid(status: 422, code: 'LIMIT_EXCEEDED');
      }
    }
    for (final r in reserves) {
      final open = byReserve[r['reserveId']] ?? 0;
      final room = r['cancelledAt'] == null ? r['amountKRW']! as int : 0;
      if (open > room) {
        return const FinancialInvalid(status: 422, code: 'LIMIT_EXCEEDED');
      }
    }
    return FinancialOk((
      institutionLinks: state.institutionLinks,
      selectedAccountIds: state.selectedAccountIds,
      salarySettings: state.salarySettings,
      accountNicknames: state.accountNicknames,
      plan: (
        obligations: obligations,
        allocations: allocations,
        reserves: reserves,
      ),
      changed: changed,
    ));
  }

  /// 2026-11-03: [source]의 [key] 묶음을 행 목록으로 반환한다. 없으면 빈 목록이다.
  static List<Map<String, Object?>> _rows(
    Map<String, Object?> source,
    String key,
  ) => [
    for (final r in (source[key] as List?) ?? const [])
      (r as Map).cast<String, Object?>(),
  ];

  /// 2026-11-03: 연결 범위의 계좌 ID 집합을 반환한다.
  static Set<String> _reachable(
    Map<String, Object?> source,
    ProjectionState state,
  ) => {
    for (final a in (source['accounts'] as List?) ?? const [])
      if (state.connectedCodes.contains((a as Map)['institutionCode']))
        a['accountId'] as String,
  };

  /// 2026-11-03: 배정 [a]의 예정 지출과 보호 설정이 모두 연결 범위 계좌이면 true다.
  static bool _allocationVisible(
    Map<String, Object?> source,
    Set<String> reachable,
    Map<String, Object?> a,
  ) {
    final obligation = _rows(
      source,
      'obligations',
    ).where((o) => o['obligationId'] == a['obligationId']).firstOrNull;
    final reserve = _rows(
      source,
      'reserves',
    ).where((r) => r['reserveId'] == a['reserveId']).firstOrNull;
    return obligation != null &&
        reserve != null &&
        reachable.contains(obligation['withdrawalAccountId']) &&
        reachable.contains(reserve['accountId']);
  }

  /// 2026-11-03: 예정 지출 [obligationId]의 유효 정산(invalidatedAt 없음) 합계를 반환한다.
  static int _paid(Map<String, Object?> source, String obligationId) {
    var sum = 0;
    for (final s in _rows(source, 'settlements')) {
      if (s['obligationId'] == obligationId && s['invalidatedAt'] == null) {
        sum += s['allocatedKRW']! as int;
      }
    }
    return sum;
  }

  /// 2026-11-03: 계약 Label(앞뒤 공백을 지운 1~80자)이면 true다.
  static bool _validLabel(String label) {
    final n = label.trim().characters.length;
    return n >= 1 && n <= 80;
  }

  /// 2026-11-03: 계약 Money(0 이상 상한 이하 원)이면 true다.
  static bool _validMoney(int amount) => amount >= 0 && amount <= maxAbsKrw;

  /// 2026-11-03: 실제 있는 날짜의 YYYY-MM-DD이면 true다.
  static bool _validDate(String date) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) return false;
    final parsed = DateTime.tryParse(date);
    return parsed != null && parsed.toIso8601String().substring(0, 10) == date;
  }

  /// 2026-10-22: 금융 쓰기 공통 절차(§5). 형식 → 같은 키 replay/충돌 → 규칙·자료 버전 → 소유권·제약 → 상태·영수증·버전을
  /// 한 번에 확정한다. 중간 실패는 아무것도 바꾸지 않는다.
  Future<FinancialOutcome<WriteSuccess>> _write({
    required String accessToken,
    required String method,
    required String path,
    required Object? body,
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
    Object? body,
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
        FinancialInvalid(:final status, :final code) => FinancialInvalid(
          status: status,
          code: code,
        ),
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
      salarySettings: change.value.salarySettings,
      accountNicknames: change.value.accountNicknames,
    );
    final plan = change.value.plan;
    final projected = _project(_withPlan(source, plan), nextState);
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
    if (plan != null) ledger.plan = plan;
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
              (ref.resource == 'account' && accounts.contains(ref.id)) ||
              (ref.resource == 'settings' && ref.id == snapshot['userId']) ||
              (ref.resource == 'obligation' &&
                  _ids(
                    snapshot,
                    'obligations',
                    'obligationId',
                  ).contains(ref.id)) ||
              (ref.resource == 'allocation' &&
                  _ids(
                    snapshot,
                    'allocations',
                    'allocationId',
                  ).contains(ref.id)))
            ref,
      ],
    );
  }

  /// 2026-11-03: [snapshot]의 [key] 묶음에 보이는 [idKey] 값 집합.
  static Set<String> _ids(
    Map<String, Object?> snapshot,
    String key,
    String idKey,
  ) => {
    for (final r in (snapshot[key] as List?) ?? const [])
      (r as Map)[idKey] as String,
  };

  /// 2026-11-03: 원본 [source]의 예정 지출·배정을 장부의 [plan]으로 바꾼 투영 입력을 반환한다. [plan]이 없으면 원본 그대로다.
  static Map<String, Object?> _withPlan(
    Map<String, Object?> source,
    _Plan? plan,
  ) => plan == null
      ? source
      : {
          ...source,
          'obligations': plan.obligations,
          'allocations': plan.allocations,
          'reserves': plan.reserves,
        };

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
    return (_withPlan(source, ledger.plan), ledger);
  }
}

/// 2026-11-03: 사용자가 바꾼 예정 지출·배정·남겨둘 돈 전체. 원본은 그대로 두고 투영 때 이 목록으로 덮는다.
typedef _Plan = ({
  List<Map<String, Object?>> obligations,
  List<Map<String, Object?>> allocations,
  List<Map<String, Object?>> reserves,
});

/// 2026-10-22: 쓰기 한 건이 만들 다음 상태와 바뀐 자원.
/// 2026-11-03: [plan]은 예정 지출·배정을 바꾸는 쓰기만 담고, 그 밖에는 null이다.
typedef _Change = ({
  List<Map<String, Object?>> institutionLinks,
  Set<String>? selectedAccountIds,
  Map<String, Object?> salarySettings,
  Map<String, String?> accountNicknames,
  _Plan? plan,
  List<ChangedRef> changed,
});

/// 2026-10-22: 사용자 한 명의 서버 장부. 상태는 쓰기 성공 때만 통째로 바꾼다.
class _UserLedger {
  /// 2026-10-22: 처음 상태 [state]로 만든다.
  _UserLedger(this.state);

  ProjectionState state;

  /// 2026-11-03: 바꾼 예정 지출·배정. 아직 바꾼 적이 없으면 null이다.
  _Plan? plan;
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

  /// 2026-10-30: 다음 거래 페이지를 조회한다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadTransactionPage(
    String cursor,
  ) async {
    if (_closed) return const FinancialSessionInvalid();
    final result = await server.getTransactionPage(accessToken, cursor);
    return _closed ? const FinancialSessionInvalid() : result;
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

  /// 2026-10-28: 월급 설정을 저장한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateSalarySettings(
    SalaryPatch salary,
    WriteContext write,
  ) async => _closed
      ? const FinancialSessionInvalid()
      : _accepted(await server.patchSettings(accessToken, salary, write));

  /// 2026-10-28: 계좌 이름을 저장한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateAccountNickname(
    String accountId,
    String? nickname,
    WriteContext write,
  ) async => _closed
      ? const FinancialSessionInvalid()
      : _accepted(
          await server.patchAccount(accessToken, accountId, nickname, write),
        );

  /// 2026-11-03: 예정 지출을 만든다.
  @override
  Future<FinancialOutcome<WriteSuccess>> createObligation(
    ObligationInput obligation,
    WriteContext write,
  ) async => _closed
      ? const FinancialSessionInvalid()
      : _accepted(await server.postObligation(accessToken, obligation, write));

  /// 2026-11-03: 예정 지출을 고친다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateObligation(
    String obligationId,
    ObligationPatch patch,
    WriteContext write,
  ) async => _closed
      ? const FinancialSessionInvalid()
      : _accepted(
          await server.patchObligation(accessToken, obligationId, patch, write),
        );

  /// 2026-11-03: 예정 지출을 취소한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> cancelObligation(
    String obligationId,
    List<DetachAllocation> detach,
    WriteContext write,
  ) async => _closed
      ? const FinancialSessionInvalid()
      : _accepted(
          await server.postObligationCancel(
            accessToken,
            obligationId,
            detach,
            write,
          ),
        );

  /// 2026-11-03: 남겨둘 돈을 만든다.
  @override
  Future<FinancialOutcome<WriteSuccess>> createReserve(
    ReserveInput reserve,
    WriteContext write,
  ) async => _closed
      ? const FinancialSessionInvalid()
      : _accepted(await server.postReserve(accessToken, reserve, write));

  /// 2026-11-03: 남겨둘 돈을 고친다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateReserve(
    String reserveId,
    ReservePatch patch,
    WriteContext write,
  ) async => _closed
      ? const FinancialSessionInvalid()
      : _accepted(
          await server.patchReserve(accessToken, reserveId, patch, write),
        );

  /// 2026-11-03: 남겨둘 돈을 취소한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> cancelReserve(
    String reserveId,
    List<DetachAllocation> detach,
    WriteContext write,
  ) async => _closed
      ? const FinancialSessionInvalid()
      : _accepted(
          await server.postReserveCancel(accessToken, reserveId, detach, write),
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
