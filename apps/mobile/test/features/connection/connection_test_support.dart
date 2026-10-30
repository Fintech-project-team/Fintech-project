import 'dart:collection';
import 'dart:math';

import 'package:payse/data/connection/financial_api.dart';
import 'package:payse/data/connection/snapshot_projector.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/connection/connection_presentation_policy.dart';

import '../../data/connection/connection_test_utils.dart';

const betaBanks = {
  'bank.kb',
  'bank.shinhan',
  'bank.hana',
  'bank.ibk',
  'bank.kakao',
};
const betaCards = {'card.hyundai', 'card.samsung', 'card.woori', 'card.kb'};

/// 2026-10-22: beta 원본을 [codes] 연결·[selected] 계좌 선택·자료 버전 [version]으로 투영한 응답 JSON을 반환한다.
/// [mutate]로 원본을 먼저 바꿀 수 있다.
Map<String, Object?> betaJson(
  Set<String> codes, {
  Set<String>? selected,
  String version = '1',
  void Function(Map<String, Object?> source)? mutate,
}) {
  final source = readSource('beta-ready');
  mutate?.call(source);
  return SnapshotProjector.project(
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
      selectedAccountIds: selected,
      dataVersion: version,
    ),
  );
}

/// 2026-10-22: [betaJson]을 화면 모델로 읽어 반환한다.
FinancialSnapshot betaSnapshot(
  Set<String> codes, {
  Set<String>? selected,
  String version = '1',
  void Function(Map<String, Object?> source)? mutate,
}) => FinancialSnapshot.fromJson(
  betaJson(codes, selected: selected, version: version, mutate: mutate),
);

/// 2026-10-22: 응답 JSON [json]을 담은 쓰기 성공 결과를 만든다.
FinancialOutcome<WriteSuccess> written(Map<String, Object?> json) =>
    FinancialOk(
      WriteSuccess(
        receipt: WriteReceipt(
          receiptId: 'r',
          operationKey: 'k',
          resultVersion: json['dataVersion']! as String,
          createdAt: DateTime(2026, 10, 22),
          changedRefs: const [],
        ),
        replayed: false,
        snapshot: json,
      ),
    );

/// 2026-10-22: 결과를 차례로 돌려주고 요청을 기록하는 저장소. 결과가 없으면 응답을 기다리게 한다.
class ScriptedRepository implements UserFinancialRepository {
  final Queue<FinancialOutcome<WriteSuccess>> linkResults = Queue();
  final Queue<FinancialOutcome<WriteSuccess>> selectResults = Queue();
  final Queue<FinancialOutcome<Map<String, Object?>>> loadResults = Queue();
  final Queue<FinancialOutcome<WriteSuccess>> salaryResults = Queue();
  final List<(SalaryPatch, WriteContext)> salaryCalls = [];
  final Queue<FinancialOutcome<WriteSuccess>> nicknameResults = Queue();
  final List<(String, String?, WriteContext)> nicknameCalls = [];
  final List<(List<String>, WriteContext)> linkCalls = [];
  final List<(List<String>, WriteContext)> selectCalls = [];

  /// 2026-10-22: 다음 조회 결과를 반환한다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() async =>
      loadResults.removeFirst();

  /// 2026-10-22: 요청을 기록하고 다음 연결 결과를 반환한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> institutionCodes,
    WriteContext write,
  ) async {
    linkCalls.add((institutionCodes, write));
    return linkResults.removeFirst();
  }

  /// 2026-10-22: 요청을 기록하고 다음 선택 결과를 반환한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> selectAccounts(
    List<String> accountIds,
    WriteContext write,
  ) async {
    selectCalls.add((accountIds, write));
    return selectResults.removeFirst();
  }

  /// 2026-10-28: 요청을 기록하고 다음 월급 설정 저장 결과를 반환한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateSalarySettings(
    SalaryPatch salary,
    WriteContext write,
  ) async {
    salaryCalls.add((salary, write));
    return salaryResults.removeFirst();
  }

  /// 2026-10-28: 요청을 기록하고 다음 계좌 이름 저장 결과를 반환한다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateAccountNickname(
    String accountId,
    String? nickname,
    WriteContext write,
  ) async {
    nicknameCalls.add((accountId, nickname, write));
    return nicknameResults.removeFirst();
  }

  /// 2026-10-22: 상태가 없으므로 할 일이 없다.
  @override
  void close() {}
}

/// 2026-10-22: 정해 둔 값을 차례로 돌려주는 난수. 실패 추첨·지연 범위를 재현한다.
class SequenceRandom implements Random {
  /// 2026-10-22: 실수 [doubles]와 정수 [ints] 순서로 만든다. 다 쓰면 마지막 값을 반복한다.
  SequenceRandom({this.doubles = const [0.5], this.ints = const [0]});

  final List<double> doubles;
  final List<int> ints;
  int _d = 0;
  int _i = 0;

  /// 2026-10-22: 다음 실수를 반환한다.
  @override
  double nextDouble() => doubles[min(_d++, doubles.length - 1)];

  /// 2026-10-22: 다음 정수를 [max] 미만으로 반환한다.
  @override
  int nextInt(int max) => ints[min(_i++, ints.length - 1)] % max;

  /// 2026-10-22: 짝수 정수면 true를 반환한다.
  @override
  bool nextBool() => nextInt(2) == 0;
}

/// 2026-10-22: 기다리지 않는 표시 정책. [failing] 순서(실수열)로 실패 추첨을 재현한다.
ConnectionPresentationPolicy instantPolicy({
  List<double> draws = const [0.9],
  bool failuresEnabled = true,
  List<Duration>? waits,
}) => ConnectionPresentationPolicy(
  failuresEnabled: () => failuresEnabled,
  random: SequenceRandom(doubles: draws),
  wait: (d) async => waits?.add(d),
);
