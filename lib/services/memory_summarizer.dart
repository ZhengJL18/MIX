/// 摘要层（v4 设计稿 §9：激活即总结，两级存储）。
///
/// 对"激活过但缺摘要"的记忆文档批量生成 ≤100 字摘要，写入
/// `memory_doc_summaries`。检索/预取注入时摘要优先（snippet 模式，
/// 已由 memory_search / prefetchRecall 支持）。
///
/// - **只总结被激活的内容**（有 activated/hit/read 证据），非全库——LLM 成本可控；
/// - **原文永远是权威**：摘要独立存储，不覆盖存档、不进 FTS、不参与排序；
/// - **stale 处理**：文档 mtime 变化后摘要失效（getSummary 已判 stale），
///   重跑 summarizeActivated 会重新生成。
/// - LLM 通过注入的 [summarizeFn] 接入（main.dart 用快模型），服务本身零依赖。
library;

import 'memory_db.dart';

/// 摘要生成函数（由调用方注入 LLM）：输入标题+内容，返回 ≤100 字摘要；
/// 失败返回 null（跳过该篇）。
typedef SummarizeFn = Future<String?> Function(String title, String content);

/// 摘要生成服务。
class MemorySummarizer {
  final MemoryDB db;
  final SummarizeFn? summarizeFn;

  /// 单批最大处理篇数（LLM 成本预算）。
  final int batchLimit;

  MemorySummarizer({
    required this.db,
    this.summarizeFn,
    this.batchLimit = 5,
  });

  /// 对激活过但缺有效摘要的文档批量生成摘要。返回成功生成条数。
  ///
  /// 候选：有 activated/hit/read 证据、非 knowledge 文档、无摘要或摘要 stale。
  Future<int> summarizeActivated() async {
    final fn = summarizeFn;
    if (fn == null) return 0;
    final docs = await _candidates(batchLimit);
    var done = 0;
    for (final doc in docs) {
      try {
        final id = doc['id'] as int;
        final title = doc['title'] as String;
        final content = doc['content'] as String? ?? '';
        if (content.trim().isEmpty) continue;
        final summary = await fn(title, content);
        if (summary == null || summary.trim().isEmpty) continue;
        final mtime = doc['mtime'] as int? ?? 0;
        // 只保留 ≤160 字（snippet 预算，设计稿 §9 ≤100 字 + 余量）。
        final clipped = summary.trim().length > 160
            ? '${summary.trim().substring(0, 160)}…'
            : summary.trim();
        await db.upsertSummary(id, clipped, mtime);
        done++;
      } catch (_) {
        continue; // 单篇失败不中断整批。
      }
    }
    return done;
  }

  /// 候选文档：激活过 + 非 knowledge + （无摘要 或 摘要 stale）。
  Future<List<Map<String, dynamic>>> _candidates(int limit) async {
    try {
      final result = await db.db.select(
        '''
        SELECT DISTINCT d.* FROM memory_docs d
        JOIN memory_evidence e ON e.obj_id = d.id
        WHERE e.obj_type = 'doc'
          AND e.evidence IN ('activated', 'hit', 'read')
          AND d.kind != 'knowledge'
          AND TRIM(d.content) != ''
          AND d.id NOT IN (
            SELECT s.doc_id FROM memory_doc_summaries s
            WHERE s.doc_mtime = d.mtime
          )
        ORDER BY d.mtime DESC
        LIMIT ?
        ''',
        [limit],
      );
      final cols = result.columnNames;
      return [
        for (final r in result) {for (final c in cols) c: r[c]},
      ];
    } catch (_) {
      return const [];
    }
  }
}
