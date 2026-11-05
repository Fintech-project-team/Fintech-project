import 'package:flutter/foundation.dart';

import '../financial_snapshot.dart';

/// 2026-11-04: 첫 계산 전 거래 분석의 화면용 상태. 서버 작업 상태(state·action·resultAvailability)를
/// 화면이 직접 해석하지 않도록 작업 추적이 이 값으로 바꿔 알린다.
sealed class AnalysisWaitState {
  /// 2026-11-04: 하위 상태만 만든다.
  const AnalysisWaitState();
}

/// 2026-11-04: 분석을 기다리는 중. 진행률·완료 단계를 담지 않는다(서버가 단계별 진행을 주지 않음).
/// 2026-11-05: [inputReceived]는 서버 응답(입력 제출 또는 상태 조회)이 running 이후를 알려 줬는지다. 접수 성공·
/// 입력 전송만으로는 true가 되지 않는다. true일 때만 '앱을 나가도 분석은 계속돼요'를 보인다.
final class AnalysisRunning extends AnalysisWaitState {
  /// 2026-11-04: 기다리는 중 상태를 만든다.
  /// 2026-11-05: 서버 입력 수신 확인 여부 [inputReceived]를 받는다.
  const AnalysisRunning({this.inputReceived = false});

  final bool inputReceived;
}

/// 2026-11-05: 분석 시도가 끝난 방식. 후보 0개는 [AnalysisFinished.candidateCount]로 따로 나타낸다.
enum AnalysisOutcome {
  /// 2026-11-05: 서버 결과를 현재 입력으로 확인했다(resultAvailability available).
  interpreted,

  /// 2026-11-05: 실행 실패·취소이거나 결과를 쓸 수 없다(failed·cancelled·partial 등). 새 키로 다시 시도한다.
  failed,

  /// 2026-11-05: 보낸 뒤 끝났는지 알 수 없다(outcomeUnknown). 다시 시도 전 중복 실행 동의가 필요하다.
  outcomeUnknown,

  /// 2026-11-05: 3개월 작업 식별 기한이 지났고 재사용할 결과도 없다(expired). 다시 분석은 recovery 접수다.
  expired,
}

/// 2026-11-04: 분석 시도가 끝남. 성공·후보 없음·분석 실패를 [candidateCount]와 결과로 구분한다.
/// 두 수는 Flutter가 센 값이다(후보는 앱 계산 규칙으로 찾음). 서버 빈 목록·조회 실패를 후보 0개로 넣지 않는다.
final class AnalysisFinished extends AnalysisWaitState {
  /// 2026-11-04: 확인한 거래 수 [transactionCount], 앱 규칙으로 찾은 반복 후보 수 [candidateCount](0 이상)로 만든다.
  /// 음수면 [ArgumentError]다.
  /// 2026-11-05: 끝난 방식 [outcome]을 받는다.
  AnalysisFinished({
    required this.transactionCount,
    required this.candidateCount,
    required this.outcome,
  }) {
    if (transactionCount < 0) {
      throw ArgumentError.value(transactionCount, 'transactionCount');
    }
    if (candidateCount < 0) {
      throw ArgumentError.value(candidateCount, 'candidateCount');
    }
  }

  final int transactionCount;
  final int candidateCount;
  final AnalysisOutcome outcome;

  /// 2026-11-04: 후보의 내용 분석을 마쳤으면 true다.
  bool get interpreted => outcome == AnalysisOutcome.interpreted;
}

/// 2026-11-04: 한 번의 첫 분석을 추적하는 화면 독립 경계. 실제 API 작업 추적이 구현한다.
/// 반복 조회·기기 저장·앱 복귀 처리는 구현이 맡고 화면은 [state]만 본다.
abstract interface class AnalysisWaitSession {
  /// 2026-11-04: 현재 화면용 상태. 처음은 [AnalysisRunning]이다.
  ValueListenable<AnalysisWaitState> get state;

  /// 2026-11-04: 사용자가 '다시 시도'를 눌렀을 때만 부른다. 모델 재호출은 이 경로에서만 한다.
  /// [state]는 곧 [AnalysisRunning]으로 돌아간다.
  /// 2026-11-05: 결과 불명이면 화면이 중복 실행 동의를 받은 뒤에만 부른다.
  void retry();

  /// 2026-11-05: 앱이 백그라운드로 갔다. 반복 조회를 멈출 뿐 서버 작업을 취소하지 않는다.
  void pause();

  /// 2026-11-05: 앱으로 돌아왔다. 현재 입력으로 결과·작업 상태부터 다시 확인한다.
  void resume();

  /// 2026-11-05: 사용자가 결과를 보고 '다음'을 눌렀다. 기기에 남긴 작업 기록을 지운다.
  Future<void> forget();

  /// 2026-11-04: 화면을 떠날 때 부른다. 반복 조회를 멈출 뿐 서버 작업을 취소하지 않는다.
  void dispose();
}

/// 2026-11-04: 01-2가 보여 준 [snapshot]으로 첫 분석 추적을 시작해 반환한다.
typedef AnalysisWaitStarter = AnalysisWaitSession Function(
  FinancialSnapshot snapshot,
);

/// 2026-11-05: 앱 구성이 넘기는 분석 연결. [start]는 추적 시작, [pending]은 사용자에게 끝내지 않은(‘다음’을 누르지
/// 않은) 첫 분석 기록이 기기에 남아 있는지다. 앱을 다시 켜면 이 값으로 분석 대기 화면부터 이어 보인다.
final class AnalysisLauncher {
  /// 2026-11-05: 추적 시작 [start]와 남은 기록 확인 [pending]으로 만든다.
  const AnalysisLauncher({required this.start, required this.pending});

  final AnalysisWaitStarter start;
  final Future<bool> Function(String userId) pending;
}
