/// memory_verify 工具（DSH 启示 5，v4 设计稿 §7.5 记忆时点对账）。
///
/// 记忆是时点快照：引用外部状态（GitHub/服务器/学习进度）前应先对账。
/// - `check`：查对象可靠度（置信度引擎）+ 证据统计，判断是否需要验证；
/// - `verify`：对账确认 → 写 `verified` 正证据（可靠度上升）；
/// - `stale`：发现过时 → 写 `stale` 负证据（可靠度下降，提醒更新）。
///
/// 对账结果写回证据 → 更新可靠度 → "越用越可信"闭环（v4 §6）。
library;

import 'dart:convert';

import '../services/memory_confidence.dart';
import '../services/memory_db.dart';
import 'registry.dart';

/// memory_verify 工具 handler。
Future<String> memoryVerifyTool({
  String? action,
  String? objType,
  int? objId,
  int? docId,
  MemoryDB? db,
}) async {
  if (db == null) {
    return toolError('Memory database not available');
  }
  final act = action?.trim() ?? 'check';
  // 定位对象：docId 快捷方式 → objType='doc'。
  final oType = objType ?? (docId != null ? 'doc' : null);
  final oId = objId ?? docId;
  if (oType == null || oId == null) {
    return toolError(
        'memory_verify: need obj_type+obj_id (or doc_id), and action '
        '(check|verify|stale)');
  }
  try {
    final confidence = MemoryConfidence(db);
    final cs = await confidence.score(oType, oId);
    switch (act) {
      case 'check':
        return jsonEncode({
          'success': true,
          'obj_type': oType,
          'obj_id': oId,
          'confidence': cs.confidence,
          'freshness': cs.freshness,
          'reliability': cs.reliability,
          'positive': cs.positive,
          'negative': cs.negative,
          'age_seconds': cs.ageSeconds,
          'needs_verify': cs.negative > 0 || cs.ageSeconds > 7 * 24 * 3600,
        });

      case 'verify':
        await db.addEvidence(oType, oId, 'verified');
        final cs2 = await confidence.score(oType, oId);
        return jsonEncode({
          'success': true,
          'action': 'verify',
          'obj_type': oType,
          'obj_id': oId,
          'confidence': cs2.confidence,
          'message': 'Marked verified. Reliability updated.',
        });

      case 'stale':
        await db.addEvidence(oType, oId, 'stale');
        final cs2 = await confidence.score(oType, oId);
        return jsonEncode({
          'success': true,
          'action': 'stale',
          'obj_type': oType,
          'obj_id': oId,
          'confidence': cs2.confidence,
          'message': 'Marked stale. Consider updating this memory.',
        });

      default:
        return toolError(
            "memory_verify: unknown action '$act'. Use: check, verify, stale");
    }
  } catch (e) {
    return toolError('memory_verify failed: $e');
  }
}

/// memory_verify 工具 schema。
const Map<String, dynamic> memoryVerifySchema = {
  'name': 'memory_verify',
  'description':
      'Reconcile memory snapshots against current reality (v4 time-point '
      'principle). check: report confidence/reliability of a memory object '
      '(doc/knowledge/fact) and whether it needs verification. verify: mark '
      'confirmed (positive evidence). stale: mark outdated (negative evidence, '
      'lowers reliability). Use before citing stale-prone facts (GitHub state, '
      'server status, learning progress).',
  'parameters': {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['check', 'verify', 'stale'],
        'description': 'check (default) / verify / stale.',
      },
      'obj_type': {
        'type': 'string',
        'enum': ['doc', 'knowledge', 'fact', 'goal'],
        'description': 'Object type.',
      },
      'obj_id': {
        'type': 'integer',
        'description': 'Object id.',
      },
      'doc_id': {
        'type': 'integer',
        'description': 'Shorthand: verify a memory document (obj_type=doc).',
      },
    },
  },
};

/// 注册 memory_verify 工具。
void registerMemoryVerifyTool({MemoryDB? db}) {
  memoryVerifyDb = db ?? memoryVerifyDb;
  registry.register(
    name: 'memory_verify',
    toolset: 'memory',
    schema: memoryVerifySchema,
    handler: (args, [kwargs]) {
      return memoryVerifyTool(
        action: args['action'] as String?,
        objType: args['obj_type'] as String?,
        objId: args['obj_id'] as int?,
        docId: args['doc_id'] as int?,
        db: memoryVerifyDb,
      );
    },
    checkFn: () => memoryVerifyDb != null,
    isAsync: true,
    emoji: '🛡️',
  );
}

/// 全局记忆库引用（main.dart 初始化，与 memory_search_tool 共用实例）。
MemoryDB? memoryVerifyDb;
