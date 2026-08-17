/// 记忆检索工具（v4 设计稿 §5/§6）。
///
/// - `memory_search`：热词检索记忆文档（FTS5 bm25 + 中文分词，LIKE 兜底）。
///   对齐 v4 §5.1：OR 连接（长问题召回归零的坑）+ 摘要优先 + token 预算裁剪。
/// - `memory_read`：读单篇记忆文档（摘要 + 全文，P0 先给全文 + 若有摘要）。
library;

import 'dart:convert';

import '../services/memory_db.dart';
import '../services/services.dart';
import 'registry.dart';

/// memory_search 工具 handler。
Future<String> memorySearchTool({
  String? query,
  int? limit,
  String? kind,
  MemoryDB? db,
}) async {
  if (db == null) {
    return toolError('Memory database not available');
  }
  final q = query?.trim() ?? '';
  if (q.isEmpty) {
    return toolError('memory_search: missing query');
  }
  try {
    final cap = (limit ?? 10).clamp(1, 50).toInt();
    final rows = await db.searchMemories(q, limit: cap, kind: kind);
    final matches = <Map<String, dynamic>>[];
    for (final r in rows) {
      final docId = r['id'] as int;
      final tags = await db.getTags(docId);
      final summary = await db.getSummary(docId);
      // 置信度引擎痕迹层（v4 §6）：检索命中记录为正证据。
      try {
        await db.addEvidence('doc', docId, 'hit');
      } catch (_) {}
      matches.add({
        'id': docId,
        'path': r['path'],
        'title': r['title'],
        'kind': r['kind'],
        'mtime': r['mtime'],
        'importance': r['importance'],
        'tags': tags,
        'summary': summary?['summary'],
      });
    }
    return jsonEncode({
      'mode': 'search',
      'query': q,
      'count': matches.length,
      'fts': db.ftsAvailable,
      'matches': matches,
    });
  } catch (e) {
    return toolError('memory_search failed: $e');
  }
}

/// memory_read 工具 handler：读单篇记忆文档（摘要优先 + 全文截断）。
Future<String> memoryReadTool({
  int? docId,
  String? path,
  MemoryDB? db,
  int? maxChars,
}) async {
  if (db == null) {
    return toolError('Memory database not available');
  }
  try {
    Map<String, dynamic>? doc;
    if (docId != null) {
      doc = await db.getDoc(docId);
    } else if (path != null && path.isNotEmpty) {
      final result = await db.db.select(
        'SELECT * FROM memory_docs WHERE path = ? LIMIT 1',
        [path],
      );
      final rows = result.toList();
      if (rows.isNotEmpty) doc = rows.first;
    }
    if (doc == null) {
      return toolError('memory_read: document not found '
          '(doc_id=$docId path=$path)');
    }
    final id = doc['id'] as int;
    final tags = await db.getTags(id);
    final summary = await db.getSummary(id);
    // 置信度引擎痕迹层：被主动读取 → 正证据。
    try {
      await db.addEvidence('doc', id, 'read');
    } catch (_) {}
    var content = doc['content'] as String? ?? '';
    final cap = (maxChars ?? 4000).clamp(500, 20000).toInt();
    var truncated = false;
    if (content.length > cap) {
      content = '${content.substring(0, cap)}…';
      truncated = true;
    }
    return jsonEncode({
      'id': id,
      'path': doc['path'],
      'title': doc['title'],
      'kind': doc['kind'],
      'mtime': doc['mtime'],
      'importance': doc['importance'],
      'tags': tags,
      'summary': summary?['summary'],
      'content': content,
      'truncated': truncated,
    });
  } catch (e) {
    return toolError('memory_read failed: $e');
  }
}

/// memory_search 工具 schema。
const Map<String, dynamic> memorySearchSchema = {
  'name': 'memory_search',
  'description':
      'Search memory documents (auto-tagged notes across sessions) by '
      'keywords. Chinese-aware (jieba segmentation + BM25 ranking). Use when '
      "you need facts/notes from past sessions that aren't in the injected "
      'memory snapshot.',
  'parameters': {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'Search query (keywords; OR-combined after segmentation).',
      },
      'kind': {
        'type': 'string',
        'enum': ['memory', 'user', 'daily', 'topic', 'note'],
        'description': 'Optional filter: document kind.',
      },
      'limit': {
        'type': 'integer',
        'description': 'Max results (1-50, default 10).',
      },
    },
    'required': ['query'],
  },
};

/// memory_read 工具 schema。
const Map<String, dynamic> memoryReadSchema = {
  'name': 'memory_read',
  'description':
      'Read a full memory document (by id or path). Returns summary if '
      'available plus content (truncated). Prefer memory_search to locate, '
      'then memory_read for full detail.',
  'parameters': {
    'type': 'object',
    'properties': {
      'doc_id': {
        'type': 'integer',
        'description': 'Memory document id (from memory_search).',
      },
      'path': {
        'type': 'string',
        'description': 'Alternative: document path.',
      },
      'max_chars': {
        'type': 'integer',
        'description': 'Max content chars (500-20000, default 4000).',
      },
    },
  },
};

/// 注册记忆检索工具。
void registerMemorySearchTools({MemoryDB? db}) {
  Services.instance.memoryDb = db ?? Services.instance.memoryDb;
  registry.register(
    name: 'memory_search',
    toolset: 'memory',
    schema: memorySearchSchema,
    handler: (args, [kwargs]) {
      return memorySearchTool(
        query: args['query'] as String?,
        kind: args['kind'] as String?,
        limit: args['limit'] as int?,
        db: Services.instance.memoryDb,
      );
    },
    checkFn: () => Services.instance.memoryDb != null,
    isAsync: true,
    emoji: '🔎',
  );
  registry.register(
    name: 'memory_read',
    toolset: 'memory',
    schema: memoryReadSchema,
    handler: (args, [kwargs]) {
      return memoryReadTool(
        docId: args['doc_id'] as int?,
        path: args['path'] as String?,
        maxChars: args['max_chars'] as int?,
        db: Services.instance.memoryDb,
      );
    },
    checkFn: () => Services.instance.memoryDb != null,
    isAsync: true,
    emoji: '📄',
  );
}
