/// 中文分词服务（v4 设计稿 §7）。
///
/// 封装 dart_jieba（Python jieba 纯 Dart 移植）：
/// - dart_jieba 内部用 `dart:io File` 读词典，Flutter assets 不能 File 读 →
///   启动时把 `assets/dict.dgz` 复制到应用私有目录缓存，再走正常 File 路径。
/// - 对外提供两类接口：`segmentWords`（词列表，热词提取/标签用）和
///   `segmentToFts`（空格连接，FTS 索引/查询用）。
library;

import 'dart:io';

import 'package:dart_jieba/dart_jieba.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

JiebaSegmenter? _segmenter;

/// 分词器单例是否已初始化。
bool get chineseSegmenterReady => _segmenter != null;

/// 初始化分词器：复制 assets/dict.dgz → 私有目录 → dart_jieba 加载。
///
/// [documentsDir] 为应用 documents 目录（main.dart _initCwd 传入）。
/// 词典 2MB，复制后缓存，重复启动不再复制。
Future<bool> initChineseSegmenter(String documentsDir) async {
  if (_segmenter != null) return true;
  try {
    final cacheDir = p.join(documentsDir, '.mix_cache');
    Directory(cacheDir).createSync(recursive: true);
    final dictPath = p.join(cacheDir, 'dict.dgz');
    final f = File(dictPath);
    if (!f.existsSync()) {
      final data = await rootBundle.load('assets/dict.dgz');
      f.writeAsBytesSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    final seg = JiebaSegmenter();
    seg.initializeSync(dictPath: dictPath);
    _segmenter = seg;
    return true;
  } catch (_) {
    // 分词不可用（assets 缺失等）：检索自动降级 LIKE。
    _segmenter = null;
    return false;
  }
}

/// 分词 → 词列表（去空白）。
List<String> segmentWords(String text) {
  final seg = _segmenter;
  if (seg == null) return const [];
  try {
    return seg.cut(text).where((w) => w.trim().isNotEmpty).toList();
  } catch (_) {
    return const [];
  }
}

/// 分词 → 空格连接字符串（FTS 索引/查询用）。无可分词内容返回 null。
String? segmentToFts(String text) {
  final words = segmentWords(text);
  if (words.isEmpty) return null;
  return words.join(' ');
}

/// 查询分词 → FTS5 MATCH 表达式（词 OR 连接，对齐 TAIPANBOX/engram 的
/// "空格=AND 长问题召回归零" 教训）。无有效词返回 null。
String? buildFtsQuery(String query) {
  final words = segmentWords(query);
  if (words.isEmpty) return null;
  final escaped = words
      .map((w) => _escapeFtsTerm(w))
      .where((s) => s.isNotEmpty)
      .toList();
  if (escaped.isEmpty) return null;
  return escaped.join(' OR ');
}

/// 清洗单个 FTS5 词（剥特殊操作符，对齐 session_db._sanitizeFtsQuery）。
String _escapeFtsTerm(String term) {
  final cleaned = term.replaceAll(
    RegExp("[^a-zA-Z0-9\\p{Script=Han}]", unicode: true),
    '',
  );
  if (cleaned.isEmpty) return '';
  return '"$cleaned"';
}
