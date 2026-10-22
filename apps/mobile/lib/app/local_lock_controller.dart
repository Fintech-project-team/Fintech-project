import 'dart:async';

import 'package:flutter/foundation.dart';

/// 2026-10-21: 10분 무입력 잠금 판정(app-architecture §3 LocalLockController). 네트워크 없이 시각만으로 판정한다.
/// 마지막 사용자 입력 후 [timeout]이 지나면 잠근다. 백그라운드에서는 타이머가 멈출 수 있으므로
/// 복귀 때 백그라운드 시간을 포함한 경과 시간을 다시 계산한다. 잠금 시각은 금융 스냅샷 시각과 무관하다.
class LocalLockController extends ChangeNotifier {
  /// 2026-10-21: 시각 [now]와 잠금 시간 [timeout]으로 만든다. 처음에는 꺼져 있다(로그인 전).
  LocalLockController({
    DateTime Function()? now,
    this.timeout = const Duration(minutes: 10),
  }) : _now = now ?? DateTime.now;

  final Duration timeout;
  final DateTime Function() _now;
  bool _enabled = false;
  bool _locked = false;
  DateTime? _lastActivity;
  Timer? _timer;

  /// 2026-10-21: 지금 잠겨 있으면 true를 반환한다.
  bool get locked => _locked;

  /// 2026-10-21: 잠금 판정을 켠다(세션·PIN 확인 후). 지금을 마지막 입력 시각으로 삼는다.
  void enable() {
    _enabled = true;
    _locked = false;
    recordActivity();
  }

  /// 2026-10-21: 잠금 판정을 끄고 잠금을 푼다(로그인 전 화면).
  void disable() {
    _enabled = false;
    _timer?.cancel();
    if (_locked) {
      _locked = false;
      notifyListeners();
    }
  }

  /// 2026-10-21: 사용자 입력을 기록하고 잠금 타이머를 다시 맞춘다. 잠금 중 입력은 잠금 화면 입력이므로 무시한다.
  void recordActivity() {
    if (!_enabled || _locked) return;
    _lastActivity = _now();
    _schedule(timeout);
  }

  /// 2026-10-21: 앱이 백그라운드로 갔다. 멈출 수 있는 타이머를 끄고 복귀 때 다시 계산한다.
  void onBackground() => _timer?.cancel();

  /// 2026-10-21: 앱이 돌아왔다. 마지막 입력 후 경과 시간이 [timeout] 이상이면 잠근다.
  void onForeground() => _check();

  /// 2026-10-21: 11-1 PIN 확인에 성공해 잠금을 푼다. 지금부터 다시 센다.
  void unlock() {
    if (!_locked) return;
    _locked = false;
    notifyListeners();
    recordActivity();
  }

  /// 2026-10-21: [after] 뒤에 경과 시간을 확인하도록 타이머를 건다.
  void _schedule(Duration after) {
    _timer?.cancel();
    _timer = Timer(after, _check);
  }

  /// 2026-10-21: 경과 시간이 [timeout] 이상이면 잠그고, 아니면 남은 시간만큼 다시 기다린다.
  void _check() {
    final last = _lastActivity;
    if (!_enabled || _locked || last == null) return;
    final elapsed = _now().difference(last);
    if (elapsed >= timeout) {
      _timer?.cancel();
      _locked = true;
      notifyListeners();
    } else {
      _schedule(timeout - elapsed);
    }
  }

  /// 2026-10-21: 타이머를 취소한다.
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
