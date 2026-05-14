package com.example.work_report_generator

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "work_report_generator/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openEnterpriseWechat" -> result.success(openEnterpriseWechat())
                    else -> result.notImplemented()
                }
            }
    }

    private fun openEnterpriseWechat(): Boolean {
        val packageNames = listOf("com.tencent.wework", "com.tencent.weworklocal")
        for (packageName in packageNames) {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            }
        }
        return false
    }
}
