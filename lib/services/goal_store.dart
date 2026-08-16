/// Goal 系统（DSH 启示 1，v4 设计稿 §7.1）。
///
/// 持久目标 + 自动续跑：goal 是持久化对象（id + revision 乐观锁 + 阶段 +
/// 轮次预算 + blocked 语义），跨会话自动续跑同一目标。
///
/// - **证据驱动进度**：goal 关联 `evidence_obj`（如 `knowledge:3`），进度由
///   置信度引擎推导（v4 §6），不是自报——"掌握线代第二章"的进度 = 该知识点
///   相关记忆的可靠度/可提取性演化。
/// - **revision 乐观锁**：更新需携带当前 revision，防并发覆盖。
library;

import 'memory_confidence.dart';
import 'memory_db.dart';

/// Goal 阶段。
class GoalPhase {
  static const String active = 'active';
  static const String paused = 'paused';
  static const String blocked = 'blocked';
  static const String done = 'done';
}

/// Goal 存储（复用 memory.db，独立类保持职责清晰）。
class GoalStore {
  final MemoryDB db;

  GoalStore(this.db);

  /// 创建目标。返回 goal id；失败返回 null。
  Future<int?> createGoal(
    String objective, {
    int? maxRounds,
    String? evidenceObj,
  }) async {
    if (objective.trim().isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    try {
      db.db.execute(
        'INSERT INTO goals(objective, phase, max_rounds, evidence_obj, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        [objective.trim(), GoalPhase.active, maxRounds, evidenceObj, now, now],
      );
      return db.db.lastInsertRowId;
    } catch (_) {
      return null;
    }
  }

  /// 读单个 goal。
  Future<Map<String, dynamic>?> getGoal(int id) async {
    final result = db.db.select(
      'SELECT * FROM goals WHERE id = ? LIMIT 1',
      [id],
    );
    final cols = result.columnNames;
    return result.isEmpty
        ? null
        : {for (final c in cols) c: result.first[c]};
  }

  /// 列出目标（按 phase 过滤，可选）。
  Future<List<Map<String, dynamic>>> listGoals({String? phase}) async {
    final result = phase != null
        ? db.db.select(
            'SELECT * FROM goals WHERE phase = ? ORDER BY updated_at DESC',
            [phase])
        : db.db.select('SELECT * FROM goals ORDER BY updated_at DESC');
    final cols = result.columnNames;
    return [
      for (final r in result) {for (final c in cols) c: r[c]},
    ];
  }

  /// 活跃目标（phase=active 且未超轮次上限）。
  Future<List<Map<String, dynamic>>> listActiveGoals() async {
    final result = db.db.select(
      'SELECT * FROM goals WHERE phase = ? ORDER BY updated_at DESC',
      [GoalPhase.active],
    );
    final cols = result.columnNames;
    return [
      for (final r in result) {for (final c in cols) c: r[c]},
    ];
  }

  /// 乐观锁更新：调用方携带当前 [expectedRevision]，不匹配返回 false。
  Future<bool> updateGoal(
    int id, {
    required int expectedRevision,
    String? objective,
    String? phase,
    String? blockedReason,
    int? rounds,
    int? maxRounds,
    String? evidenceObj,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final updates = <String, dynamic>{'updated_at': now};
    if (objective != null) updates['objective'] = objective.trim();
    if (phase != null) updates['phase'] = phase;
    if (blockedReason != null) updates['blocked_reason'] = blockedReason;
    if (rounds != null) updates['rounds'] = rounds;
    if (maxRounds != null) updates['max_rounds'] = maxRounds;
    if (evidenceObj != null) updates['evidence_obj'] = evidenceObj;
    updates['revision'] = expectedRevision + 1; // 乐观锁递增。
    try {
      final sets = updates.keys.map((k) => '$k = ?').join(', ');
      final args = <Object?>[...updates.values, id, expectedRevision];
      db.db.execute(
        'UPDATE goals SET $sets WHERE id = ? AND revision = ?',
        args,
      );
      final changed = db.db.select('SELECT changes() AS n');
      return changed.isNotEmpty && (changed.first['n'] as int) > 0;
    } catch (_) {
      return false;
    }
  }

  /// 续跑一轮（rounds+1，revision 递增）。供 goal driver 每轮调用。
  Future<bool> advanceRound(int id, int expectedRevision) async {
    final g = await getGoal(id);
    if (g == null) return false;
    final next = ((g['rounds'] as int?) ?? 0) + 1;
    return updateGoal(id, expectedRevision: expectedRevision, rounds: next);
  }

  /// 暂停/恢复/完成/阻塞（携带 revision 乐观锁）。
  Future<bool> setPhase(
    int id,
    int expectedRevision,
    String phase, {
    String? blockedReason,
  }) {
    return updateGoal(
      id,
      expectedRevision: expectedRevision,
      phase: phase,
      blockedReason: phase == GoalPhase.blocked ? blockedReason : null,
    );
  }

  /// 从证据对象推导目标进度（v4 §6 证据驱动）：
  /// 返回 (进度分 0~1, 证据数)。无证据对象返回 null。
  Future<(double, int)?> deriveProgress(int id) async {
    final goal = await getGoal(id);
    if (goal == null) return null;
    final evidenceObj = goal['evidence_obj'] as String?;
    if (evidenceObj == null || !evidenceObj.contains(':')) return null;
    final parts = evidenceObj.split(':');
    if (parts.length < 2) return null;
    final objType = parts[0];
    final objId = int.tryParse(parts[1]);
    if (objId == null) return null;
    // 掌握度信号：置信度引擎的 Beta 置信度即进度（v4 §6.3 学习描绘）。
    final confidence = MemoryConfidence(db);
    final score = await confidence.score(objType, objId);
    return (score.confidence, score.positive + score.negative);
  }

  /// 渲染活跃目标块（v4 §7.1 自动续跑）：agent 系统提示注入用。
  ///
  /// 列出活跃目标 + 证据驱动进度 + 轮次——agent 每轮看到长期目标，
  /// 自动朝目标推进（跨会话持续）。无活跃目标返回空串。
  Future<String> renderActiveGoalsBlock() async {
    final goals = await listActiveGoals();
    if (goals.isEmpty) return '';
    final lines = <String>[];
    for (final g in goals) {
      final progress = await deriveProgress(g['id'] as int);
      final p = progress == null
          ? ''
          : '（进度 ${(progress.$1 * 100).toStringAsFixed(0)}%，'
              '证据 ${progress.$2} 条）';
      final rounds = '轮次 ${g['rounds']}/${g['max_rounds'] ?? '∞'}';
      lines.add('- ${g['objective']}$p（$rounds）');
    }
    return '<active-goals>\n'
        'Current active goals (persist across sessions, keep working toward '
        'them):\n'
        '${lines.join('\n')}\n'
        '</active-goals>';
  }
}
