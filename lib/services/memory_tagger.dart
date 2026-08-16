/// 热词提取器（v4 设计稿 §5 表#1 + §7 防污染）。
///
/// P1 自动标签管线的核心：从文档文本提取 top-k 热词作为自动标签。
/// 对齐 jieba extract_tags（TF-IDF）+ 业界防污染组合：
/// - 黑名单：中文停用词（内置精简版）+ 长度过滤（<2 字符剔除）；
/// - IDF 门槛：idf 低于阈值（虚词/高频词）剔除；
/// - TF 饱和：log(1+tf) 替代线性 tf（重复轰炸无法刷高权重）；
/// - 查不到 idf 的词用中位数兜底（jieba tfidf.py 的 median_idf 逻辑）。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'chinese_segmenter.dart';

/// 停用词黑名单（内置精简版，中文虚词/日常词）。
/// jieba 默认 STOP_WORDS 只有英文，中文必须自备（v4 §7 调研结论）。
const Set<String> kChineseStopwords = {
  '的', '了', '是', '在', '我', '你', '他', '她', '它', '们', '这', '那', '有', '和',
  '与', '及', '或', '就', '都', '而', '但', '也', '又', '还', '很', '更', '最', '被',
  '把', '让', '给', '对', '从', '向', '到', '于', '之', '其', '此', '彼', '一个',
  '没有', '不是', '可以', '因为', '所以', '但是', '如果', '然后', '现在', '今天',
  '什么', '怎么', '这个', '那个', '我们', '你们', '他们', '自己', '时候', '东西',
  '进行', '以及', '对于', '通过', '根据', '关于', '主要', '重要', '需要', '可能',
  '应该', '已经', '还是', '虽然', '由于', '其中', '目前', '同时', '相关', '使用',
  'the', 'of', 'and', 'to', 'in', 'is', 'are', 'was', 'for', 'with', 'on', 'at',
};

/// IDF 门槛：低于此值视为高频/虚词（"的"=0.88、"是"=1.69）。
const double kMinIdf = 2.0;

/// 热词提取结果。
class Hotword {
  final String word;
  final double score;
  const Hotword(this.word, this.score);
}

/// 热词提取器（jieba idf.txt 表 + TF 饱和 + 黑名单/门槛）。
class MemoryTagger {
  Map<String, double>? _idf;
  double _medianIdf = 8.0; // 兜底（jieba median_idf 语义，先用保守值）。
  bool _loaded = false;

  /// idf 表是否已加载。
  bool get loaded => _loaded;

  /// 从 assets/jieba_idf.txt 加载 idf 表（复制到私有目录后读取）。
  Future<bool> loadIdf(String documentsDir) async {
    if (_loaded) return true;
    try {
      final cacheDir = p.join(documentsDir, '.mix_cache');
      Directory(cacheDir).createSync(recursive: true);
      final idfPath = p.join(cacheDir, 'jieba_idf.txt');
      final f = File(idfPath);
      if (!f.existsSync()) {
        final data = await rootBundle.load('assets/jieba_idf.txt');
        f.writeAsBytesSync(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      await _loadFromFile(idfPath);
      return _loaded;
    } catch (_) {
      _loaded = false;
      return false;
    }
  }

  /// 测试/调试用：直接从文件加载。
  Future<void> loadIdfFromFile(String path) async {
    await _loadFromFile(path);
  }

  Future<void> _loadFromFile(String path) async {
    final map = <String, double>{};
    final file = File(path);
    if (!file.existsSync()) return;
    final lines = await file.readAsLines();
    final values = <double>[];
    for (final line in lines) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final v = double.tryParse(parts[1]);
      if (v == null || v <= 0) continue;
      map[parts[0]] = v;
      values.add(v);
    }
    if (map.isNotEmpty) {
      _idf = map;
      values.sort();
      _medianIdf = values[values.length ~/ 2];
      _loaded = true;
    }
  }

  /// 提取热词：分词 → 过滤 → TF → idf → log 饱和 → top-k。
  ///
  /// 防污染（v4 §7）：连续重复去重 + 长度/黑名单过滤 + IDF 门槛 +
  /// log(1+tf) 饱和（重复 1000 次与 50 次贡献几乎相同）。
  List<Hotword> extractHotwords(
    String text, {
    int topK = 5,
    bool useIdf = true,
  }) {
    final words = segmentWords(text);
    if (words.isEmpty) return const [];

    // 连续重复去重 + 过滤：把 "词 词 词" 折叠为一次。
    final freq = <String, int>{};
    String? prev;
    for (final w in words) {
      final lower = w.toLowerCase();
      if (lower.length < 2) continue; // 单字符虚词/噪声。
      if (kChineseStopwords.contains(lower)) continue; // 黑名单。
      if (prev == lower) continue; // 连续重复。
      freq[lower] = (freq[lower] ?? 0) + 1;
      prev = lower;
    }
    if (freq.isEmpty) return const [];

    // 计分：log(1+tf) × idf（无 idf 表时纯 TF，log 饱和仍有效）。
    final scored = <Hotword>[];
    for (final entry in freq.entries) {
      final tf = entry.value;
      final saturatedTf = math.log(1.0 + tf);
      double idf = 1.0;
      if (useIdf && _idf != null) {
        idf = _idf![entry.key] ?? _medianIdf;
        if (idf < kMinIdf) continue; // IDF 门槛：高频/虚词剔除。
      }
      scored.add(Hotword(entry.key, saturatedTf * idf));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(topK).toList();
  }
}
