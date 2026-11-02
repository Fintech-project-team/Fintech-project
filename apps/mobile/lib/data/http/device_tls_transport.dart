import 'dart:convert';

import 'package:flutter/services.dart';

import 'api_transport.dart';

/// 2026-11-01: Android 기기 인증서(mTLS) 통신(DeviceTlsChannel.kt). Keystore의 내보낼 수 없는 키 [alias]와 등록한 인증서 체인으로
/// 클라이언트 인증을 하며, 개인키는 Dart로 오지 않는다. 서버 이름·인증서 검증은 끄지 않는다. [trustedCaPem]이 있으면 그 CA로만
/// 서버를 검증한다(실제 서버의 인증서 체인 방식은 서버 담당 확인 전이라 정하지 않음).
class DeviceTlsTransport implements ApiTransport {
  /// 2026-11-01: 키 별칭 [alias], 요청 제한 시간 [timeout], 서버 CA [trustedCaPem](없으면 기기 기본 신뢰 저장소)으로 만든다.
  const DeviceTlsTransport({
    required this.alias,
    required this.timeout,
    this.trustedCaPem,
  });

  final String alias;
  final Duration timeout;
  final String? trustedCaPem;

  static const MethodChannel channel = MethodChannel('payse/device_tls');

  /// 2026-11-01: 요청을 네이티브로 보낸다. 응답을 받지 못하면 채널 오류 코드에 맞춰 [ApiTransportException]을 던진다.
  @override
  Future<ApiResponse> send(ApiRequest request) async {
    final Map<Object?, Object?>? reply;
    try {
      reply = await channel.invokeMethod<Map<Object?, Object?>>('send', {
        'alias': alias,
        'method': request.method,
        'url': request.uri.toString(),
        'headers': request.headers,
        'body': request.body == null ? null : jsonEncode(request.body),
        'timeoutMs': timeout.inMilliseconds,
        'trustedCaPem': trustedCaPem,
      });
    } on PlatformException catch (error) {
      throw ApiTransportException(switch (error.code) {
        'tls' || 'noKey' || 'noCertificate' => ApiFailureKind.tls,
        'unknown' => ApiFailureKind.unknown,
        _ => ApiFailureKind.notSent,
      }, error);
    }
    final status = reply?['status'];
    final headers = reply?['headers'];
    final body = reply?['body'];
    if (status is! int || headers is! Map || body is! String) {
      throw ApiTransportException(ApiFailureKind.unknown, 'reply format');
    }
    return ApiResponse(
      status: status,
      headers: {
        for (final e in headers.entries) '${e.key}'.toLowerCase(): '${e.value}',
      },
      body: body,
    );
  }
}

/// 2026-11-02: 서버 모드의 기기 인증서 키 별칭. CSR을 만든 뒤에는 바꾸지 않는다(바꾸면 새 CSR·재등록이 필요).
const String deviceTlsAlias = 'payse.device_tls';

/// 2026-11-01: 기기 인증서 키 관리. 개인키는 Keystore 밖으로 나오지 않으며 공개키·CSR·인증서만 다룬다.
/// 2026-11-02: 서버 발급 절차(EC P-256, PKCS#10)에 맞춘 CSR 생성과 인증서 연결 결과 확인을 더한다.
class DeviceTlsKeys {
  /// 2026-11-01: 키 별칭 [alias]로 만든다.
  const DeviceTlsKeys(this.alias);

  final String alias;

  /// 2026-11-01: 키가 없으면 [algorithm]('EC_P256'·'RSA_2048')으로 만든다. 있던 키는 바꾸지 않는다.
  /// 2026-11-02: 새로 만들었는지(created)·알고리즘·공개키 DER(base64)·보관 위치(securityLevel)를 반환한다.
  Future<Map<String, Object?>> ensureKey(String algorithm) async {
    final reply = await DeviceTlsTransport.channel
        .invokeMethod<Map<Object?, Object?>>('ensureKey', {
          'alias': alias,
          'algorithm': algorithm,
        });
    return reply!.cast<String, Object?>();
  }

  /// 2026-11-02: 기존 EC 키로 서명한 PKCS#10 CSR을 만든다. 주체는 비식별 [commonName] 하나다.
  /// PEM 문자열과 CSR DER의 SHA-256(소문자 16진수)을 반환한다. 키가 없으면 [PlatformException]이다(키를 새로 만들지 않음).
  Future<({String pem, String derSha256})> createCsr(String commonName) async {
    final reply = await DeviceTlsTransport.channel
        .invokeMethod<Map<Object?, Object?>>('createCsr', {
          'alias': alias,
          'commonName': commonName,
        });
    return (
      pem: reply!['pem']! as String,
      derSha256: reply['derSha256']! as String,
    );
  }

  /// 2026-11-01: 발급받은 인증서 체인 [chainPem](클라이언트 인증서 다음 체인)을 키에 연결한다. 첫 인증서 공개키가 기기 키와 다르면
  /// [PlatformException]이다.
  /// 2026-11-02: 클라이언트 인증서 DER의 SHA-256·주체·발급자·유효기간(밀리초)·체인 길이를 반환한다.
  Future<Map<String, Object?>> setCertificateChain(String chainPem) async {
    final reply = await DeviceTlsTransport.channel
        .invokeMethod<Map<Object?, Object?>>('setCertificateChain', {
          'alias': alias,
          'chainPem': chainPem,
        });
    return reply!.cast<String, Object?>();
  }
}
