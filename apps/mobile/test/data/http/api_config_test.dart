import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/http/api_config.dart';

void main() {
  test('no address means no real-server mode', () {
    expect(ApiConfig.parse(baseUrl: '', timeoutSeconds: ''), isNull);
  });

  test('https address keeps the deploy prefix without a trailing slash', () {
    final config = ApiConfig.parse(
      baseUrl: 'https://payse.test/api/',
      timeoutSeconds: '15',
    )!;
    expect(config.timeout, const Duration(seconds: 15));
    expect(
      config.resolve('/transactions', {'cursor': 'a+b/c'}).toString(),
      'https://payse.test/api/transactions?cursor=a%2Bb%2Fc',
    );
  });

  test('a bad address or timeout fails instead of falling back to fake', () {
    for (final (url, seconds) in [
      ('http://payse.test', '10'),
      ('https://', '10'),
      ('https://payse.test?x=1', '10'),
      ('https://user@payse.test', '10'),
      ('https://payse.test', ''),
      ('https://payse.test', '0'),
      ('https://payse.test', '601'),
    ]) {
      expect(
        () => ApiConfig.parse(baseUrl: url, timeoutSeconds: seconds),
        throwsA(isA<ApiConfigException>()),
        reason: '$url / $seconds',
      );
    }
  });
}
