import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/snapshot_projector.dart';
import 'package:payse/data/financial_snapshot.dart';

import 'connection/connection_test_utils.dart';

const _allBeta = {
  'bank.kb',
  'bank.shinhan',
  'bank.hana',
  'bank.ibk',
  'bank.kakao',
  'card.hyundai',
  'card.samsung',
  'card.woori',
  'card.kb',
};

/// 2026-10-22: beta 원본을 [codes] 기관 연결 상태로 투영한 HTTP 응답 JSON을 반환한다.
Map<String, Object?> _beta(Set<String> codes) {
  final source = readSource('beta-ready');
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
      selectedAccountIds: null,
      dataVersion: '3',
    ),
  );
}

/// 2026-10-22: [json]의 settings.salary 객체를 반환한다.
Map<String, Object?> _salary(Map<String, Object?> json) =>
    ((json['settings']! as Map)['salary']! as Map).cast<String, Object?>();

void main() {
  group('settings, reserves, obligations and card schedules', () {
    test('full connection reads every value as a typed model', () {
      final s = FinancialSnapshot.fromJson(_beta(_allBeta));
      final salary = s.settings!.salary;
      expect(salary.salaryDay, 25);
      expect(salary.salaryAmountKrw, 3000000);
      expect(salary.salaryAccountId, '1d383795-5b7c-56f9-9535-ff418040183d');
      expect(salary.salaryAccountRestricted, isFalse);
      expect(s.settings!.cardPlans, isEmpty);
      expect(s.reserves!.single.label, '현재 비상금');
      expect(s.reserves!.single.amountKrw, 400000);
      expect(s.obligations!.map((o) => o.label), ['월세', '수리비', '카드 청구', '통신비']);
      final hyundai = s.cards!.firstWhere(
        (c) => c.institutionCode == 'card.hyundai',
      );
      expect(hyundai.scheduleEvidence.map((e) => e.dueDate), [
        '2026-10-10',
        '2026-11-10',
        '2026-12-10',
        '2027-01-10',
        '2027-02-10',
      ]);
      final debit = s.cards!.firstWhere((c) => c.institutionCode == 'card.kb');
      expect(debit.scheduleEvidence, isEmpty, reason: '일정 미확보는 빈 목록');
      expect(s.reservesRestricted, isFalse);
      expect(s.obligationsRestricted, isFalse);
      expect(s.cardPlansRestricted, isFalse);
    });

    test(
      'partial connection keeps hidden values hidden instead of guessing',
      () {
        final s = FinancialSnapshot.fromJson(
          _beta({'bank.shinhan', 'card.hyundai'}),
        );
        final salary = s.settings!.salary;
        expect(salary.salaryAccountRestricted, isTrue);
        expect(salary.salaryAccountId, isNull);
        expect(salary.salaryDay, 25, reason: '다른 설정은 그대로');
        expect(s.reserves, isEmpty);
        expect(s.reservesRestricted, isTrue);
        expect(s.obligations, isEmpty);
        expect(s.obligationsRestricted, isTrue);
        final card = s.cards!.single;
        expect(card.withdrawalAccountRestricted, isTrue);
        expect(card.withdrawalAccountId, isNull);
      },
    );

    test('before connection the financial groups are absent, not empty', () {
      final source = readSource('beta-ready');
      final s = FinancialSnapshot.fromJson(
        SnapshotProjector.project(
          source,
          const ProjectionState(
            institutionLinks: [],
            selectedAccountIds: null,
            dataVersion: '1',
          ),
        ),
      );
      expect(s.settings, isNull);
      expect(s.reserves, isNull);
      expect(s.obligations, isNull);
    });

    test('unset salary values stay null, not zero or a guessed account', () {
      final json = _beta(_allBeta);
      _salary(json)
        ..['salaryDay'] = null
        ..['salaryAmountKRW'] = null
        ..['salaryAccountId'] = null;
      final salary = FinancialSnapshot.fromJson(json).settings!.salary;
      expect(salary.salaryDay, isNull);
      expect(salary.salaryAmountKrw, isNull);
      expect(salary.salaryAccountId, isNull);
      expect(salary.salaryAccountRestricted, isFalse, reason: '미입력은 미연결이 아님');
    });

    test('a user card plan for a visible card is read', () {
      final json = _beta(_allBeta);
      final card = rows(json, 'cards').first;
      ((json['settings']! as Map)['cardPlans']! as List).add({
        'cardId': card['cardId'],
        'plannedPaymentDay': 15,
      });
      final plans = FinancialSnapshot.fromJson(json).settings!.cardPlans;
      expect(plans.single.cardId, card['cardId']);
      expect(plans.single.plannedPaymentDay, 15);
    });

    test('an explicit null plan day is read as no user setting', () {
      final json = _beta(_allBeta);
      final card = rows(json, 'cards').first;
      ((json['settings']! as Map)['cardPlans']! as List).add({
        'cardId': card['cardId'],
        'plannedPaymentDay': null,
      });
      final plans = FinancialSnapshot.fromJson(json).settings!.cardPlans;
      expect(plans.single.plannedPaymentDay, isNull);
    });

    test('malformed or contradictory values are format errors', () {
      final cases = <String, void Function(Map<String, Object?>)>{
        'salaryDay 0': (j) => _salary(j)['salaryDay'] = 0,
        'salaryDay 32': (j) => _salary(j)['salaryDay'] = 32,
        'negative salary': (j) => _salary(j)['salaryAmountKRW'] = -1,
        'salary missing': (j) => (j['settings']! as Map).remove('salary'),
        'salaryDay field omitted': (j) => _salary(j).remove('salaryDay'),
        'salaryAmountKRW field omitted': (j) =>
            _salary(j).remove('salaryAmountKRW'),
        'plannedPaymentDay field omitted': (j) =>
            ((j['settings']! as Map)['cardPlans']! as List).add({
              'cardId': rows(j, 'cards').first['cardId'],
            }),
        'salary account omitted without marker': (j) =>
            _salary(j).remove('salaryAccountId'),
        'receipt evidence omitted without marker': (j) =>
            _salary(j).remove('receiptEvidence'),
        'salary account not in response': (j) =>
            _salary(j)['salaryAccountId'] = 'not-here',
        'plan for unknown card': (j) =>
            ((j['settings']! as Map)['cardPlans']! as List).add({
              'cardId': 'not-here',
              'plannedPaymentDay': 3,
            }),
        'plan day out of range': (j) =>
            ((j['settings']! as Map)['cardPlans']! as List).add({
              'cardId': rows(j, 'cards').first['cardId'],
              'plannedPaymentDay': 32,
            }),
        'reserve account not in response': (j) =>
            rows(j, 'reserves').first['accountId'] = 'not-here',
        'negative reserve': (j) => rows(j, 'reserves').first['amountKRW'] = -5,
        'obligation account not in response': (j) =>
            rows(j, 'obligations').first['withdrawalAccountId'] = 'not-here',
        'unknown obligation status': (j) =>
            rows(j, 'obligations').first['status'] = 'paid',
        'obligation date not a date': (j) =>
            rows(j, 'obligations').first['dueDate'] = '2026-13-01',
        'schedule with half a period': (j) =>
            ((rows(j, 'cards').first['scheduleEvidence']! as List).first as Map)
                .remove('periodEnd'),
        'empty schedule': (j) =>
            (rows(j, 'cards').first['scheduleEvidence']! as List).add({
              'periodStart': null,
              'periodEnd': null,
              'dueDate': null,
              'evidenceRef': 'x',
            }),
        'schedule list missing': (j) =>
            rows(j, 'cards').first.remove('scheduleEvidence'),
      };
      cases.forEach((name, mutate) {
        final json = _beta(_allBeta);
        mutate(json);
        expect(
          () => FinancialSnapshot.fromJson(json),
          throwsA(isA<SnapshotFormatException>()),
          reason: name,
        );
      });
    });
  });
}
