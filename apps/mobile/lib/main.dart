import 'package:flutter/material.dart';

import 'app/payse_app.dart';
import 'data/salary_notice_store.dart';

/// 2026-10-19: PAYSE 앱을 시작한다. 인자는 없고 반환값 없이 루트 위젯을 등록한다.
/// 2026-10-29: 홈 월급 입금 확인 안내 접힘 기록은 기기 저장소에 남긴다.
void main() {
  runApp(PayseApp(salaryNotices: DeviceSalaryNoticeStore()));
}
