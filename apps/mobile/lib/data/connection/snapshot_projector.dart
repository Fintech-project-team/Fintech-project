import 'dart:convert';

import 'access_restriction.dart';

/// 2026-10-22: 원본·상태가 계약과 맞지 않아 정상 응답을 만들 수 없을 때 던진다(서비스 불가로 처리).
class SnapshotContractException implements Exception {
  /// 2026-10-22: 문제 위치 [where]와 이유 [reason]으로 만든다. 숨겨진 ID·금액은 넣지 않는다.
  const SnapshotContractException(this.where, this.reason);

  final String where;
  final String reason;

  /// 2026-10-22: 위치와 이유를 합친 설명을 반환한다.
  @override
  String toString() => 'SnapshotContractException($where: $reason)';
}

/// 2026-10-22: 응답 투영에 쓰는 사용자 저장 상태. 원본 fixture와 분리된 가변 값의 읽기 전용 사본이다.
class ProjectionState {
  /// 2026-10-22: 연결 기록 [institutionLinks](연결 순서 유지), 계좌 선택 [selectedAccountIds](아직 저장 전이면 null),
  /// 현재 자료 버전 [dataVersion]으로 만든다.
  const ProjectionState({
    required this.institutionLinks,
    required this.selectedAccountIds,
    required this.dataVersion,
  });

  final List<Map<String, Object?>> institutionLinks;
  final Set<String>? selectedAccountIds;
  final String dataVersion;

  /// 2026-10-22: 연결된 기관 코드 집합을 반환한다.
  Set<String> get connectedCodes => {
    for (final link in institutionLinks) link['institutionCode'] as String,
  };
}

/// 2026-10-22: 원본 fixture(PAYSE-DRAFT-3)와 사용자 상태로 HTTP Snapshot(PAYSE-API-0.6-3)을 만든다
/// (docs/api-response-models.md §1.1·§2). 원본은 바꾸지 않고 새 객체를 만든다. 상태·화면 전역값을 읽지 않는다.
abstract final class SnapshotProjector {
  static const String sourceSchema = 'PAYSE-DRAFT-3';
  static const String apiSchema = 'PAYSE-API-0.6-3';

  static const List<String> _headerKeys = [
    'userId',
    'schemaVersion',
    'currency',
    'dataVersion',
    'sourceVersion',
    'ruleVersion',
    'asOf',
  ];

  /// 2026-10-22: [source] 원본과 [state]로 Snapshot JSON을 반환한다. 연결 기관이 없으면 연결 전 10개 키만 만든다.
  static Map<String, Object?> project(
    Map<String, Object?> source,
    ProjectionState state,
  ) {
    final src = _deepCopy(source);
    if (src['schemaVersion'] != sourceSchema) {
      throw const SnapshotContractException(
        r'$.schemaVersion',
        '지원하지 않는 원본 형식',
      );
    }
    final header = <String, Object?>{
      for (final key in _headerKeys) key: src[key],
      'schemaVersion': apiSchema,
      'dataVersion': state.dataVersion,
    };
    final partial = _Partial(src, state, header)
      ..validateSource(requireConnected: state.connectedCodes.isNotEmpty);
    final institutions = _list(src, 'institutions');
    final known = {for (final i in institutions) i['code'] as String};
    for (final code in state.connectedCodes) {
      if (!known.contains(code)) {
        throw const SnapshotContractException(
          r'$.institutionLinks',
          '제공되지 않은 기관 연결',
        );
      }
    }
    if (state.connectedCodes.isEmpty) {
      return {
        ...header,
        'institutions': institutions,
        'institutionLinks': <Object?>[],
        'coverage': <Object?>[],
      };
    }
    return partial.build();
  }

  /// 2026-10-22: [source] 원본이 연결 가능한 지원 형식(연결 후 키 모두 포함)이고 타입·소유자·참조가 계약과 맞는지
  /// 검사한다. 맞지 않으면 [SnapshotContractException]을 던진다. 서버가 원본을 처음 열 때 쓰며 원본을 바꾸지 않는다.
  static void validate(Map<String, Object?> source) {
    if (source['schemaVersion'] != sourceSchema) {
      throw const SnapshotContractException(
        r'$.schemaVersion',
        '지원하지 않는 원본 형식',
      );
    }
    _Partial(
      source,
      const ProjectionState(
        institutionLinks: [],
        selectedAccountIds: null,
        dataVersion: '1',
      ),
      {for (final key in _headerKeys) key: source[key]},
    ).validateSource(requireConnected: true);
  }

  /// 2026-10-22: JSON 값을 깊이 복사해 반환한다. 원본 공유로 사용자 상태가 섞이지 않게 한다.
  static Map<String, Object?> _deepCopy(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  /// 2026-10-22: [json]의 객체 배열 [key]를 반환한다. 배열이 아니면 계약 오류다.
  static List<Map<String, Object?>> _list(
    Map<String, Object?> json,
    String key,
  ) {
    final value = json[key];
    if (value is! List) throw SnapshotContractException('\$.$key', '배열이 아님');
    return [
      for (final item in value)
        if (item is Map)
          item.cast<String, Object?>()
        else
          throw SnapshotContractException('\$.$key', '객체가 아닌 행'),
    ];
  }
}

/// 2026-10-22: 연결 기관 범위로 공개·생략·제한을 판정해 연결 후 Snapshot을 만든다(§2.1~2.3).
class _Partial {
  /// 2026-10-22: 깊이 복사한 원본 [src], 사용자 [state], 공통 머리 [header]로 만든다.
  _Partial(this.src, this.state, this.header)
    : connected = state.connectedCodes;

  final Map<String, Object?> src;
  final ProjectionState state;
  final Map<String, Object?> header;
  final Set<String> connected;
  final Set<String> _restrictionKeys = {};
  final List<Map<String, Object?>> _restrictions = [];
  final Set<String> _hiddenIds = {};

  late final List<Map<String, Object?>> _institutions = _list('institutions');
  late final Map<String, String> _kindOf = {
    for (final i in _institutions) i['code'] as String: i['kind'] as String,
  };

  late final Set<String> _visibleAccounts = {};
  late final Set<String> _visibleCards = {};
  late final Set<String> _visibleTransactions = {};
  late final Set<String> _knownTransactions = {};
  late final Set<String> _visibleStatements = {};
  late final Set<String> _visibleObligations = {};
  late final Set<String> _visibleReserves = {};
  late final Set<String> _visiblePlans = {};
  late final Set<String> _visibleRevisions = {};
  late final Set<String> _knownPlans = {};
  late final Set<String> _knownRevisions = {};

  /// 2026-10-22: 원본의 객체 배열 [key]를 반환한다.
  List<Map<String, Object?>> _list(String key) =>
      SnapshotProjector._list(src, key);

  /// 2026-10-22: 등록 표로 검사한 뒤 제한 표식 하나를 중복 없이 추가한다.
  void _restrict(
    String ownerType,
    String? ownerId,
    String field,
    String targetKind,
  ) {
    final valid = isValidRestriction(
      ownerType: ownerType,
      ownerId: ownerId,
      field: field,
      targetKind: targetKind,
      reason: 'not_connected',
    );
    if (!valid) {
      throw SnapshotContractException(
        'accessRestrictions',
        '등록되지 않은 제한 조합 $ownerType/$field/$targetKind',
      );
    }
    final key = '$ownerType|$ownerId|$field|$targetKind';
    if (_restrictionKeys.add(key)) {
      _restrictions.add({
        'ownerType': ownerType,
        'ownerId': ownerId,
        'field': field,
        'targetKind': targetKind,
        'reason': 'not_connected',
      });
    }
  }

  /// 2026-10-22: [code] 기관이 [kind] 종류이고 연결됐으면 true를 반환한다. 모르는 기관·종류 불일치는 계약 오류다.
  bool _connectedAs(String? code, String kind, String where) {
    final actual = _kindOf[code];
    if (code == null || actual == null) {
      throw SnapshotContractException(where, '알 수 없는 기관');
    }
    if (actual != kind) throw SnapshotContractException(where, '기관 종류 불일치');
    return connected.contains(code);
  }

  /// 2026-10-22: 연결 전 원본에도 있어야 하는 배열.
  static const List<String> _baseArrays = [
    'institutions',
    'institutionLinks',
    'coverage',
  ];

  /// 2026-10-22: 연결 후 원본의 필수 키. 모두 있거나 모두 없어야 하며 null을 허용하지 않는다(settings·page는 객체, 나머지는 배열).
  static const List<String> _connectedKeys = [
    'accounts',
    'cards',
    'transactions',
    'statements',
    'settings',
    'obligations',
    'reserves',
    'allocations',
    'settlements',
    'recurringPlans',
    'recurringDecisions',
    'recurringPlanRevisions',
    'occurrenceOverrides',
    'relatedTransactions',
    'referenceResolutions',
    'transactionRelations',
    'occurrenceLinks',
    'page',
  ];

  /// 2026-10-22: 원본 필드 타입 규격. 투영·쓰기가 형변환으로 읽는 필드를 모두 담는다.
  /// 'id'는 비어 있지 않은 문자열, '?'는 null·생략 허용, 'ids'는 ID 문자열 배열, 'strs'는 문자열 배열, 'maps'는 객체 배열이다.
  static const Map<String, Map<String, String>> _fieldTypes = {
    'institutions': {
      'code': 'id',
      'kind': 'str',
      'accountCount': 'int',
      'cardCount': 'int',
    },
    'coverage': {'targetKind': 'str', 'targetId': 'id'},
    'accounts': {'accountId': 'id', 'institutionCode': 'str'},
    'cards': {
      'cardId': 'id',
      'institutionCode': 'str',
      'withdrawalAccountId': 'id?',
      'scheduleEvidence': 'maps?',
    },
    'transactions': {
      'transactionId': 'id',
      'recordKind': 'str',
      'accountId': 'id?',
      'cardId': 'id?',
      'originalTransactionId': 'id?',
    },
    'relatedTransactions': {
      'transactionId': 'id',
      'recordKind': 'str',
      'accountId': 'id?',
      'cardId': 'id?',
      'originalTransactionId': 'id?',
    },
    'referenceResolutions': {'transactionId': 'id'},
    'statements': {
      'statementId': 'id',
      'cardId': 'id',
      'includedTransactionRefs': 'ids?',
    },
    'obligations': {
      'obligationId': 'id',
      'withdrawalAccountId': 'id',
      'statementId': 'id?',
      'recurringPlanId': 'id?',
      'planRevisionId': 'id?',
    },
    'reserves': {'reserveId': 'id', 'accountId': 'id'},
    'allocations': {
      'allocationId': 'id',
      'reserveId': 'id',
      'obligationId': 'id',
      'releaseEvidence': 'maps?',
    },
    'settlements': {
      'linkId': 'id',
      'obligationId': 'id',
      'transactionId': 'id',
      'evidenceRefs': 'strs?',
    },
    'recurringPlans': {'planId': 'id'},
    'recurringDecisions': {'planId': 'id?', 'evidenceTransactionIds': 'ids?'},
    'recurringPlanRevisions': {
      'revisionId': 'id',
      'planId': 'id',
      'withdrawalAccountId': 'id',
      'cardId': 'id?',
      'scheduleOverrides': 'maps?',
    },
    'occurrenceOverrides': {
      'planRevisionId': 'id',
      'withdrawalAccountId': 'id',
      'recurrenceKey': 'str?',
    },
    'transactionRelations': {
      'fromId': 'id',
      'toId': 'id',
      'evidenceRef': 'str?',
    },
    'occurrenceLinks': {
      'recurrenceKey': 'str?',
      'purchaseTransactionId': 'id?',
      'statementId': 'id?',
      'obligationId': 'id?',
      'evidenceRef': 'str?',
    },
  };

  /// 2026-10-22: [value]가 규격 [type]에 맞으면 true를 반환한다.
  static bool _typed(Object? value, String type) {
    final optional = type.endsWith('?');
    if (value == null) return optional;
    return switch (optional ? type.substring(0, type.length - 1) : type) {
      'id' => value is String && value.isNotEmpty,
      'str' => value is String,
      'int' => value is int,
      'ids' => value is List && value.every((v) => v is String && v.isNotEmpty),
      'strs' => value is List && value.every((v) => v is String),
      'maps' => value is List && value.every((v) => v is Map),
      _ => false,
    };
  }

  /// 2026-10-22: 머리·필수 키·배열·중첩 객체의 필드 타입을 규격대로 검사한다. 어긋나면 위치와 이유를 담은 계약 오류다.
  /// 연결 후 키는 [requireConnected]이거나 하나라도 있으면 모두 있어야 한다.
  void _checkTypes(bool requireConnected) {
    for (final key in const [
      'userId',
      'currency',
      'dataVersion',
      'sourceVersion',
      'ruleVersion',
      'asOf',
    ]) {
      if (!_typed(header[key], 'id')) {
        throw SnapshotContractException('\$.$key', '문자열이 아님');
      }
    }
    for (final key in _baseArrays) {
      if (src[key] is! List) {
        throw SnapshotContractException('\$.$key', '필수 배열이 없거나 배열이 아님');
      }
    }
    if (requireConnected || _connectedKeys.any(src.containsKey)) {
      for (final key in _connectedKeys) {
        final value = src[key];
        final ok = key == 'settings' || key == 'page'
            ? value is Map
            : value is List;
        if (!ok) {
          throw SnapshotContractException('\$.$key', '연결 후 필수 키가 없거나 형식이 다름');
        }
      }
    }
    void field(
      Map<String, Object?> row,
      String name,
      String type,
      String where,
    ) {
      if (!_typed(row[name], type)) {
        throw SnapshotContractException('$where.$name', '$type 형식이 아님');
      }
    }

    _fieldTypes.forEach((key, fields) {
      for (final row in _optional(key)) {
        fields.forEach((name, type) => field(row, name, type, key));
      }
    });
    for (final row in _optional('allocations')) {
      for (final e in (row['releaseEvidence'] as List?) ?? const []) {
        field(
          (e as Map).cast(),
          'settlementLinkId',
          'id',
          'allocations.releaseEvidence',
        );
      }
    }
    for (final key in const ['cards', 'recurringPlanRevisions']) {
      final nested = key == 'cards' ? 'scheduleEvidence' : 'scheduleOverrides';
      for (final row in _optional(key)) {
        for (final e in (row[nested] as List?) ?? const []) {
          field((e as Map).cast(), 'evidenceRef', 'str?', '$key.$nested');
        }
      }
    }
    final settings = src['settings'];
    if (settings == null) return;
    if (settings is! Map) {
      throw const SnapshotContractException(r'$.settings', '객체가 아님');
    }
    final salary = settings['salary'];
    if (salary != null) {
      if (salary is! Map) {
        throw const SnapshotContractException(r'$.settings.salary', '객체가 아님');
      }
      field(salary.cast(), 'salaryAccountId', 'id?', 'settings.salary');
      field(salary.cast(), 'receiptEvidence', 'maps?', 'settings.salary');
      final payMonths = <Object?>{};
      for (final e in (salary['receiptEvidence'] as List?) ?? const []) {
        final proof = (e as Map).cast<String, Object?>();
        const where = 'settings.salary.receiptEvidence';
        field(proof, 'transactionIds', 'ids', where);
        field(proof, 'payMonth', 'id', where);
        // 명목 회차는 정확한 YYYY-MM이고 사용자·스냅샷에서 유일하다(data-model '급여 회차와 예정일').
        final month = proof['payMonth'] as String;
        if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month) ||
            month.startsWith('0000')) {
          throw const SnapshotContractException(
            r'$.settings.salary.receiptEvidence.payMonth',
            'YYYY-MM 급여 회차가 아님',
          );
        }
        if (!payMonths.add(month)) {
          throw const SnapshotContractException(
            r'$.settings.salary.receiptEvidence.payMonth',
            '같은 회차 근거 중복',
          );
        }
      }
    }
    field(settings.cast(), 'cardPlans', 'maps?', 'settings');
    for (final p in (settings['cardPlans'] as List?) ?? const []) {
      field((p as Map).cast(), 'cardId', 'id', 'settings.cardPlans');
    }
  }

  /// 2026-10-22: 공개 판정 전에 원본을 검증한다. 모든 자원 행의 userId가 응답 사용자와 같아야 하고,
  /// 필수 부모·참조(계좌·카드·청구·의무·보호·정산·계획·버전·거래)가 원본 안에 실제로 있어야 한다.
  /// 모순된 원본은 다른 값으로 대체하지 않고 계약 오류로 거절한다.
  void validateSource({required bool requireConnected}) {
    _checkTypes(requireConnected);
    final userId = header['userId'];
    if (userId is! String || userId.isEmpty) {
      throw const SnapshotContractException(r'$.userId', '사용자 ID 없음');
    }
    const owned = [
      'accounts',
      'cards',
      'transactions',
      'relatedTransactions',
      'statements',
      'obligations',
      'reserves',
      'allocations',
      'settlements',
      'recurringPlans',
      'recurringDecisions',
      'recurringPlanRevisions',
      'occurrenceOverrides',
    ];
    for (final key in owned) {
      for (final row in _optional(key)) {
        if (row['userId'] != userId) {
          throw SnapshotContractException(key, '다른 사용자 자료가 섞임');
        }
      }
    }
    Set<String> ids(String key, String field) => {
      for (final row in _optional(key)) row[field] as String,
    };
    final accounts = ids('accounts', 'accountId');
    final cards = ids('cards', 'cardId');
    final transactions = {
      ...ids('transactions', 'transactionId'),
      ...ids('relatedTransactions', 'transactionId'),
    };
    final statements = ids('statements', 'statementId');
    final obligations = ids('obligations', 'obligationId');
    final reserves = ids('reserves', 'reserveId');
    final settlements = ids('settlements', 'linkId');
    final plans = ids('recurringPlans', 'planId');
    final revisions = {
      for (final r in _optional('recurringPlanRevisions'))
        r['revisionId'] as String: r['planId'],
    };
    void need(bool ok, String where, {String reason = '원본에 없는 부모·참조'}) {
      if (!ok) throw SnapshotContractException(where, reason);
    }

    bool optionalIn(Object? id, Set<String> set) =>
        id == null || set.contains(id);
    const planKeys = {'userId', 'planId', 'firstOccurrenceMonth'};
    for (final p in _optional('recurringPlans')) {
      need(
        p.keys.toSet().length == planKeys.length &&
            p.keys.toSet().containsAll(planKeys),
        'recurringPlans',
        reason: '계획은 userId·planId·firstOccurrenceMonth 세 키만 가질 수 있음',
      );
    }
    for (final key in const ['transactions', 'relatedTransactions']) {
      for (final t in _optional(key)) {
        need(optionalIn(t['accountId'], accounts), '$key.accountId');
        need(optionalIn(t['cardId'], cards), '$key.cardId');
      }
    }
    for (final c in _optional('cards')) {
      need(
        optionalIn(c['withdrawalAccountId'], accounts),
        'cards.withdrawalAccountId',
      );
    }
    for (final s in _optional('statements')) {
      need(cards.contains(s['cardId']), 'statements.cardId');
      for (final ref in (s['includedTransactionRefs'] as List?) ?? const []) {
        need(transactions.contains(ref), 'statements.includedTransactionRefs');
      }
    }
    for (final o in _optional('obligations')) {
      need(
        accounts.contains(o['withdrawalAccountId']),
        'obligations.withdrawalAccountId',
      );
      need(optionalIn(o['statementId'], statements), 'obligations.statementId');
      need(
        optionalIn(o['recurringPlanId'], plans),
        'obligations.recurringPlanId',
      );
      final revisionId = o['planRevisionId'];
      if (revisionId != null) {
        need(revisions.containsKey(revisionId), 'obligations.planRevisionId');
        need(
          revisions[revisionId] == o['recurringPlanId'],
          'obligations.planRevisionId',
        );
      }
    }
    for (final r in _optional('reserves')) {
      need(accounts.contains(r['accountId']), 'reserves.accountId');
    }
    for (final s in _optional('settlements')) {
      need(obligations.contains(s['obligationId']), 'settlements.obligationId');
      need(
        transactions.contains(s['transactionId']),
        'settlements.transactionId',
      );
    }
    for (final a in _optional('allocations')) {
      need(reserves.contains(a['reserveId']), 'allocations.reserveId');
      need(obligations.contains(a['obligationId']), 'allocations.obligationId');
      for (final e in (a['releaseEvidence'] as List?) ?? const []) {
        need(
          settlements.contains((e as Map)['settlementLinkId']),
          'allocations.releaseEvidence',
        );
      }
    }
    for (final r in _optional('recurringPlanRevisions')) {
      need(plans.contains(r['planId']), 'recurringPlanRevisions.planId');
      need(
        accounts.contains(r['withdrawalAccountId']),
        'recurringPlanRevisions.withdrawalAccountId',
      );
      need(optionalIn(r['cardId'], cards), 'recurringPlanRevisions.cardId');
    }
    for (final o in _optional('occurrenceOverrides')) {
      need(
        revisions.containsKey(o['planRevisionId']),
        'occurrenceOverrides.planRevisionId',
      );
      need(
        accounts.contains(o['withdrawalAccountId']),
        'occurrenceOverrides.withdrawalAccountId',
      );
      final planId = (o['recurrenceKey'] as String?)?.split(':').first;
      need(
        planId != null && plans.contains(planId),
        'occurrenceOverrides.recurrenceKey',
      );
      need(
        revisions[o['planRevisionId']] == planId,
        'occurrenceOverrides.planRevisionId',
        reason: '회차의 고정 버전이 회차 계획에 속하지 않음',
      );
    }
    for (final d in _optional('recurringDecisions')) {
      need(optionalIn(d['planId'], plans), 'recurringDecisions.planId');
      for (final id in (d['evidenceTransactionIds'] as List?) ?? const []) {
        need(
          transactions.contains(id),
          'recurringDecisions.evidenceTransactionIds',
        );
      }
    }
    for (final l in _optional('occurrenceLinks')) {
      final planId = (l['recurrenceKey'] as String?)?.split(':').first;
      need(
        planId != null && plans.contains(planId),
        'occurrenceLinks.recurrenceKey',
      );
      need(
        optionalIn(l['obligationId'], obligations),
        'occurrenceLinks.obligationId',
      );
      need(
        optionalIn(l['statementId'], statements),
        'occurrenceLinks.statementId',
      );
      need(
        optionalIn(l['purchaseTransactionId'], transactions),
        'occurrenceLinks.purchaseTransactionId',
      );
    }
    for (final r in _optional('transactionRelations')) {
      need(
        transactions.contains(r['fromId']) && transactions.contains(r['toId']),
        'transactionRelations',
      );
    }
    for (final c in _optional('coverage')) {
      final set = c['targetKind'] == 'account' ? accounts : cards;
      need(set.contains(c['targetId']), 'coverage.targetId');
    }
    final settings = src['settings'];
    if (settings is Map) {
      final salary = settings['salary'];
      if (salary is Map) {
        need(
          optionalIn(salary['salaryAccountId'], accounts),
          'settings.salary.salaryAccountId',
        );
        for (final e in (salary['receiptEvidence'] as List?) ?? const []) {
          for (final id
              in ((e as Map)['transactionIds'] as List?) ?? const []) {
            need(transactions.contains(id), 'settings.salary.receiptEvidence');
          }
        }
      }
      for (final p in (settings['cardPlans'] as List?) ?? const []) {
        need(cards.contains((p as Map)['cardId']), 'settings.cardPlans');
      }
    }
  }

  /// 2026-10-22: 원본에 있으면 객체 배열 [key]를, 없으면(연결 전 원본 등) 빈 목록을 반환한다.
  List<Map<String, Object?>> _optional(String key) =>
      src.containsKey(key) ? _list(key) : const [];

  /// 2026-10-22: 연결 후 Snapshot을 키 순서대로 만들어 반환한다.
  Map<String, Object?> build() {
    final accounts = _accounts();
    final cards = _cards();
    final transactions = _transactions('transactions');
    final related = _transactions('relatedTransactions');
    final references = _referenceResolutions();
    final relations = _transactionRelations();
    final statements = _statements();
    final revisions = _revisions();
    final plans = _plans();
    final obligations = _obligations();
    final reserves = _reserves();
    final settlements = _settlements();
    final allocations = _allocations();
    final overrides = _overrides();
    final decisions = _decisions();
    final occurrenceLinks = _occurrenceLinks();
    final settings = _settings();
    final coverage = _coverage();
    _checkRefs([
      accounts,
      cards,
      transactions,
      related,
      statements,
      obligations,
      settlements,
      relations,
      occurrenceLinks,
      revisions,
    ]);
    return {
      ...header,
      'institutions': _institutions,
      'institutionLinks': [
        for (final link in state.institutionLinks)
          Map<String, Object?>.of(link),
      ],
      'coverage': coverage,
      'accounts': accounts,
      'cards': cards,
      'transactions': transactions,
      'statements': statements,
      'settings': settings,
      'obligations': obligations,
      'reserves': reserves,
      'allocations': allocations,
      'settlements': settlements,
      'recurringPlans': plans,
      'recurringDecisions': decisions,
      'recurringPlanRevisions': revisions,
      'occurrenceOverrides': overrides,
      'relatedTransactions': related,
      'referenceResolutions': references,
      'transactionRelations': relations,
      'occurrenceLinks': occurrenceLinks,
      'page': {
        'nextCursor': null,
        'dataVersion': state.dataVersion,
        'sourceVersion': src['sourceVersion'],
      },
      'accessRestrictions': _restrictions,
    };
  }

  /// 2026-10-22: 연결 은행의 계좌만 공개한다. included는 계좌 선택 저장 값으로만 정한다(최초 연결로 확정하지 않음).
  List<Map<String, Object?>> _accounts() {
    final out = <Map<String, Object?>>[];
    for (final a in _list('accounts')) {
      final id = a['accountId'] as String;
      if (_connectedAs(a['institutionCode'] as String?, 'bank', 'accounts')) {
        _visibleAccounts.add(id);
        a['included'] = state.selectedAccountIds?.contains(id) ?? false;
        out.add(a);
      } else {
        _hiddenIds.add(id);
        _restrict('response', null, 'accounts', 'account');
      }
    }
    return out;
  }

  /// 2026-10-22: 연결 카드사의 카드만 공개하고, 출금 계좌가 미연결이면 그 키만 생략한다.
  List<Map<String, Object?>> _cards() {
    final out = <Map<String, Object?>>[];
    for (final c in _list('cards')) {
      final id = c['cardId'] as String;
      if (!_connectedAs(c['institutionCode'] as String?, 'card', 'cards')) {
        _hiddenIds.add(id);
        _restrict('response', null, 'cards', 'card');
        continue;
      }
      _visibleCards.add(id);
      final withdrawal = c['withdrawalAccountId'] as String?;
      if (withdrawal != null && !_visibleAccounts.contains(withdrawal)) {
        c.remove('withdrawalAccountId');
        _restrict('card', id, 'withdrawalAccountId', 'account');
      }
      out.add(c);
    }
    return out;
  }

  /// 2026-10-22: 거래 공개 기준(§2.2)으로 [key] 배열을 투영한다. 주 원천 연결로 공개를 정하고 반대쪽 미연결 참조는 생략한다.
  List<Map<String, Object?>> _transactions(String key) {
    final rows = _list(key);
    for (final t in rows) {
      _knownTransactions.add(t['transactionId'] as String);
    }
    final out = <Map<String, Object?>>[];
    for (final t in rows) {
      final id = t['transactionId'] as String;
      final kind = t['recordKind'] as String?;
      final accountId = t['accountId'] as String?;
      final cardId = t['cardId'] as String?;
      final bool visible;
      if (kind == 'account_entry') {
        if (accountId == null) {
          throw SnapshotContractException(key, '계좌 거래에 accountId 없음');
        }
        visible = _accountConnected(accountId, key);
      } else if (kind == 'card_purchase' ||
          kind == 'card_refund' ||
          kind == 'card_cancellation') {
        if (cardId == null) {
          throw SnapshotContractException(key, '카드 거래에 cardId 없음');
        }
        visible = _cardConnected(cardId, key);
      } else {
        throw SnapshotContractException(key, '알 수 없는 recordKind');
      }
      if (!visible) {
        _hiddenIds.add(id);
        _restrict('response', null, key, 'transaction');
        continue;
      }
      _visibleTransactions.add(id);
      out.add(t);
    }
    for (final t in out) {
      final id = t['transactionId'] as String;
      final accountId = t['accountId'] as String?;
      final cardId = t['cardId'] as String?;
      if (accountId != null &&
          t['recordKind'] != 'account_entry' &&
          !_visibleAccounts.contains(accountId)) {
        t.remove('accountId');
        _restrict('transaction', id, 'accountId', 'account');
      }
      if (cardId != null &&
          t['recordKind'] == 'account_entry' &&
          !_visibleCards.contains(cardId)) {
        t.remove('cardId');
        _restrict('transaction', id, 'cardId', 'card');
      }
    }
    return out;
  }

  /// 2026-10-22: [accountId] 계좌의 은행이 연결됐으면 true를 반환한다. 원본에 없는 계좌는 계약 오류다.
  bool _accountConnected(String accountId, String where) {
    final account = _list('accounts').where((a) => a['accountId'] == accountId);
    if (account.isEmpty) throw SnapshotContractException(where, '원본에 없는 계좌 참조');
    return _connectedAs(
      account.first['institutionCode'] as String?,
      'bank',
      where,
    );
  }

  /// 2026-10-22: [cardId] 카드의 카드사가 연결됐으면 true를 반환한다. 원본에 없는 카드는 계약 오류다.
  bool _cardConnected(String cardId, String where) {
    final card = _list('cards').where((c) => c['cardId'] == cardId);
    if (card.isEmpty) throw SnapshotContractException(where, '원본에 없는 카드 참조');
    return _connectedAs(
      card.first['institutionCode'] as String?,
      'card',
      where,
    );
  }

  /// 2026-10-22: 공개 거래의 원거래 참조를 검사한다. 미연결이면 생략, 원본에 없는 미확보 원거래는 검증된 근거가 없으므로 계약 오류다(§2.2).
  void _originals(List<Map<String, Object?>> rows) {
    for (final t in rows) {
      if (!_visibleTransactions.contains(t['transactionId'])) continue;
      final original = t['originalTransactionId'] as String?;
      if (original == null) continue;
      if (_knownTransactions.contains(original)) {
        if (!_visibleTransactions.contains(original)) {
          t.remove('originalTransactionId');
          _restrict(
            'transaction',
            t['transactionId'] as String,
            'originalTransactionId',
            'transaction',
          );
        }
      } else {
        throw const SnapshotContractException(
          'transactions.originalTransactionId',
          '미확보 원거래의 사용자·기관 근거가 없어 공개 권한을 판정할 수 없음',
        );
      }
    }
  }

  /// 2026-10-22: 공개 거래의 미확보 참조 상태만 남긴다. 숨긴 거래를 이 배열로 우회 공개하지 않는다.
  List<Map<String, Object?>> _referenceResolutions() {
    final out = <Map<String, Object?>>[];
    for (final r in _list('referenceResolutions')) {
      final id = r['transactionId'] as String;
      if (_knownTransactions.contains(id)) {
        if (_visibleTransactions.contains(id)) {
          out.add(r);
        } else {
          _restrict('response', null, 'referenceResolutions', 'transaction');
        }
      } else {
        throw const SnapshotContractException(
          'referenceResolutions',
          '미확보 참조의 사용자·기관 근거가 없어 공개 권한을 판정할 수 없음',
        );
      }
    }
    return out;
  }

  /// 2026-10-22: 양 끝 거래가 모두 공개된 관계만 남기고, 공개된 쪽 거래에 관계 제한을 표시한다.
  List<Map<String, Object?>> _transactionRelations() {
    final out = <Map<String, Object?>>[];
    for (final r in _list('transactionRelations')) {
      final from = r['fromId'] as String;
      final to = r['toId'] as String;
      final fromVisible = _visibleTransactions.contains(from);
      final toVisible = _visibleTransactions.contains(to);
      if (fromVisible && toVisible) {
        out.add(r);
        continue;
      }
      _restrict('response', null, 'transactionRelations', 'transaction');
      if (fromVisible) {
        _restrict('transaction', from, 'transactionRelations', 'transaction');
      }
      if (toVisible) {
        _restrict('transaction', to, 'transactionRelations', 'transaction');
      }
    }
    return out;
  }

  /// 2026-10-22: 부모 카드가 공개된 청구서만 남기고, 포함 거래 중 미연결 거래 참조를 생략한다.
  List<Map<String, Object?>> _statements() {
    _originals(_list('transactions'));
    _originals(_list('relatedTransactions'));
    final out = <Map<String, Object?>>[];
    for (final s in _list('statements')) {
      final id = s['statementId'] as String;
      final cardId = s['cardId'] as String?;
      if (cardId == null || !_visibleCards.contains(cardId)) {
        _hiddenIds.add(id);
        _restrict('response', null, 'statements', 'card');
        continue;
      }
      _visibleStatements.add(id);
      final refs =
          (s['includedTransactionRefs'] as List?)?.cast<String>() ??
          const <String>[];
      final kept = [
        for (final ref in refs)
          if (_visibleTransactions.contains(ref)) ref,
      ];
      if (kept.length != refs.length) {
        s['includedTransactionRefs'] = kept;
        _restrict('statement', id, 'includedTransactionRefs', 'transaction');
      }
      out.add(s);
    }
    return out;
  }

  /// 2026-10-22: 계획 버전을 출금 계좌 연결로 공개 판정하고, 미연결 카드는 cardId 키만 생략한다.
  List<Map<String, Object?>> _revisions() {
    final out = <Map<String, Object?>>[];
    for (final r in _list('recurringPlanRevisions')) {
      final id = r['revisionId'] as String;
      _knownRevisions.add(id);
      final withdrawal = r['withdrawalAccountId'] as String?;
      if (withdrawal == null || !_visibleAccounts.contains(withdrawal)) {
        _hiddenIds.add(id);
        _restrict('response', null, 'recurringPlanRevisions', 'account');
        continue;
      }
      final cardId = r['cardId'] as String?;
      if (cardId != null && !_visibleCards.contains(cardId)) {
        r.remove('cardId');
        _restrict('recurringPlanRevision', id, 'cardId', 'card');
      }
      _visibleRevisions.add(id);
      _visiblePlans.add(r['planId'] as String);
      out.add(r);
    }
    return out;
  }

  /// 2026-10-22: 공개 버전이 하나 이상인 계획만 공개하고, 숨긴 버전이 섞인 계획에 버전 제한을 표시한다.
  List<Map<String, Object?>> _plans() {
    final revisions = _list('recurringPlanRevisions');
    final out = <Map<String, Object?>>[];
    for (final p in _list('recurringPlans')) {
      final id = p['planId'] as String;
      _knownPlans.add(id);
      if (!_visiblePlans.contains(id)) {
        _hiddenIds.add(id);
        _restrict('response', null, 'recurringPlans', 'account');
        continue;
      }
      final hiddenRevision = revisions.any(
        (r) =>
            r['planId'] == id && !_visibleRevisions.contains(r['revisionId']),
      );
      if (hiddenRevision) {
        _restrict(
          'recurringPlan',
          id,
          'recurringPlanRevisions',
          'planRevision',
        );
      }
      out.add(p);
    }
    return out;
  }

  /// 2026-10-22: 계획 ID [planId]·고정 버전 [revisionId] 참조가 숨겨졌으면 그 종류를, 공개면 null을 반환한다.
  String? _hiddenPlanRef(String? planId, String? revisionId) {
    if (planId != null &&
        _knownPlans.contains(planId) &&
        !_visiblePlans.contains(planId)) {
      return 'plan';
    }
    if (revisionId != null &&
        _knownRevisions.contains(revisionId) &&
        !_visibleRevisions.contains(revisionId)) {
      return 'planRevision';
    }
    return null;
  }

  /// 2026-10-22: 출금 계좌가 공개된 예정 지출만 남기고, 숨긴 청구 참조는 statementId 키만 생략한다.
  List<Map<String, Object?>> _obligations() {
    final out = <Map<String, Object?>>[];
    for (final o in _list('obligations')) {
      final id = o['obligationId'] as String;
      final withdrawal = o['withdrawalAccountId'] as String?;
      if (withdrawal == null || !_visibleAccounts.contains(withdrawal)) {
        _hiddenIds.add(id);
        _restrict('response', null, 'obligations', 'account');
        continue;
      }
      final planRef = _hiddenPlanRef(
        o['recurringPlanId'] as String?,
        o['planRevisionId'] as String?,
      );
      if (planRef != null) {
        _hiddenIds.add(id);
        _restrict('response', null, 'obligations', planRef);
        continue;
      }
      final statementId = o['statementId'] as String?;
      if (statementId != null && !_visibleStatements.contains(statementId)) {
        o.remove('statementId');
        _restrict('obligation', id, 'statementId', 'statement');
      }
      _visibleObligations.add(id);
      out.add(o);
    }
    return out;
  }

  /// 2026-10-22: 보호 계좌가 공개된 모아둘 돈만 남긴다.
  List<Map<String, Object?>> _reserves() {
    final out = <Map<String, Object?>>[];
    for (final r in _list('reserves')) {
      final id = r['reserveId'] as String;
      if (!_visibleAccounts.contains(r['accountId'])) {
        _hiddenIds.add(id);
        _restrict('response', null, 'reserves', 'account');
        continue;
      }
      _visibleReserves.add(id);
      out.add(r);
    }
    return out;
  }

  /// 2026-10-22: 의무와 정산 거래가 모두 공개된 정산만 남기고, 공개 의무의 숨긴 정산은 부모에 제한을 표시한다.
  List<Map<String, Object?>> _settlements() {
    final out = <Map<String, Object?>>[];
    for (final s in _list('settlements')) {
      final obligationId = s['obligationId'] as String;
      final transactionId = s['transactionId'] as String;
      if (!_visibleObligations.contains(obligationId)) {
        _hiddenIds.add(s['linkId'] as String);
        _restrict('response', null, 'settlements', 'obligation');
        continue;
      }
      if (!_visibleTransactions.contains(transactionId)) {
        _hiddenIds.add(s['linkId'] as String);
        _restrict('response', null, 'settlements', 'transaction');
        _restrict('obligation', obligationId, 'settlements', 'transaction');
        continue;
      }
      out.add(s);
    }
    return out;
  }

  /// 2026-10-22: 부모 보호·의무가 공개된 배정만 남기고, 해제 근거가 숨긴 정산 거래를 드러내면 그 키만 생략한다.
  List<Map<String, Object?>> _allocations() {
    final settlements = {
      for (final s in _list('settlements')) s['linkId'] as String: s,
    };
    final out = <Map<String, Object?>>[];
    for (final a in _list('allocations')) {
      final id = a['allocationId'] as String;
      if (!_visibleReserves.contains(a['reserveId'])) {
        _hiddenIds.add(id);
        _restrict('response', null, 'allocations', 'reserve');
        continue;
      }
      if (!_visibleObligations.contains(a['obligationId'])) {
        _hiddenIds.add(id);
        _restrict('response', null, 'allocations', 'obligation');
        continue;
      }
      final evidence = (a['releaseEvidence'] as List?) ?? const [];
      final revealsHidden = evidence.any((e) {
        final link = settlements[(e as Map)['settlementLinkId']];
        return link != null &&
            !_visibleTransactions.contains(link['transactionId']);
      });
      if (revealsHidden) {
        a.remove('releaseEvidence');
        _restrict('allocation', id, 'releaseEvidence', 'transaction');
      }
      out.add(a);
    }
    return out;
  }

  /// 2026-10-22: 출금 계좌·고정 버전·계획이 공개된 회차 override만 남긴다.
  List<Map<String, Object?>> _overrides() {
    final out = <Map<String, Object?>>[];
    for (final o in _list('occurrenceOverrides')) {
      if (!_visibleAccounts.contains(o['withdrawalAccountId'])) {
        _restrict('response', null, 'occurrenceOverrides', 'account');
        continue;
      }
      final planId = (o['recurrenceKey'] as String?)?.split(':').first;
      final planRef = _hiddenPlanRef(planId, o['planRevisionId'] as String?);
      if (planRef != null) {
        _restrict('response', null, 'occurrenceOverrides', planRef);
        continue;
      }
      out.add(o);
    }
    return out;
  }

  /// 2026-10-22: 승인 계획과 근거 거래가 모두 공개된 반복 결정만 남긴다.
  List<Map<String, Object?>> _decisions() {
    final out = <Map<String, Object?>>[];
    for (final d in _list('recurringDecisions')) {
      final planId = d['planId'] as String?;
      if (planId != null && _hiddenPlanRef(planId, null) != null) {
        _restrict('response', null, 'recurringDecisions', 'plan');
        continue;
      }
      final evidence =
          (d['evidenceTransactionIds'] as List?)?.cast<String>() ??
          const <String>[];
      if (evidence.any(
        (e) =>
            _knownTransactions.contains(e) && !_visibleTransactions.contains(e),
      )) {
        _restrict('response', null, 'recurringDecisions', 'transaction');
        continue;
      }
      out.add(d);
    }
    return out;
  }

  /// 2026-10-22: 명시된 참조(계획·구매 거래·청구·의무)가 모두 공개된 회차 연결만 남긴다.
  List<Map<String, Object?>> _occurrenceLinks() {
    final out = <Map<String, Object?>>[];
    for (final l in _list('occurrenceLinks')) {
      final planId = (l['recurrenceKey'] as String?)?.split(':').first;
      final String? hidden;
      if (_hiddenPlanRef(planId, null) != null) {
        hidden = 'plan';
      } else if (l['purchaseTransactionId'] != null &&
          !_visibleTransactions.contains(l['purchaseTransactionId'])) {
        hidden = 'transaction';
      } else if (l['statementId'] != null &&
          !_visibleStatements.contains(l['statementId'])) {
        hidden = 'statement';
      } else if (l['obligationId'] != null &&
          !_visibleObligations.contains(l['obligationId'])) {
        hidden = 'obligation';
      } else {
        hidden = null;
      }
      if (hidden != null) {
        _restrict('response', null, 'occurrenceLinks', hidden);
        continue;
      }
      out.add(l);
    }
    return out;
  }

  /// 2026-10-22: 급여 계좌·급여 근거·카드 계획의 미연결 참조를 생략하고 settings 제한을 표시한다. 나머지 설정은 유지한다.
  Map<String, Object?> _settings() {
    final settings = (src['settings'] as Map).cast<String, Object?>();
    final salary = (settings['salary'] as Map?)?.cast<String, Object?>();
    if (salary != null) {
      final salaryAccount = salary['salaryAccountId'] as String?;
      final accountHidden =
          salaryAccount != null && !_visibleAccounts.contains(salaryAccount);
      if (accountHidden) {
        salary.remove('salaryAccountId');
        _restrict('settings', null, 'salary.salaryAccountId', 'account');
      }
      final evidence = (salary['receiptEvidence'] as List?) ?? const [];
      final hiddenEvidence = evidence.any(
        (e) => ((e as Map)['transactionIds'] as List).any(
          (id) =>
              _knownTransactions.contains(id) &&
              !_visibleTransactions.contains(id),
        ),
      );
      if (evidence.isNotEmpty && accountHidden) {
        salary.remove('receiptEvidence');
        _restrict('settings', null, 'salary.receiptEvidence', 'account');
      } else if (hiddenEvidence) {
        salary.remove('receiptEvidence');
        _restrict('settings', null, 'salary.receiptEvidence', 'transaction');
      }
      settings['salary'] = salary;
    }
    final plans = (settings['cardPlans'] as List?) ?? const [];
    final keptPlans = [
      for (final p in plans)
        if (_visibleCards.contains((p as Map)['cardId'])) p,
    ];
    if (keptPlans.length != plans.length) {
      _restrict('settings', null, 'cardPlans', 'card');
    }
    settings['cardPlans'] = keptPlans;
    return settings;
  }

  /// 2026-10-22: 공개 계좌·카드의 조회 범위만 남긴다.
  List<Map<String, Object?>> _coverage() {
    final out = <Map<String, Object?>>[];
    for (final c in _list('coverage')) {
      final kind = c['targetKind'];
      final id = c['targetId'];
      if (kind != 'account' && kind != 'card') {
        throw const SnapshotContractException('coverage', '알 수 없는 targetKind');
      }
      kind as String;
      final visible = kind == 'account'
          ? _visibleAccounts.contains(id)
          : _visibleCards.contains(id);
      if (visible) {
        out.add(c);
      } else {
        _restrict('response', null, 'coverage', kind);
      }
    }
    return out;
  }

  /// 2026-10-22: 공개 행의 sourceRef·evidenceRef(s)에 숨긴 자원 ID가 섞였으면 계약 오류를 던진다.
  void _checkRefs(List<List<Map<String, Object?>>> groups) {
    if (_hiddenIds.isEmpty) return;
    for (final rows in groups) {
      for (final row in rows) {
        final refs = <Object?>[
          row['sourceRef'],
          row['evidenceRef'],
          ...?(row['evidenceRefs'] as List?),
          for (final e in (row['scheduleEvidence'] as List?) ?? const [])
            (e as Map)['evidenceRef'],
          for (final e in (row['scheduleOverrides'] as List?) ?? const [])
            (e as Map)['evidenceRef'],
        ];
        for (final ref in refs.whereType<String>()) {
          if (_hiddenIds.any(ref.contains)) {
            throw const SnapshotContractException(
              'sourceRef',
              '공개 행 참조에 숨긴 자원 ID가 있음',
            );
          }
        }
      }
    }
  }
}
