import 'package:flutter/material.dart';

import '../../data/financial_snapshot.dart';
import '../../shared/design/payse_tokens.dart';
import '../overview/accounts_screen.dart';
import '../overview/home_screen.dart' show asOfLabel;

/// 2026-11-03: 설치된 앱의 버전 [version]과 빌드 번호 [buildNumber].
typedef AppVersion = ({String version, String buildNumber});

/// 2026-11-03: 설치된 앱 버전을 읽는 함수. 앱 시작 지점이 만들어 넘기며 화면은 플랫폼 기능을 직접 부르지 않는다.
typedef AppVersionReader = Future<AppVersion?> Function();

/// 2026-11-03: 하단 '내 정보' 탭(03-6, 29-4). 위에서부터 제목, 로그인한 사용자 이름, 설정 목록 위의 작은 기준 시각,
/// '월급 정보'·'계산에 포함할 계좌' 줄, 로그아웃 등 아래 위젯, 앱 버전 순서다. 두 줄은 계좌 관리와 같은 화면·저장을 연다.
/// 카드 목록·카드 결제일과 후속 메뉴는 두지 않는다. 내용이 화면보다 길면 함께 스크롤한다.
class MyInfoScreen extends StatefulWidget {
  /// 2026-11-03: 현재 Snapshot [snapshot], 사용자 이름 [userName](없으면 이름 줄 없음), 저장 연결 [writer](없으면 두 줄을
  /// 누를 수 없음), 월급 편집 열기 [onEditSalary], 로그아웃 등 아래 위젯 [footer], 버전 읽기 [version](없거나 실패하면
  /// 버전 줄 없음)으로 만든다.
  const MyInfoScreen({
    super.key,
    required this.snapshot,
    this.userName,
    this.writer,
    this.onEditSalary,
    this.footer,
    this.version,
  });

  final FinancialSnapshot snapshot;
  final String? userName;
  final AccountsWriter? writer;
  final VoidCallback? onEditSalary;
  final Widget? footer;
  final AppVersionReader? version;

  /// 2026-11-03: 버전 조회 상태 객체를 반환한다.
  @override
  State<MyInfoScreen> createState() => _MyInfoScreenState();
}

/// 2026-11-03: 버전을 화면이 처음 만들어질 때 한 번 읽는다.
class _MyInfoScreenState extends State<MyInfoScreen> {
  String? _version;

  /// 2026-11-03: 버전 읽기를 시작한다.
  @override
  void initState() {
    super.initState();
    _readVersion();
  }

  /// 2026-11-03: 버전을 읽어 'PAYSE 버전 (빌드 번호)'로 둔다. 읽지 못했거나 값이 비면 버전 줄을 두지 않는다.
  Future<void> _readVersion() async {
    final reader = widget.version;
    if (reader == null) return;
    AppVersion? read;
    try {
      read = await reader();
    } catch (_) {
      return;
    }
    if (!mounted || read == null) return;
    final (:version, :buildNumber) = read;
    if (version.trim().isEmpty || buildNumber.trim().isEmpty) return;
    setState(() => _version = 'PAYSE $version ($buildNumber)');
  }

  /// 2026-11-03: 화면을 반환한다. 아래 위젯과 버전은 내용이 짧으면 화면 아래에 붙는다.
  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final writer = widget.writer;
    final name = widget.userName?.trim();
    final salary = snapshot.settings?.salary;
    final included = (snapshot.accounts ?? const <Account>[])
        .where((a) => a.included)
        .length;
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PayseSpace.screenHorizontal,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: PayseSpace.x6),
                  Semantics(
                    header: true,
                    child: const Text(
                      '내 정보',
                      style: TextStyle(
                        fontSize: 24,
                        height: 1.42,
                        fontWeight: FontWeight.w700,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                  ),
                  if (name != null && name.isNotEmpty) ...[
                    const SizedBox(height: PayseSpace.x5),
                    Text(
                      '$name님',
                      key: const ValueKey('my-info-name'),
                      style: const TextStyle(
                        fontSize: 20,
                        height: 1.4,
                        fontWeight: FontWeight.w700,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                  ],
                  const SizedBox(height: PayseSpace.x6),
                  Text(
                    asOfLabel(snapshot.asOf),
                    key: const ValueKey('my-info-as-of'),
                    style: PayseTypography.caption,
                  ),
                  const SizedBox(height: PayseSpace.x2),
                  const Divider(height: 1, color: PayseColors.dividerSection),
                  if (salary != null)
                    _MyInfoRow(
                      key: const ValueKey('my-info-salary'),
                      title: '월급 정보',
                      text: salarySummary(snapshot, salary),
                      onTap: writer == null ? null : widget.onEditSalary,
                    ),
                  _MyInfoRow(
                    key: const ValueKey('my-info-accounts'),
                    title: '계산에 포함할 계좌',
                    text: '계좌 $included개 포함',
                    onTap: switch (writer) {
                      final w? => () => openAccountSelection(
                        context,
                        snapshot,
                        w,
                      ),
                      null => null,
                    },
                  ),
                  const Spacer(),
                  if (widget.footer case final footer?) ...[
                    const SizedBox(height: PayseSpace.x6),
                    footer,
                  ],
                  if (_version case final version?)
                    Padding(
                      padding: const EdgeInsets.only(top: PayseSpace.x4),
                      child: Text(
                        version,
                        key: const ValueKey('my-info-version'),
                        textAlign: TextAlign.center,
                        style: PayseTypography.caption,
                      ),
                    ),
                  const SizedBox(height: PayseSpace.x5),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 2026-11-03: 내 정보 설정 줄(최소 높이 72, 제목 15/600·설명 13, 오른쪽 화살표, 아래 옅은 선). 누를 수 없으면 화살표를 두지 않는다.
class _MyInfoRow extends StatelessWidget {
  /// 2026-11-03: 제목 [title], 설명 [text], 누르기 [onTap]으로 만든다.
  const _MyInfoRow({
    super.key,
    required this.title,
    required this.text,
    required this.onTap,
  });

  final String title;
  final String text;
  final VoidCallback? onTap;

  /// 2026-11-03: 설정 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(vertical: PayseSpace.x3),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.47,
                        fontWeight: FontWeight.w600,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    Text(text, style: PayseTypography.caption),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: PayseSpace.x3),
                const Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: PayseColors.textSecondary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
