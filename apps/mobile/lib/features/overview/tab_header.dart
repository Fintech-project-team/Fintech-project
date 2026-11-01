import 'package:flutter/material.dart';

import '../../shared/design/payse_tokens.dart';

/// 2026-11-01: 계좌·카드 탭 세 화면(이번 기간 내역·전체 거래·계좌 관리) 상단의 공통 순서(#163, 혜연 요청)는
/// 범위 문구 → 핵심 정보(기간 또는 잔액) → 기준 시각 → 조작 영역이다. 안쪽 탭 아래 첫 줄까지의 여백이다.
const double tabTopGap = PayseSpace.x5;

/// 2026-11-01: 핵심 정보 줄의 최소 높이. 기간(누를 수 있는 제목)과 잔액이 같은 높이를 차지해 기준 시각이 같은 자리에 온다.
const double tabKeyLineHeight = PayseSize.touchMin;

/// 2026-11-01: 핵심 정보 글자(기간 20/700). 계좌 관리 잔액은 이보다 한 단계 큰 24/800이다.
const TextStyle tabKeyStyle = TextStyle(
  fontSize: 20,
  height: 28 / 20,
  fontWeight: FontWeight.w700,
  color: PayseColors.textPrimary,
  fontFeatures: PayseTypography.tabular,
);

/// 2026-11-01: 상단 범위 문구(14/500 textSecondary). 무엇을 보는 화면인지 알리며 핵심 정보보다 낮게 강조한다.
class TabScope extends StatelessWidget {
  /// 2026-11-01: 문구 [text]로 만든다.
  const TabScope(this.text, {super.key});

  final String text;

  /// 2026-11-01: 범위 문구를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          height: 20 / 14,
          fontWeight: FontWeight.w500,
          color: PayseColors.textSecondary,
        ),
      ),
    );
  }
}

/// 2026-11-01: 상단 조작 영역의 이동 줄(전체 폭 한 터치 영역, 최소 48dp). 왼쪽 [label](14/600) … 오른쪽 보조 [trailing]
/// (13 textSecondary, 누를 수 없는 정보)·'›'. 좁거나 글자가 크면 보조 정보를 다음 줄로 내린다.
class TabLinkRow extends StatelessWidget {
  /// 2026-11-01: 문구 [label], 보조 정보 [trailing], 누르기 [onTap]으로 만든다.
  const TabLinkRow({
    required this.label,
    required this.onTap,
    this.trailing,
    super.key,
  });

  final String label;
  final String? trailing;
  final VoidCallback onTap;

  /// 2026-11-01: 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final info = trailing;
    return Semantics(
      button: true,
      label: info == null ? label : '$label, $info',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: PayseSize.touchMin),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: PayseSpace.x2,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 20 / 14,
                        fontWeight: FontWeight.w600,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    if (info != null)
                      Text(
                        info,
                        key: const ValueKey('tab-link-trailing'),
                        style: PayseTypography.caption,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: PayseSpace.x1),
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: PayseColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
