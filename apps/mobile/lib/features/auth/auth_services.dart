import '../../data/auth/auth_repository.dart';
import '../../data/auth/credential_stores.dart';
import '../../data/auth/session_cleanup.dart';

/// 2026-10-21: 인증 화면이 쓰는 의존성 묶음. 앱 시작 지점에서 만들어 생성자로 넘긴다(전역 조회 없음).
class AuthServices {
  /// 2026-10-21: 인증 저장소 [repository], 기기 저장소 [sessionStore]·[pinStore]·[consentStore],
  /// 시각 [now], 저장하지 않을 세션의 종료 담당 [cleanup]으로 만든다.
  /// 2026-10-22: 인증 계약에서 제거한 설치 식별값을 보관하지 않는다.
  const AuthServices({
    required this.repository,
    required this.sessionStore,
    required this.pinStore,
    required this.consentStore,
    required this.now,
    required this.cleanup,
  });

  final AuthRepository repository;
  final PendingSessionCleanup cleanup;
  final SessionStore sessionStore;
  final LocalPinStore pinStore;
  final ConsentStore consentStore;
  final DateTime Function() now;
}

/// 2026-10-21: 10-2에서 검사를 통과한 합성 식별 입력. 같은 흐름 안에서만 메모리에 두고 성공·취소·이탈 때 버린다.
class IdentityDraft {
  /// 2026-10-21: 정규화한 [name]·[phone]으로 만든다.
  const IdentityDraft({required this.name, required this.phone});

  final String name;
  final String phone;
}

/// 2026-10-21: 본인 확인 흐름의 목적. 첫 가입은 새 세션 발급, 복구는 기존 세션 재확인(새 세션 없음)이다.
enum IdentityPurpose { signup, recovery }
