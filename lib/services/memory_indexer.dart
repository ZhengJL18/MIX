/// 记忆索引器（v4 设计稿 §5 确定性图建构）。
///
/// P1 核心：把 agent 写入的记忆内容自动索引进记忆网——
/// 1. **自动标签**：热词提取（MemoryTagger）→ memory_tags（一对多衔接）；
/// 2. **标签互连**：同标签文档间建 `kind='tag'` 边（Hebbian 强化）；
/// 3. **知识层级边**：内容包含知识点名 → 连到知识点文档
///    （`kind='knowledge'` 行，path=`knowledge://<id>`），扩散沿
///    subjects→knowledge_points 层级走。
///
/// 全部确定性、零 LLM。写路径 fire-and-forget（不阻塞 agent 回合）。
library;

import 'chinese_segmenter.dart';
import 'memory_db.dart';
import 'memory_tagger.dart';
import 'study_engine.dart';

/// 知识点在记忆库中的文档 path 前缀。
const String kKnowledgeDocPathPrefix = 'knowledge://';

/// 记忆索引器。
class MemoryIndexer {
  final MemoryDB db;
  final MemoryTagger tagger;
  final StudyEngine? studyEngine;

  MemoryIndexer({
    required this.db,
    required this.tagger,
    this.studyEngine,
  });

  /// 索引一段新内容：upsert 记忆文档 → 自动标签 → 标签互连 → 知识点边。
  ///
  /// [path] 稳定标识（同 path 重复索引会更新而非重复插入）。
  /// [title] 文档标题（用于 FTS 标题检索）。
  /// [kind] 文档类型（memory/daily/topic...）。
  /// [mtime] 外部时间戳（文件 mtime 等，供增量同步）。
  /// 返回文档 id；失败返回 null（不抛，写路径容错）。
  Future<int?> indexEntry({
    required String path,
    required String title,
    required String content,
    String kind = 'memory',
    int? mtime,
  }) async {
    try {
      // 幂等：同 path 内容未变 → 直接返回已有 id，不重跑标签/连边
      // （防重复索引导致 tag 边权不断 +0.5 膨胀、旧标签残留）。
      final existing = await db.getDocByPath(path);
      if (existing != null && existing['content'] == content) {
        return existing['id'] as int;
      }
      final docId = await db.upsertDoc(
        path: path,
        title: title,
        content: content,
        kind: kind,
        mtime: mtime,
      );
      await _autoTag(docId, content);
      await _linkKnowledge(docId, '$title $content');
      return docId;
    } catch (_) {
      return null;
    }
  }

  /// 自动标签 + 标签互连（v4 §5 表#1：热词 top-k → 标签 → 同标签互连）。
  Future<void> _autoTag(int docId, String content) async {
    // 重索引重建：先清旧标签与旧 tag 边，再按新内容重建
    // （防旧标签残留 + 防同一对文档因 N 个共同标签被累加 N×0.5 膨胀）。
    await db.removeAllTags(docId);
    await db.removeLinksOf(docId, kind: 'tag');
    final hotwords = tagger.extractHotwords(content, topK: 5);
    if (hotwords.isEmpty) return;
    final peerIds = <int>{};
    for (final hw in hotwords) {
      await db.addTag(docId, hw.word, score: hw.score);
      // 同标签已有文档 → 互连（Hebbian）。多个共同标签只连一次。
      final peers = await db.searchByTag(hw.word, limit: 20);
      for (final peer in peers) {
        final peerId = peer['id'] as int;
        if (peerId != docId) peerIds.add(peerId);
      }
    }
    for (final peerId in peerIds) {
      await db.addLink(docId, peerId, kind: 'tag', weight: 0.5);
    }
  }

  /// 知识层级边：内容包含知识点名 → 连到知识点文档。
  Future<void> _linkKnowledge(int docId, String text) async {
    final engine = studyEngine;
    if (engine == null) return;
    try {
      final kps = await engine.listKps();
      // 精确匹配：分词后按独立词匹配 + 名称长度门槛（≥2 字），
      // 防短名知识点（如"极限"）在长文本里大量误连（原 text.contains 全扫）。
      final words = segmentWords(text).toSet();
      for (final kp in kps) {
        if (kp.name.length >= 2 && words.contains(kp.name)) {
          final kpDocId = await _ensureKpDoc(kp);
          if (kpDocId != null && kpDocId != docId) {
            await db.addLink(docId, kpDocId, kind: 'knowledge');
          }
        }
      }
    } catch (_) {}
  }

  /// 知识点 → 记忆库文档行（kind='knowledge'，path='knowledge://<id>'）。
  Future<int?> _ensureKpDoc(KpInfo kp) async {
    try {
      final path = '$kKnowledgeDocPathPrefix${kp.id}';
      // 幂等：已存在则复用（内容固定，无需重写，避免摘要被标 stale）。
      final existing = await db.getDocByPath(path);
      if (existing != null) return existing['id'] as int;
      return await db.upsertDoc(
        path: path,
        title: kp.name,
        content: '知识点：${kp.name}（科目：${kp.subjectName}）',
        kind: 'knowledge',
      );
    } catch (_) {
      return null;
    }
  }

  /// 全量同步知识点为记忆库文档（App 启动/新知识点时调用一次）。
  Future<int> syncKnowledgePoints() async {
    final engine = studyEngine;
    if (engine == null) return 0;
    var count = 0;
    try {
      final kps = await engine.listKps();
      for (final kp in kps) {
        final id = await _ensureKpDoc(kp);
        if (id != null) count++;
      }
    } catch (_) {}
    return count;
  }

  /// 全量强制重建索引（真机验证用）：清掉历史边权膨胀/旧标签残留。
  ///
  /// 跳过 path 以 [kKnowledgeDocPathPrefix] 开头的知识点文档自身；对其余
  /// 每个 doc 强制重建：删旧标签 + 删旧 tag 边 + 热词重建 + 去重互连
  /// （_autoTag）+ 按 title+content 重建知识点边（_linkKnowledge）。
  /// 返回处理文档数。
  Future<int> forceReindexAll() async {
    var count = 0;
    try {
      final result = db.db.select('SELECT * FROM memory_docs');
      final cols = result.columnNames;
      for (final row in result) {
        final doc = {for (final c in cols) c: row[c]};
        final path = doc['path'] as String? ?? '';
        if (path.startsWith(kKnowledgeDocPathPrefix)) continue;
        final docId = doc['id'] as int;
        final content = doc['content'] as String? ?? '';
        await _autoTag(docId, content);
        await _linkKnowledge(docId, '${doc['title'] ?? ''} $content');
        count++;
      }
    } catch (_) {}
    return count;
  }
}
