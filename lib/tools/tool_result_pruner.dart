/// 工具结果裁剪器（DSH 启示 3，v4 设计稿 §7.3）。
///
/// 所有工具输出先**确定性裁剪**（不调 LLM）：大 JSON → 结构统计摘要，
/// 大文本 → 头部 + 截断标注。先裁剪后压缩（LLM 摘要兜底留给上下文压缩）。
///
/// 目标：防止超大工具结果（大文件读、大列表、长下载）淹没上下文，
/// 同时保留模型可用的结构信息。
library;

import 'dart:convert';

/// 默认裁剪阈值（字符）。比 registry 默认 100k 更激进，保证注入质量。
const int kPruneDefaultMaxChars = 30000;

/// 裁剪工具结果。未超限原样返回。
String pruneToolResult(String raw, {int maxChars = kPruneDefaultMaxChars}) {
  if (raw.length <= maxChars) return raw;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return raw;

  // JSON 结构裁剪（保统计 + 前 N 项）。
  final jsonPruned = _pruneJson(trimmed, maxChars);
  if (jsonPruned != null) return jsonPruned;

  // 纯文本：头部 + 截断标注。
  final head = raw.substring(0, maxChars);
  return '$head\n…[truncated by pruner: total ${raw.length} chars, '
      'showing first $maxChars]';
}

/// JSON 裁剪：数组 → 元素数 + 前 N 项；对象 → 键数 + 前 N 键。
/// 解析失败返回 null（走文本裁剪）。
String? _pruneJson(String trimmed, int maxChars) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return null;
  }
  final head = trimmed.substring(0, 2000); // 判断形状（避免全量编码）。
  try {
    if (decoded is List) {
      final shown = decoded.take(5).toList();
      return jsonEncode({
        '_pruned': true,
        'total_items': decoded.length,
        'shown_count': shown.length,
        'items': shown,
      });
    }
    if (decoded is Map) {
      final keys = decoded.keys.take(8).toList();
      final shown = <String, dynamic>{
        for (final k in keys) k: decoded[k],
      };
      return jsonEncode({
        '_pruned': true,
        'total_keys': decoded.length,
        'shown_keys': keys,
        'values': shown,
      });
    }
    // 标量：直接截断。
    if (head.length > maxChars) {
      return '$head…[truncated]';
    }
    return null;
  } catch (_) {
    return null;
  }
}
