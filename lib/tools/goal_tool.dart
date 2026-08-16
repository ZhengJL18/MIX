/// goal 工具（DSH 启示 1，v4 设计稿 §7.1）。
///
/// 持久目标管理：agent 可创建/查看/更新跨会话目标。
/// - `goal_create`：objective + 可选 max_rounds/evidence_obj（证据驱动进度）
/// - `goal_list`：列出目标（默认活跃）
/// - `goal_update`：暂停/恢复/完成/阻塞 + 更新 objective
/// 进度推导：关联 evidence_obj 时由置信度引擎算（Beta 置信度）。
library;

import 'dart:convert';

import '../services/goal_store.dart';
import 'registry.dart';

/// 全局 GoalStore 引用（main.dart 初始化）。
GoalStore? goalStore;

/// goal 工具 handler。
Future<String> goalTool({
  String? action,
  String? objective,
  int? goalId,
  String? phase,
  String? blockedReason,
  int? maxRounds,
  String? evidenceObj,
  GoalStore? store,
}) async {
  if (store == null) {
    return toolError('Goal store not available');
  }
  try {
    switch (action) {
      case 'create':
        if (objective == null || objective.trim().isEmpty) {
          return toolError('goal: objective required for create');
        }
        final id = await store.createGoal(
          objective,
          maxRounds: maxRounds,
          evidenceObj: evidenceObj,
        );
        if (id == null) return toolError('goal: create failed');
        return toolResult({
          'success': true,
          'goal_id': id,
          'objective': objective.trim(),
          'phase': 'active',
        });

      case 'list':
        final goals = await store.listGoals(phase: phase ?? GoalPhase.active);
        return toolResult({
          'success': true,
          'count': goals.length,
          'goals': [
            for (final g in goals)
              {
                'id': g['id'],
                'objective': g['objective'],
                'phase': g['phase'],
                'revision': g['revision'],
                'rounds': g['rounds'],
                'max_rounds': g['max_rounds'],
                'blocked_reason': g['blocked_reason'],
                'evidence_obj': g['evidence_obj'],
              },
          ],
        });

      case 'update':
        if (goalId == null) {
          return toolError('goal: goal_id required for update');
        }
        final current = await store.getGoal(goalId);
        if (current == null) {
          return toolError('goal: goal $goalId not found');
        }
        final rev = current['revision'] as int;
        final ok = await store.updateGoal(
          goalId,
          expectedRevision: rev,
          objective: objective,
          phase: phase,
          blockedReason: blockedReason,
          maxRounds: maxRounds,
          evidenceObj: evidenceObj,
        );
        if (!ok) {
          return toolError('goal: update failed (revision conflict?)');
        }
        return toolResult({
          'success': true,
          'goal_id': goalId,
          'phase': phase ?? current['phase'],
        });

      case 'progress':
        if (goalId == null) {
          return toolError('goal: goal_id required for progress');
        }
        final p = await store.deriveProgress(goalId);
        final goal = await store.getGoal(goalId);
        return toolResult({
          'success': true,
          'goal_id': goalId,
          'objective': goal?['objective'],
          'progress': p?.$1,
          'evidence_count': p?.$2,
          'phase': goal?['phase'],
          'rounds': goal?['rounds'],
        });

      default:
        return toolError(
            "goal: unknown action '$action'. Use: create, list, update, progress");
    }
  } catch (e) {
    return toolError('goal failed: $e');
  }
}

/// goal 工具 schema。
const Map<String, dynamic> goalSchema = {
  'name': 'goal',
  'description':
      'Manage persistent goals that survive across sessions (auto-resumed). '
      'Actions: create (objective + optional max_rounds/evidence_obj), list, '
      'update (pause/resume/complete/blocked), progress (evidence-driven '
      'progress from confidence engine). Use for long-term learning targets '
      'like "master linear algebra chapter 2".',
  'parameters': {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['create', 'list', 'update', 'progress'],
        'description': 'Action to perform.',
      },
      'objective': {
        'type': 'string',
        'description': 'Goal objective (for create/update).',
      },
      'goal_id': {
        'type': 'integer',
        'description': 'Goal id (for update/progress).',
      },
      'phase': {
        'type': 'string',
        'enum': ['active', 'paused', 'blocked', 'done'],
        'description': 'Phase to set (for update).',
      },
      'blocked_reason': {
        'type': 'string',
        'description': 'Reason when blocking a goal.',
      },
      'max_rounds': {
        'type': 'integer',
        'description': 'Round cap (for create).',
      },
      'evidence_obj': {
        'type': 'string',
        'description': 'Evidence object like knowledge:3 (progress derived '
            'from its confidence score).',
      },
    },
    'required': ['action'],
  },
};

/// 注册 goal 工具。
void registerGoalTool({GoalStore? store}) {
  goalStore = store ?? goalStore;
  registry.register(
    name: 'goal',
    toolset: 'memory',
    schema: goalSchema,
    handler: (args, [kwargs]) {
      return goalTool(
        action: args['action'] as String?,
        objective: args['objective'] as String?,
        goalId: args['goal_id'] as int?,
        phase: args['phase'] as String?,
        blockedReason: args['blocked_reason'] as String?,
        maxRounds: args['max_rounds'] as int?,
        evidenceObj: args['evidence_obj'] as String?,
        store: goalStore,
      );
    },
    checkFn: () => goalStore != null,
    isAsync: true,
    emoji: '🎯',
  );
}
