import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  /// 下载源标识（'国内镜像' / 'GitHub'），更新时让用户选。
  final String source;

  const UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    this.notes,
    this.source = 'GitHub',
  });
}

/// 自动更新服务。
///
/// 版本源：国内镜像优先（免 VPN），兜底 GitHub Releases（tag = v1.0.0+N）。
/// App 启动时 checkForUpdate()，有新版返回 UpdateInfo，无/失败返回 null（静默）。
class UpdateService {
  static const String _repo = 'ZhengJL18/MIX';
  static const Duration _timeout = Duration(seconds: 15);

  /// 国内更新镜像清单（服务器自动同步 GitHub Releases，免 VPN）。
  static const String _mirrorManifestUrl =
      'http://43.139.179.58/update/latest.json';

  /// 查更新（静默）：返回所有有新版可用的源（国内镜像 / GitHub）。
  /// 空 = 无更新或全部失败；启动静默不打扰。
  static Future<List<UpdateInfo>> checkForUpdate() async {
    try {
      return await checkForUpdateDetailed();
    } catch (e) {
      debugPrint('[Update] 检查失败: $e');
      return const <UpdateInfo>[];
    }
  }

  /// 手动检查：返回有新版可用的源列表（可能 0 / 1 / 2 个）。
  /// 每个源独立判断，镜像未同步好或 GitHub 挂了都不影响另一个。
  static Future<List<UpdateInfo>> checkForUpdateDetailed() async {
    final results = <UpdateInfo>[];
    final mirror = await _fetchFromMirror();
    final github = await _fetchFromGitHub();
    if (mirror != null) results.add(mirror);
    if (github != null) results.add(github);
    return results;
  }

  /// 从国内镜像 /update/latest.json 读取（清单由服务器同步脚本生成）。
  static Future<UpdateInfo?> _fetchFromMirror() async {
    // 镜像清单目前只同步 Android APK，Linux 桌面走 GitHub Releases 抓 .deb。
    if (Platform.isLinux) return null;
    try {
      final resp =
          await http.get(Uri.parse(_mirrorManifestUrl)).timeout(_timeout);
      if (resp.statusCode != 200) return null;
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final remoteBuild = data['build'] as int? ?? 0;
      final downloadUrl = data['apk_url'] as String? ?? '';
      debugPrint('[Update] mirror build=$remoteBuild url=$downloadUrl');
      if (remoteBuild <= 0 || downloadUrl.isEmpty) return null;

      final local = await PackageInfo.fromPlatform();
      final localBuild = int.tryParse(local.buildNumber) ?? 0;
      debugPrint('[Update] local build=$localBuild');
      if (remoteBuild <= localBuild) return null;

      return UpdateInfo(
        version: data['version'] as String? ?? '',
        buildNumber: remoteBuild,
        downloadUrl: downloadUrl,
        notes: data['notes'] as String?,
        source: '国内镜像',
      );
    } catch (e) {
      debugPrint('[Update] 镜像检查失败: $e');
      return null;
    }
  }

  static Future<UpdateInfo?> _fetchFromGitHub() async {
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

      // 下载直链：Android 抓 .apk，Linux 抓 .deb（平台感知）。
      String? downloadUrl;
      for (final a in assets) {
        final name = a['name'] as String? ?? '';
        final wanted = Platform.isLinux ? name.endsWith('.deb') : name.endsWith('.apk');
        if (wanted) {
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
    // Linux 桌面：下载 .deb 到 ~/Downloads，交给用户手动 dpkg 安装。
    if (Platform.isLinux) {
      final path = await downloadLinuxDeb(downloadUrl, onProgress: onProgress);
      return path != null;
    }
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

  /// Linux：流式下载 .deb 到 ~/Downloads（内存友好），返回保存路径（失败 null）。
  static Future<String?> downloadLinuxDeb(
    String downloadUrl, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return null;
      final dir = Directory('$home/Downloads');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final dest = File('${dir.path}/MIX-update.deb');

      final client = http.Client();
      final resp = await client
          .send(http.Request('GET', Uri.parse(downloadUrl)))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        client.close();
        return null;
      }

      final total = resp.contentLength ?? 0;
      var received = 0;
      final sink = dest.openWrite();
      await for (final chunk in resp.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0 && onProgress != null) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();
      client.close();
      return dest.path;
    } catch (e) {
      debugPrint('[Update] Linux deb 下载失败: $e');
      return null;
    }
  }
}
