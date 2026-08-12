// 按需下载资源管理器：大体积运行时资源（mermaid.min.js、pdf.js 等）
// 不打包进 APK，首次使用时从 GitHub 仓库下载到应用私有目录缓存，之后永久复用。
// 与 wheels 按需下载同一模式，但抽象成通用组件，任何引擎/功能都能注册资源。
//
// 设计：
//   - 缓存目录：appSupport/remote_assets/<name>
//   - 幂等：已缓存直接返回路径；下载中并发请求只拉一次（Completer 去重）
//   - 安全：先写 .part 临时文件，成功后原子 rename；失败清理不留垃圾
//   - 进度：onProgress 回调供 UI 显示下载进度
//
// 用法：
//   final path = await RemoteAssetManager.instance.ensure('mermaid');
//   // path = /data/.../remote_assets/mermaid.min.js
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 一个可按需下载的远程资源。
class RemoteAssetSpec {
  const RemoteAssetSpec({
    required this.name,
    required this.url,
    this.sizeMB,
    this.sha256,
  });

  /// 缓存文件名（唯一标识）。
  final String name;

  /// 下载地址（GitHub raw / 任意 HTTP(S)）。
  final String url;

  /// 提示用体积（MB），用于 UI 显示"预计大小"。
  final double? sizeMB;

  /// 可选：下载后 SHA-256 校验（防坏档/防篡改）。
  /// 注：当前未强制校验（避免引入 crypto 依赖），字段预留给后续接入。
  final String? sha256;
}

class RemoteAssetManager {
  RemoteAssetManager._();

  static final RemoteAssetManager instance = RemoteAssetManager._();

  /// 全 App 注册的远程资源表（key = 资源逻辑名）。
  /// 仅 mermaid 仍按需下载；bin_extract 已退役（fflate/sqljs/pdfjs 随之移除，
  /// read_doc 改用纯 Dart archive + 云端 /extract）。
  final Map<String, RemoteAssetSpec> _specs = {
    'mermaid': RemoteAssetSpec(
      name: 'mermaid.min.js',
      url:
          'https://raw.githubusercontent.com/ZhengJL18/MIX/master/assets/mermaid/mermaid.min.js',
      sizeMB: 3.5,
    ),
  };

  /// 进行中的下载（并发去重）。
  final Map<String, Future<String>> _inflight = {};

  Future<Directory> get _cacheDir async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/remote_assets');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// 已缓存？（仅本地检查，不发请求）
  Future<bool> has(String key) async {
    final spec = _specs[key];
    if (spec == null) return false;
    final dir = await _cacheDir;
    return File('${dir.path}/${spec.name}').existsSync();
  }

  /// 确保资源可用，返回本地文件路径。未缓存则下载（并发去重）。
  /// [onProgress] 可选回调 (done, total, name)，供 UI 显示进度。
  Future<String> ensure(
    String key, {
    void Function(int, int, String)? onProgress,
  }) async {
    final spec = _specs[key];
    if (spec == null) throw StateError('未注册的远程资源: $key');
    final dir = await _cacheDir;
    final file = File('${dir.path}/${spec.name}');
    if (file.existsSync()) return file.path;

    // 并发去重：同一 key 同时被多处请求时只下载一次
    final inflight = _inflight[key];
    if (inflight != null) return inflight;

    final future = _download(spec, dir, onProgress);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<String> _download(
    RemoteAssetSpec spec,
    Directory dir,
    void Function(int, int, String)? onProgress,
  ) async {
    final tmp = File('${dir.path}/${spec.name}.part');
    final request = http.Request('GET', Uri.parse(spec.url));
    try {
      // 流式下载写盘：整包 http.get 会把整个 body 读进内存再 writeAsBytes 二次
      // 拷贝，大资源在低内存设备上引发 GC 停顿 → 界面卡死。改流式分块写，
      // 内存占用恒定，并顺带逐块上报真实进度（onProgress(done, total, name)）。
      final resp = await http.Client()
          .send(request)
          .timeout(const Duration(minutes: 5));
      if (resp.statusCode != 200) {
        throw StateError('下载 ${spec.name} 失败: HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength ?? 0;
      final sink = tmp.openWrite();
      var done = 0;
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          done += chunk.length;
          if (total > 0) {
            onProgress?.call(done, total, spec.name);
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      // 原子改名：避免半成品被误当缓存
      final finalFile = File('${dir.path}/${spec.name}');
      if (finalFile.existsSync()) await finalFile.delete();
      await tmp.rename(finalFile.path);
      onProgress?.call(total > 0 ? total : done, total > 0 ? total : done, spec.name);
      return finalFile.path;
    } catch (e) {
      if (tmp.existsSync()) await tmp.delete();
      rethrow;
    }
  }
}
