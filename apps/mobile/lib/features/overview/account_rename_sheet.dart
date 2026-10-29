import 'package:flutter/material.dart';

import '../../data/connection/financial_api.dart';
import '../../data/financial_snapshot.dart';
import '../../shared/design/payse_text_field.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_flow_controller.dart';
import '../connection/connection_review.dart';
import 'account_rename_controller.dart';
import 'home_screen.dart' show NoticeBand;

/// 2026-10-29: 02-6 저장 결과. [snapshot]은 저장 응답의 최신 Snapshot, [reverted]는 이름을 지워 원래 이름으로 되돌렸는지다.
typedef AccountRenameResult = ({FinancialSnapshot snapshot, bool reverted});

/// 2026-10-29: 02-6 계좌 이름 바꾸기 시트를 연다. 저장에 성공하면 결과를, 닫으면 null을 반환한다.
/// 저장·최신 정보 불러오기 중에는 닫을 수 없다. 최신 정보를 불러왔으면 [onSnapshot]으로 알린다.
Future<AccountRenameResult?> showAccountRenameSheet(
  BuildContext context, {
  required UserFinancialRepository repository,
  required FinancialSnapshot snapshot,
  required String accountId,
  required VoidCallback onSessionInvalid,
  required ValueChanged<FinancialSnapshot> onSnapshot,
}) {
  return showModalBottomSheet<AccountRenameResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: PayseColors.background,
    barrierColor: const Color(0x80242629),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(PayseRadius.lg)),
    ),
    builder: (_) => AccountRenameSheet(
      repository: repository,
      snapshot: snapshot,
      accountId: accountId,
      onSessionInvalid: onSessionInvalid,
      onSnapshot: onSnapshot,
    ),
  );
}

/// 2026-10-29: 02-6 시트 본문. 제목·대상 계좌 → 실패 안내 띠 → 이름 입력칸(N/12) → 안내 → 저장 버튼.
class AccountRenameSheet extends StatefulWidget {
  /// 2026-10-29: 세션 저장소 [repository], 시작 Snapshot [snapshot], 대상 계좌 [accountId], 세션 무효 [onSessionInvalid],
  /// 최신 정보를 불러온 뒤 알릴 [onSnapshot]으로 만든다.
  const AccountRenameSheet({
    super.key,
    required this.repository,
    required this.snapshot,
    required this.accountId,
    required this.onSessionInvalid,
    required this.onSnapshot,
  });

  final UserFinancialRepository repository;
  final FinancialSnapshot snapshot;
  final String accountId;
  final VoidCallback onSessionInvalid;
  final ValueChanged<FinancialSnapshot> onSnapshot;

  /// 2026-10-29: 입력 상태 객체를 반환한다.
  @override
  State<AccountRenameSheet> createState() => _AccountRenameSheetState();
}

/// 2026-10-29: 입력칸과 상태 소유자를 이어 두고, 저장 성공이면 시트를 닫으며 결과를 넘긴다.
class _AccountRenameSheetState extends State<AccountRenameSheet> {
  late final AccountRenameController _c = AccountRenameController(
    repository: widget.repository,
    snapshot: widget.snapshot,
    accountId: widget.accountId,
    onSessionInvalid: widget.onSessionInvalid,
  );
  late final TextEditingController _input = TextEditingController(
    text: _c.text,
  );
  late final NicknameInputFormatter _formatter = NicknameInputFormatter(
    onBlocked: _c.setBlocked,
  );

  /// 2026-10-29: 입력칸 변화를 상태 소유자에 전한다.
  @override
  void initState() {
    super.initState();
    _input.addListener(() => _c.setText(_input.text));
  }

  /// 2026-10-29: 상태 소유자와 입력칸을 폐기한다.
  @override
  void dispose() {
    _c.dispose();
    _input.dispose();
    super.dispose();
  }

  /// 2026-10-29: 저장한다. 성공하면 시트를 닫고 결과를 넘긴다.
  Future<void> _submit() async {
    final reverted = _c.target == null;
    final next = await _c.submit();
    if (next == null || !mounted) return;
    Navigator.of(context).pop((snapshot: next, reverted: reverted));
  }

  /// 2026-10-29: 최신 정보를 불러온다. 성공하면 바깥 화면에도 알린다.
  Future<void> _reload() async {
    final next = await _c.reloadLatest();
    if (next != null) widget.onSnapshot(next);
  }

  /// 2026-10-29: 저장·불러오기 실패 안내 띠를 반환한다. 실패가 없으면 null이다.
  Widget? _band() {
    if (_c.reload == ReloadStatus.failed) {
      return NoticeBand(
        key: const ValueKey('rename-band-reload-failed'),
        title: '최신 정보를 불러오지 못했어요',
        body: '입력한 내용은 그대로 남아 있어요. 다시 불러와 주세요.',
        actionLabel: '다시 불러오기',
        actionKey: const ValueKey('rename-reload'),
        onAction: _reload,
      );
    }
    return switch (_c.save) {
      SaveFailed(failure: ConnectionSaveFailure.retryable) => const NoticeBand(
        key: ValueKey('rename-band-retryable'),
        title: '계좌 이름을 저장하지 못했어요',
        body: '입력한 내용은 그대로 남아 있어요. 잠시 후 다시 저장해 주세요.',
      ),
      SaveFailed(failure: ConnectionSaveFailure.outdated) => NoticeBand(
        key: const ValueKey('rename-band-outdated'),
        title: '저장 전에 정보가 바뀌었어요',
        body: '최신 정보를 불러온 뒤 다시 저장해 주세요. 입력한 내용은 그대로 남아 있어요.',
        actionLabel: _c.reload == ReloadStatus.loading
            ? '불러오는 중'
            : '최신 정보 불러오기',
        actionKey: const ValueKey('rename-reload'),
        onAction: _c.reload == ReloadStatus.loading ? null : _reload,
      ),
      SaveFailed(failure: ConnectionSaveFailure.rejected) => const NoticeBand(
        key: ValueKey('rename-band-rejected'),
        title: '계좌 이름을 저장할 수 없어요',
        body: '입력한 내용을 다시 확인해 주세요.',
      ),
      _ => null,
    };
  }

  /// 2026-10-29: 시트 본문을 반환한다. 키보드가 올라오면 그만큼 위로 올린다.
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final account = _c.account;
        final snapshot = _c.snapshot;
        final band = _band();
        final busy = _c.busy;
        return PopScope(
          canPop: !busy,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                0,
                PayseSpace.x2,
                0,
                PayseSpace.x6,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: PayseColors.dividerSection,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      PayseSpace.screenHorizontal,
                      PayseSpace.x3,
                      PayseSpace.x2,
                      0,
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '계좌 이름 바꾸기',
                            style: TextStyle(
                              fontSize: 17,
                              height: 1.45,
                              fontWeight: FontWeight.w700,
                              color: PayseColors.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('rename-close'),
                          tooltip: '닫기',
                          constraints: const BoxConstraints.tightFor(
                            width: PayseSize.touchMin,
                            height: PayseSize.touchMin,
                          ),
                          onPressed: busy
                              ? null
                              : () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ],
                    ),
                  ),
                  if (account != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: PayseSpace.screenHorizontal,
                      ),
                      child: Text(
                        '${institutionName(snapshot, account.institutionCode)} '
                        '${account.productName} ····${lastFour(account.maskedNumber)}',
                        key: const ValueKey('rename-target'),
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: PayseColors.textSecondary,
                        ),
                      ),
                    ),
                  if (band != null)
                    Padding(
                      padding: const EdgeInsets.only(top: PayseSpace.x4),
                      child: band,
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      PayseSpace.screenHorizontal,
                      PayseSpace.x5,
                      PayseSpace.screenHorizontal,
                      0,
                    ),
                    child: PayseTextField(
                      key: const ValueKey('rename-field'),
                      label: '계좌 이름',
                      controller: _input,
                      hintText: account?.productName,
                      errorText: _c.specialsOnly
                          ? '한글, 영문, 숫자, 이모지를 1자 이상 넣어주세요.'
                          : null,
                      enabled: !busy,
                      autofocus: true,
                      inputFormatters: [_formatter],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      PayseSpace.screenHorizontal,
                      6,
                      PayseSpace.screenHorizontal,
                      0,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _c.blocked
                              ? const Row(
                                  key: ValueKey('rename-blocked'),
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.only(top: 2),
                                      child: Icon(
                                        Icons.warning_amber_rounded,
                                        size: 14,
                                        color: PayseColors.warning,
                                      ),
                                    ),
                                    SizedBox(width: PayseSpace.x1),
                                    Expanded(
                                      child: Text(
                                        '한글, 영문, 숫자, 특수문자, 이모지만 쓸 수 있어요.',
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 18 / 12,
                                          color: PayseColors.warning,
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : Text(
                                  '비워두고 저장하면 원래 이름으로 돌아가요.',
                                  key: const ValueKey('rename-guide'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 18 / 12,
                                    color: _c.target == null && _c.saved != null
                                        ? PayseColors.textPrimary
                                        : PayseColors.textSecondary,
                                  ),
                                ),
                        ),
                        const SizedBox(width: PayseSpace.x3),
                        Text(
                          '${_c.length}/${AccountNicknameRule.maxLength}',
                          key: const ValueKey('rename-count'),
                          style: const TextStyle(
                            fontSize: 12,
                            height: 18 / 12,
                            color: PayseColors.textSecondary,
                            fontFeatures: PayseTypography.tabular,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      PayseSpace.screenHorizontal,
                      PayseSpace.x6,
                      PayseSpace.screenHorizontal,
                      0,
                    ),
                    child: SizedBox(
                      height: 52,
                      child: FilledButton(
                        key: const ValueKey('rename-save'),
                        onPressed: _c.canSave ? _submit : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: PayseColors.charcoal,
                          foregroundColor: PayseColors.onCharcoal,
                          disabledBackgroundColor: PayseColors.surfaceMuted,
                          disabledForegroundColor: PayseColors.textSecondary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(PayseRadius.sm),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: Text(
                          _c.save is SaveInProgress ? '저장하는 중' : '저장하기',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
