package com.example.payse

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 2026-11-01: PAYSE Android 진입점. 기기 인증서(mTLS) 통신 채널을 등록한다. */
class MainActivity : FlutterActivity() {
    /** 2026-11-01: [flutterEngine]에 채널을 연결한다. */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DeviceTlsChannel.CHANNEL)
            .setMethodCallHandler(DeviceTlsChannel(this))
    }
}
