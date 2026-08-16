/// 记忆库（v4 设计稿 §3/§4/§6）。
///
/// 多记忆文档 + 确定性图建构的存储层，与 session_db 同库（sqflite）。
/// P0 范围：memory_docs / memory_tags / memory_links / memory_doc_summaries /
/// memory_evidence + memory_docs_fts（中文预分词，dart_jieba 分词后喂入）。
///
/// ## FTS 策略（v4 §7 + 嵌入式搜索引擎调研）
/// - 不用 external-content 触发器（触发器里无法跑 Dart 分词）→ 普通 FTS5 表，
///   由代码在 upsertDoc/deleteDoc 时同步分词列。
/// - 中文：写入/查询两侧都用 dart_jieba 分词后空格连接（unicode61 对连续汉字
///   只出一个 token，必须预分词）。
/// - 排序：FTS5 原生 `bm25()`（负分，越小越相关，ORDER BY ASC）。
/// - ⚠️ FTS5 工程风险（调研纠错）：Android 系统 SQLite 从未启用 FTS5，
///   sqflite 走系统库 → FTS5 可用性因设备而异；不可用时自动降级 LIKE。
library;

import 'package:sqflite/sqflite.dart';

import 'chinese_segmenter.dart';

/// 记忆库工厂（测试用 ffi，与 session_db 共用注入点）。
DatabaseFactory? memoryDbFactory;

/// 记忆库。
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

  /// FTS5 是否可用（不可用时检索降级 LIKE）。
  bool get ftsAvailable => _ftsAvailable;

  /// 打开数据库（建表 + FTS）。
  Future<void> init() async {
    final factory = memoryDbFactory ?? databaseFactory;
    final db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        // 开启外键约束（ON DELETE CASCADE 生效；sqflite 默认关闭）。
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await _createSchema(db);
        },
      ),
    );
    _db = db;
    await _ensureFts(db);
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
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
    await db.execute('CREATE INDEX IF NOT EXISTS idx_memory_docs_kind ON memory_docs(kind)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS memory_tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doc_id INTEGER NOT NULL REFERENCES memory_docs(id) ON DELETE CASCADE,
        tag TEXT NOT NULL,
        score REAL NOT NULL DEFAULT 1.0,
        UNIQUE(doc_id, tag)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_memory_tags_tag ON memory_tags(tag)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS memory_links (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        src INTEGER NOT NULL REFERENCES memory_docs(id) ON DELETE CASCADE,
        dst INTEGER NOT NULL REFERENCES memory_docs(id) ON DELETE CASCADE,
        kind TEXT NOT NULL DEFAULT 'tag',
        weight REAL NOT NULL DEFAULT 1.0,
        UNIQUE(src, dst, kind)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS memory_doc_summaries (
        doc_id INTEGER PRIMARY KEY REFERENCES memory_docs(id) ON DELETE CASCADE,
        summary TEXT NOT NULL,
        doc_mtime INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS memory_evidence (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        obj_type TEXT NOT NULL,
        obj_id INTEGER NOT NULL,
        evidence TEXT NOT NULL,
        ts REAL NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_evidence_obj ON memory_evidence(obj_type, obj_id)');
    // Goal 系统（DSH 启示 1，v4 §3）：持久目标 + 自动续跑。
    await db.execute('''
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
    await db.execute('''
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

  /// FTS5 建表（普通表，代码同步分词列）。不可用则静默降级。
  Future<void> _ensureFts(Database db) async {
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_docs_fts USING fts5(
          title_seg, content_seg, tags_seg
        )
      ''');
      _ftsAvailable = true;
    } catch (_) {
      _ftsAvailable = false;
    }
  }

  // ------------------------------------------------------------------
  // 文档 CRUD（FTS 同步）
  // ------------------------------------------------------------------

  /// 新增或更新记忆文档。内容变化时同步分词列进 FTS。
  Future<int> upsertDoc({
    required String path,
    required String title,
    String content = '',
    String kind = 'memory',
    double importance = 0.5,
    String? frozenSnapshot,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await db.query(
      'memory_docs',
      where: 'path = ?',
      whereArgs: [path],
      limit: 1,
    );
    final int id;
    if (existing.isEmpty) {
      id = await db.insert('memory_docs', {
        'path': path,
        'title': title,
        'kind': kind,
        'content': content,
        'mtime': now,
        'frozen_snapshot': frozenSnapshot,
        'importance': importance,
      });
    } else {
      id = existing.first['id'] as int;
      await db.update(
        'memory_docs',
        {
          'title': title,
          'kind': kind,
          'content': content,
          'mtime': now,
          'frozen_snapshot': frozenSnapshot,
          'importance': importance,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await _syncFts(id, title, content);
    return id;
  }

  /// 更新文档重要度（置信度引擎 P1 用）。
  Future<void> updateImportance(int docId, double importance) async {
    await db.update(
      'memory_docs',
      {'importance': importance},
      where: 'id = ?',
      whereArgs: [docId],
    );
  }

  /// 删除文档（手动清理关联，兼容外键未开启的旧库；FTS 同步删除）。
  Future<void> deleteDoc(int id) async {
    await db.delete('memory_evidence',
        where: 'obj_type = ? AND obj_id = ?', whereArgs: ['doc', id]);
    await db.delete('memory_doc_summaries', where: 'doc_id = ?', whereArgs: [id]);
    await db.delete('memory_tags', where: 'doc_id = ?', whereArgs: [id]);
    await db.delete('memory_links', where: 'src = ? OR dst = ?', whereArgs: [id, id]);
    await db.delete('memory_docs', where: 'id = ?', whereArgs: [id]);
    if (_ftsAvailable) {
      try {
        await db.rawDelete(
          'DELETE FROM memory_docs_fts WHERE rowid = ?',
          [id],
        );
      } catch (_) {}
    }
  }

  Future<void> _syncFts(int id, String title, String content) async {
    if (!_ftsAvailable) return;
    final tags = await getTags(id);
    try {
      await db.rawDelete('DELETE FROM memory_docs_fts WHERE rowid = ?', [id]);
      final titleSeg = segmentToFts(title);
      final contentSeg = segmentToFts(content);
      final tagsSeg = segmentToFts(tags.join(' '));
      if ((titleSeg ?? '').isNotEmpty ||
          (contentSeg ?? '').isNotEmpty ||
          (tagsSeg ?? '').isNotEmpty) {
        await db.rawInsert(
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
  /// 返回按相关度排序的文档（含匹配标签）。summary 由调用方按需取。
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
          final rows = await db.rawQuery(sql, args);
          if (rows.isNotEmpty) {
            return rows;
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
    return db.rawQuery(sql, args);
  }

  /// 按标签精确检索（P1 扩散激活的种子来源之一）。
  Future<List<Map<String, dynamic>>> searchByTag(
    String tag, {
    int limit = 20,
  }) async {
    final rows = await db.rawQuery(
      '''
      SELECT d.* FROM memory_docs d
      JOIN memory_tags t ON t.doc_id = d.id
      WHERE t.tag = ?
      ORDER BY d.importance DESC, d.mtime DESC
      LIMIT ?
      ''',
      [tag, limit],
    );
    return rows;
  }

  // ------------------------------------------------------------------
  // 标签 / 链接 / 证据 / 摘要
  // ------------------------------------------------------------------

  /// 给文档添加标签（P1 自动标签管线用）。
  Future<void> addTag(int docId, String tag, {double score = 1.0}) async {
    await db.insert(
      'memory_tags',
      {'doc_id': docId, 'tag': tag, 'score': score},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // 标签变化 → 同步 FTS（tags_seg）。
    if (_ftsAvailable) {
      final doc = await getDoc(docId);
      if (doc != null) {
        await _syncFts(docId, doc['title'] as String, doc['content'] as String);
      }
    }
  }

  /// 移除标签。
  Future<void> removeTag(int docId, String tag) async {
    await db.delete(
      'memory_tags',
      where: 'doc_id = ? AND tag = ?',
      whereArgs: [docId, tag],
    );
  }

  /// 文档全部标签（按 score 降序）。
  Future<List<String>> getTags(int docId) async {
    final rows = await db.query(
      'memory_tags',
      where: 'doc_id = ?',
      whereArgs: [docId],
      orderBy: 'score DESC',
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
    final existing = await db.query(
      'memory_links',
      where: 'src = ? AND dst = ? AND kind = ?',
      whereArgs: [src, dst, kind],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert(
        'memory_links',
        {'src': src, 'dst': dst, 'kind': kind, 'weight': weight},
      );
    } else {
      // Hebbian 强化：共访问/采纳 → 边权 +weight。
      await db.rawUpdate(
        'UPDATE memory_links SET weight = weight + ?1 '
        'WHERE src = ?2 AND dst = ?3 AND kind = ?4',
        [weight, src, dst, kind],
      );
    }
  }

  /// 目标文档的直接邻居（P1 扩散激活用）。
  ///
  /// 图是无向的（Hebbian 关联边）→ 双向查询：邻居是"另一端"的文档，
  /// 无论边方向是 src→dst 还是 dst→src。
  Future<List<Map<String, dynamic>>> getNeighbors(
    int docId, {
    String? kind,
    int limit = 20,
  }) async {
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
    return db.rawQuery(sql, args);
  }

  /// 记录证据事件（置信度引擎痕迹层，P1 用；P0 先落表）。
  Future<void> addEvidence(
    String objType,
    int objId,
    String evidence,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    await db.insert('memory_evidence', {
      'obj_type': objType,
      'obj_id': objId,
      'evidence': evidence,
      'ts': now,
    });
  }

  /// 写摘要（激活即总结，P2 用；表先建）。
  Future<void> upsertSummary(
    int docId,
    String summary,
    int docMtime,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'memory_doc_summaries',
      {'doc_id': docId, 'summary': summary, 'doc_mtime': docMtime, 'updated_at': now},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读摘要。文档 mtime 变更后摘要视为 stale（返回 null）。
  Future<Map<String, dynamic>?> getSummary(int docId) async {
    final rows = await db.query(
      'memory_doc_summaries',
      where: 'doc_id = ?',
      whereArgs: [docId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final summary = rows.first;
    final doc = await getDoc(docId);
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
  Future<Map<String, dynamic>?> getDoc(int id) async {
    final rows = await db.query(
      'memory_docs',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
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
    return db.rawQuery(sql, args);
  }

  /// 关闭数据库。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }
}
