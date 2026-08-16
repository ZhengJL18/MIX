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
  ///   注入成功的记录 `activated` 正证据；
  /// - trivial-prompt 门控（Hermes）：寒暄类消息跳过检索（省成本）。
  Future<String> prefetchRecall(String query) async {
    final base = buildSystemPromptMemory();
    final db = memoryDb;
    if (db == null) return base;
    final q = query.trim();
    if (q.isEmpty) return base;
    if (isTrivialPrompt(q)) return base; // "hi/thanks/ok" 不触发检索。
    try {
      // 1. 热词定位种子（FTS5 bm25 / LIKE 降级）。
      final rows = await db.searchMemories(q, limit: 5);
      if (rows.isEmpty) return base;
      // 2. 图扩散激活（v4 §6.2）：沿联想边带出跨词关联文档。
      //    打分：种子按检索序（bm25 优先），邻居按激活能量；
      //    合并取 top-k（token 预算）。
      final seedIds = [for (final r in rows) r['id'] as int];
      final spread = await db.spreadActivate(seedIds, limit: 12);
      // 候选排序：种子（检索命中，分数随序递减）> 邻居（激活能量）。
      final scored = <(int, double)>[];
      for (var i = 0; i < rows.length; i++) {
        scored.add((rows[i]['id'] as int, 1.0 - 0.05 * i));
      }
      final seedSet = seedIds.toSet();
      for (final s in spread) {
        final sid = s['id'] as int;
        if (seedSet.contains(sid)) continue; // 种子已计分。
        scored.add((sid, (s['energy'] as num).toDouble()));
      }
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      final top = scored.take(8).toList();

      final confidence = MemoryConfidence(db);
      final parts = <String>[];
      for (final (id, score) in top) {
        // 置信度门控：可靠度过低（可能过时）跳过。
        final cs = await confidence.score('doc', id);
        if (!confidence.shouldInject(cs)) continue;
        final doc = await db.getDoc(id);
        if (doc == null) continue;
        final summary = await db.getSummary(id);
        final raw = summary?['summary'] as String? ??
            (doc['content'] as String? ?? '');
        final snippet = raw.length > 300
            ? '${raw.substring(0, 300)}…'
            : raw;
        final tag = seedSet.contains(id)
            ? '🔍' // 热词命中。
            : '🔗'; // 联想扩散带出。
        parts.add('$tag ${doc['title']}（${doc['kind']}）: $snippet');
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

/// trivial-prompt 门控（Hermes turn_context.py 的 trivial-prompt 判断）：
/// 寒暄/确认类短消息跳过记忆检索（省 LLM/DB 成本，对齐 Hermes 行为）。
bool isTrivialPrompt(String message) {
  final m = message.trim().toLowerCase();
  if (m.isEmpty) return true;
  if (m.length > 24) return false; // 长消息一定是实质内容。
  // 纯寒暄/确认/语气词。
  const trivial = <String>{
    'hi', 'hello', 'hey', 'ok', 'okay', 'thanks', 'thank you', 'thx',
    'yes', 'no', 'bye', 'good', 'great', 'nice', 'sure', 'done',
    '好的', '好', '嗯', '哦', '嗯嗯', '谢谢', '多谢', '感谢', '可以', '行',
    '知道了', '明白', '没问题', '再见', '早上好', '晚安', '在吗',
  };
  if (trivial.contains(m)) return true;
  // 纯 emoji/标点。
  return RegExp(r'^[\s\p{Emoji}\p{P}\p{S}]+$', unicode: true).hasMatch(m);
}
