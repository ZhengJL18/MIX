/// 学习画像投影（v4 设计稿 §6.3 + P4："副业干过主业"最后一块）。
///
/// 把记忆证据流推导的学习状态渲染成 Markdown 画像投影——**证据驱动的实时
/// 投影**，与 `0_profile.md`（LLM 叙事画像）互补：
/// - 0_profile.md：LLM 合并观察写回（人话叙事，但静态、周期性更新）；
/// - 本投影：从 memory_evidence 实时推导（掌握/薄弱/复习到期/未接触），
///   零 LLM、永远最新——agent 通过 memory_read 读它即可掌握学习全貌。
///
/// 投影文档写入记忆库（kind='profile'），可选落盘 notes 目录。
library;

import 'memory_db.dart';
import 'memory_learning.dart';

/// 记忆库中画像投影文档的 path。
const String kProfileDocPath = 'memory/profile.md';

/// 画像投影生成器。
class MemoryProfileProjector {
  final MemoryLearning learning;
  final MemoryDB db;

  MemoryProfileProjector({required this.learning, required this.db});

  /// 生成画像投影 Markdown（证据驱动，含时间戳）。
  Future<String> buildMarkdown() async {
    final states = await learning.deriveStates();
    final due = await learning.reviewDue(limit: 8);
    final now = DateTime.now();
    final buf = StringBuffer();

    buf.writeln('# 学习状态投影（证据驱动，自动生成）');
    buf.writeln();
    buf.writeln('> 由记忆证据流推导，非人工维护。生成时间：'
        '${now.year}-${_pad(now.month)}-${_pad(now.day)} '
        '${_pad(now.hour)}:${_pad(now.minute)}');
    buf.writeln();

    // 统计。
    final byStatus = <String, int>{};
    for (final s in states) {
      byStatus[s.status] = (byStatus[s.status] ?? 0) + 1;
    }
    buf.writeln('**知识点总数**：${states.length} ｜ '
        '掌握 ${byStatus['mastered'] ?? 0} ｜ '
        '学习中 ${byStatus['learning'] ?? 0} ｜ '
        '薄弱 ${byStatus['weak'] ?? 0} ｜ '
        '复习到期 ${byStatus['review_due'] ?? 0} ｜ '
        '未接触 ${byStatus['unknown'] ?? 0}');
    buf.writeln();

    // 复习推荐。
    if (due.isNotEmpty) {
      buf.writeln('## 建议复习');
      for (final s in due) {
        final days = s.ageSeconds < 0
            ? '?'
            : (s.ageSeconds / 86400).toStringAsFixed(1);
        buf.writeln('- **${s.name}**（${s.subjectName}，${s.status}，'
            '可靠度 ${(s.retrievability * 100).toStringAsFixed(0)}%，'
            '距上次 $days 天）');
      }
      buf.writeln();
    }

    // 按科目分组。
    final bySubject = <String, List<dynamic>>{};
    for (final s in states) {
      bySubject.putIfAbsent(s.subjectName, () => []).add(s);
    }
    for (final entry in bySubject.entries) {
      buf.writeln('## ${entry.key}');
      for (final s in entry.value) {
        final statusLabel = _statusLabel(s.status);
        buf.writeln('- $statusLabel ${s.name}'
            '（掌握 ${(s.mastery * 100).toStringAsFixed(0)}%，'
            '证据 ${s.evidenceCount} 条）');
      }
      buf.writeln();
    }
    return buf.toString();
  }

  /// 把投影写入记忆库（kind='profile'，agent 可 memory_read 读到）。
  Future<int?> saveToMemory() async {
    final md = await buildMarkdown();
    try {
      return await db.upsertDoc(
        path: kProfileDocPath,
        title: '学习状态投影',
        content: md,
        kind: 'profile',
      );
    } catch (_) {
      return null;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'mastered':
        return '✅';
      case 'learning':
        return '📖';
      case 'weak':
        return '⚠️';
      case 'review_due':
        return '⏰';
      default:
        return '·';
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}
