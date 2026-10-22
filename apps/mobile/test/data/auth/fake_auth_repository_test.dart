import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';

/// 2026-10-21: 테스트 전용 계정과 시각으로 가짜 저장소를 만든다. 코드는 테스트 값이며 서버 값이 아니다.
({FakeAuthRepository repo, void Function(Duration) advance}) build() {
  var now = DateTime(2026, 10, 21, 9);
  final repo = FakeAuthRepository(
    accounts: const [
      FakeDemoAccount(
        userId: 'u1',
        name: '김합성',
        phone: '01011112222',
        code: '246810',
      ),
      FakeDemoAccount(
        userId: 'u2',
        name: '이합성',
        phone: '01033334444',
        code: '135791',
      ),
    ],
    now: () => now,
  );
  return (repo: repo, advance: (d) => now = now.add(d));
}

const good = DemoCredentials(name: '김합성', phone: '01011112222', code: '246810');
const other = DemoCredentials(
  name: '이합성',
  phone: '01033334444',
  code: '135791',
);

/// 2026-10-21: [i]번째 틀린 코드(형식은 맞음)를 만든다.
DemoCredentials wrong(int i) =>
    DemoCredentials(name: '김합성', phone: '01011112222', code: '00000$i');

void main() {
  test('matching credentials issue one session', () async {
    final (:repo, advance: _) = build();
    final result = await repo.createSession(good);

    expect(result, isA<AuthOk<DemoSession>>());
    final session = (result as AuthOk<DemoSession>).value;
    expect(session.userId, 'u1');
    expect(session.accessToken, hasLength(64));
  });

  test(
    'allowed separators normalize before matching and reverification',
    () async {
      final (:repo, advance: _) = build();
      const formatted = DemoCredentials(
        name: '  김합성 ',
        phone: ' 010-1111 2222 ',
        code: '246810',
      );
      final session =
          ((await repo.createSession(formatted)) as AuthOk<DemoSession>).value;
      final reverified = await repo.reverify(session.accessToken, formatted);
      expect(reverified, isA<AuthOk<ReverifiedSession>>());
      expect(
        (reverified as AuthOk<ReverifiedSession>).value.sessionId,
        session.sessionId,
      );
      expect(await repo.createSession(good), isA<AuthRejected<DemoSession>>());
      expect(
        await repo.reverify(session.accessToken, good),
        isA<AuthOk<ReverifiedSession>>(),
        reason: '새 로그인 거절 뒤에도 기존 세션 유지',
      );
    },
  );

  test(
    'well-formed mismatches are 401 and English names remain case sensitive',
    () async {
      final repo = FakeAuthRepository(
        accounts: const [
          FakeDemoAccount(
            userId: 'english',
            name: 'Kim',
            phone: '01011112222',
            code: '246810',
          ),
        ],
      );
      expect(
        await repo.createSession(
          const DemoCredentials(
            name: 'kim',
            phone: '01011112222',
            code: '246810',
          ),
        ),
        isA<AuthRejected<DemoSession>>(),
      );
      expect(
        await repo.createSession(
          const DemoCredentials(
            name: 'Kim',
            phone: '01011112222',
            code: '246810',
          ),
        ),
        isA<AuthOk<DemoSession>>(),
      );
    },
  );

  test('mismatch and an already active account look the same', () async {
    final (:repo, advance: _) = build();
    expect(
      await repo.createSession(wrong(0)),
      isA<AuthRejected<DemoSession>>(),
    );

    await repo.createSession(good);
    expect(
      await repo.createSession(good),
      isA<AuthRejected<DemoSession>>(),
      reason: '이미 활성 세션이 있으면 같은 401',
    );
  });

  test(
    'create: the 5th failure itself is 429 for 5 minutes and is not extended',
    () async {
      final (:repo, :advance) = build();
      for (var i = 0; i < 4; i++) {
        expect(
          await repo.createSession(wrong(i)),
          isA<AuthRejected<DemoSession>>(),
        );
      }
      final fifth = await repo.createSession(wrong(4));
      expect(fifth, isA<AuthRateLimited<DemoSession>>(), reason: '5번째부터 429');
      expect((fifth as AuthRateLimited).retryAfter, const Duration(minutes: 5));

      final blocked = await repo.createSession(good);
      expect(
        blocked,
        isA<AuthRateLimited<DemoSession>>(),
        reason: '차단 중엔 맞는 코드도 429',
      );

      advance(const Duration(minutes: 3));
      final later = await repo.createSession(wrong(5));
      expect(
        (later as AuthRateLimited).retryAfter,
        const Duration(minutes: 2),
        reason: '차단 중 시도는 종료 시각을 늘리지 않음',
      );

      advance(const Duration(minutes: 2));
      expect(await repo.createSession(good), isA<AuthOk<DemoSession>>());
    },
  );

  test('reverify: the 5th failure is 429 as well', () async {
    final (:repo, advance: _) = build();
    final token = ((await repo.createSession(
      good,
    )) as AuthOk<DemoSession>).value.accessToken;
    for (var i = 0; i < 4; i++) {
      expect(
        await repo.reverify(token, wrong(i)),
        isA<AuthRejected<ReverifiedSession>>(),
      );
    }
    final fifth = await repo.reverify(token, wrong(4));
    expect(fifth, isA<AuthRateLimited<ReverifiedSession>>());
    expect((fifth as AuthRateLimited).retryAfter, const Duration(minutes: 5));
  });

  test('changing the code does not bypass the name+phone limit', () async {
    final (:repo, advance: _) = build();
    for (var i = 0; i < 5; i++) {
      await repo.createSession(wrong(i));
    }
    expect(await repo.createSession(good), isA<AuthRateLimited<DemoSession>>());
    expect(
      await repo.createSession(other),
      isA<AuthOk<DemoSession>>(),
      reason: '다른 조합은 영향 없음',
    );
  });

  test(
    'allowed separators do not bypass the normalized failure limit',
    () async {
      final (:repo, :advance) = build();
      for (var i = 0; i < 5; i++) {
        final result = await repo.createSession(
          DemoCredentials(
            name: i.isEven ? ' 김합성 ' : '김합성',
            phone: i.isEven ? '010-1111-2222' : '010 1111 2222',
            code: '00000$i',
          ),
        );
        if (i < 4) {
          expect(result, isA<AuthRejected<DemoSession>>());
        } else {
          expect(result, isA<AuthRateLimited<DemoSession>>());
        }
      }
      expect(
        await repo.createSession(good),
        isA<AuthRateLimited<DemoSession>>(),
      );
      advance(const Duration(minutes: 5));
      expect(await repo.createSession(good), isA<AuthOk<DemoSession>>());
    },
  );

  test('format errors are 422 and do not count toward the limit', () async {
    final (:repo, advance: _) = build();
    for (final bad in [
      const DemoCredentials(name: '김합성', phone: '01011112222', code: '24681'),
      const DemoCredentials(name: '김합성', phone: '01011112222', code: '24681a'),
      const DemoCredentials(name: '김합성', phone: '0101111222', code: '246810'),
      const DemoCredentials(name: '김 합성', phone: '01011112222', code: '246810'),
      const DemoCredentials(
        name: '김  합성',
        phone: '01011112222',
        code: '246810',
      ),
      const DemoCredentials(
        name: '\t김합성',
        phone: '01011112222',
        code: '246810',
      ),
      const DemoCredentials(
        name: '\u00a0김합성',
        phone: '01011112222',
        code: '246810',
      ),
      const DemoCredentials(
        name: '김합성\u3000',
        phone: '01011112222',
        code: '246810',
      ),
      const DemoCredentials(
        name: '김합성\n',
        phone: '01011112222',
        code: '246810',
      ),
      const DemoCredentials(
        name: '김합성',
        phone: '\t01011112222',
        code: '246810',
      ),
      const DemoCredentials(
        name: '김합성',
        phone: '01011112222\n',
        code: '246810',
      ),
      const DemoCredentials(
        name: '김합성',
        phone: '0101111\u00a02222',
        code: '246810',
      ),
      const DemoCredentials(name: '김합성', phone: '０１０１１１１２２２２', code: '246810'),
      const DemoCredentials(name: '김합성', phone: '01011112222', code: '２４６８１０'),
      const DemoCredentials(
        name: '김합성',
        phone: '01011112222',
        code: '246810\n',
      ),
      const DemoCredentials(name: 'ㄱㄴ', phone: '01011112222', code: '246810'),
      const DemoCredentials(
        name: '12345',
        phone: '01011112222',
        code: '246810',
      ),
      const DemoCredentials(name: '김', phone: '01011112222', code: '246810'),
    ]) {
      for (var i = 0; i < 3; i++) {
        expect(
          await repo.createSession(bad),
          isA<AuthInvalidInput<DemoSession>>(),
          reason: '${bad.name}/${bad.phone}/${bad.code}',
        );
      }
    }
    expect(
      await repo.createSession(good),
      isA<AuthOk<DemoSession>>(),
      reason: '형식 오류 반복 뒤에도 차단되지 않음',
    );
  });

  test('reverify shares 422 validation without consuming failures or ending the session', () async {
    final (:repo, advance: _) = build();
    final session =
        ((await repo.createSession(good)) as AuthOk<DemoSession>).value;
    const bad = DemoCredentials(
      name: '김 합성',
      phone: '01011112222',
      code: '246810',
    );
    for (var i = 0; i < 6; i++) {
      expect(
        await repo.reverify(session.accessToken, bad),
        isA<AuthInvalidInput<ReverifiedSession>>(),
      );
    }
    expect(
      await repo.reverify(session.accessToken, good),
      isA<AuthOk<ReverifiedSession>>(),
    );
    expect(
      await repo.reverify('unknown-token', bad),
      isA<AuthSessionInvalid<ReverifiedSession>>(),
      reason: '토큰 검사 순서를 입력 형식 검사보다 먼저 유지',
    );
  });

  test(
    'reverify keeps the same session; invalid token is SESSION_INVALID',
    () async {
      final (:repo, advance: _) = build();
      final session =
          ((await repo.createSession(good)) as AuthOk<DemoSession>).value;

      final ok = await repo.reverify(session.accessToken, good);
      expect(ok, isA<AuthOk<ReverifiedSession>>());
      expect(
        (ok as AuthOk<ReverifiedSession>).value.sessionId,
        session.sessionId,
      );

      expect(
        await repo.reverify(session.accessToken, other),
        isA<AuthRejected<ReverifiedSession>>(),
        reason: '다른 사용자 자격은 자격 거절',
      );
      expect(
        await repo.reverify('unknown-token', good),
        isA<AuthSessionInvalid<ReverifiedSession>>(),
      );

      repo.terminateSessionOf('u1');
      expect(
        await repo.reverify(session.accessToken, good),
        isA<AuthSessionInvalid<ReverifiedSession>>(),
        reason: '운영 종료된 토큰은 맞는 자격이어도 무효 세션',
      );
    },
  );

  test(
    'ending a session frees the account; ending again is SESSION_INVALID',
    () async {
      final (:repo, advance: _) = build();
      final session =
          ((await repo.createSession(good)) as AuthOk<DemoSession>).value;

      expect(await repo.endSession(session.accessToken), isA<AuthOk<void>>());
      expect(
        await repo.endSession(session.accessToken),
        isA<AuthSessionInvalid<void>>(),
      );
      expect(await repo.createSession(good), isA<AuthOk<DemoSession>>());
    },
  );

  test('unavailable repository never reports success', () async {
    const repo = UnavailableAuthRepository();
    expect(await repo.createSession(good), isA<AuthUnavailable<DemoSession>>());
    expect(
      await repo.reverify('t', good),
      isA<AuthUnavailable<ReverifiedSession>>(),
    );
    expect(await repo.endSession('t'), isA<AuthUnavailable<void>>());
  });
}
