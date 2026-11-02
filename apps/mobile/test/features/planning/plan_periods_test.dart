import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;
import 'package:payse/data/calculation_input_adapter.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/planning/plan_periods.dart';

import '../../data/calculation_input_adapter_test.dart'
    show alphaWithReceipt, salaryOf;

calc.BusinessDate _d(String text) => calc.BusinessDate.parse(text, 'test');

/// 2026-11-02: 원천 근거 회차 [month]의 예정일 [date] 근거를 만든다.
calc.SalaryReceipt _receipt(String month, String date) => calc.SalaryReceipt(
  payMonth: month,
  expectedPayDate: date,
  transactionIds: const [],
  confirmation: calc.SalaryConfirmation.confirmed,
);

/// 2026-11-02: [start]~[end) 현재 구간. [fromEvidence]면 시작일이 원천 근거 예정일이다.
calc.SalaryCycle _cycle(
  String? start,
  String end, {
  String month = '2026-09',
  bool fromEvidence = true,
}) => calc.SalaryCycle(
  state: calc.SalaryCycleState.normal,
  previousPayDate: start == null
      ? null
      : calc.PayDate(
          _d(start),
          false,
          payMonth: calc.PayMonth.parse(month, 'test'),
          fromEvidence: fromEvidence,
        ),
  periodStart: start == null ? null : _d(start),
  periodEnd: _d(end),
);

/// 2026-11-02: 예정 지출 한 줄. [settled]가 [amount]면 정산 완료다.
calc.ObligationLine _line(
  String id,
  String due, {
  int amount = 100000,
  int settled = 0,
  calc.ObligationPlacement? placement =
      calc.ObligationPlacement.inCurrentPeriod,
}) => calc.ObligationLine(
  obligationId: id,
  amountKrw: amount,
  settledKrw: settled,
  remainingKrw: amount - settled,
  dueDate: _d(due),
  placement: placement,
  overlapKrw: 0,
);

/// 2026-11-03: 기간 예측 구간 경계 [ends](C1부터 차례, 앞 구간 끝이 다음 시작)를 만든다. 첫 시작은 [start]다.
List<ProjectionFrame> _frames(String start, List<String> ends) {
  final result = <ProjectionFrame>[];
  var s = _d(start);
  for (final e in ends) {
    result.add((start: s, end: _d(e)));
    s = _d(e);
  }
  return result;
}

final _threeFrames = _frames('2026-10-12', [
  '2026-10-25',
  '2026-11-25',
  '2026-12-25',
]);

void main() {
  final today = _d('2026-10-12');

  group('월급 기간 목록', () {
    test('미래 기간은 기간 예측 구간의 끝 경계를 현재 기간 끝부터 그대로 잇는다', () {
      final p = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25'),
        salary: calc.SalaryInput(
          salaryDay: 25,
          receiptEvidence: [_receipt('2026-09', '2026-09-25')],
        ),
        frames: _threeFrames,
      )!;
      expect(
        [for (final x in p.periods) (x.role, x.range)],
        [
          (SalaryRole.current, '9/25 ~ 10/24'),
          (SalaryRole.next, '10/25 ~ 11/24'),
          (SalaryRole.later, '11/25 ~ 12/24'),
        ],
      );
      expect(p.currentIndex, 0);
      expect(p.periods.first.title, '다음 월급일까지');
      expect(p.periods[1].caption, '다음 월급 기간');
    });

    test('월급일·근거·장부를 받지 못하면 기간 예측 구간이 없고 미래 기간도 없다', () {
      final ledger = calculationInputsFromSnapshot(
        FinancialSnapshot.fromJson(alphaWithReceipt()),
      ).ledger;
      expect(
        projectionFrames(
          today: today,
          ledger: ledger,
          salary: calc.SalaryInput(salaryDay: 25, receiptEvidence: null),
        ),
        isEmpty,
      );
      expect(
        projectionFrames(
          today: today,
          ledger: null,
          salary: calc.SalaryInput(salaryDay: 25, receiptEvidence: const []),
        ),
        isEmpty,
      );
      final p = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25'),
        salary: calc.SalaryInput(salaryDay: 25, receiptEvidence: null),
      )!;
      expect(p.periods, hasLength(1));
    });

    test('계산이 상한으로 자른 마지막 구간도 그대로 선택지가 된다', () {
      final p = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25'),
        salary: null,
        frames: _frames('2026-10-12', [
          '2026-10-25',
          '2026-11-25',
          '2027-01-12',
        ]),
      )!;
      expect(p.periods.last.range, '11/25 ~ 1/11');
    });

    test('입금 대기로 홈 현재 기간 끝이 앞이면 그 끝부터 계산 구간 끝까지가 다음 기간', () {
      final p = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25'),
        salary: null,
        frames: _frames('2026-10-26', ['2026-11-25', '2026-12-25']),
      )!;
      expect(
        [for (final x in p.periods) x.range],
        ['9/25 ~ 10/24', '10/25 ~ 11/24', '11/25 ~ 12/24'],
      );
    });

    test('실제 계산이 3개월 상한에서 자른 마지막 구간이 선택지까지 그대로 온다', () {
      final json = alphaWithReceipt();
      final salary = salaryOf(json);
      salary['receiptEvidence'] = <Object?>[
        ...(salary['receiptEvidence']! as List),
        {
          'payMonth': '2026-11',
          'expectedPayDate': '2026-11-25',
          'transactionIds': <String>[],
          'confirmation': 'unknown',
        },
        {
          'payMonth': '2026-12',
          'expectedPayDate': '2027-01-25',
          'transactionIds': <String>[],
          'confirmation': 'unknown',
        },
      ];
      final snapshot = FinancialSnapshot.fromJson(json);
      final result =
          (computeHomeCalculation(snapshot) as HomeCalculationReady).result;
      final inputs = calculationInputsFromSnapshot(snapshot);
      final frames = projectionFrames(
        today: result.context.businessDate,
        ledger: inputs.ledger,
        salary: inputs.salary,
      );
      final cap = _d('2026-10-19').addMonthsClamped(3);
      expect(frames.last.end, cap, reason: '계산이 상한에서 자름');
      final p = salaryPeriods(
        cycle: result.salaryCycle,
        salary: inputs.salary,
        frames: frames,
      )!;
      expect(p.periods.last.start, frames.last.start);
      expect(p.periods.last.end, cap);
      expect(p.periods.last.range, '11/25 ~ 1/18');
    });

    test('실제 계산(데모알파·9월분 근거)의 구간 경계와 같다', () {
      final snapshot = FinancialSnapshot.fromJson(alphaWithReceipt());
      final inputs = calculationInputsFromSnapshot(snapshot);
      final frames = projectionFrames(
        today: _d('2026-10-19'),
        ledger: inputs.ledger,
        salary: inputs.salary,
      );
      final p = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25'),
        salary: inputs.salary,
        frames: frames,
      )!;
      final ends = [for (final f in frames) ?f.end];
      expect(
        [for (final x in p.periods.skip(1)) x.end],
        [
          for (final e in ends)
            if (e.isAfter(_d('2026-10-25'))) e,
        ],
      );
    });

    test('지난 기간은 원천 예정일로 앞뒤가 확인될 때만, 끊기면 그 앞은 없다', () {
      final evidence = [
        _receipt('2026-06', '2026-06-25'),
        _receipt('2026-08', '2026-08-25'),
        _receipt('2026-09', '2026-09-25'),
      ];
      final p = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25'),
        salary: calc.SalaryInput(salaryDay: 25, receiptEvidence: evidence),
      )!;
      final past = [
        for (final x in p.periods)
          if (x.role == SalaryRole.past) x.range,
      ];
      expect(past, ['8/25 ~ 9/24']);
      expect(p.currentIndex, 1);
    });

    test('현재 시작일이 반복 설정 예상이면 지난 기간을 소급하지 않는다', () {
      final p = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25', fromEvidence: false),
        salary: calc.SalaryInput(
          salaryDay: 25,
          receiptEvidence: [_receipt('2026-08', '2026-08-25')],
        ),
      )!;
      expect(p.periods.where((x) => x.role == SalaryRole.past), isEmpty);
    });

    test('입금 거래일이 아니라 예정일을 경계로 쓴다(조기 입금)', () {
      final p = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25'),
        salary: calc.SalaryInput(
          salaryDay: 25,
          receiptEvidence: [
            calc.SalaryReceipt(
              payMonth: '2026-08',
              expectedPayDate: '2026-08-25',
              transactionIds: const ['early-deposit-on-0824'],
              confirmation: calc.SalaryConfirmation.confirmed,
            ),
            _receipt('2026-09', '2026-09-25'),
          ],
        ),
      )!;
      expect(p.periods.first.range, '8/25 ~ 9/24');
    });

    test('근거를 접근 제한으로 받지 못했거나 현재 기간을 정할 수 없으면 지난 기간·목록이 없다', () {
      expect(
        salaryPeriods(
          cycle: _cycle('2026-09-25', '2026-10-25'),
          salary: calc.SalaryInput(salaryDay: 25, receiptEvidence: null),
        )!.periods.where((x) => x.role == SalaryRole.past),
        isEmpty,
      );
      expect(salaryPeriods(cycle: null, salary: null), isNull);
    });

    test('시작일을 모르는 현재 기간은 범위를 ~끝으로 쓰고 끝 전 예정일을 모두 담는다', () {
      final current = salaryPeriods(
        cycle: _cycle(null, '2026-10-25'),
        salary: null,
      )!.periods.single;
      expect(current.range, '~ 10/24');
      expect(current.contains(_d('2026-08-01')), isTrue);
      expect(current.contains(_d('2026-10-25')), isFalse);
    });
  });

  group('기간 경계와 분류', () {
    test('끝 전날은 현재 기간, 끝 당일은 다음 기간', () {
      final p = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25'),
        salary: calc.SalaryInput(
          salaryDay: 25,
          receiptEvidence: [_receipt('2026-09', '2026-09-25')],
        ),
        frames: _threeFrames,
      )!.periods;
      expect(p[0].contains(_d('2026-10-24')), isTrue);
      expect(p[0].contains(_d('2026-10-25')), isFalse);
      expect(p[1].contains(_d('2026-10-25')), isTrue);
      expect(p[1].contains(_d('2026-11-25')), isFalse);
      expect(p[2].contains(_d('2026-11-25')), isTrue);
    });

    test('예정일 기준으로 넣고, 일부 출금은 앞으로 나갈 돈, 정산 완료는 이미 나간 돈, 취소는 빠진다', () {
      final september = monthOf(_d('2026-09-15'));
      final groups = linesIn(september, [
        _line(
          'a',
          '2026-09-30',
          settled: 100000,
          placement: calc.ObligationPlacement.settled,
        ),
        _line('b', '2026-09-20', settled: 40000),
        _line('c', '2026-09-10'),
        _line(
          'd',
          '2026-09-05',
          placement: calc.ObligationPlacement.excludedAccount,
        ),
        _line('e', '2026-09-01', placement: calc.ObligationPlacement.cancelled),
        _line('f', '2026-10-02'),
      ]);
      expect(
        [for (final l in groups[PlanGroup.upcoming]!) l.obligationId],
        ['c', 'b'],
      );
      expect([for (final l in groups[PlanGroup.done]!) l.obligationId], ['a']);
      expect(
        [for (final l in groups[PlanGroup.excluded]!) l.obligationId],
        ['d'],
      );
    });

    test('예정일이 지났어도 정산이 없으면 이미 나간 돈에 넣지 않는다', () {
      expect(planGroup(_line('x', '2026-01-01')), PlanGroup.upcoming);
      expect(
        planGroup(_line('y', '2026-01-01', placement: null)),
        PlanGroup.upcoming,
      );
    });
  });

  group('이전 기간에서 남은 지출', () {
    final lines = [
      _line('old1', '2026-08-14', settled: 348000, amount: 398000),
      _line('old2', '2026-09-20'),
      _line(
        'done',
        '2026-09-10',
        settled: 100000,
        placement: calc.ObligationPlacement.settled,
      ),
      _line(
        'excluded',
        '2026-09-01',
        placement: calc.ObligationPlacement.excludedAccount,
      ),
      _line('now', '2026-10-01'),
    ];

    test('현재 기간 시작 전의 앞으로 나갈 돈만, 여러 기간 모두 예정일순', () {
      final current = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25'),
        salary: null,
      )!.periods.single;
      expect(
        [for (final l in carriedOver(current, lines)) l.obligationId],
        ['old1', 'old2'],
      );
    });

    test('시작일을 모르면 안내하지 않는다', () {
      final current = salaryPeriods(
        cycle: _cycle(null, '2026-10-25'),
        salary: null,
      )!.periods.single;
      expect(carriedOver(current, lines), isEmpty);
    });
  });

  group('달력 월', () {
    test('가장 이른~가장 늦은 예정일 달, 이번 달 포함, 빈 달도 건너뛰지 않는다', () {
      final months = calendarMonths(today, [
        _d('2026-08-14'),
        _d('2027-01-01'),
      ]);
      expect(
        [for (final m in months) m.title],
        [
          '2026년 8월',
          '2026년 9월',
          '2026년 10월',
          '2026년 11월',
          '2026년 12월',
          '2027년 1월',
        ],
      );
      expect(months[2].range, '10/1 ~ 10/31');
    });

    test('예정 지출이 없어도 이번 달은 있다', () {
      expect(
        [for (final m in calendarMonths(today, [])) m.title],
        ['2026년 10월'],
      );
    });
  });

  group('날짜 라벨', () {
    final periods = salaryPeriods(
      cycle: _cycle('2026-09-25', '2026-10-25'),
      salary: calc.SalaryInput(
        salaryDay: 25,
        receiptEvidence: [_receipt('2026-09', '2026-09-25')],
      ),
      frames: _threeFrames,
    );

    test('현재·다음 월급 기간까지만 D-n·오늘, 지난 예정일은 예정일 지남(D+n 없음)', () {
      final end = labelEnd(periods);
      expect(end, _d('2026-11-25'));
      expect(planDueLabel(_line('a', '2026-10-20'), today, end), 'D-8');
      expect(planDueLabel(_line('b', '2026-10-12'), today, end), '오늘');
      expect(planDueLabel(_line('c', '2026-11-24'), today, end), 'D-43');
      expect(planDueLabel(_line('d', '2026-11-25'), today, end), isNull);
      expect(planDueLabel(_line('e', '2026-08-14'), today, end), '예정일 지남');
    });

    test('일부 출금 행도 날짜 라벨을 쓴다', () {
      expect(
        planDueLabel(
          _line('p', '2026-10-10', settled: 60000),
          today,
          labelEnd(periods),
        ),
        '예정일 지남',
      );
    });

    test('다음 기간이 없으면 현재 기간까지만, 월급 정보가 없으면 D-n 없이 예정일 지남만', () {
      final only = salaryPeriods(
        cycle: _cycle('2026-09-25', '2026-10-25'),
        salary: null,
      );
      expect(
        planDueLabel(_line('a', '2026-10-30'), today, labelEnd(only)),
        isNull,
      );
      expect(planDueLabel(_line('b', '2026-10-20'), today, null), isNull);
      expect(planDueLabel(_line('c', '2026-10-01'), today, null), '예정일 지남');
    });
  });

  group('일부 출금 문구', () {
    test('같은 확인된 날짜면 그 날짜, 여러 날짜·모르는 날짜가 섞이면 누적', () {
      expect(withdrawalNote(['2026-10-10'], 60000), '10/10 출금 60,000원');
      expect(
        withdrawalNote(['2026-10-10', '2026-10-10'], 60000),
        '10/10 출금 60,000원',
      );
      expect(
        withdrawalNote(['2026-10-10', '2026-10-15'], 60000),
        '누적 출금 60,000원',
      );
      expect(withdrawalNote(['2026-10-10', null], 60000), '누적 출금 60,000원');
      expect(withdrawalNote([null], 60000), '출금 60,000원');
      expect(withdrawalNote([], 60000), '출금 60,000원');
    });
  });
}
