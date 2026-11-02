package com.example.payse

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.Socket
import java.net.URL
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Principal
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.security.spec.RSAKeyGenParameterSpec
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLException
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedKeyManager

/**
 * 2026-11-01: 기기 인증서(mTLS) 통신. Android Keystore에서 내보낼 수 없는 서명 키를 만들고, 그 키와 등록한 인증서 체인으로
 * 클라이언트 인증 TLS 요청을 보낸다. 개인키는 앱도 꺼낼 수 없으며 이 채널은 공개키·인증서만 다룬다.
 * 서버 이름·인증서 체인 검증을 끄지 않는다. 키 알고리즘은 호출부가 [ALGORITHMS] 중 하나를 넘기며, CSR은 서버 발급 절차
 * (2026-11-02 확정: EC P-256, PKCS#10)에 맞춰 EC 키만 만든다.
 */
class DeviceTlsChannel(context: Context) : MethodChannel.MethodCallHandler {
    private val prefs = context.getSharedPreferences("payse_device_tls", Context.MODE_PRIVATE)
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** 2026-11-01: Dart 호출 [call]을 처리한다. 네트워크 요청은 별도 스레드에서 보내고 [result]는 메인 스레드에서 돌려준다. */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val alias = call.argument<String>("alias")
        if (alias == null) {
            result.error("invalid", "alias 없음", null)
            return
        }
        executor.execute {
            val reply: (Any?) -> Unit = { value -> main.post { result.success(value) } }
            val fail: (String, String) -> Unit = { code, message -> main.post { result.error(code, message, null) } }
            try {
                when (call.method) {
                    "ensureKey" -> reply(ensureKey(alias, call.argument<String>("algorithm")))
                    "createCsr" -> reply(createCsr(alias, call.argument<String>("commonName")))
                    "setCertificateChain" -> reply(setCertificateChain(alias, call.argument<String>("chainPem") ?: ""))
                    "send" -> reply(send(alias, call))
                    else -> main.post { result.notImplemented() }
                }
            } catch (error: TlsCallException) {
                fail(error.code, error.message ?: "")
            } catch (error: Exception) {
                fail("invalid", error.javaClass.simpleName)
            }
        }
    }

    /**
     * 2026-11-01: [alias] 키가 없으면 [algorithm]으로 만든다. 공개키(DER, base64)와 새로 만들었는지를 반환한다.
     * 이미 있는 키는 알고리즘을 바꾸지 않는다.
     */
    private fun ensureKey(alias: String, algorithm: String?): Map<String, Any> {
        val store = keyStore()
        var created = false
        if (!store.containsAlias(alias)) {
            val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_NONE)
            val generator = when (algorithm) {
                "EC_P256" -> {
                    spec.setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
                }
                "RSA_2048" -> {
                    spec.setAlgorithmParameterSpec(RSAKeyGenParameterSpec(2048, RSAKeyGenParameterSpec.F4))
                        .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1, KeyProperties.SIGNATURE_PADDING_RSA_PSS)
                    KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, KEYSTORE)
                }
                else -> throw TlsCallException("invalid", "지원하지 않는 키 알고리즘")
            }
            generator.initialize(spec.build())
            generator.generateKeyPair()
            created = true
        }
        val publicKey = store.getCertificate(alias).publicKey
        val info = KeyFactory.getInstance(publicKey.algorithm, KEYSTORE)
            .getKeySpec(store.getKey(alias, null) as PrivateKey, KeyInfo::class.java)
        return mapOf(
            "created" to created,
            "algorithm" to publicKey.algorithm,
            "publicKeyDer" to Base64.encodeToString(publicKey.encoded, Base64.NO_WRAP),
            "securityLevel" to securityLevel(info),
        )
    }

    /** 2026-11-02: 키 보관 위치를 반환한다(Android 12+ 보안 수준, 그 전은 보안 하드웨어 여부). */
    @Suppress("DEPRECATION")
    private fun securityLevel(info: KeyInfo): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongbox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "tee"
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> "software"
                else -> "unknown"
            }
        } else if (info.isInsideSecureHardware) "secure_hardware" else "software"

    /**
     * 2026-11-02: [alias]의 EC 키로 서명한 PKCS#10 CSR을 만든다. 주체는 [commonName] 하나(인쇄 가능한 ASCII)이며 확장 속성은 없다.
     * PEM과 DER의 SHA-256(소문자 16진수)을 반환한다. 개인키는 Keystore 안에서 서명에만 쓰인다.
     */
    private fun createCsr(alias: String, commonName: String?): Map<String, String> {
        if (commonName == null || commonName.isEmpty() || commonName.length > 64 || !commonName.all { it in ' '..'~' }) {
            throw TlsCallException("invalid", "주체는 1~64자 인쇄 가능한 ASCII")
        }
        val store = keyStore()
        val publicKey = store.getCertificate(alias)?.publicKey ?: throw TlsCallException("noKey", "키 없음")
        if (publicKey.algorithm != KeyProperties.KEY_ALGORITHM_EC) throw TlsCallException("invalid", "EC 키가 아님")
        val subject = der(0x30, der(0x31, der(0x30, OID_COMMON_NAME + der(0x0c, commonName.toByteArray(Charsets.UTF_8)))))
        val info = der(0x30, byteArrayOf(0x02, 0x01, 0x00) + subject + publicKey.encoded + byteArrayOf(0xa0.toByte(), 0x00))
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(store.getKey(alias, null) as PrivateKey)
        signer.update(info)
        val signature = signer.sign()
        val csr = der(0x30, info + der(0x30, OID_ECDSA_SHA256) + der(0x03, byteArrayOf(0x00) + signature))
        val body = Base64.encodeToString(csr, Base64.NO_WRAP).chunked(64).joinToString("\n")
        return mapOf(
            "pem" to "-----BEGIN CERTIFICATE REQUEST-----\n$body\n-----END CERTIFICATE REQUEST-----\n",
            "derSha256" to sha256(csr),
        )
    }

    /** 2026-11-02: DER 태그 [tag]와 내용 [content]로 TLV를 만든다. */
    private fun der(tag: Int, content: ByteArray): ByteArray {
        val length = content.size
        val header = when {
            length < 0x80 -> byteArrayOf(length.toByte())
            length < 0x100 -> byteArrayOf(0x81.toByte(), length.toByte())
            else -> byteArrayOf(0x82.toByte(), (length shr 8).toByte(), length.toByte())
        }
        return byteArrayOf(tag.toByte()) + header + content
    }

    /** 2026-11-02: [bytes]의 SHA-256을 소문자 16진수로 반환한다. */
    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /**
     * 2026-11-01: 발급받은 인증서 체인 [chainPem](클라이언트 인증서 다음 체인 순서)을 [alias] 키에 연결한다. 첫 인증서의 공개키가
     * Keystore 키와 다르면 거절한다.
     * 2026-11-02: 클라이언트 인증서 DER의 SHA-256·주체·발급자·유효기간을 반환한다(CSR 지문과 다른 값).
     */
    private fun setCertificateChain(alias: String, chainPem: String): Map<String, Any> {
        val chain = parseCertificates(chainPem)
        val key = keyStore().getCertificate(alias)?.publicKey
            ?: throw TlsCallException("noKey", "키 없음")
        if (chain.isEmpty() || !chain[0].publicKey.encoded.contentEquals(key.encoded)) {
            throw TlsCallException("invalid", "인증서가 기기 키와 맞지 않음")
        }
        if (!prefs.edit().putString("chain.$alias", chainPem).commit()) {
            throw TlsCallException("storage", "인증서 저장 실패")
        }
        val leaf = chain[0]
        return mapOf(
            "certificateSha256" to sha256(leaf.encoded),
            "subject" to leaf.subjectX500Principal.name,
            "issuer" to leaf.issuerX500Principal.name,
            "notBefore" to leaf.notBefore.time,
            "notAfter" to leaf.notAfter.time,
            "chainLength" to chain.size,
        )
    }

    /**
     * 2026-11-01: 요청 하나를 보낸다. 받은 응답은 상태와 무관하게 {status, headers, body}로 반환하고, 응답을 받지 못하면
     * tls(협상 실패)·notSent(연결 전 실패)·unknown(보낸 뒤 실패) 오류다. trustedCaPem이 있으면 그 CA로 서버를 검증한다.
     */
    private fun send(alias: String, call: MethodCall): Map<String, Any?> {
        val privateKey = keyStore().getKey(alias, null) as PrivateKey?
            ?: throw TlsCallException("noKey", "키 없음")
        val chain = prefs.getString("chain.$alias", null)?.let(::parseCertificates)
            ?: throw TlsCallException("noCertificate", "등록한 인증서 없음")
        val timeout = call.argument<Int>("timeoutMs") ?: throw TlsCallException("invalid", "timeoutMs 없음")
        val context = SSLContext.getInstance("TLS")
        context.init(arrayOf(KeystoreKeyManager(alias, privateKey, chain.toTypedArray())), trustManagers(call.argument("trustedCaPem")), null)
        val connection = URL(call.argument<String>("url")).openConnection() as HttpsURLConnection
        connection.sslSocketFactory = context.socketFactory
        connection.instanceFollowRedirects = false
        connection.connectTimeout = timeout
        connection.readTimeout = timeout
        connection.requestMethod = call.argument<String>("method")
        call.argument<Map<String, String>>("headers")?.forEach(connection::setRequestProperty)
        val body = call.argument<String>("body")
        try {
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("content-type", "application/json; charset=utf-8")
            }
            connection.connect()
        } catch (error: SSLException) {
            throw TlsCallException("tls", error.javaClass.simpleName)
        } catch (error: IOException) {
            throw TlsCallException("notSent", error.javaClass.simpleName)
        }
        try {
            if (body != null) connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val text = stream?.use { String(it.readBytes(), Charsets.UTF_8) } ?: ""
            val headers = connection.headerFields
                .filterKeys { it != null }
                .map { (name, values) -> name.lowercase() to values.joinToString(",") }
                .toMap()
            return mapOf("status" to status, "headers" to headers, "body" to text)
        } catch (error: SSLException) {
            throw TlsCallException("tls", error.javaClass.simpleName)
        } catch (error: IOException) {
            throw TlsCallException("unknown", error.javaClass.simpleName)
        } finally {
            connection.disconnect()
        }
    }

    /** 2026-11-01: 서버 검증용 신뢰 저장소. [caPem]이 없으면 기기 기본 신뢰 저장소, 있으면 그 CA만 신뢰한다. */
    private fun trustManagers(caPem: String?): Array<javax.net.ssl.TrustManager> {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        if (caPem == null) {
            factory.init(null as KeyStore?)
        } else {
            val store = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null) }
            parseCertificates(caPem).forEachIndexed { i, cert -> store.setCertificateEntry("ca$i", cert) }
            factory.init(store)
        }
        return factory.trustManagers
    }

    /** 2026-11-01: PEM 문자열 [pem]의 인증서들을 순서대로 읽는다. */
    private fun parseCertificates(pem: String): List<X509Certificate> =
        CertificateFactory.getInstance("X.509")
            .generateCertificates(ByteArrayInputStream(pem.toByteArray(Charsets.US_ASCII)))
            .map { it as X509Certificate }

    /** 2026-11-01: Android Keystore를 연다. */
    private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    /** 2026-11-01: 채널 오류 코드 [code]와 원인 형식 [message]를 담는다. */
    private class TlsCallException(val code: String, message: String) : Exception(message)

    /** 2026-11-01: 클라이언트 인증 요청에 [alias] 하나의 Keystore 키 [key]와 인증서 [chain]만 내는 키 관리자. */
    private class KeystoreKeyManager(
        private val alias: String,
        private val key: PrivateKey,
        private val chain: Array<X509Certificate>,
    ) : X509ExtendedKeyManager() {
        override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = alias
        override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = alias
        override fun getCertificateChain(alias: String?) = if (alias == this.alias) chain else null
        override fun getPrivateKey(alias: String?) = if (alias == this.alias) key else null
        override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(alias)
        override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = null
        override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?) = null
    }

    companion object {
        const val CHANNEL = "payse/device_tls"
        private const val KEYSTORE = "AndroidKeyStore"
        val ALGORITHMS = listOf("EC_P256", "RSA_2048")
        private val OID_COMMON_NAME = byteArrayOf(0x06, 0x03, 0x55, 0x04, 0x03)
        private val OID_ECDSA_SHA256 = byteArrayOf(0x06, 0x08, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x04, 0x03, 0x02)
    }
}
