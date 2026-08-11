import 'dart:async';
import 'dart:convert';

import 'package:app_installer_plus/app_installer_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// 更新信息。
class UpdateInfo {
  /// 远端版本号（如 1.0.0+12）。
  final String version;

  /// 远端 versionCode（从版本号 `+N` 解析）。
  final int buildNumber;

  /// APK 下载直链。
  final String downloadUrl;

  /// 更新说明（release body）。
  final String? notes;

  const UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    this.notes,
  });
}

/// 自动更新服务。
///
/// 版本源：GitHub Releases（CI 每次 push 发 release，tag = v1.0.0+<run_number>）。
/// App 启动时 checkForUpdate()，有新版返回 UpdateInfo，无/失败返回 null（静默）。
class UpdateService {
  static const String _repo = 'ZhengJL18/MIX';
  static const Duration _timeout = Duration(seconds: 15);

  /// 查最新 release，与本地版本比较。有新版返回 UpdateInfo，否则 null。
  /// 网络/解析失败返回 null（启动静默，不打扰用户）。
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      return await _fetchLatest();
    } catch (e) {
      debugPrint('[Update] 检查失败: $e');
      return null;
    }
  }

  /// 手动检查：有新版返回 UpdateInfo，无新版返回 null，检查失败抛异常。
  /// 调用者据此区分三种状态（区别于启动静默的 [checkForUpdate]）。
  static Future<UpdateInfo?> checkForUpdateDetailed() async {
    return _fetchLatest();
  }

  static Future<UpdateInfo?> _fetchLatest() async {
      final resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'MIX-app',
            },
          )
          .timeout(_timeout);
      debugPrint('[Update] HTTP ${resp.statusCode}');

      if (resp.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;

      final tagName = data['tag_name'] as String? ?? '';
      final assets = data['assets'] as List<dynamic>? ?? [];
      debugPrint('[Update] tag=$tagName assets=${assets.length}');
      if (tagName.isEmpty || assets.isEmpty) return null;

      // APK 下载直链（release 上传的 app-release.apk）
      String? downloadUrl;
      for (final a in assets) {
        final name = a['name'] as String? ?? '';
        if (name.endsWith('.apk')) {
          downloadUrl = a['browser_download_url'] as String?;
          break;
        }
      }
      debugPrint('[Update] url=$downloadUrl');
      if (downloadUrl == null) return null;

      // 本地版本
      final local = await PackageInfo.fromPlatform();
      final localBuild = int.tryParse(local.buildNumber) ?? 0;
      debugPrint('[Update] local build=$localBuild');

      // 远端 buildNumber 从 tag 末尾 +N 解析（如 v1.0.0+12 → 12）
      final plusIdx = tagName.lastIndexOf('+');
      final remoteBuild =
          plusIdx >= 0 ? int.tryParse(tagName.substring(plusIdx + 1)) ?? 0 : 0;
      debugPrint('[Update] remote build=$remoteBuild');

      if (remoteBuild <= localBuild) {
        debugPrint('[Update] 无新版，跳过');
        return null;
      }

      return UpdateInfo(
        version: tagName.replaceFirst('v', ''),
        buildNumber: remoteBuild,
        downloadUrl: downloadUrl,
        notes: data['body'] as String?,
      );
  }

  /// 下载并安装新版 APK（app_installer_plus 自带 FileProvider + 授权引导）。
  /// [onProgress] 0~1 下载进度。
  /// 返回 true 表示已触发安装，false 表示失败。
  static Future<bool> downloadAndInstall(
    String downloadUrl, {
    void Function(double progress)? onProgress,
  }) async {
    // 固定唯一文件名 + 每次下载前清理同名残留。否则「缓存」的旧/半成品
    // APK 会一直占着路径，安装器可能读到坏文件 —— 表现为"一直装不上"。
    const fileName = 'MIX-update';
    try {
      // 1) 取消可能仍挂在后台的下载。超时/中断后 app_installer_plus 的
      //    _isDownloading 会卡在 true，之后所有下载都被拒（"永远下载不下来"）。
      //    这里顺带删掉半成品文件。
      await AppInstallerPlus().cancelDownload(deletePartialDownload: true);
      // 2) 删除上次同名 APK，确保这次从零下载干净文件。
      await AppInstallerPlus().removedDownloadedApk(downloadFileName: fileName);
      // 3) 下载 + 安装。失败自动清理残留。
      try {
        await AppInstallerPlus().downloadAndInstallApk(
          downloadFileUrl: downloadUrl,
          onProgress: onProgress,
          downloadFileName: fileName,
          deleteOnError: true,
        ).timeout(const Duration(minutes: 15));
      } on TimeoutException {
        // 放弃等待时把后台下载一并取消 + 清残留，下次重试才不卡死。
        await AppInstallerPlus().cancelDownload(deletePartialDownload: true);
        return false;
      }
      return true;
    } catch (e) {
      return false;
    }
  }
}
