import 'package:flutter/material.dart';

import '../../data/financial_snapshot_repository.dart';
import '../../data/fixture_scenario.dart';

/// 2026-10-20: 개발·테스트 전용 더미 확인 화면. 릴리스 빌드에는 진입점이 없다.
/// 스냅샷을 고르고 계좌·카드·거래 수와 기준 시각·버전을 보여준다. 금액을 계산하지 않는다.
/// 2026-10-23: 개발 설정 화면. 연결 실패 연출 켜기·끄기를 두고, 더미 스냅샷은 읽기 전용 미리보기로만 보인다
/// (첫 화면 판단·저장 대상을 바꾸지 않음).
class FixtureDebugScreen extends StatefulWidget {
  /// 2026-10-20: 스냅샷별 Repository를 만드는 [repositoryFor]로 만든다.
  /// 2026-10-23: 앱 프로세스 동안 유지하는 실패 연출 토글 [failurePresentation]을 받는다.
  const FixtureDebugScreen({
    super.key,
    required this.repositoryFor,
    required this.failurePresentation,
  });

  final FinancialSnapshotRepository Function(FixtureScenario) repositoryFor;
  final ValueNotifier<bool> failurePresentation;

  /// 2026-10-20: 화면 상태 객체를 반환한다.
  @override
  State<FixtureDebugScreen> createState() => _FixtureDebugScreenState();
}

/// 2026-10-20: 선택한 스냅샷과 조회 결과를 보관한다.
class _FixtureDebugScreenState extends State<FixtureDebugScreen> {
  FixtureScenario _scenario = FixtureScenario.defaultScenario;
  late Future<SnapshotLoadResult> _result = _load();

  /// 2026-10-20: 현재 스냅샷을 Repository로 조회한다.
  Future<SnapshotLoadResult> _load() =>
      widget.repositoryFor(_scenario).loadSnapshot();

  /// 2026-10-20: [scenario]로 바꾸고 다시 조회한다. 반환값 없음.
  void _select(FixtureScenario scenario) {
    setState(() {
      _scenario = scenario;
      _result = _load();
    });
  }

  /// 2026-10-20: 스냅샷 선택 목록과 조회 결과를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('개발 설정')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('개발·테스트 전용 화면이에요. 릴리스 빌드에는 나오지 않아요.'),
          const SizedBox(height: 16),
          ValueListenableBuilder<bool>(
            valueListenable: widget.failurePresentation,
            builder: (context, enabled, _) => SwitchListTile(
              key: const ValueKey('failure-presentation-toggle'),
              contentPadding: EdgeInsets.zero,
              title: const Text('연결 실패 연출'),
              subtitle: const Text(
                '12-3에서 실패를 처음 추첨하기 전에 바꾸면 이번 연결에, 그 뒤에 바꾸면 다음 연결부터 적용돼요. '
                '실제 저장 오류 안내는 그대로예요.',
              ),
              value: enabled,
              onChanged: (v) => widget.failurePresentation.value = v,
            ),
          ),
          const Divider(height: 32),
          const Text('더미 스냅샷 미리보기(읽기 전용, 현재 계정의 화면·저장에는 쓰지 않아요)'),
          const SizedBox(height: 8),
          for (final s in FixtureScenario.values)
            ListTile(
              key: ValueKey('scenario-${s.fileStem}'),
              contentPadding: EdgeInsets.zero,
              title: Text(s.fileStem),
              subtitle: Text(s.devLabel),
              trailing: s == _scenario ? const Icon(Icons.check) : null,
              selected: s == _scenario,
              onTap: () => _select(s),
            ),
          const Divider(height: 32),
          FutureBuilder<SnapshotLoadResult>(
            future: _result,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Text('불러오는 중…');
              }
              return switch (snap.requireData) {
                SnapshotLoaded(:final snapshot) => Column(
                  key: const ValueKey('fixture-summary'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('기준 시각 ${snapshot.asOf}'),
                    Text(
                      '자료 버전 ${snapshot.dataVersion} · 규칙 ${snapshot.ruleVersion}',
                    ),
                    Text(_count('계좌', snapshot.accounts?.length, '개')),
                    Text(_count('카드', snapshot.cards?.length, '장')),
                    Text(_count('거래', snapshot.transactions?.length, '건')),
                  ],
                ),
                SnapshotLoadFailed() => const Text(
                  '더미를 읽지 못했어요.',
                  key: ValueKey('fixture-load-failed'),
                ),
                SnapshotFormatInvalid(:final path, :final reason) => Text(
                  '더미 형식이 맞지 않아요: $path ($reason)',
                  key: const ValueKey('fixture-format-invalid'),
                ),
              };
            },
          ),
        ],
      ),
    );
  }

  /// 2026-10-20: 개수 문장을 만든다. [count]가 null이면 묶음이 없는 것이라 0개와 구분해 표시한다.
  static String _count(String label, int? count, String unit) =>
      count == null ? '$label 자료 없음(미노출)' : '$label $count$unit';
}
