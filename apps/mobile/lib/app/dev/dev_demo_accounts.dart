import '../../data/auth/fake_auth_repository.dart';

/// 2026-10-21: 개발 빌드 전용 데모 계정. userId·전화번호는 apps/api/fixtures/generated/server-seeds.json과 같다.
/// 이름은 docs/api-contract.md §2 '인증 입력과 단일 이름'의 통합 name이다. 서버 시드는 아직 이행 전 이름이며, 모바일 Fake에서
/// 새 이름을 먼저 쓰는 것은 서버 담당자가 허용했다(2026-10-22). test/app/dev_demo_accounts_test.dart가 대조한다.
/// 코드는 서버 원본이 'DISABLED:auth-design-pending'이라 A 확정 전 임시값이며 계약 값이 아니다. 릴리스 빌드에서는 참조하지 않는다.
const List<FakeDemoAccount> devDemoAccounts = [
  FakeDemoAccount(
    userId: 'f0a4be6c-01d7-53eb-ab2c-74675b22fd8c',
    name: '데모알파',
    phone: '01000000001',
    code: '000001',
  ),
  FakeDemoAccount(
    userId: '87f7bbf9-2355-5210-9325-f25d83a8ff35',
    name: '데모베타',
    phone: '01000000002',
    code: '000002',
  ),
  FakeDemoAccount(
    userId: 'd04073fd-f7ab-518d-8938-f2920d593db2',
    name: '데모감마',
    phone: '01000000003',
    code: '000003',
  ),
];
