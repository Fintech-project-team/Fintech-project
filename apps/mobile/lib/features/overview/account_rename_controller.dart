import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../data/auth/random_id.dart';
import '../../data/connection/financial_api.dart';
import '../../data/connection/user_snapshot_repository.dart';
import '../../data/financial_snapshot.dart';
import '../../data/financial_snapshot_repository.dart';
import '../connection/connection_flow_controller.dart';
import '../connection/connection_review.dart';

/// 2026-10-29: 02-6 계좌 이름 입력에 쓸 수 있는 글자인지 판단한다. 한글(자모 포함)·영문·숫자·공백·PC 키보드
/// 특수문자 32종·이모지(조합·피부색·국기·키캡 포함)만 허용한다. [grapheme]은 화면에 보이는 한 글자다.
bool isNicknameGrapheme(String grapheme) {
  final runes = grapheme.runes.toList();
  if (runes.length == 1) {
    final r = runes.first;
    if (r == 0x20 ||
        (r >= 0x30 && r <= 0x39) ||
        (r >= 0x41 && r <= 0x5A) ||
        (r >= 0x61 && r <= 0x7A) ||
        (r >= 0xAC00 && r <= 0xD7A3) ||
        (r >= 0x1100 && r <= 0x11FF) ||
        (r >= 0x3130 && r <= 0x318F) ||
        AccountNicknameRule.specials.contains(grapheme)) {
      return true;
    }
  }
  return runes.any(_isEmojiBase) && runes.every(_isEmojiPart);
}

/// 2026-10-29: 이모지 그림 글자([rune])면 true를 반환한다.
bool _isEmojiBase(int rune) =>
    (rune >= 0x1F000 && rune <= 0x1FAFF) ||
    (rune >= 0x2600 && rune <= 0x27BF) ||
    (rune >= 0x2300 && rune <= 0x23FF) ||
    (rune >= 0x2B00 && rune <= 0x2BFF) ||
    (rune >= 0x2190 && rune <= 0x21FF) ||
    rune == 0x00A9 ||
    rune == 0x00AE ||
    rune == 0x20E3;

/// 2026-10-29: 이모지 한 글자를 이루는 부분([rune]: 그림·결합자·변형 선택자·피부색·태그·키캡 숫자)이면 true를 반환한다.
bool _isEmojiPart(int rune) =>
    _isEmojiBase(rune) ||
    rune == 0x200D ||
    rune == 0xFE0F ||
    rune == 0xFE0E ||
    (rune >= 0xE0020 && rune <= 0xE007F) ||
    (rune >= 0x30 && rune <= 0x39) ||
    rune == 0x23 ||
    rune == 0x2A;

/// 2026-10-29: 02-6 입력 필터. 허용하지 않는 글자는 넣지 않고 [onBlocked]로 알리며, 보이는 글자 12자를 넘게 입력되지
/// 않게 자른다. 글자 수는 앞뒤 공백을 포함해 센다(저장할 때 앞뒤 공백을 지운다).
class NicknameInputFormatter extends TextInputFormatter {
  /// 2026-10-29: 거른 글자가 있었는지 알릴 [onBlocked]로 만든다.
  NicknameInputFormatter({required this.onBlocked});

  final ValueChanged<bool> onBlocked;

  /// 2026-10-29: [text]에서 허용 글자만 남긴 문자열과 거른 글자가 있었는지를 반환한다.
  static (String, bool) _filter(String text) {
    final kept = text.characters.where(isNicknameGrapheme).toList();
    return (kept.join(), kept.length != text.characters.length);
  }

  /// 2026-10-29: 새 입력 [newValue]를 걸러 반환한다. 12자를 넘으면 앞에서부터 12자만 남긴다.
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final (filtered, blocked) = _filter(newValue.text);
    onBlocked(blocked);
    final chars = filtered.characters;
    final text = chars.length > AccountNicknameRule.maxLength
        ? chars.take(AccountNicknameRule.maxLength).join()
        : filtered;
    if (text == newValue.text) return newValue;
    final cursor = newValue.selection.isValid
        ? _filter(
            newValue.text.substring(
              0,
              newValue.selection.extentOffset.clamp(0, newValue.text.length),
            ),
          ).$1.length.clamp(0, text.length)
        : text.length;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }
}

/// 2026-10-29: 02-6 계좌 이름 바꾸기의 상태 소유자. 마지막으로 받은 Snapshot의 계좌 이름을 저장 값으로 두고 입력과 비교해
/// PATCH /accounts/{accountId}로 보낸다. 비우면 null(원래 이름)로 보낸다. 금액을 계산하지 않는다.
class AccountRenameController extends ChangeNotifier {
  /// 2026-10-29: 세션 저장소 [repository], 시작 Snapshot [snapshot], 대상 계좌 [accountId], 세션 무효 [onSessionInvalid],
  /// 작업 키 난수 [random]으로 만든다. 입력은 저장된 이름으로 시작한다.
  AccountRenameController({
    required this.repository,
    required this._snapshot,
    required this.accountId,
    required this.onSessionInvalid,
    Random? random,
  }) : _random = random ?? Random.secure() {
    _text = saved ?? '';
  }

  final UserFinancialRepository repository;
  final String accountId;
  final VoidCallback onSessionInvalid;
  final Random _random;
  FinancialSnapshot _snapshot;
  String _text = '';
  bool _blocked = false;
  ConnectionSaveState _save = const SaveIdle();
  ReloadStatus _reload = ReloadStatus.idle;
  ({String key, String fingerprint})? _attempt;
  bool _disposed = false;

  /// 2026-10-29: 마지막으로 받은 Snapshot.
  FinancialSnapshot get snapshot => _snapshot;

  /// 2026-10-29: 대상 계좌. 최신 정보에서 사라졌으면 null이다.
  Account? get account => accountById(_snapshot, accountId);

  /// 2026-10-29: 저장된 계좌 이름. 정하지 않았으면 null이다.
  String? get saved => account?.nickname;

  /// 2026-10-29: 입력 중인 글자(앞뒤 공백 포함).
  String get text => _text;

  /// 2026-10-29: 입력 중인 글자 수(보이는 글자 기준, 공백 포함).
  int get length => _text.characters.length;

  /// 2026-10-29: 방금 입력에서 쓸 수 없는 글자를 걸렀으면 true를 반환한다.
  bool get blocked => _blocked;

  /// 2026-10-29: 보낼 이름. 앞뒤 공백을 지우고, 비었으면 null(원래 이름)이다.
  String? get target {
    final trimmed = _text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 2026-10-29: 입력이 특수문자·공백만이라 저장할 수 없으면 true를 반환한다.
  bool get specialsOnly {
    final t = target;
    return t != null && !AccountNicknameRule.isValid(t);
  }

  /// 2026-10-29: 저장 진행 상태.
  ConnectionSaveState get save => _save;

  /// 2026-10-29: 버전 불일치 뒤 최신 정보 불러오기 상태.
  ReloadStatus get reload => _reload;

  /// 2026-10-29: 저장 중이거나 최신 정보를 불러오는 중이면 true를 반환한다(입력·닫기를 막는다).
  bool get busy => _save is SaveInProgress || _reload == ReloadStatus.loading;

  /// 2026-10-29: 자료·규칙 버전 불일치로 저장하지 못해 최신 정보를 다시 불러와야 하면 true를 반환한다.
  bool get outdated => switch (_save) {
    SaveFailed(failure: ConnectionSaveFailure.outdated) => true,
    _ => false,
  };

  /// 2026-10-29: 저장 버튼을 누를 수 있으면 true를 반환한다. 보낼 이름이 저장 값과 다르고, 특수문자만이 아니며,
  /// 진행 중이 아니고, 최신 정보를 다시 불러와야 하는 상태가 아닐 때다.
  bool get canSave =>
      target != saved && !specialsOnly && !busy && !outdated && account != null;

  /// 2026-10-29: 입력을 [text]로 바꾼다.
  void setText(String text) {
    if (busy || text == _text) return;
    _text = text;
    _changed();
  }

  /// 2026-10-29: 쓸 수 없는 글자 안내를 [blocked]로 바꾼다.
  void setBlocked(bool blocked) {
    if (_blocked == blocked) return;
    _blocked = blocked;
    _changed();
  }

  /// 2026-10-29: 이름을 저장한다. 성공 응답의 Snapshot을 반환하고, 실패면 입력을 그대로 두고 null을 반환한다.
  /// 응답을 받지 못한 같은 내용의 재시도에는 같은 작업 키를 쓴다.
  Future<FinancialSnapshot?> submit() async {
    if (!canSave) return null;
    final body = target;
    final fingerprint = jsonEncode([
      _snapshot.dataVersion,
      _snapshot.ruleVersion,
      accountId,
      body,
    ]);
    final attempt = _attempt?.fingerprint == fingerprint
        ? _attempt!
        : (key: randomUuidV4(_random), fingerprint: fingerprint);
    _attempt = attempt;
    _save = const SaveInProgress();
    _changed();
    final outcome = await repository.updateAccountNickname(
      accountId,
      body,
      WriteContext(
        expectedDataVersion: _snapshot.dataVersion,
        ruleVersion: _snapshot.ruleVersion,
        idempotencyKey: attempt.key,
      ),
    );
    if (_disposed) return null;
    FinancialSnapshot? next;
    switch (outcome) {
      case FinancialOk(:final value):
        next = _parse(value.snapshot);
        _save = next == null
            ? const SaveFailed(ConnectionSaveFailure.retryable)
            : const SaveIdle();
      case FinancialSessionInvalid():
        _save = const SaveFailed(ConnectionSaveFailure.retryable);
        onSessionInvalid();
      case FinancialStaleData() || FinancialRuleVersionMismatch():
        _save = const SaveFailed(ConnectionSaveFailure.outdated);
      case FinancialUnavailable() || FinancialNetworkFailure():
        _save = const SaveFailed(ConnectionSaveFailure.retryable);
      case FinancialInvalid() ||
          FinancialForbidden() ||
          FinancialIdempotencyConflict():
        _save = const SaveFailed(ConnectionSaveFailure.rejected);
    }
    if (_save case SaveFailed(:final failure)
        when failure != ConnectionSaveFailure.retryable) {
      _attempt = null;
    }
    if (next != null) {
      _attempt = null;
      _snapshot = next;
    }
    _changed();
    return next;
  }

  /// 2026-10-29: 최신 Snapshot을 다시 읽는다. 성공하면 저장 값 기준을 바꾸고 입력은 그대로 둔 뒤 그 Snapshot을 반환한다.
  /// 실패면 null이고, 세션 무효면 신규 로그인으로 넘긴다.
  Future<FinancialSnapshot?> reloadLatest() async {
    if (busy) return null;
    _reload = ReloadStatus.loading;
    _changed();
    final result = await UserSnapshotRepository(repository).loadSnapshot();
    if (_disposed) return null;
    FinancialSnapshot? next;
    switch (result) {
      case SnapshotLoaded(:final snapshot) when snapshot.accounts != null:
        next = snapshot;
      case SnapshotLoadFailed(:final error)
          when error is FinancialLoadError && error.sessionInvalid:
        onSessionInvalid();
      case _:
        break;
    }
    if (next == null) {
      _reload = ReloadStatus.failed;
    } else {
      _snapshot = next;
      _reload = ReloadStatus.idle;
      _save = const SaveIdle();
      _attempt = null;
    }
    _changed();
    return next;
  }

  /// 2026-10-29: 응답 JSON [json]을 Snapshot으로 읽는다. 형식이 맞지 않거나 계좌 묶음이 없으면 null이다.
  FinancialSnapshot? _parse(Map<String, Object?> json) {
    try {
      final parsed = FinancialSnapshot.fromJson(json);
      return parsed.accounts == null ? null : parsed;
    } on SnapshotFormatException {
      return null;
    }
  }

  /// 2026-10-29: 폐기 전이면 듣는 화면에 알린다.
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// 2026-10-29: 폐기한다. 늦게 도착한 응답은 반영하지 않는다.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
