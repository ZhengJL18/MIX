package com.mix.app

import android.Manifest
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.mix.app/storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // 原生检测「所有文件访问」权限 —— 比 permission_handler 在鸿蒙上可靠。
                "isExternalStorageManager" -> {
                    val granted = isExternalStorageManagerGranted()
                    result.success(granted)
                }
                // 打开「所有文件访问」专用设置页。
                "openExternalStorageSettings" -> {
                    openExternalStorageSettings()
                    result.success(null)
                }
                // MediaScanner 扫描单个文件，让系统相册识别（图片保存用）。
                "scanMedia" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("400", "Missing path", null)
                    } else {
                        MediaScannerConnection.scanFile(
                            applicationContext, arrayOf(path), null, null
                        )
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isExternalStorageManagerGranted(): Boolean {
        // 用 appops 反映的运行时状态（鸿蒙上 MANAGE_EXTERNAL_STORAGE 的 permission
        // 声明 granted=false，但 appops 是 allow，App 实际能访问 /sdcard）。
        // Environment.isExternalStorageManager() 查的是运行时 appops，与鸿蒙实际
        // 行为一致。不能用 checkSelfPermission —— 它在鸿蒙上恒 false。
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                Environment.isExternalStorageManager()
            } catch (e: Exception) {
                checkSelfPermission(Manifest.permission.MANAGE_EXTERNAL_STORAGE) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
            }
        } else {
            checkSelfPermission(Manifest.permission.MANAGE_EXTERNAL_STORAGE) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    private fun openExternalStorageSettings() {
        // 专用页：ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION（Android 11+）。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName")
                )
                startActivity(intent)
                return
            } catch (e: Exception) {
                // 该 action 不可用（部分鸿蒙版本）→ fallback 通用应用设置页。
            }
        }
        // 通用应用设置页（Android 10 及以下 / 鸿蒙 fallback）。
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        } catch (e: Exception) {
            // 最后兜底：跳到系统设置首页。
            startActivity(Intent(Settings.ACTION_SETTINGS))
        }
    }
}
