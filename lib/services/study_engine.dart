/// 学习引擎 — 事实层（纯本地，零 LLM）。
///
/// 复用之 mix.db 的 schema 瘦身版（砍掉全部状态机列：权重/艾宾浩斯/streak/
/// 四维系数/阶段）。掌握度 = SQL 现场聚合近 N 题正确率（一维、确定性、零公式）。
///
/// 表：subjects / knowledge_points / questions / practice_records。
/// 不引入状态机、不迁移、不加计算。
library;

import 'package:sqflite/sqflite.dart';

import '../db/session_db.dart' show sessionDbFactory;

/// 知识点（含 SQL 聚合的掌握度）。
class KpInfo {
  final int id;
  final int subjectId;
  final String name;
  final String subjectName;
  final double mastery; // 近 [masteryWindow] 题正确率（无记录则 null→0.5）。
  final int recentCount;

  KpInfo({
    required this.id,
    required this.subjectId,
    required this.name,
    required this.subjectName,
    required this.mastery,
    required this.recentCount,
  });
}

/// 一道题（含答案/解析）。
class StudyQuestion {
  final int id;
  final int kpId;
  final String content;
  final String answer; // 'A'..'D'
  final List<String> options;
  final String explanation;

  StudyQuestion({
    required this.id,
    required this.kpId,
    required this.content,
    required this.answer,
    required this.options,
    required this.explanation,
  });
}

/// 学习引擎（单例持有 Database）。
class StudyEngine {
  Database? _db;
  final String dbPath;
  bool _closed = false;

  /// 掌握度聚合窗口（近 N 题正确率）。
  final int masteryWindow;

  /// 去重 ground truth 窗口（出题前查最近 N 题防雷同）。
  final int dedupWindow;

  StudyEngine({
    required this.dbPath,
    this.masteryWindow = 15,
    this.dedupWindow = 15,
  });

  /// 打开数据库（建表）。
  Future<void> init() async {
    final factory = sessionDbFactory ?? databaseFactory;
    final db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await _createSchema(db);
        },
      ),
    );
    _db = db;
  }

  Database get db {
    if (_db == null) {
      throw StateError('StudyEngine not initialized — call init() first');
    }
    return _db!;
  }

  Future<void> _createSchema(Database db) async {
    final batch = db.batch();
    // 科目（瘦身：只留 name）。
    batch.execute('''
      CREATE TABLE IF NOT EXISTS subjects (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');
    // 知识点。
    batch.execute('''
      CREATE TABLE IF NOT EXISTS knowledge_points (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        subject_id INTEGER NOT NULL REFERENCES subjects(id),
        name TEXT NOT NULL
      )
    ''');
    batch.execute(
        'CREATE INDEX IF NOT EXISTS idx_kp_subject ON knowledge_points(subject_id)');
    // 题目。
    batch.execute('''
      CREATE TABLE IF NOT EXISTS questions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kp_id INTEGER NOT NULL REFERENCES knowledge_points(id),
        content TEXT NOT NULL,
        answer TEXT NOT NULL,
        options TEXT,
        explanation TEXT,
        is_seed INTEGER NOT NULL DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now'))
      )
    ''');
    batch.execute('CREATE INDEX IF NOT EXISTS idx_q_kp ON questions(kp_id)');
    // 练习记录。
    batch.execute('''
      CREATE TABLE IF NOT EXISTS practice_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        question_id INTEGER NOT NULL REFERENCES questions(id),
        correct INTEGER NOT NULL,
        main_cause TEXT,
        minor_cause TEXT,
        created_at TEXT DEFAULT (datetime('now'))
      )
    ''');
    batch.execute('CREATE INDEX IF NOT EXISTS idx_pr_question ON practice_records(question_id)');
    await batch.commit(noResult: true);
  }

  // ── 科目/知识点 ──

  /// 确保科目存在，返回 id。
  Future<int> ensureSubject(String name) async {
    final existing = await db.query('subjects',
        where: 'name = ?', whereArgs: [name], limit: 1);
    if (existing.isNotEmpty) return existing.first['id'] as int;
    return db.insert('subjects', {'name': name});
  }

  /// 确保知识点存在，返回 id。
  Future<int> ensureKnowledgePoint(int subjectId, String name) async {
    final existing = await db.query('knowledge_points',
        where: 'subject_id = ? AND name = ?',
        whereArgs: [subjectId, name],
        limit: 1);
    if (existing.isNotEmpty) return existing.first['id'] as int;
    return db.insert('knowledge_points', {'subject_id': subjectId, 'name': name});
  }

  /// 所有知识点（含掌握度）。
  Future<List<KpInfo>> listKps() async {
    final rows = await db.rawQuery('''
      SELECT kp.id, kp.subject_id, kp.name, s.name AS subject_name
      FROM knowledge_points kp
      JOIN subjects s ON s.id = kp.subject_id
      ORDER BY s.name, kp.name
    ''');
    final out = <KpInfo>[];
    for (final r in rows) {
      final kpId = r['id'] as int;
      final (mastery, recent) = await _masteryOf(kpId);
      out.add(KpInfo(
        id: kpId,
        subjectId: r['subject_id'] as int,
        name: r['name'] as String,
        subjectName: r['subject_name'] as String,
        mastery: mastery,
        recentCount: recent,
      ));
    }
    return out;
  }

  /// 单个知识点掌握度（近 [masteryWindow] 次作答正确率，无记录→0.5）。
  ///
  /// 原实现取"最近创建的 N 道题"再聚合它们的作答：练旧题（id 小）时该次
  /// 作答不计入，掌握度失真。改为按作答记录时间取最近 N 次，符合
  /// "近 N 题正确率"语义，也避免同一题答多次被重复计入分母。
  Future<(double, int)> _masteryOf(int kpId) async {
    final qRows = await db.rawQuery(
        'SELECT id FROM questions WHERE kp_id = ?', [kpId]);
    final qIds = [for (final r in qRows) r['id'] as int];
    if (qIds.isEmpty) return (0.5, 0);
    final placeholders = List.filled(qIds.length, '?').join(',');
    final pr = await db.rawQuery('''
      SELECT correct FROM practice_records
      WHERE question_id IN ($placeholders)
      ORDER BY id DESC
      LIMIT ?
    ''', [...qIds, masteryWindow]);
    if (pr.isEmpty) return (0.5, 0);
    final correct = pr.where((r) => (r['correct'] as int) == 1).length;
    return (correct / pr.length, pr.length);
  }

  // ── 题目 ──

  /// 保存题目，返回 id。
  Future<int> insertQuestion({
    required int kpId,
    required String content,
    required String answer,
    required List<String> options,
    required String explanation,
    bool isSeed = false,
  }) async {
    return db.insert('questions', {
      'kp_id': kpId,
      'content': content,
      'answer': answer,
      'options': options.join(''), // U+0001 分隔符存储。
      'explanation': explanation,
      'is_seed': isSeed ? 1 : 0,
    });
  }

  /// 查最近 [dedupWindow] 题（去重 ground truth）。
  Future<List<StudyQuestion>> recentQuestions(int kpId) async {
    final rows = await db.rawQuery('''
      SELECT * FROM questions WHERE kp_id = ? ORDER BY id DESC LIMIT ?
    ''', [kpId, dedupWindow]);
    return [for (final r in rows) _rowToQuestion(r)];
  }

  StudyQuestion _rowToQuestion(Map<String, dynamic> r) => StudyQuestion(
        id: r['id'] as int,
        kpId: r['kp_id'] as int,
        content: r['content'] as String,
        answer: r['answer'] as String,
        options: (r['options'] as String? ?? '')
            .split('')
            .where((s) => s.isNotEmpty)
            .toList(),
        explanation: r['explanation'] as String? ?? '',
      );

  // ── 判题（机械，归一化） ──

  /// 归一化答案：去空白/标点/大小写，容错 "A. xxx" / "选A" / "a"。
  String normalizeAnswer(String raw) {
    var s = raw.trim();
    // 提取首字母（"A." / "选A" / "选项 B"）。
    final m = RegExp(r'[A-Da-d]').firstMatch(s);
    if (m != null) return m.group(0)!.toUpperCase();
    return s.toUpperCase();
  }

  /// 机械判对错（零 LLM）。[userAnswer] 原始输入，[question] 题目。
  /// 返回 (isCorrect, normalized)。近似但不对 → 返回可"看参考答案"出口。
  ({bool correct, String normalized}) judge(
    StudyQuestion question,
    String userAnswer,
  ) {
    final norm = normalizeAnswer(userAnswer);
    final correct = norm == question.answer.toUpperCase();
    return (correct: correct, normalized: norm);
  }

  // ── 记录 ──

  /// 记录作答（单写，同一事务）。返回记录 id。
  Future<int> recordAnswer({
    required int questionId,
    required bool correct,
    String? mainCause,
    String? minorCause,
  }) async {
    return db.insert('practice_records', {
      'question_id': questionId,
      'correct': correct ? 1 : 0,
      if (mainCause != null) 'main_cause': mainCause,
      if (minorCause != null) 'minor_cause': minorCause,
    });
  }

  /// 题目所属知识点 id（学习事件→证据流映射用，v4 §6 学习事件=记忆观察）。
  /// 无此题或查询失败返回 null。
  Future<int?> getQuestionKp(int questionId) async {
    try {
      final rows = await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: [questionId],
        columns: ['kp_id'],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.first['kp_id'] as int;
    } catch (_) {
      return null;
    }
  }

  /// 最近作答记录（供统计/小结）。
  Future<List<Map<String, dynamic>>> recentRecords(int limit) async {
    return db.query('practice_records',
        orderBy: 'id DESC', limit: limit);
  }

  /// 某个知识点的历史正确率（供回合小结）。
  Future<(int, int)> kpStats(int kpId) async {
    final qRows = await db.query('questions',
        where: 'kp_id = ?', whereArgs: [kpId], columns: ['id']);
    final qIds = [for (final r in qRows) r['id'] as int];
    if (qIds.isEmpty) return (0, 0);
    final placeholders = List.filled(qIds.length, '?').join(',');
    final pr = await db.rawQuery('''
      SELECT correct FROM practice_records WHERE question_id IN ($placeholders)
    ''', qIds);
    final correct = pr.where((r) => (r['correct'] as int) == 1).length;
    return (correct, pr.length);
  }

  Future<void> close() async {
    if (!_closed && _db != null) {
      await _db!.close();
      _closed = true;
    }
  }
}
