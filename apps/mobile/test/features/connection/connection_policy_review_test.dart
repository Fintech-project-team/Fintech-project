import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/connection/connection_presentation_policy.dart';
import 'package:payse/features/connection/connection_review.dart';

import '../../data/connection/connection_test_utils.dart';
import 'connection_test_support.dart';

/// 2026-10-22: 첫 카드(현대)의 결제 일정을 [dues]로, 기준 시각을 [asOf]로 바꾼 beta 전체 연결 Snapshot.
FinancialSnapshot _withSchedule(List<String> dues, {String? asOf}) =>
    betaSnapshot(
      {...betaBanks, ...betaCards},
      mutate: (source) {
        if (asOf != null) source['asOf'] = asOf;
        rows(source, 'cards').first['scheduleEvidence'] = [
          for (final (i, d) in dues.indexed)
            {
              'periodStart': null,
              'periodEnd': null,
              'dueDate': d,
              'evidenceRef': 'e$i',
            },
        ];
      },
    );

void main() {
  group('presentation policy', () {
    test('each institution fails at 10% and at most two fail', () {
      final policy = ConnectionPresentationPolicy(
        failuresEnabled: () => true,
        random: SequenceRandom(doubles: [0.05, 0.5, 0.09, 0.01, 0.0]),
      );
      expect(policy.drawFailures(['a', 'b', 'c', 'd', 'e']), {'a', 'c'});
      final none = ConnectionPresentationPolicy(
        failuresEnabled: () => true,
        random: SequenceRandom(doubles: [0.1, 0.5]),
      );
      expect(none.drawFailures(['a', 'b']), isEmpty, reason: '0.1은 10% 밖');
    });

    test('turned off draws nothing', () {
      final policy = ConnectionPresentationPolicy(
        failuresEnabled: () => false,
        random: SequenceRandom(doubles: [0.0]),
      );
      expect(policy.drawFailures(['a', 'b']), isEmpty);
    });

    test('delays stay inside the screen-rule ranges', () async {
      final waits = <Duration>[];
      Future<void> record(Duration d) async => waits.add(d);
      final low = ConnectionPresentationPolicy(
        failuresEnabled: () => true,
        random: SequenceRandom(ints: [0]),
        wait: record,
      );
      final high = ConnectionPresentationPolicy(
        failuresEnabled: () => true,
        random: SequenceRandom(ints: [100000]),
        wait: record,
      );
      for (final p in [low, high]) {
        await p.entryStepDelay();
        await p.entryStepDelay();
        await p.stepDelay();
        await p.retryDelay();
      }
      final ms = waits.map((d) => d.inMilliseconds).toList();
      for (final run in [0, 4]) {
        expect(ms[run], inInclusiveRange(1000, 1500));
        expect(ms[run + 1], inInclusiveRange(1000, 1500));
        expect(
          ms[run] + ms[run + 1],
          inInclusiveRange(2000, 3000),
          reason: '진입 로딩 두 단계 합 2~3초',
        );
        expect(ms[run + 2], inInclusiveRange(1000, 1500));
        expect(ms[run + 3], inInclusiveRange(2000, 3000));
      }
    });
  });

  group('card payment day on 01-2', () {
    test('a user planned day wins over card schedules', () {
      final snapshot = betaSnapshot(
        {...betaBanks, ...betaCards},
        mutate: (source) {
          final card = rows(source, 'cards').first;
          ((source['settings']! as Map)['cardPlans']! as List).add({
            'userId': source['userId'],
            'cardId': card['cardId'],
            'plannedPaymentDay': 15,
          });
        },
      );
      final card = snapshot.cards!.first;
      expect(cardPaymentDay(snapshot, card), isA<PlannedPaymentDay>());
      expect((cardPaymentDay(snapshot, card) as PlannedPaymentDay).day, 15);
    });

    test(
      'the earliest schedule on or after the snapshot date, in any order',
      () {
        final snapshot = _withSchedule([
          '2026-12-10',
          '2026-10-10',
          '2026-10-19',
          '2026-11-10',
        ]);
        final due = cardPaymentDay(snapshot, snapshot.cards!.first);
        expect(
          (due as NextConfirmedDue).date,
          '2026-10-19',
          reason: '기준일 당일 포함',
        );
      },
    );

    test('only past schedules show no upcoming date instead of a past one', () {
      final snapshot = _withSchedule(['2026-09-10', '2026-10-10']);
      expect(
        cardPaymentDay(snapshot, snapshot.cards!.first),
        isA<NoUpcomingDue>(),
      );
    });

    test('no schedule at all shows no upcoming date', () {
      final snapshot = betaSnapshot({...betaBanks, ...betaCards});
      final debit = snapshot.cards!.firstWhere(
        (c) => c.institutionCode == 'card.kb',
      );
      expect(debit.scheduleEvidence, isEmpty);
      expect(cardPaymentDay(snapshot, debit), isA<NoUpcomingDue>());
    });

    test('year end rolls into next year and shows the year', () {
      final snapshot = _withSchedule([
        '2026-12-10',
        '2027-01-10',
      ], asOf: '2026-12-20T09:00:00+09:00');
      final due = cardPaymentDay(snapshot, snapshot.cards!.first);
      expect((due as NextConfirmedDue).date, '2027-01-10');
      expect(formatBusinessDate(due.date, '2026-12-20'), '2027년 1월 10일');
      expect(formatBusinessDate('2026-11-10', '2026-10-19'), '11월 10일');
    });

    test('the snapshot date is used, not the device clock', () {
      final snapshot = _withSchedule([
        '2020-01-10',
        '2020-02-10',
      ], asOf: '2020-01-05T09:00:00+09:00');
      final due = cardPaymentDay(snapshot, snapshot.cards!.first);
      expect((due as NextConfirmedDue).date, '2020-01-10');
    });
  });

  test('account label uses institution, product kind and last four', () {
    final snapshot = betaSnapshot({...betaBanks});
    final kb = snapshot.accounts!.first;
    expect(accountLabel(snapshot, kb), '국민은행 입출금 ····0001');
    expect(productTypeLabel('time_deposit'), '예금');
    expect(productTypeLabel('savings'), '적금');
  });
}
