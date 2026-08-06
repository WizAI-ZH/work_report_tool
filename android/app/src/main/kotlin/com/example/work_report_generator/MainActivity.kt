package com.example.work_report_generator

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.TextUtils
import androidx.core.content.FileProvider
import java.io.File
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
                    "sendToEnterpriseWechat" -> {
                        val message = call.argument<String>("message") ?: ""
                        val groupName = call.argument<String>("groupName") ?: "文件传输助手"
                        result.success(sendToEnterpriseWechat(message, groupName))
                    }
                    "isAccessibilityEnabled" -> result.success(isAccessibilityEnabled())
                    "openAccessibilitySettings" -> {
                        openAccessibilitySettings()
                        result.success(true)
                    }
                    "getSupportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        result.success(installApk(path))
                    }
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

    /**
     * 一键发送到企业微信。无障碍服务未启用时返回 "no_accessibility"，
     * Flutter 端据此引导用户去系统设置授权。
     */
    private fun sendToEnterpriseWechat(message: String, groupName: String): String {
        if (!isAccessibilityEnabled()) {
            return "no_accessibility"
        }
        // 先把企微拉到前台，无障碍服务才能操作它的控件树。
        if (!openEnterpriseWechat()) {
            return "no_wework"
        }
        Thread.sleep(1500)
        return WeWorkAccessibilityService.startSend(message, groupName)
    }

    private fun isAccessibilityEnabled(): Boolean {
        if (WeWorkAccessibilityService.isEnabled()) return true
        val expectedComponent = ComponentName(this, WeWorkAccessibilityService::class.java)
        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        val colonSplit = TextUtils.SimpleStringSplitter(':').apply { setString(enabledServices) }
        while (colonSplit.hasNext()) {
            val component = colonSplit.next()
            if (component.equals(expectedComponent.flattenToString(), ignoreCase = true)) {
                return true
            }
        }
        return false
    }

    private fun openAccessibilitySettings() {
        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun installApk(path: String?): String {
        if (path.isNullOrBlank()) {
            return "missing_path"
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            return "unknown_sources"
        }

        val apkFile = File(path)
        if (!apkFile.exists()) {
            return "missing_file"
        }

        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apkFile
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(apkUri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(intent)
        return "install_started"
    }
}
