import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/calculation_input_adapter.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import 'connection/connection_test_utils.dart';
import 'connection/snapshot_projector_test.dart' show projectWith;

const kbMain = '6069b37a-abf5-56fc-8bf0-153f5301fd1c';
const shinhanMain = '67521b1b-de86-54cf-98ba-91bb04d0a256';
const septemberSalaryTx = '002b5513-88ca-5bff-882c-981b043336d9';

calc.CurrentAmountResult run(Map<String, Object?> json) {
  final inputs = calculationInputsFromSnapshot(
    FinancialSnapshot.fromJson(json),
  );
  return calc.calculateCurrentAmount(
    calc.CurrentAmountInput(ledger: inputs.ledger, salary: inputs.salary),
  );
}

Matcher contractError() => throwsA(isA<CalculationContractException>());

Map<String, Object?> salaryOf(Map<String, Object?> json) =>
    ((json['settings']! as Map)['salary']! as Map).cast<String, Object?>();

/// 2026-10-23: 테스트 전용 입력. 공통 더미 사본(메모리)에 직전 회차 급여 근거를 넣는다. 원본 파일은 바꾸지 않는다.
Map<String, Object?> alphaWithReceipt({
  String confirmation = 'confirmed',
  List<String> ids = const [septemberSalaryTx],
}) {
  final json = readSource('alpha-ready');
  salaryOf(json)['receiptEvidence'] = [
    {
      'expectedPayDate': '2026-09-25',
      'transactionIds': ids,
      'confirmation': confirmation,
    },
  ];
  return json;
}

Map<String, Object?> txById(Map<String, Object?> json, String id) =>
    rows(json, 'transactions').firstWhere((t) => t['transactionId'] == id);

void expectLedgerIdentity(calc.CurrentAmountResult r) {
  expect(r.u, r.b! - r.e! - (r.r! - r.o!));
  expect(r.rEff, r.r! - r.o!);
}

void main() {
  group('공통 더미 그대로 연결(#96 반영 전)', () {
    int includedBalance(Map<String, Object?> json) => rows(json, 'accounts')
        .where((a) => a['included'] == true)
        .fold(0, (sum, a) => sum + (a['balanceKRW']! as int));

    for (final stem in ['alpha-ready', 'beta-ready', 'gamma-month-end']) {
      test('$stem: 직전 회차 근거가 없어 입금 정보 부족, B만 계산', () {
        final json = readSource(stem);
        final r = run(json);
        expect(r.u, isNull);
        expect(r.insufficient, [calc.InsufficientReason.receiptEvidenceAbsent]);
        expect(r.b, includedBalance(json));
      });
    }

    test('salary-wait: 10/25 입금 확인 전이라 입금 대기, 반영 대기 의무 분리', () {
      final r = run(readSource('salary-wait'));
      expect(r.salaryCycle!.state, calc.SalaryCycleState.awaitingDeposit);
      expect(r.u, isNotNull);
      expect(
        r.obligationLines!.where(
          (l) => l.placement == calc.ObligationPlacement.awaitingSalary,
        ),
        isNotEmpty,
      );
      expectLedgerIdentity(r);
    });

    test('salary-confirmed: 10/25 confirmed라 정상 구간으로 계산', () {
      final r = run(readSource('salary-confirmed'));
      expect(r.salaryCycle!.state, calc.SalaryCycleState.normal);
      expect(r.insufficient, isEmpty);
      expectLedgerIdentity(r);
    });
  });

  group('테스트 전용 입력으로 정상·음수 계산', () {
    test('alpha-ready + 9/25 confirmed 근거: B 2,000,000 − E 360,000 − (R 400,000 − O 60,000) = 1,300,000', () {
      final r = run(alphaWithReceipt());
      expect(
        [r.b, r.e, r.r, r.o, r.rEff, r.u],
        [2000000, 360000, 400000, 60000, 340000, 1300000],
      );
      expect(r.context.inputRevision, 0);
      expect(r.context.dataVersion, readSource('alpha-ready')['dataVersion']);
    });

    test('잔액이 낮으면 음수 U를 그대로 계산', () {
      final json = alphaWithReceipt();
      for (final a in rows(json, 'accounts')) {
        if (a['included'] == true) a['balanceKRW'] = 100000;
      }
      final r = run(json);
      expect(r.u, 200000 - 360000 - 340000);
      expectLedgerIdentity(r);
    });
  });

  group('급여 근거 검증', () {
    test('partial 근거 거래도 잔액 반영된 posted 계좌 입금이어야 한다', () {
      final json = alphaWithReceipt(confirmation: 'partial');
      txById(json, septemberSalaryTx)['reflectionReason'] = 'not_reflected';
      expect(() => run(json), contractError());
    });

    test('confirmed 근거 거래가 출금이거나 posted가 아니면 계약 위반', () {
      final out = alphaWithReceipt();
      txById(out, septemberSalaryTx)['direction'] = 'out';
      expect(() => run(out), contractError());
      final approved = alphaWithReceipt();
      txById(approved, septemberSalaryTx)['status'] = 'approved';
      expect(() => run(approved), contractError());
    });

    test('근거 거래가 없으면 계약 위반, 다음 페이지가 남았으면 근거 미수신', () {
      expect(() => run(alphaWithReceipt(ids: ['missing-tx'])), contractError());
      expect(() => run(alphaWithReceipt(ids: [])), contractError());
      final paged = alphaWithReceipt(ids: ['missing-tx']);
      paged['page'] = {'nextCursor': 'cursor-2'};
      final r = run(paged);
      expect(r.insufficient, [
        calc.InsufficientReason.receiptEvidenceUnavailable,
      ]);
    });

    test('unknown 근거는 거래를 검사하지 않고 입금 대기로 계산', () {
      final r = run(alphaWithReceipt(confirmation: 'unknown', ids: []));
      expect(r.salaryCycle!.state, calc.SalaryCycleState.awaitingDeposit);
    });
  });

  group('정산 검증', () {
    Map<String, Object?> bill(Map<String, Object?> json) => rows(
      json,
      'settlements',
    ).firstWhere((s) => s['allocatedKRW'] == 110000);

    Map<String, Object?> extraLink(
      Map<String, Object?> json,
      int amount, {
      String? invalidatedAt,
    }) {
      final base = bill(json);
      final firstOpen = rows(
        json,
        'obligations',
      ).firstWhere((o) => o['amountKRW'] == 300000);
      return {
        ...base,
        'linkId': 'extra-link',
        'obligationId': firstOpen['obligationId'],
        'allocatedKRW': amount,
        'invalidatedAt': invalidatedAt,
      };
    }

    test('같은 출금에 걸린 유효 배분 합계가 실제 출금액을 넘으면 계약 위반', () {
      final json = alphaWithReceipt();
      (json['settlements']! as List).add(extraLink(json, 10000));
      expect(() => run(json), contractError());
    });

    test('무효화된 연결은 거래별 합계와 정산에 넣지 않는다', () {
      final json = alphaWithReceipt();
      (json['settlements']! as List).add(
        extraLink(json, 10000, invalidatedAt: '2026-10-18T09:00:00+09:00'),
      );
      expect(run(json).u, 1300000);
    });

    test('정산 거래 계좌가 의무 출금 계좌와 다르면 계약 위반', () {
      final json = alphaWithReceipt();
      final link = bill(json);
      txById(json, link['transactionId']! as String)['accountId'] = shinhanMain;
      expect(() => run(json), contractError());
    });

    test('정산 거래가 입금이거나 근거가 비면 계약 위반', () {
      final inflow = alphaWithReceipt();
      txById(inflow, bill(inflow)['transactionId']! as String)['direction'] =
          'in';
      expect(() => run(inflow), contractError());
      final noEvidence = alphaWithReceipt();
      bill(noEvidence)['evidenceRefs'] = <String>[];
      expect(() => run(noEvidence), contractError());
    });

    test('정산 거래가 없으면 계약 위반, 다음 페이지가 남았으면 정산 미수신', () {
      final missing = alphaWithReceipt();
      bill(missing)['transactionId'] = 'missing-tx';
      expect(() => run(missing), contractError());
      final paged = alphaWithReceipt();
      bill(paged)['transactionId'] = 'missing-tx';
      paged['page'] = {'nextCursor': 'cursor-2'};
      expect(run(paged).insufficient, [
        calc.InsufficientReason.settlementsMissing,
      ]);
    });
  });

  group('같은 스냅샷 원천 검증', () {
    Map<String, Object?> billTx(Map<String, Object?> json) {
      final link = rows(
        json,
        'settlements',
      ).firstWhere((s) => s['allocatedKRW'] == 110000);
      return txById(json, link['transactionId']! as String);
    }

    test('급여 근거 거래의 원천 버전만 다르면 정상 계산을 거절한다', () {
      final json = alphaWithReceipt();
      txById(json, septemberSalaryTx)['sourceVersion'] =
          'fixture-1:alpha:other';
      expect(() => run(json), contractError());
    });

    test('정산 거래의 원천 버전만 다르면 거절한다', () {
      final json = alphaWithReceipt();
      billTx(json)['sourceVersion'] = 'fixture-1:alpha:other';
      expect(() => run(json), contractError());
    });

    test('근거 거래 계좌의 원천 버전이 다르면 거절한다', () {
      final json = alphaWithReceipt();
      rows(json, 'accounts').firstWhere(
        (a) => a['accountId'] == kbMain,
      )['sourceVersion'] = 'fixture-1:alpha:other';
      expect(() => run(json), contractError());
    });

    test('근거 거래의 원천 버전 키가 없으면 같은 버전으로 추정하지 않는다', () {
      final json = alphaWithReceipt();
      txById(json, septemberSalaryTx).remove('sourceVersion');
      expect(() => run(json), contractError());
    });
  });

  group('미수신과 계약 위반이 함께 있을 때', () {
    Map<String, Object?> link(Map<String, Object?> json, int amount) => rows(
      json,
      'settlements',
    ).firstWhere((s) => s['allocatedKRW'] == amount);

    for (final reversed in [false, true]) {
      test('미수신 연결 + 계좌 불일치 연결은 순서와 관계없이 계약 위반(reversed=$reversed)', () {
        final json = alphaWithReceipt();
        final repairTx = link(json, 40000)['transactionId']! as String;
        link(json, 110000)['transactionId'] = 'missing-tx';
        json['page'] = {'nextCursor': 'cursor-2'};
        txById(json, repairTx)['accountId'] = shinhanMain;
        if (reversed) {
          json['settlements'] = (json['settlements']! as List).reversed
              .toList();
        }
        expect(() => run(json), contractError());
      });

      test('숨김 표식 + 초과 배분은 순서와 관계없이 계약 위반(reversed=$reversed)', () {
        final json = alphaWithReceipt();
        final bill = link(json, 110000);
        (json['settlements']! as List).add({
          ...bill,
          'linkId': 'extra-link',
          'obligationId': rows(
            json,
            'obligations',
          ).firstWhere((o) => o['amountKRW'] == 300000)['obligationId'],
          'allocatedKRW': 10000,
        });
        json['accessRestrictions'] = [
          {
            'ownerType': 'response',
            'ownerId': null,
            'field': 'settlements',
            'targetKind': 'transaction',
            'reason': 'not_connected',
          },
        ];
        if (reversed) {
          json['settlements'] = (json['settlements']! as List).reversed
              .toList();
        }
        expect(() => run(json), contractError());
      });
    }

    test('미수신만 있고 위반이 없으면 정산 정보 부족', () {
      final json = alphaWithReceipt();
      link(json, 110000)['transactionId'] = 'missing-tx';
      json['page'] = {'nextCursor': 'cursor-2'};
      expect(run(json).insufficient, [
        calc.InsufficientReason.settlementsMissing,
      ]);
    });

    test('급여 근거도 미수신 거래 + 잘못된 거래가 섞이면 계약 위반', () {
      final json = alphaWithReceipt(ids: ['missing-tx', septemberSalaryTx]);
      json['page'] = {'nextCursor': 'cursor-2'};
      txById(json, septemberSalaryTx)['reflectionReason'] = 'not_reflected';
      expect(() => run(json), contractError());
    });
  });

  group('참조 확보 상태(referenceResolutions)', () {
    Map<String, Object?> resolution(String id, String status) => {
      'transactionId': id,
      'status': status,
      'reason': status == 'unavailable' ? 'outside_retention' : null,
    };

    test('정산 거래가 미확보(unavailable)면 계약 위반이 아니라 정산 정보 부족', () {
      final json = alphaWithReceipt();
      rows(json, 'settlements').firstWhere(
        (s) => s['allocatedKRW'] == 110000,
      )['transactionId'] = 'old-tx';
      json['referenceResolutions'] = [resolution('old-tx', 'unavailable')];
      expect(run(json).insufficient, [
        calc.InsufficientReason.settlementsMissing,
      ]);
    });

    test('급여 근거 거래가 미확보면 입금 정보 미수신', () {
      final json = alphaWithReceipt(ids: ['old-tx']);
      json['referenceResolutions'] = [resolution('old-tx', 'unavailable')];
      expect(run(json).insufficient, [
        calc.InsufficientReason.receiptEvidenceUnavailable,
      ]);
    });

    test('확보됨(resolved)인데 거래가 응답에 없으면 계약 위반', () {
      final json = alphaWithReceipt(ids: ['old-tx']);
      json['referenceResolutions'] = [resolution('old-tx', 'resolved')];
      expect(() => run(json), contractError());
    });
  });

  group('숨김·빈 목록·누락 참조', () {
    Map<String, Object?> marker(
      String ownerType,
      String? ownerId,
      String field,
      String targetKind,
    ) => {
      'ownerType': ownerType,
      'ownerId': ownerId,
      'field': field,
      'targetKind': targetKind,
      'reason': 'not_connected',
    };

    test('미연결 계좌 때문에 숨긴 의무·보호액·배정은 홈 계산에 영향이 없다', () {
      final json = alphaWithReceipt();
      json['accessRestrictions'] = [
        marker('response', null, 'obligations', 'account'),
        marker('response', null, 'reserves', 'account'),
        marker('response', null, 'allocations', 'obligation'),
        marker('response', null, 'settlements', 'obligation'),
      ];
      expect(run(json).u, 1300000);
    });

    test('계획 버전 때문에 숨긴 의무는 포함 계좌 의무일 수 있어 예정 지출 정보 부족', () {
      final json = alphaWithReceipt();
      json['accessRestrictions'] = [
        marker('response', null, 'obligations', 'planRevision'),
      ];
      final r = run(json);
      expect([r.e, r.u], [null, null]);
      expect(
        r.insufficient,
        contains(calc.InsufficientReason.obligationsMissing),
      );
      expect(r.b, 2000000);
    });

    test('포함 계좌 의무의 정산 거래가 숨겨지면 정산 정보 부족', () {
      final json = alphaWithReceipt();
      final owner = rows(
        json,
        'obligations',
      ).firstWhere((o) => o['amountKRW'] == 100000);
      json['accessRestrictions'] = [
        marker(
          'obligation',
          owner['obligationId']! as String,
          'settlements',
          'transaction',
        ),
      ];
      expect(
        run(json).insufficient,
        contains(calc.InsufficientReason.settlementsMissing),
      );
      final responseLevel = alphaWithReceipt();
      responseLevel['accessRestrictions'] = [
        marker('response', null, 'settlements', 'transaction'),
      ];
      expect(
        run(responseLevel).insufficient,
        contains(calc.InsufficientReason.settlementsMissing),
      );
    });

    test('확인된 빈 목록은 0건으로 계산한다', () {
      final json = alphaWithReceipt();
      json['obligations'] = <Object?>[];
      json['allocations'] = <Object?>[];
      json['settlements'] = <Object?>[];
      final r = run(json);
      expect([r.e, r.o, r.u], [0, 0, 2000000 - 400000]);
    });

    test('공개 배정·정산이 응답에 없는 보호액·의무를 가리키면 형식 오류', () {
      final allocation = alphaWithReceipt();
      rows(allocation, 'allocations').first['reserveId'] = 'missing-reserve';
      expect(
        () => FinancialSnapshot.fromJson(allocation),
        throwsA(isA<SnapshotFormatException>()),
      );
      final settlement = alphaWithReceipt();
      rows(settlement, 'settlements').first['obligationId'] =
          'missing-obligation';
      expect(
        () => FinancialSnapshot.fromJson(settlement),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
  });

  group('부분 연결(HTTP 투영)', () {
    const banks = {
      'bank.kb',
      'bank.shinhan',
      'bank.hana',
      'bank.ibk',
      'bank.kakao',
    };

    test('급여 계좌 은행만 연결하면 다른 은행 계좌·보호액이 숨어도 계산 가능', () {
      final source = alphaWithReceipt();
      final projected = projectWith(source, {'bank.kb'}, selected: {kbMain});
      final r = run(projected);
      expect(r.insufficient, isEmpty);
      expect(r.b, 1500000);
      expectLedgerIdentity(r);
    });

    test('급여 계좌 은행을 빼면 근거가 숨겨져 입금 정보 미수신, 구간을 정할 수 없어 E도 null이고 B·R은 계산', () {
      final source = alphaWithReceipt();
      final projected = projectWith(
        source,
        banks.difference({'bank.kb'}),
        selected: {shinhanMain},
      );
      final r = run(projected);
      expect(r.insufficient, [
        calc.InsufficientReason.receiptEvidenceUnavailable,
      ]);
      expect(r.u, isNull);
      expect([r.b, r.e, r.r], [500000, null, 0]);
    });
  });
}
