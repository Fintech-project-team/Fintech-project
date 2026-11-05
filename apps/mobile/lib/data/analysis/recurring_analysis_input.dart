import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../financial_snapshot.dart';
import 'analysis_identity.dart';

/// 2026-11-05: 분석 요청 한 번의 상한(apps/api/docs/analysis-api.md, 스키마 recurringInput).
const int maxCandidatesPerAnalysis = 20;
const int maxTransactionsPerAnalysis = 60;

/// 2026-11-05: 공통 계약 버전. 서버 스키마의 고정값이며 context.schemaVersion은 v4 스냅샷이어도 API 값이다.
const String analysisContractVersion = 'PAYSE-ANALYSIS-1';
const String analysisSchemaVersion = 'PAYSE-API-0.6-4';

/// 2026-11-05: 분석 입력에 넣지 못한 이유. 이번 준비 결과에만 담고 영구 제외로 저장하지 않는다.
enum RecurringNotAnalyzedReason {
  /// 근거가 겹치는 후보 그룹 전체가 한 요청의 후보 20개·거래 60개를 넘는다. 그룹을 쪼개지 않는다.
  groupTooLarge,

  /// 근거에 닿는 거래(원거래·관계 상대)를 이번 조회에서 받지 못했다. 다시 조회하면 풀릴 수 있다.
  transactionNotReceived,

  /// 서버가 원거래를 미확보(referenceResolutions status=unavailable)로 명시했다. 사유는 [RecurringNotAnalyzed.serverReason].
  originalUnavailable,

  /// 근거 거래에 계약 필수 원천 필드(reflectionReason)가 없다.
  sourceFieldMissing,

  /// 이 후보는 문제가 없지만 근거가 겹치는 같은 그룹의 다른 후보를 보낼 수 없어 함께 보류한다.
  groupMemberHeld,
}

/// 2026-11-05: 분석 입력에 넣지 못한 후보 [candidate]와 이유 [reason]. 0개나 분석 실패로 바꾸지 않는다.
/// [transactionIds]는 원인 거래 ID(정렬), [serverReason]은 originalUnavailable일 때 서버 사유 원문,
/// [groupKeys]는 같은 그룹 후보 키 전체(정렬)다.
final class RecurringNotAnalyzed {
  /// 2026-11-05: 후보·이유·원인 거래·서버 사유·그룹 후보 키로 만든다.
  RecurringNotAnalyzed({
    required this.candidate,
    required this.reason,
    Iterable<String> transactionIds = const [],
    this.serverReason,
    required Iterable<String> groupKeys,
  }) : transactionIds = List.unmodifiable(transactionIds),
       groupKeys = List.unmodifiable(groupKeys);

  final calc.RecurringCandidate candidate;
  final RecurringNotAnalyzedReason reason;
  final List<String> transactionIds;
  final String? serverReason;
  final List<String> groupKeys;
}

/// 2026-11-05: 작업 하나로 보낼 반복 의미 분석 묶음. [input]은 /input·/retry·/analysis-results/query의
/// `input`, [accept]는 POST /analysis-jobs 본문에서 idempotencyKey·previousJobId를 뺀 부분이다.
/// [candidateByItemKey]는 응답 itemKey를 앱 후보 키로 되돌리는 대응표다.
final class RecurringAnalysisBatch {
  /// 2026-11-05: 입력·접수 본문·지문·대응표로 만든다.
  RecurringAnalysisBatch({
    required this.input,
    required this.accept,
    required this.identity,
    required Map<String, String> candidateByItemKey,
  }) : candidateByItemKey = Map.unmodifiable(candidateByItemKey);

  final Map<String, Object?> input;
  final Map<String, Object?> accept;
  final AnalysisIdentity identity;
  final Map<String, String> candidateByItemKey;
}

/// 2026-11-05: 반복 의미 분석 준비 결과. [batches]가 비고 [notAnalyzed]도 비면 보낼 후보가 없는 것이다.
/// 정상 0개인지는 [detection]의 completeWithoutCandidates로 따로 판단한다.
final class RecurringAnalysisPlan {
  /// 2026-11-05: 탐지 결과, 보낼 묶음, 보내지 못한 후보로 만든다.
  RecurringAnalysisPlan({
    required this.detection,
    required Iterable<RecurringAnalysisBatch> batches,
    required Iterable<RecurringNotAnalyzed> notAnalyzed,
  }) : batches = List.unmodifiable(batches),
       notAnalyzed = List.unmodifiable(notAnalyzed);

  final calc.RecurringDetection detection;
  final List<RecurringAnalysisBatch> batches;
  final List<RecurringNotAnalyzed> notAnalyzed;
}

/// 2026-11-05: [detection]의 후보로 recurringMeaning 분석 입력과 접수 본문을 만든다(docs/analysis-protocol.md §1·§2).
///
/// [snapshot]은 탐지에 쓴 스냅샷, [transactions]는 끝까지 받은 거래다. 원거래·관계 상대는 스냅샷의
/// relatedTransactions에서도 찾는다. [localSessionEpoch]·[inputRevision]은 응답이 현재 화면 것인지
/// 앱이 가리는 값이고, [triggerKind]는 접수 종류다(연결 저장 뒤 처음 공개된 범위는 A, docs/payse-execution-contract.md EX-A).
/// 넓힌 근거가 겹치는 후보는 한 그룹으로 같은 묶음에 넣고, 그룹을 첫 후보 순으로 후보 20개·거래 60개를
/// 넘지 않게 채운다. 한도를 넘거나 보낼 수 없는 후보가 있는 그룹은 쪼개지 않고 전부 [RecurringAnalysisPlan.notAnalyzed]에
/// 둔다. v4 스냅샷이 아니면 [FormatException]이다.
RecurringAnalysisPlan planRecurringAnalysis({
  required FinancialSnapshot snapshot,
  required calc.RecurringDetection detection,
  required List<SourceTransaction> transactions,
  required int localSessionEpoch,
  required String triggerKind,
  int inputRevision = 0,
}) {
  if (!FinancialSnapshot.v4Schemas.contains(snapshot.schemaVersion)) {
    throw FormatException('v4가 아닌 스냅샷: ${snapshot.schemaVersion}');
  }
  if (localSessionEpoch < 0 || inputRevision < 0) {
    throw ArgumentError('localSessionEpoch·inputRevision은 0 이상');
  }
  final source = _Source(snapshot, transactions);
  final context = <String, Object?>{
    'schemaVersion': analysisSchemaVersion,
    'dataVersion': snapshot.dataVersion,
    'sourceVersion': snapshot.sourceVersion,
    'ruleVersion': snapshot.ruleVersion,
    'asOf': snapshot.asOf,
    'inputRevision': inputRevision,
    'localSessionEpoch': localSessionEpoch,
    'selectedAccountIds': [
      for (final a in snapshot.accounts ?? const <Account>[])
        if (a.included) a.accountId,
    ]..sort(),
  };

  final ordered = [...detection.candidates]
    ..sort((a, b) => a.key.compareTo(b.key));
  final reach = [for (final c in ordered) source.closure(c.evidenceIds)];
  final batches = <RecurringAnalysisBatch>[];
  final notAnalyzed = <RecurringNotAnalyzed>[];
  var pending = <(calc.RecurringCandidate, Set<String>)>[];
  var pendingIds = <String>{};
  void flush() {
    if (pending.isEmpty) return;
    batches.add(_batch(context, triggerKind, pending, source));
    pending = [];
    pendingIds = {};
  }

  for (final group in _groups(reach)) {
    final keys = [for (final i in group) ordered[i].key];
    final ids = <String>{for (final i in group) ...reach[i].refs};
    final held = group.any((i) => reach[i].problem != null);
    if (held ||
        group.length > maxCandidatesPerAnalysis ||
        ids.length > maxTransactionsPerAnalysis) {
      for (final i in group) {
        final problem = reach[i].problem;
        notAnalyzed.add(
          RecurringNotAnalyzed(
            candidate: ordered[i],
            reason:
                problem?.reason ??
                (held
                    ? RecurringNotAnalyzedReason.groupMemberHeld
                    : RecurringNotAnalyzedReason.groupTooLarge),
            transactionIds: problem?.transactionIds ?? const [],
            serverReason: problem?.serverReason,
            groupKeys: keys,
          ),
        );
      }
      continue;
    }
    if (pending.length + group.length > maxCandidatesPerAnalysis ||
        {...pendingIds, ...ids}.length > maxTransactionsPerAnalysis) {
      flush();
    }
    for (final i in group) {
      pending.add((ordered[i], reach[i].refs));
    }
    pendingIds.addAll(ids);
  }
  flush();
  return RecurringAnalysisPlan(
    detection: detection,
    batches: batches,
    notAnalyzed: notAnalyzed,
  );
}

/// 2026-11-05: 넓힌 근거가 하나라도 겹치는 후보를 연쇄로 묶는다(a–b, b–c면 a·b·c 한 그룹).
/// [reach]는 candidateKey 순 후보별 도달 거래다. 그룹 안은 후보 순, 그룹 사이는 첫 후보 순이라
/// 같은 입력은 항상 같은 그룹·순서를 만든다.
List<List<int>> _groups(List<_Reach> reach) {
  final parent = [for (var i = 0; i < reach.length; i++) i];
  int root(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  final owner = <String, int>{};
  for (var i = 0; i < reach.length; i++) {
    for (final id in reach[i].refs) {
      final seen = owner[id];
      if (seen == null) {
        owner[id] = i;
      } else {
        final a = root(seen);
        final b = root(i);
        if (a != b) parent[a > b ? a : b] = a < b ? a : b;
      }
    }
  }
  final groups = <int, List<int>>{};
  for (var i = 0; i < reach.length; i++) {
    groups.putIfAbsent(root(i), () => []).add(i);
  }
  return groups.values.toList()..sort((a, b) => a.first.compareTo(b.first));
}

/// 2026-11-05: 후보 묶음 [group]으로 입력·접수 본문·지문을 만든다. itemKey는 묶음 안 순번(recurring-N)이다.
RecurringAnalysisBatch _batch(
  Map<String, Object?> context,
  String triggerKind,
  List<(calc.RecurringCandidate, Set<String>)> group,
  _Source source,
) {
  final ids = <String>{for (final (_, refs) in group) ...refs}.toList()..sort();
  final rows = [for (final id in ids) source.byId[id]!];
  final items = <Map<String, Object?>>[];
  final candidates = <Map<String, Object?>>[];
  final candidateByItemKey = <String, String>{};
  for (var i = 0; i < group.length; i++) {
    final candidate = group[i].$1;
    final itemKey = 'recurring-$i';
    final evidence = [...candidate.evidenceIds]..sort();
    candidateByItemKey[itemKey] = candidate.key;
    items.add({
      'itemKey': itemKey,
      'targetTransactionId': null,
      'candidateKey': candidate.key,
      'evidenceTransactionIds': evidence,
    });
    final features = candidate.features;
    candidates.add({
      'candidateKey': candidate.key,
      'ruleVersion': context['ruleVersion'],
      'sourceVersion': context['sourceVersion'],
      'evidenceTransactionIds': evidence,
      'normalizedName': candidate.normalizedName,
      'suggestedAmountKRW': candidate.suggestedAmountKrw,
      'suggestedDay': candidate.suggestedDay,
      'features': {
        'occurrenceCount': features['occurrenceCount'],
        'observedMonths': [...features['observedMonths']! as List],
        'dayWithinRule': features['dayWithinRule'],
        'amountWithinRule': features['amountWithinRule'],
        'hasUnresolvedReversal': features['hasUnresolvedReversal'],
      },
    });
  }

  final input = <String, Object?>{
    'contractVersion': analysisContractVersion,
    'semanticTaskKind': 'recurringMeaning',
    'context': context,
    'items': items,
    'transactions': [
      for (final tx in rows)
        {
          'transactionId': tx.transactionId,
          'recordKind': tx.recordKind,
          'direction': tx.direction,
          'status': tx.status,
          'reflectionReason': tx.reflectionReason,
          'merchantName': tx.merchantName,
          'description': tx.description,
          'originalTransactionId': tx.originalTransactionId,
        },
    ],
    'relations': [
      for (final r in source.relations)
        if (ids.contains(r.fromId) || ids.contains(r.toId))
          {'kind': r.kind, 'fromId': r.fromId, 'toId': r.toId},
    ],
    'unavailableReferences': const <Object?>[],
    'currentClassifications': [
      for (final tx in rows)
        if (tx.payseTransactionType != null)
          {'transactionId': tx.transactionId, 'value': tx.payseTransactionType},
    ],
    'candidates': candidates,
  };
  final identity = identifyAnalysisInput(input);
  return RecurringAnalysisBatch(
    input: input,
    accept: {
      'context': context,
      'triggerKind': triggerKind,
      'semanticTaskKind': 'recurringMeaning',
      'items': [
        for (final item in items)
          {
            'itemKey': item['itemKey'],
            'evidenceTransactionIds': item['evidenceTransactionIds'],
            'candidateIds': [item['candidateKey']],
          },
      ],
      'inputHashHint': identity.inputHashHint,
      'reasonCodes': const <Object?>[],
    },
    identity: identity,
    candidateByItemKey: candidateByItemKey,
  );
}

/// 2026-11-05: 입력에 넣을 수 있는 거래·명시 관계·서버 미확보 표식. 받은 거래와 스냅샷의 관련 거래를 합친다.
final class _Source {
  /// 2026-11-05: [snapshot]의 관계·관련 거래와 끝까지 받은 [transactions]로 만든다.
  _Source(FinancialSnapshot snapshot, List<SourceTransaction> transactions)
    : relations = snapshot.transactionRelations ?? const [],
      resolutions = {
        for (final r
            in snapshot.referenceResolutions ?? const <ReferenceResolution>[])
          r.transactionId: r,
      },
      byId = {
        for (final tx
            in snapshot.relatedTransactions ?? const <SourceTransaction>[])
          tx.transactionId: tx,
        for (final tx in transactions) tx.transactionId: tx,
      };

  final List<TransactionRelation> relations;
  final Map<String, ReferenceResolution> resolutions;
  final Map<String, SourceTransaction> byId;

  /// 2026-11-05: 직접 근거 [direct]를 원거래·관계 양끝으로 더 늘지 않을 때까지 넓힌다. 서버는 닿는 원거래·
  /// 관계 상대를 모두 받아야 검증하므로, 받지 못한 거래·서버가 원거래로 명시한 미확보·필수 필드 누락이 있으면 problem에
  /// 담는다. 여러 문제가 겹치면 서버 명시 미확보 → 미수신 → 필드 누락 순으로 하나를 고른다.
  _Reach closure(List<String> direct) {
    final refs = {...direct};
    final checked = <String>{};
    final notReceived = <String>{};
    final unavailable = <String, String?>{};
    final missingField = <String>{};
    final originals = <String>{};
    while (true) {
      final before = refs.length;
      for (final id in [...refs]) {
        if (!checked.add(id)) continue;
        final tx = byId[id];
        if (tx == null) {
          final resolution = originals.contains(id) ? resolutions[id] : null;
          if (resolution != null && resolution.status == 'unavailable') {
            unavailable[id] = resolution.reason;
          } else {
            notReceived.add(id);
          }
          continue;
        }
        if (tx.reflectionReason == null) missingField.add(id);
        final original = tx.originalTransactionId;
        if (original != null) {
          refs.add(original);
          originals.add(original);
        }
      }
      for (final r in relations) {
        if (refs.contains(r.fromId) || refs.contains(r.toId)) {
          refs
            ..add(r.fromId)
            ..add(r.toId);
        }
      }
      if (refs.length == before) break;
    }

    _Problem? problem;
    if (unavailable.isNotEmpty) {
      final ids = unavailable.keys.toList()..sort();
      problem = _Problem(
        RecurringNotAnalyzedReason.originalUnavailable,
        ids,
        unavailable[ids.first],
      );
    } else if (notReceived.isNotEmpty) {
      problem = _Problem(
        RecurringNotAnalyzedReason.transactionNotReceived,
        notReceived.toList()..sort(),
        null,
      );
    } else if (missingField.isNotEmpty) {
      problem = _Problem(
        RecurringNotAnalyzedReason.sourceFieldMissing,
        missingField.toList()..sort(),
        null,
      );
    }
    return _Reach(refs, problem);
  }
}

/// 2026-11-05: 후보 하나의 도달 거래 [refs]와 보낼 수 없는 이유 [problem](없으면 null).
final class _Reach {
  /// 2026-11-05: 도달 거래와 문제로 만든다.
  const _Reach(this.refs, this.problem);

  final Set<String> refs;
  final _Problem? problem;
}

/// 2026-11-05: 보낼 수 없는 이유 [reason], 원인 거래 [transactionIds], 서버 사유 원문 [serverReason].
final class _Problem {
  /// 2026-11-05: 이유·원인 거래·서버 사유로 만든다.
  const _Problem(this.reason, this.transactionIds, this.serverReason);

  final RecurringNotAnalyzedReason reason;
  final List<String> transactionIds;
  final String? serverReason;
}
