/// 置信度引擎（v4 设计稿 §6 通用置信度引擎）。
///
/// 从 `memory_evidence` 事件流推导记忆对象的可靠度：
/// - **置信度**：Beta-Binomial 后验均值 `(p+1)/(p+n+2)`（拉普拉斯平滑；
///   样本少时自动保守）。
/// - **新鲜度**：遗忘衰减 `exp(-Δt/τ)`（τ 按对象类型：fact 长 / preference 中 /
///   学习状态短）。
/// - **综合可靠度** = 置信度 × 新鲜度。
///
/// 统一服务：注入决策（低可靠度不注入或标注）、排序加权、画像可靠性、
/// 学习状态描绘、记忆对账触发。
library;

import 'dart:math' as math;

import 'memory_db.dart';

/// 正证据类型（提升置信度）。
const Set<String> kPositiveEvidence = {
  'hit', // 检索命中并采纳
  'adopted', // 注入被采纳
  'correct', // 作答正确
  'verified', // 对账确认
  'read', // 被主动读取
};

/// 负证据类型（降低置信度）。
const Set<String> kNegativeEvidence = {
  'miss', // 检索无果
  'rejected', // 注入被忽略/纠正
  'wrong', // 作答错误
  'stale', // 发现过时
};

/// 遗忘半衰期（秒）按对象类型：事实长、偏好中、学习状态短。
const Map<String, double> kTauSeconds = {
  'fact': 180 * 24 * 3600.0, // 事实 ~6 个月
  'preference': 60 * 24 * 3600.0, // 偏好 ~2 个月
  'learning': 14 * 24 * 3600.0, // 学习状态 ~2 周
  'doc': 90 * 24 * 3600.0, // 记忆文档 ~3 个月
  'knowledge': 30 * 24 * 3600.0, // 知识点 ~1 个月
};

/// 置信度得分。
class ConfidenceScore {
  /// Beta 后验均值 (0~1)：样本少时收敛到 0.5（保守）。
  final double confidence;

  /// 新鲜度 (0~1)：时间衰减。
  final double freshness;

  /// 综合可靠度 = 置信度 × 新鲜度。
  final double reliability;

  /// 正/负证据计数。
  final int positive;
  final int negative;

  /// 距最近一次证据的秒数（-1 表示无证据）。
  final double ageSeconds;

  const ConfidenceScore({
    required this.confidence,
    required this.freshness,
    required this.reliability,
    required this.positive,
    required this.negative,
    required this.ageSeconds,
  });
}

/// 置信度推导器（纯统计、零 LLM）。
class MemoryConfidence {
  final MemoryDB db;

  MemoryConfidence(this.db);

  /// 推导对象 [objType]/[objId] 的可靠度。
  Future<ConfidenceScore> score(
    String objType,
    int objId, {
    double tauSeconds = 90 * 24 * 3600.0,
  }) async {
    final rows = await db.db.select(
      'SELECT evidence, ts FROM memory_evidence '
      'WHERE obj_type = ? AND obj_id = ? ORDER BY ts DESC',
      [objType, objId],
    );
    var p = 0;
    var n = 0;
    var lastTs = -1.0;
    for (final r in rows) {
      final ev = r['evidence'] as String;
      if (kPositiveEvidence.contains(ev)) p++;
      if (kNegativeEvidence.contains(ev)) n++;
      final ts = (r['ts'] as num).toDouble();
      if (ts > lastTs) lastTs = ts;
    }
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final age = lastTs < 0 ? -1.0 : now - lastTs;

    // Beta(1,1) 先验 + 拉普拉斯平滑。
    final confidence = (p + 1) / (p + n + 2);
    final freshness = age < 0 ? 0.5 : math.exp(-age / tauSeconds);
    return ConfidenceScore(
      confidence: confidence,
      freshness: freshness,
      reliability: confidence * freshness,
      positive: p,
      negative: n,
      ageSeconds: age,
    );
  }

  /// 注入门控判定：是否值得注入（v4 §5.5 宁可缺不可杂）。
  ///
  /// 无证据（全新对象）→ 允许注入（0.5 置信度，给新记忆机会）；
  /// 有证据但可靠度低于 [minReliability] → 拒绝（可能过时/不可信）。
  bool shouldInject(ConfidenceScore score, {double minReliability = 0.2}) {
    if (score.positive == 0 && score.negative == 0) return true;
    return score.reliability >= minReliability;
  }
}
