import 'package:flutter/foundation.dart';

import '../financial_snapshot.dart';

/// 2026-11-04: 첫 계산 전 거래 분석의 화면용 상태. 서버 작업 상태(state·action·resultAvailability)를
/// 화면이 직접 해석하지 않도록 작업 추적이 이 값으로 바꿔 알린다.
sealed class AnalysisWaitState {
  /// 2026-11-04: 하위 상태만 만든다.
  const AnalysisWaitState();
}

/// 2026-11-04: 분석을 기다리는 중. 진행률·완료 단계를 담지 않는다(서버가 단계별 진행을 주지 않음).
final class AnalysisRunning extends AnalysisWaitState {
  /// 2026-11-04: 기다리는 중 상태를 만든다.
  const AnalysisRunning();
}

/// 2026-11-04: 분석 시도가 끝남. 성공·후보 없음·분석 실패를 [candidateCount]와 [interpreted]로 구분한다.
/// 두 수는 Flutter가 센 값이다(후보는 앱 계산 규칙으로 찾음). 서버 빈 목록·조회 실패를 후보 0개로 넣지 않는다.
final class AnalysisFinished extends AnalysisWaitState {
  /// 2026-11-04: 확인한 거래 수 [transactionCount], 앱 규칙으로 찾은 반복 후보 수 [candidateCount](0 이상),
  /// 후보의 내용 분석을 마쳤는지 [interpreted]로 만든다. 음수면 [ArgumentError]다.
  AnalysisFinished({
    required this.transactionCount,
    required this.candidateCount,
    required this.interpreted,
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

  /// 2026-11-04: false면 failed·outcomeUnknown·cancelled·expired 등으로 내용 분석을 마치지 못했다.
  final bool interpreted;
}

/// 2026-11-04: 한 번의 첫 분석을 추적하는 화면 독립 경계. 실제 API 작업 추적이 구현한다.
/// 반복 조회·기기 저장·앱 복귀 처리는 구현이 맡고 화면은 [state]만 본다.
abstract interface class AnalysisWaitSession {
  /// 2026-11-04: 현재 화면용 상태. 처음은 [AnalysisRunning]이다.
  ValueListenable<AnalysisWaitState> get state;

  /// 2026-11-04: 사용자가 '다시 시도'를 눌렀을 때만 부른다. 모델 재호출은 이 경로에서만 한다.
  /// [state]는 곧 [AnalysisRunning]으로 돌아간다.
  void retry();

  /// 2026-11-04: 화면을 떠날 때 부른다. 반복 조회를 멈출 뿐 서버 작업을 취소하지 않는다.
  void dispose();
}

/// 2026-11-04: 01-2가 보여 준 [snapshot]으로 첫 분석 추적을 시작해 반환한다.
typedef AnalysisWaitStarter = AnalysisWaitSession Function(
  FinancialSnapshot snapshot,
);
