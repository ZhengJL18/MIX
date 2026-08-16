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
    final hotwords = tagger.extractHotwords(content, topK: 5);
    if (hotwords.isEmpty) return;
    for (final hw in hotwords) {
      await db.addTag(docId, hw.word, score: hw.score);
      // 同标签已有文档 → 互连（Hebbian）。
      final peers = await db.searchByTag(hw.word, limit: 20);
      for (final peer in peers) {
        final peerId = peer['id'] as int;
        if (peerId != docId) {
          await db.addLink(docId, peerId, kind: 'tag', weight: 0.5);
        }
      }
    }
  }

  /// 知识层级边：内容包含知识点名 → 连到知识点文档。
  Future<void> _linkKnowledge(int docId, String text) async {
    final engine = studyEngine;
    if (engine == null) return;
    try {
      final kps = await engine.listKps();
      for (final kp in kps) {
        if (kp.name.isNotEmpty && text.contains(kp.name)) {
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
}
