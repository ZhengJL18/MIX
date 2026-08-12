/// 「所有文件访问」权限处理（Android 11+ MANAGE_EXTERNAL_STORAGE）。
///
/// 关键：Android 11+ 的「所有文件访问」开关**不在通用应用设置页**，必须在
/// `ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION` 专用设置页才能看到。
/// 之前用 `openAppSettings()` 打开的是应用信息页，用户找不到开关 —— 这就是
/// 无法授权的根因。现改走原生通道（MainActivity.kt）发专用 intent，并由
/// 原生 `Environment.isExternalStorageManager()` 检测权限（鸿蒙上比
/// permission_handler 可靠）。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../tools/file_tools.dart';

/// MainActivity 原生通道（见 MainActivity.kt）。
const MethodChannel _storageChannel =
    MethodChannel('com.mix.app/storage');

/// 是否已授予「所有文件访问」。
///
/// 优先走原生 `Environment.isExternalStorageManager()`（鸿蒙上比
/// permission_handler 可靠）；原生通道不可用（非 Android / 异常）时
/// fallback 到 permission_handler。
Future<bool> isExternalStorageGranted() async {
  // 桌面端（Linux/Windows/macOS）无沙箱：文件系统直接可访问，无需权限。
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    return true;
  }
  try {
    final granted = await _storageChannel.invokeMethod<bool>(
      'isExternalStorageManager',
    );
    if (granted != null) return granted;
  } catch (_) {
    // 原生通道不可用 → fallback。
  }
  try {
    final status = await Permission.manageExternalStorage.status;
    return status.isGranted;
  } catch (_) {
    // 鸿蒙上 permission_handler 也可能不可用 → 按未授权处理。
    return false;
  }
}

/// 打开「所有文件访问」专用设置页。
///
/// 走原生 `ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`（带包名 data
/// URI），这是唯一能看到该开关的页面；鸿蒙部分版本不支持该 action 时
/// MainActivity 会 fallback 到通用应用设置页。
Future<void> openManageExternalStorageSettings() async {
  try {
    await _storageChannel.invokeMethod<void>('openExternalStorageSettings');
    return;
  } catch (_) {
    // 原生通道不可用（非 Android / 鸿蒙不支持）→ fallback 到通用应用设置页。
  }
  try {
    await openAppSettings();
  } catch (_) {
    // 连通用设置页都打不开 → 忽略（用户手动去系统设置也行）。
  }
}

/// 根据权限状态刷新 file_tools 的外部访问开关。
/// 应在 App 启动（_initCwd 之后）和设置页授予后调用。
///
/// [fallbackCwd]：权限检测失败时兜底使用的 cwd（App documents），
/// 防止 _currentCwd 为空导致 file_tools 无 cwd（search_files 会从 `/` 遍历卡死）。
Future<void> syncExternalAccessPermission({String? fallbackCwd}) async {
  var granted = false;
  try {
    granted = await isExternalStorageGranted();
  } catch (_) {
    // 权限检测失败 → 按未授权处理（allowExternal = false），仍配置 cwd。
  }
  // 保持 cwd（documents 目录）不变，仅切换外部访问开关。
  configureFileTools(
    cwd: _currentCwd ?? fallbackCwd,
    allowExternal: granted,
  );
}

// 记住当前 cwd（避免重复调用时丢配置）。
String? _currentCwd;
void rememberFileToolsCwd(String? cwd) {
  _currentCwd = cwd;
}

/// 读取当前 file_tools cwd（无则 null）。
String? currentFileToolsCwd() => _currentCwd;
