import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 保存图片到系统相册。
///
/// 走 MIX 已有的「所有文件访问」权限：直接写公共 Pictures/MIX/ 目录，
/// 再通过 MainActivity 的 MediaScanner 扫描，让系统相册识别。
class ImageSaver {
  static const _channel = MethodChannel('com.mix.app/storage');

  /// 把图片字节存到相册 Pictures/MIX/，返回保存的文件路径。
  /// 失败抛异常（权限/IO 错误）。
  static Future<String> saveImageToGallery(
    Uint8List bytes, {
    String? fileName,
  }) async {
    final dir = await _pickDir();
    final name = fileName ?? 'mix_${DateTime.now().millisecondsSinceEpoch}.png';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);

    // MediaScanner 扫描，让系统相册立即识别这张图。
    await _channel.invokeMethod('scanMedia', {'path': file.path});
    return file.path;
  }

  static Future<Directory> _pickDir() async {
    // 优先公共 Pictures/MIX（MIX 有所有文件访问权限，可直接写）。
    const public = '/storage/emulated/0/Pictures/MIX';
    final publicDir = Directory(public);
    try {
      await publicDir.create(recursive: true);
      // 验证可写（鸿蒙/部分 ROM 可能挂载差异）。
      final probe = File('${publicDir.path}/.mix_write_test');
      await probe.writeAsString('t', flush: true);
      await probe.delete();
      return publicDir;
    } catch (_) {
      // fallback：app 专属外部目录（不进系统相册，但保存不失败）。
      final external = await getExternalStorageDirectory();
      if (external == null) throw StateError('无法访问存储目录');
      final dir = Directory('${external.path}/Pictures/MIX');
      await dir.create(recursive: true);
      return dir;
    }
  }
}
