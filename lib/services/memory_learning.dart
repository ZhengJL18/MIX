/// 学习状态描绘（v4 设计稿 §6.3 + P4："副业干过主业"）。
///
/// 从记忆证据流（correct/wrong/hit/miss/activated，由 study_record 判题 +
/// 记忆检索写入）推导知识点的**可提取性/掌握/遗忘信号**——无侵入式学习分析：
/// - **可提取性**（Bjork retrievability）= 最近激活成功率 × 新鲜度；
/// - **掌握信号** = 置信度引擎 Beta 置信度（学习事件即记忆观察的特例）；
/// - **遗忘节律** = 距最近证据时间（学习状态 τ 短，2 周量级）。
///
/// 状态分类：unknown（无证据）/ mastered（高置信+新鲜）/ learning（中置信）/
/// weak（负证据主导）/ review_due（遗忘节律到期）。
library;

import 'dart:math' as math;

import 'memory_confidence.dart';
import 'memory_db.dart';
import 'study_engine.dart';

/// 复习到期阈值（秒）：距最近证据超过此时长 → review_due。
const double kReviewDueSeconds = 7 * 24 * 3600.0;

/// 单个知识点学习状态。
class KnowledgeLearningState {
  final int kpId;
  final String name;
  final String subjectName;
  final double mastery; // Beta 置信度（0~1，无证据 0.5）。
  final double retrievability; // 可提取性（0~1）。
  final double ageSeconds; // 距最近证据秒数（无证据 -1）。
  final int evidenceCount;
  final String status; // unknown|mastered|learning|weak|review_due

  const KnowledgeLearningState({
    required this.kpId,
    required this.name,
    required this.subjectName,
    required this.mastery,
    required this.retrievability,
    required this.ageSeconds,
    required this.evidenceCount,
    required this.status,
  });
}

/// 学习状态推导器（纯统计、零 LLM）。
class MemoryLearning {
  final MemoryDB db;
  final StudyEngine? studyEngine;

  MemoryLearning({required this.db, this.studyEngine});

  /// 推导全部知识点的学习状态。
  Future<List<KnowledgeLearningState>> deriveStates() async {
    final engine = studyEngine;
    if (engine == null) return const [];
    try {
      final kps = await engine.listKps();
      final confidence = MemoryConfidence(db);
      final out = <KnowledgeLearningState>[];
      for (final kp in kps) {
        final cs = await confidence.score(
          'knowledge',
          kp.id,
          tauSeconds: kTauSeconds['knowledge'] ?? 30 * 24 * 3600.0,
        );
        out.add(KnowledgeLearningState(
          kpId: kp.id,
          name: kp.name,
          subjectName: kp.subjectName,
          mastery: cs.confidence,
          retrievability: cs.reliability,
          ageSeconds: cs.ageSeconds,
          evidenceCount: cs.positive + cs.negative,
          status: _classify(cs),
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 复习推荐：状态为 weak / review_due 的知识点（按遗忘紧急度排序）。
  Future<List<KnowledgeLearningState>> reviewDue({int limit = 10}) async {
    final states = await deriveStates();
    final due = states
        .where((s) => s.status == 'weak' || s.status == 'review_due')
        .toList()
      ..sort((a, b) {
        // weak（薄弱）优先，再按遗忘时长。
        final aWeak = a.status == 'weak' ? 0 : 1;
        final bWeak = b.status == 'weak' ? 0 : 1;
        if (aWeak != bWeak) return aWeak.compareTo(bWeak);
        return b.ageSeconds.compareTo(a.ageSeconds);
      });
    return due.take(limit).toList();
  }

  String _classify(ConfidenceScore cs) {
    if (cs.positive == 0 && cs.negative == 0) return 'unknown';
    if (cs.negative >= cs.positive) return 'weak'; // 负证据主导。
    if (cs.confidence >= 0.7) {
      // 高置信但遗忘到期 → 需复习。
      if (cs.ageSeconds > kReviewDueSeconds) return 'review_due';
      return 'mastered';
    }
    if (cs.confidence >= 0.4) {
      if (cs.ageSeconds > kReviewDueSeconds) return 'review_due';
      return 'learning';
    }
    return 'weak';
  }
}

/// 可提取性工具（供外部计算激活成功率）。
double retrievabilityOf(double recentHitRate, double ageSeconds,
    {double tau = 14 * 24 * 3600.0}) {
  return recentHitRate * math.exp(-ageSeconds / tau);
}
