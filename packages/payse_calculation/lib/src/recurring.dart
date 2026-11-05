import 'dart:convert';

import 'business_date.dart';
import 'money.dart';
import 'recurring_input.dart';

/// 2026-11-04: 공백·대소문자만 정규화한다. 의미 없는 접두어 제거를 임의 추가하지 않는다.
const recurringRuleVersion = 'PAYSE-RECURRING-1';

/// 2026-11-04: 명시 원천 [name]을 정규화한다. 상호 유사도·LLM 추측으로 병합하지 않는다.
String normalizeRecurringName(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// 2026-11-04: 최근 달력3개월의 월간 패턴을 탐지한다. 계산 시각·입출력을 스스로 읽지 않는다.
/// 최근 세 서로 다른 달의 한 회차씩만 검증하며 과거 9개월로 부족한 최근 근거를 채우지 않는다.
RecurringDetection detectRecurring(RecurringInput input) {
  final end = input.context.businessDate;
  final start = end.addMonthsClamped(-3);
  final issues = <RecurringIssue>[];
  final candidates = <RecurringCandidate>[];
  final entries = <String, RecurringEntry>{};
  for (final row in input.entries) {
    if (entries.containsKey(row.id) ||
        !input.instrumentIds.contains(row.instrumentId) ||
        (row.date?.isAfter(end) ?? false)) {
      throw CalculationInputException(
        InputErrorCode.invalidValue,
        'recurring.entries',
        '중복 ID·범위 밖 거래·미래 원천',
      );
    }
    entries[row.id] = row;
  }
  final reversed = <String>{};
  for (final row in input.entries.where(
    (row) => row.kind == RecurringEntryKind.reversal,
  )) {
    if (row.originalId != null) reversed.add(row.originalId!);
    if (row.originalId == null || !entries.containsKey(row.originalId)) {
      issues.add(
        RecurringIssue(RecurringIssueKind.reversal, row.instrumentId, [row.id]),
      );
    }
  }
  final complete = <String>{};
  for (final instrument in input.instrumentIds) {
    if (_covered(input.coverage, instrument, start.addDays(1), end)) {
      complete.add(instrument);
    } else {
      issues.add(
        RecurringIssue(
          RecurringIssueKind.incompleteCoverage,
          instrument,
          const [],
        ),
      );
    }
  }
  final groups = <String, List<RecurringEntry>>{};
  for (final row in input.entries) {
    if (row.kind != RecurringEntryKind.accountOutflow &&
        row.kind != RecurringEntryKind.cardPurchase) {
      continue;
    }
    if (row.exclusion != null) continue;
    final date = row.date;
    if (date == null) {
      issues.add(
        RecurringIssue(RecurringIssueKind.unknownDate, row.instrumentId, [
          row.id,
        ]),
      );
      continue;
    }
    if (!date.isAfter(start)) continue;
    final name = row.name == null ? '' : normalizeRecurringName(row.name!);
    if (name.isEmpty) {
      issues.add(
        RecurringIssue(RecurringIssueKind.unknownName, row.instrumentId, [
          row.id,
        ]),
      );
      continue;
    }
    final group = jsonEncode([row.instrumentId, row.kind.name, name]);
    groups.putIfAbsent(group, () => []).add(row);
  }
  for (final key in groups.keys.toList()..sort()) {
    final rows = groups[key]!..sort((a, b) => a.date!.compareTo(b.date!));
    if (!complete.contains(rows.first.instrumentId)) continue;
    if (rows.any((row) => !row.confirmed)) {
      issues.add(_issue(RecurringIssueKind.unconfirmed, rows));
      continue;
    }
    if (rows.any((row) => reversed.contains(row.id))) {
      issues.add(_issue(RecurringIssueKind.reversal, rows));
      continue;
    }
    if (rows.length < 3) continue;
    final byMonth = <String, List<RecurringEntry>>{};
    for (final row in rows) {
      byMonth
          .putIfAbsent(row.date!.toString().substring(0, 7), () => [])
          .add(row);
    }
    if (byMonth.length < 3 ||
        byMonth.values.any((month) => month.length != 1)) {
      issues.add(_issue(RecurringIssueKind.multipleOccurrences, rows));
      continue;
    }
    final evidence = rows.sublist(rows.length - 3);
    final days = [
      for (var day = 1; day <= 31; day++)
        if (evidence.every(
          (row) =>
              (row.date!.day -
                      BusinessDate.monthly(
                        row.date!.year,
                        row.date!.month,
                        day,
                      ).date.day)
                  .abs() <=
              5,
        ))
          day,
    ];
    if (days.isEmpty) {
      issues.add(_issue(RecurringIssueKind.irregularDates, evidence));
      continue;
    }
    final amounts = evidence.map((row) => row.amountKrw).toList()..sort();
    final median = amounts[1];
    if (median == 0 ||
        amounts.any((amount) => (amount - median).abs() * 10 > median)) {
      issues.add(_issue(RecurringIssueKind.changedAmount, evidence));
      continue;
    }
    final exactDays = days
        .where(
          (day) => evidence.every(
            (row) =>
                BusinessDate.monthly(
                  row.date!.year,
                  row.date!.month,
                  day,
                ).date ==
                row.date,
          ),
        )
        .toList();
    final ids = evidence.map((row) => row.id).toList()..sort();
    final candidateKey = jsonEncode([
      recurringRuleVersion,
      input.context.ruleVersion,
      ids,
    ]);
    if (input.decidedCandidateKeys.contains(candidateKey)) continue;
    candidates.add(
      RecurringCandidate(
        key: candidateKey,
        context: input.context,
        instrumentId: rows.first.instrumentId,
        kind: rows.first.kind,
        normalizedName: normalizeRecurringName(rows.first.name!),
        evidence: evidence,
        suggestedAmountKrw: evidence.last.amountKrw,
        suggestedDay: exactDays.length == 1 ? exactDays.single : null,
        amountVaries: amounts.first != amounts.last,
      ),
    );
  }
  return RecurringDetection(input.context, start, candidates, issues);
}

/// 2026-11-04: 여러 완료 구간을 합쳐 실제 빈틈 없이 요청 기간을 확보했는지 확인한다.
bool _covered(
  List<RecurringCoverage> coverage,
  String instrument,
  BusinessDate from,
  BusinessDate through,
) {
  final ranges =
      coverage
          .where((range) => range.instrumentId == instrument && range.complete)
          .toList()
        ..sort((a, b) => a.from.compareTo(b.from));
  var next = from;
  for (final range in ranges) {
    if (range.through.isBefore(next)) continue;
    if (range.from.isAfter(next)) return false;
    if (!range.through.isBefore(through)) return true;
    next = range.through.addDays(1);
  }
  return false;
}

/// 2026-11-04: 문제 원천의 ID를 그대로 보존해 사용자 확인 경로로 전달한다.
RecurringIssue _issue(RecurringIssueKind kind, List<RecurringEntry> entries) =>
    RecurringIssue(
      kind,
      entries.first.instrumentId,
      entries.map((row) => row.id),
    );
