import '../../data/auth/fake_auth_repository.dart';

/// 2026-10-21: 개발 빌드 전용 데모 계정. 이름·전화번호·userId는 apps/api/fixtures/generated/server-seeds.json과 같다
/// (test/app/dev_demo_accounts_test.dart가 대조). 코드는 서버 원본이 'DISABLED:auth-design-pending'이라
/// A 확정 전 임시값이며 계약 값이 아니다. 릴리스 빌드에서는 참조하지 않는다.
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
