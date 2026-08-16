/// 记忆库（v4 设计稿 §3/§4/§6）。
///
/// 多记忆文档 + 确定性图建构的存储层。**sqlite3 3.x 自带 SQLite（编译含
/// SQLITE_ENABLE_FTS5）**——v4 设计稿 §2 方案 A：Android 系统 SQLite 从未
/// 启用 FTS5（AOSP 铁证），sqflite 走系统库导致 FTS5 真机不可用；memory.db
/// 独立用 sqlite3 3.x 捆绑 SQLite，FTS5 稳定可用。
///
/// 表：memory_docs / memory_tags / memory_links / memory_doc_summaries /
/// memory_evidence / goals / async_delegations + memory_docs_fts。
///
/// ## FTS 策略（v4 §7 + 嵌入式搜索引擎调研）
/// - 不用 external-content 触发器（触发器里无法跑 Dart 分词）→ 普通 FTS5 表，
///   由代码在 upsertDoc/deleteDoc 时同步分词列。
/// - 中文：写入/查询两侧都用 dart_jieba 分词后空格连接（unicode61 对连续汉字
///   只出一个 token，必须预分词）。
/// - 排序：FTS5 原生 `bm25()`（负分，越小越相关，ORDER BY ASC）。
/// - LIKE 降级保留（极端兜底）。
library;

import 'package:sqlite3/sqlite3.dart';

import '../utils/levenshtein.dart';
import 'chinese_segmenter.dart';

/// 记忆库（sqlite3 3.x 自带 FTS5）。
class MemoryDB {
  Database? _db;
  final String dbPath;
  bool _closed = false;
  bool _ftsAvailable = false;

  MemoryDB({required this.dbPath});

  Database get db {
    if (_db == null) {
      throw StateError('MemoryDB not initialized — call init() first');
    }
    return _db!;
  }

  /// FTS5 是否可用（sqlite3 3.x 自带，应为 true；失败才降级 LIKE）。
  bool get ftsAvailable => _ftsAvailable;

  /// 打开数据库（sqlite3 3.x 自带 SQLite，建表 + FTS）。
  Future<void> init() async {
    try {
      final db = sqlite3.open(dbPath);
      _db = db;
      db.execute('PRAGMA foreign_keys = ON');
      _createSchema(db);
      _ensureFts(db);
    } catch (_) {
      _db = null;
      rethrow;
    }
  }

  void _createSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS memory_docs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT UNIQUE NOT NULL,
        title TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'memory',
        content TEXT NOT NULL DEFAULT '',
        mtime INTEGER NOT NULL,
        frozen_snapshot TEXT,
        importance REAL NOT NULL DEFAULT 0.5
      )
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_memory_docs_kind ON memory_docs(kind)');
    db.execute('''
      CREATE TABLE IF NOT EXISTS memory_tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doc_id INTEGER NOT NULL REFERENCES memory_docs(id) ON DELETE CASCADE,
        tag TEXT NOT NULL,
        score REAL NOT NULL DEFAULT 1.0,
        UNIQUE(doc_id, tag)
      )
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_memory_tags_tag ON memory_tags(tag)');
    db.execute('''
      CREATE TABLE IF NOT EXISTS memory_links (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        src INTEGER NOT NULL REFERENCES memory_docs(id) ON DELETE CASCADE,
        dst INTEGER NOT NULL REFERENCES memory_docs(id) ON DELETE CASCADE,
        kind TEXT NOT NULL DEFAULT 'tag',
        weight REAL NOT NULL DEFAULT 1.0,
        UNIQUE(src, dst, kind)
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS memory_doc_summaries (
        doc_id INTEGER PRIMARY KEY REFERENCES memory_docs(id) ON DELETE CASCADE,
        summary TEXT NOT NULL,
        doc_mtime INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS memory_evidence (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        obj_type TEXT NOT NULL,
        obj_id INTEGER NOT NULL,
        evidence TEXT NOT NULL,
        ts REAL NOT NULL
      )
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_evidence_obj ON memory_evidence(obj_type, obj_id)');
    // Goal 系统（DSH 启示 1，v4 §3）：持久目标 + 自动续跑。
    db.execute('''
      CREATE TABLE IF NOT EXISTS goals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        objective TEXT NOT NULL,
        revision INTEGER NOT NULL DEFAULT 1, -- 乐观锁
        phase TEXT NOT NULL DEFAULT 'active', -- active|paused|blocked|done
        rounds INTEGER NOT NULL DEFAULT 0,   -- 已续跑轮次
        max_rounds INTEGER,
        blocked_reason TEXT,
        evidence_obj TEXT,                   -- 关联证据对象（如 knowledge:3）
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
      )
    ''');
    // 异步委派（DSH 启示 2，Hermes async_delegations 表补全）。
    db.execute('''
      CREATE TABLE IF NOT EXISTS async_delegations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_session_id TEXT,
        task TEXT NOT NULL,
        model TEXT,
        status TEXT NOT NULL DEFAULT 'running', -- running|done|failed|cancelled
        result TEXT,
        created_at REAL NOT NULL,
        finished_at REAL
      )
    ''');
  }

  /// FTS5 建表（普通表，代码同步分词列）。sqlite3 3.x 自带 FTS5 → 应成功。
  void _ensureFts(Database db) {
    try {
      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_docs_fts USING fts5(
          title_seg, content_seg, tags_seg
        )
      ''');
      _ftsAvailable = true;
    } catch (_) {
      _ftsAvailable = false;
    }
  }

  /// 全量重建 FTS 索引（迁移/历史数据补索引用）。
  ///
  /// 场景：旧库（sqflite 时代系统 SQLite 无 FTS5）→ memory_docs_fts 从未建成；
  /// 迁 sqlite3 3.x 后建表成功但**存量文档没有 FTS 行**——检索命中全靠 LIKE。
  /// 启动时调用一次把存量文档补进 FTS。文档量小（个人记忆库数百篇），
  /// 逐篇 _syncFts 即可（毫秒~秒级）。
  Future<void> rebuildFts() async {
    if (!_ftsAvailable) return;
    try {
      final docs = _query(
        'SELECT id, title, content FROM memory_docs',
      );
      for (final d in docs) {
        _syncFts(d['id'] as int, d['title'] as String, d['content'] as String);
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------------
  // 查询辅助（Row → Map）
  // ------------------------------------------------------------------

  /// SELECT 查询 → List<Map<String, dynamic>>。
  List<Map<String, dynamic>> _query(String sql, [List<Object?> args = const []]) {
    final result = db.select(sql, args);
    final cols = result.columnNames;
    return [
      for (final row in result)
        {for (final c in cols) c: row[c]},
    ];
  }

  // ------------------------------------------------------------------
  // 文档 CRUD（FTS 同步）
  // ------------------------------------------------------------------

  /// 新增或更新记忆文档。内容变化时同步分词列进 FTS。
  ///
  /// [mtime] 可指定外部时间戳（如文件 mtime，供增量同步比对）；
  /// 缺省用当前时间。
  Future<int> upsertDoc({
    required String path,
    required String title,
    String content = '',
    String kind = 'memory',
    double importance = 0.5,
    String? frozenSnapshot,
    int? mtime,
  }) async {
    final now = mtime ?? DateTime.now().millisecondsSinceEpoch;
    final existing = _query(
      'SELECT id FROM memory_docs WHERE path = ? LIMIT 1',
      [path],
    );
    final int id;
    if (existing.isEmpty) {
      db.execute(
        'INSERT INTO memory_docs'
        '(path, title, kind, content, mtime, frozen_snapshot, importance) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [path, title, kind, content, now, frozenSnapshot, importance],
      );
      id = db.lastInsertRowId;
    } else {
      id = existing.first['id'] as int;
      db.execute(
        'UPDATE memory_docs SET title = ?, kind = ?, content = ?, mtime = ?, '
        'frozen_snapshot = ?, importance = ? WHERE id = ?',
        [title, kind, content, now, frozenSnapshot, importance, id],
      );
    }
    _syncFts(id, title, content);
    return id;
  }

  /// 更新文档重要度（置信度引擎 P1 用）。
  Future<void> updateImportance(int docId, double importance) async {
    db.execute(
      'UPDATE memory_docs SET importance = ? WHERE id = ?',
      [importance, docId],
    );
  }

  /// 删除文档（手动清理关联；FTS 同步删除）。
  Future<void> deleteDoc(int id) async {
    db.execute(
      'DELETE FROM memory_evidence WHERE obj_type = ? AND obj_id = ?',
      ['doc', id],
    );
    db.execute('DELETE FROM memory_doc_summaries WHERE doc_id = ?', [id]);
    db.execute('DELETE FROM memory_tags WHERE doc_id = ?', [id]);
    db.execute('DELETE FROM memory_links WHERE src = ? OR dst = ?', [id, id]);
    db.execute('DELETE FROM memory_docs WHERE id = ?', [id]);
    if (_ftsAvailable) {
      try {
        db.execute('DELETE FROM memory_docs_fts WHERE rowid = ?', [id]);
      } catch (_) {}
    }
  }

  void _syncFts(int id, String title, String content) {
    if (!_ftsAvailable) return;
    final tags = getTagsSync(id);
    try {
      db.execute('DELETE FROM memory_docs_fts WHERE rowid = ?', [id]);
      final titleSeg = segmentToFts(title);
      final contentSeg = segmentToFts(content);
      final tagsSeg = segmentToFts(tags.join(' '));
      if ((titleSeg ?? '').isNotEmpty ||
          (contentSeg ?? '').isNotEmpty ||
          (tagsSeg ?? '').isNotEmpty) {
        db.execute(
          'INSERT INTO memory_docs_fts(rowid, title_seg, content_seg, tags_seg) '
          'VALUES (?, ?, ?, ?)',
          [id, titleSeg ?? '', contentSeg ?? '', tagsSeg ?? ''],
        );
      }
    } catch (_) {
      // FTS 写入失败不阻塞主流程（检索侧会降级）。
    }
  }

  // ------------------------------------------------------------------
  // 检索
  // ------------------------------------------------------------------

  /// 热词检索记忆文档（v4 §5.1：FTS5 bm25 + OR 连接，LIKE 兜底）。
  ///
  /// 返回按相关度排序的文档。summary 由调用方按需取。
  Future<List<Map<String, dynamic>>> searchMemories(
    String query, {
    int limit = 10,
    String? kind,
  }) async {
    // FTS5 路径：query 分词 → OR 连接 → MATCH → bm25 排序。
    if (_ftsAvailable) {
      try {
        final matchExpr = buildFtsQuery(query);
        if (matchExpr != null && matchExpr.isNotEmpty) {
          var sql = '''
            SELECT d.* FROM memory_docs d
            JOIN memory_docs_fts f ON f.rowid = d.id
            WHERE memory_docs_fts MATCH ?
          ''';
          final args = <Object?>[matchExpr];
          if (kind != null && kind.isNotEmpty) {
            sql += ' AND d.kind = ?';
            args.add(kind);
          }
          sql += ' ORDER BY bm25(memory_docs_fts) ASC LIMIT ?';
          args.add(limit);
          final rows = _query(sql, args);
          if (rows.isNotEmpty) {
            return rows;
          }
          // FTS 无命中 → typo 容错展开（v4 §12：记错名字也能搜到；
          // 在自动标签库里找编辑距离相近的标签 OR 展开）。
          final typoExpr = _expandTypoQuerySync(query);
          if (typoExpr != null && typoExpr != matchExpr) {
            final typoSql = 'SELECT d.* FROM memory_docs d '
                'JOIN memory_docs_fts f ON f.rowid = d.id '
                'WHERE memory_docs_fts MATCH ? '
                'ORDER BY bm25(memory_docs_fts) ASC LIMIT ?';
            final typoRows = _query(typoSql, [typoExpr, limit]);
            if (typoRows.isNotEmpty) {
              return typoRows;
            }
          }
        }
      } catch (_) {
        // FTS 查询失败 → 降级 LIKE。
      }
    }
    // LIKE 兜底（中文子串匹配）。
    final like = '%$query%';
    var sql = 'SELECT * FROM memory_docs WHERE title LIKE ? OR content LIKE ?';
    final args = <Object?>[like, like];
    if (kind != null && kind.isNotEmpty) {
      sql += ' AND kind = ?';
      args.add(kind);
    }
    sql += ' ORDER BY mtime DESC LIMIT ?';
    args.add(limit);
    return _query(sql, args);
  }

  /// typo 容错展开（v4 §12）：FTS 无命中时，在自动标签库（memory_tags）
  /// 里找与查询词编辑距离 ≤ 容错阈值（词长分级）的相近标签，OR 展开重查。
  String? _expandTypoQuerySync(String query) {
    final words = segmentWords(query);
    if (words.isEmpty) return null;
    List<String> tags;
    try {
      final tagRows = _query('SELECT DISTINCT tag FROM memory_tags');
      tags = [for (final r in tagRows) r['tag'] as String];
    } catch (_) {
      return null;
    }
    if (tags.isEmpty) return null;
    final additions = <String>{};
    for (final w in words) {
      if (w.length < 2) continue; // 单字不展开（易误配）。
      // 2 字词也给 1 错余地（候选来自真实标签库，误配风险低；
      // 专名如"泊松/泊菘" 2 字常被记错）。
      final tol = w.length <= 2 ? 1 : typoTolerance(w.length);
      if (tol == 0) continue;
      for (final t in tags) {
        if ((t.length - w.length).abs() > tol) continue; // 长度差剪枝。
        if (levenshteinDistance(w, t) <= tol) {
          additions.add(t);
        }
      }
    }
    if (additions.isEmpty) return null;
    return buildFtsOrQuery([...words, ...additions]);
  }

  /// 按标签精确检索（P1 扩散激活的种子来源之一）。
  Future<List<Map<String, dynamic>>> searchByTag(
    String tag, {
    int limit = 20,
  }) async {
    return _query(
      '''
      SELECT d.* FROM memory_docs d
      JOIN memory_tags t ON t.doc_id = d.id
      WHERE t.tag = ?
      ORDER BY d.importance DESC, d.mtime DESC
      LIMIT ?
      ''',
      [tag, limit],
    );
  }

  // ------------------------------------------------------------------
  // 标签 / 链接 / 证据 / 摘要
  // ------------------------------------------------------------------

  /// 给文档添加标签（P1 自动标签管线用）。
  Future<void> addTag(int docId, String tag, {double score = 1.0}) async {
    db.execute(
      'INSERT OR REPLACE INTO memory_tags(doc_id, tag, score) VALUES (?, ?, ?)',
      [docId, tag, score],
    );
    // 标签变化 → 同步 FTS（tags_seg）。
    if (_ftsAvailable) {
      final doc = getDocSync(docId);
      if (doc != null) {
        _syncFts(docId, doc['title'] as String, doc['content'] as String);
      }
    }
  }

  /// 移除标签。
  Future<void> removeTag(int docId, String tag) async {
    db.execute(
      'DELETE FROM memory_tags WHERE doc_id = ? AND tag = ?',
      [docId, tag],
    );
  }

  /// 文档全部标签（按 score 降序）。
  Future<List<String>> getTags(int docId) async => getTagsSync(docId);

  List<String> getTagsSync(int docId) {
    final rows = _query(
      'SELECT tag FROM memory_tags WHERE doc_id = ? ORDER BY score DESC',
      [docId],
    );
    return [for (final r in rows) r['tag'] as String];
  }

  /// 建文档间关联边（Hebbian：已存在则 +weight 强化）。
  Future<void> addLink(
    int src,
    int dst, {
    String kind = 'tag',
    double weight = 1.0,
  }) async {
    if (src == dst) return;
    final existing = _query(
      'SELECT id FROM memory_links WHERE src = ? AND dst = ? AND kind = ? '
      'LIMIT 1',
      [src, dst, kind],
    );
    if (existing.isEmpty) {
      db.execute(
        'INSERT INTO memory_links(src, dst, kind, weight) VALUES (?, ?, ?, ?)',
        [src, dst, kind, weight],
      );
    } else {
      // Hebbian 强化：共访问/采纳 → 边权 +weight。
      db.execute(
        'UPDATE memory_links SET weight = weight + ?1 '
        'WHERE src = ?2 AND dst = ?3 AND kind = ?4',
        [weight, src, dst, kind],
      );
    }
  }

  /// 扩散激活（v4 设计稿 §6.2，TAIPANBOX/engram `graph.py` 算法）：
  /// 从种子文档沿 links 图 BFS 扩散，每跳能量衰减
  /// `decay × min(边权, 1.0)`（Hebbian 边权参与）。
  Future<List<Map<String, dynamic>>> spreadActivate(
    List<int> seedIds, {
    int maxDepth = 2,
    double decay = 0.5,
    int limit = 20,
  }) async {
    if (seedIds.isEmpty) return const [];
    final energy = <int, double>{};
    final queue = <(int, int, double)>[
      for (final s in seedIds) (s, 0, 1.0),
    ];
    final visited = <int>{};
    while (queue.isNotEmpty) {
      final (id, hop, e) = queue.removeAt(0);
      if (visited.contains(id)) continue;
      visited.add(id);
      energy[id] = (energy[id] ?? 0) + e;
      if (hop >= maxDepth) continue;
      try {
        final neighbors = getNeighborsSync(id, limit: 20);
        for (final n in neighbors) {
          final nid = n['id'] as int;
          if (visited.contains(nid)) continue;
          final w = (n['link_weight'] as num?)?.toDouble() ?? 1.0;
          final next = e * decay * w.clamp(0.0, 1.0);
          if (next > 0.01) {
            queue.add((nid, hop + 1, next));
          }
        }
      } catch (_) {
        continue;
      }
    }
    final sorted = energy.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final e in sorted.take(limit)) {'id': e.key, 'energy': e.value},
    ];
  }

  /// 目标文档的直接邻居（P1 扩散激活用）。
  Future<List<Map<String, dynamic>>> getNeighbors(
    int docId, {
    String? kind,
    int limit = 20,
  }) async =>
      getNeighborsSync(docId, kind: kind, limit: limit);

  List<Map<String, dynamic>> getNeighborsSync(
    int docId, {
    String? kind,
    int limit = 20,
  }) {
    var sql = '''
      SELECT d.*, l.kind AS link_kind, l.weight AS link_weight
      FROM memory_links l
      JOIN memory_docs d ON d.id = CASE WHEN l.src = ? THEN l.dst ELSE l.src END
      WHERE l.src = ? OR l.dst = ?
    ''';
    final args = <Object?>[docId, docId, docId];
    if (kind != null && kind.isNotEmpty) {
      sql += ' AND l.kind = ?';
      args.add(kind);
    }
    sql += ' ORDER BY l.weight DESC LIMIT ?';
    args.add(limit);
    return _query(sql, args);
  }

  /// 记录证据事件（置信度引擎痕迹层）。
  Future<void> addEvidence(
    String objType,
    int objId,
    String evidence,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    db.execute(
      'INSERT INTO memory_evidence(obj_type, obj_id, evidence, ts) '
      'VALUES (?, ?, ?, ?)',
      [objType, objId, evidence, now],
    );
  }

  /// 写摘要（激活即总结，P2 用）。
  Future<void> upsertSummary(
    int docId,
    String summary,
    int docMtime,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      'INSERT OR REPLACE INTO memory_doc_summaries'
      '(doc_id, summary, doc_mtime, updated_at) VALUES (?, ?, ?, ?)',
      [docId, summary, docMtime, now],
    );
  }

  /// 读摘要。文档 mtime 变更后摘要视为 stale（返回 null）。
  Future<Map<String, dynamic>?> getSummary(int docId) async {
    final rows = _query(
      'SELECT * FROM memory_doc_summaries WHERE doc_id = ? LIMIT 1',
      [docId],
    );
    if (rows.isEmpty) return null;
    final summary = rows.first;
    final doc = getDocSync(docId);
    if (doc == null) return null;
    final docMtime = doc['mtime'] as int? ?? 0;
    final summaryMtime = summary['doc_mtime'] as int? ?? 0;
    if (docMtime != summaryMtime) return null; // stale
    return {
      'summary': summary['summary'],
      'updated_at': summary['updated_at'],
    };
  }

  /// 按 id 读文档。
  Future<Map<String, dynamic>?> getDoc(int id) async => getDocSync(id);

  Map<String, dynamic>? getDocSync(int id) {
    final rows = _query(
      'SELECT * FROM memory_docs WHERE id = ? LIMIT 1',
      [id],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 最近文档列表。
  Future<List<Map<String, dynamic>>> listDocs({
    int limit = 20,
    String? kind,
  }) async {
    var sql = 'SELECT * FROM memory_docs';
    final args = <Object?>[];
    if (kind != null && kind.isNotEmpty) {
      sql += ' WHERE kind = ?';
      args.add(kind);
    }
    sql += ' ORDER BY mtime DESC LIMIT ?';
    args.add(limit);
    return _query(sql, args);
  }

  /// 关闭数据库。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_db != null) {
      _db!.dispose();
      _db = null;
    }
  }
}
