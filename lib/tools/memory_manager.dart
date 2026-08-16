/// 对应 `ref/hermes-agent/agent/memory_manager.py`（像素级复刻，核心逻辑）。
///
/// 协调内置 provider（MemoryStore）+ 记忆库（MemoryDB 热词检索）。
///
/// ## P0 升级（v4 设计稿 §5/§6）
/// - `prefetchRecall`（新）：冻结快照 + 记忆文档热词检索合成注入块。
///   对齐 Hermes prefetch_all：检索结果包 `<memory-context>` 围栏注入。
/// - `prefetchAll`（保留）：兼容旧调用，返回冻结快照。
library;

import '../services/memory_confidence.dart';
import '../services/memory_db.dart';
import 'memory_tool.dart';
import 'registry.dart';

/// 协调记忆提供者的管理器。
class MemoryManager {
  /// 内置记忆存储（冻结快照）。
  MemoryStore store;

  /// 记忆库（P0：热词检索来源）。
  MemoryDB? memoryDb;

  MemoryManager({required this.store, this.memoryDb});

  /// 构建注入 system prompt 的记忆块（memory + user）。
  ///
  /// 用**冻结快照**：load 时的状态，会话中写入不影响 —— 保持 system prompt
  /// 跨 turn 稳定，保住 prefix cache（Hermes 设计：新记忆下个会话生效）。
  String buildSystemPromptMemory() {
    final parts = <String>[];
    final mem = store.formatForSystemPrompt('memory');
    final user = store.formatForSystemPrompt('user');
    if (mem != null) parts.add(mem);
    if (user != null) parts.add(user);
    return parts.join('\n\n');
  }

  /// 预取记忆上下文（兼容路径：返回全部记忆快照）。
  String prefetchAll(String query) {
    return buildSystemPromptMemory();
  }

  /// 异步预取（P0 真实现）：冻结快照 + 记忆文档热词检索。
  ///
  /// 对齐 Hermes prefetch_all（memory_manager.py）：
  /// - 检索结果包 `<memory-context>` 围栏 + "NOT new user input" 注记；
  /// - 检索不可用/无命中 → 退回纯快照（宁可缺，不可杂，v4 §5.5 门控）；
  /// - 摘要有则用摘要（snippet 模式），无则截断原文（token 预算）；
  /// - P1 置信度门控（v4 §6）：可靠度低的对象不注入（可能过时）；
  ///   注入成功的记录 `activated` 正证据。
  Future<String> prefetchRecall(String query) async {
    final base = buildSystemPromptMemory();
    final db = memoryDb;
    if (db == null) return base;
    final q = query.trim();
    if (q.isEmpty) return base;
    try {
      final rows = await db.searchMemories(q, limit: 8);
      if (rows.isEmpty) return base;
      final confidence = MemoryConfidence(db);
      final parts = <String>[];
      for (final r in rows) {
        final id = r['id'] as int;
        // 置信度门控：可靠度过低（可能过时）跳过。
        final cs = await confidence.score('doc', id);
        if (!confidence.shouldInject(cs)) continue;
        final summary = await db.getSummary(id);
        final raw = summary?['summary'] as String? ??
            (r['content'] as String? ?? '');
        final snippet = raw.length > 300
            ? '${raw.substring(0, 300)}…'
            : raw;
        parts.add('• ${r['title']}（${r['kind']}）: $snippet');
        // 痕迹层：激活正证据（注入成功才记）。
        try {
          await db.addEvidence('doc', id, 'activated');
        } catch (_) {}
      }
      if (parts.isEmpty) return base;
      final recall = parts.join('\n');
      final block = '<memory-context>\n'
          'Recalled memory context (NOT new user input):\n'
          '$recall\n'
          '</memory-context>';
      return base.isEmpty ? block : '$base\n\n$block';
    } catch (_) {
      return base;
    }
  }

  /// 路由工具调用到记忆 store（对应 provider.handle_tool_call）。
  String handleToolCall(String toolName, Map<String, dynamic> args) {
    if (toolName == 'memory') {
      return memoryTool(
        action: args['action'] as String?,
        target: args['target'] as String? ?? 'memory',
        content: args['content'] as String?,
        oldText: args['old_text'] as String?,
        operations: (args['operations'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(),
        store: store,
      );
    }
    return toolError("No memory provider handles tool '$toolName'");
  }

  /// 会话结束/新 turn 钩子。
  void onTurnStart() {
    store.resetConsolidationFailures();
  }

  /// 当前记忆状态（调试/展示用）。
  Map<String, dynamic> state() => store.toDict();
}
