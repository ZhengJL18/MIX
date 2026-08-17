/// MIX 调试服务（真机验证 CLI 通道，2026-08 旅行者要求）。
///
/// 监听 `127.0.0.1:8701`，通过 `adb forward tcp:8701 tcp:8701` 从主机交互。
/// 协议：每行一个 JSON 请求 `{"cmd": ..., "args": ...}`，每行一个 JSON 响应。
///
/// 命令集覆盖 `docs/VERIFICATION.md` 真机清单（全部可读/可脚本化）：
/// - `ping`              存活 + FTS5 可用性 + 文档/标签/边/证据统计
/// - `fts_status`        FTS5 是否可用（决定是否需迁 sqlite3 3.x）
/// - `segment <text>`    中文分词结果（验证 dart_jieba）
/// - `memory_search <q>` 热词检索（含 fts 字段 + typo 容错命中标记）
/// - `memory_docs`       文档列表（验证笔记同步/知识点入库）
/// - `memory_tags <id>`  自动标签（验证图建构）
/// - `memory_links <id>` 关联边（验证扩散图）
/// - `study_status`      学习状态 + 复习推荐（验证学习描绘）
/// - `goal_list`         持久目标（验证 Goal 系统）
/// - `evidence <t> <id>` 证据流（验证置信度引擎）
/// - `notes_sync`        手动触发笔记同步
/// - `reindex`           全量强制重建记忆索引（清边权膨胀/旧标签残留）
///
/// 安全：仅 127.0.0.1 回环 + adb forward（USB 授权才可达）；release 也启用
/// （用户明确要求调试模式，本地回环无外部暴露）。
library;

import 'dart:convert';
import 'dart:io';

import 'chinese_segmenter.dart';
import 'goal_store.dart';
import 'memory_db.dart';
import 'memory_indexer.dart';
import 'memory_learning.dart';
import 'memory_tagger.dart';
import 'notes_sync.dart';
import 'study_engine.dart';
import '../tools/read_doc_tool.dart' show readDocTool;

/// 调试服务端口（adb forward 用）。
const int kDebugServerPort = 8701;

/// 调试服务。
class DebugServer {
  final MemoryDB? memoryDb;
  final StudyEngine? studyEngine;
  final GoalStore? goalStore;
  final MemoryLearning? learning;
  final MemoryTagger? tagger;
  final NotesSyncService? notesSync;
  final MemoryIndexer? indexer;
  final int port;

  ServerSocket? _server;
  bool _running = false;

  DebugServer({
    this.memoryDb,
    this.studyEngine,
    this.goalStore,
    this.learning,
    this.tagger,
    this.notesSync,
    this.indexer,
    this.port = kDebugServerPort,
  });

  bool get running => _running;

  /// 启动调试服务（失败静默——调试通道非必需）。
  Future<bool> start() async {
    if (_running) return true;
    try {
      _server = await ServerSocket.bind('127.0.0.1', port);
      _running = true;
      _server!.listen(_onConnection, onError: (_) {});
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    _running = false;
    await _server?.close();
    _server = null;
  }

  void _onConnection(Socket socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) async {
      try {
        final resp = await handleCommand(line);
        socket.writeln(resp);
        await socket.flush();
      } catch (e) {
        socket.writeln(jsonEncode({'error': 'handler error: $e'}));
        await socket.flush();
      }
    }, onError: (_) {
      socket.close();
    }, onDone: () {
      socket.close();
    });
  }

  /// 处理一行命令，返回 JSON 响应串（也可直接单元测试调用）。
  Future<String> handleCommand(String line) async {
    final Map<String, dynamic> req;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        return jsonEncode({'error': 'request must be a JSON object'});
      }
      req = decoded;
    } catch (_) {
      return jsonEncode({'error': 'bad JSON'});
    }
    final cmd = (req['cmd'] as String? ?? '').trim();
    final args = req['args'];
    try {
      switch (cmd) {
        case 'ping':
          return _cmdPing();
        case 'fts_status':
          return _cmdFtsStatus();
        case 'segment':
          return _cmdSegment(args);
        case 'memory_search':
          return _cmdMemorySearch(args);
        case 'memory_docs':
          return _cmdMemoryDocs(args);
        case 'memory_tags':
          return _cmdMemoryTags(args);
        case 'memory_links':
          return _cmdMemoryLinks(args);
        case 'study_status':
          return _cmdStudyStatus();
        case 'goal_list':
          return _cmdGoalList();
        case 'evidence':
          return _cmdEvidence(args);
        case 'notes_sync':
          return _cmdNotesSync();
        case 'reindex':
          return _cmdReindex();
        case 'read_doc':
          return _cmdReadDoc(args);
        default:
          return jsonEncode({'error': "unknown cmd '$cmd'"});
      }
    } catch (e) {
      return jsonEncode({'error': '$cmd failed: $e'});
    }
  }

  String _cmdPing() {
    return jsonEncode({
      'ok': true,
      'app': 'MIX',
      'fts_available': memoryDb?.ftsAvailable ?? false,
    });
  }

  String _cmdFtsStatus() {
    return jsonEncode({
      'fts_available': memoryDb?.ftsAvailable ?? false,
      'note': 'FTS5 不可用 → memory_search 降级 LIKE（需迁 sqlite3 3.x）',
    });
  }

  String _cmdSegment(Object? args) {
    final text = _argStr(args, 'text') ?? '';
    if (text.isEmpty) return jsonEncode({'error': 'segment: text required'});
    return jsonEncode({
      'text': text,
      'words': segmentWords(text),
      'fts_query': buildFtsQuery(text),
    });
  }

  Future<String> _cmdMemorySearch(Object? args) async {
    final db = memoryDb;
    if (db == null) return jsonEncode({'error': 'memory_db unavailable'});
    final q = _argStr(args, 'query') ?? '';
    if (q.isEmpty) return jsonEncode({'error': 'memory_search: query required'});
    final rows = await db.searchMemories(q, limit: _argInt(args, 'limit') ?? 10);
    final items = <Map<String, dynamic>>[];
    for (final r in rows) {
      items.add({
        'id': r['id'],
        'title': r['title'],
        'kind': r['kind'],
        'path': r['path'],
        'tags': await db.getTags(r['id'] as int),
        'mtime': r['mtime'],
      });
    }
    return jsonEncode({
      'query': q,
      'fts_available': db.ftsAvailable,
      'count': items.length,
      'items': items,
    });
  }

  Future<String> _cmdMemoryDocs(Object? args) async {
    final db = memoryDb;
    if (db == null) return jsonEncode({'error': 'memory_db unavailable'});
    final kind = _argStr(args, 'kind');
    final docs = await db.listDocs(limit: _argInt(args, 'limit') ?? 100, kind: kind);
    return jsonEncode({
      'count': docs.length,
      'kind_filter': kind,
      'docs': [
        for (final d in docs)
          {
            'id': d['id'],
            'title': d['title'],
            'kind': d['kind'],
            'path': d['path'],
            'mtime': d['mtime'],
            'importance': d['importance'],
          },
      ],
    });
  }

  Future<String> _cmdMemoryTags(Object? args) async {
    final db = memoryDb;
    if (db == null) return jsonEncode({'error': 'memory_db unavailable'});
    final id = _argInt(args, 'doc_id');
    if (id == null) return jsonEncode({'error': 'memory_tags: doc_id required'});
    return jsonEncode({'doc_id': id, 'tags': await db.getTags(id)});
  }

  Future<String> _cmdMemoryLinks(Object? args) async {
    final db = memoryDb;
    if (db == null) return jsonEncode({'error': 'memory_db unavailable'});
    final id = _argInt(args, 'doc_id');
    if (id == null) return jsonEncode({'error': 'memory_links: doc_id required'});
    final links = await db.getNeighbors(id, limit: 50);
    return jsonEncode({
      'doc_id': id,
      'count': links.length,
      'links': [
        for (final l in links)
          {'id': l['id'], 'title': l['title'], 'kind': l['link_kind'],
           'weight': l['link_weight']},
      ],
    });
  }

  Future<String> _cmdStudyStatus() async {
    final l = learning;
    if (l == null) return jsonEncode({'error': 'learning unavailable'});
    final states = await l.deriveStates();
    final due = await l.reviewDue(limit: 8);
    return jsonEncode({
      'states': [
        for (final s in states)
          {
            'kp_id': s.kpId,
            'name': s.name,
            'subject': s.subjectName,
            'status': s.status,
            'mastery': s.mastery,
            'retrievability': s.retrievability,
          },
      ],
      'review_due': [
        for (final s in due) {'kp_id': s.kpId, 'name': s.name, 'status': s.status},
      ],
    });
  }

  Future<String> _cmdGoalList() async {
    final gs = goalStore;
    if (gs == null) return jsonEncode({'error': 'goal_store unavailable'});
    final goals = await gs.listGoals();
    return jsonEncode({
      'count': goals.length,
      'goals': [
        for (final g in goals)
          {
            'id': g['id'],
            'objective': g['objective'],
            'phase': g['phase'],
            'revision': g['revision'],
            'rounds': g['rounds'],
            'evidence_obj': g['evidence_obj'],
          },
      ],
    });
  }

  Future<String> _cmdEvidence(Object? args) async {
    final db = memoryDb;
    if (db == null) return jsonEncode({'error': 'memory_db unavailable'});
    final objType = _argStr(args, 'obj_type');
    final objId = _argInt(args, 'obj_id');
    if (objType == null || objId == null) {
      return jsonEncode({'error': 'evidence: obj_type + obj_id required'});
    }
    final result = await db.db.select(
      'SELECT evidence, ts FROM memory_evidence '
      'WHERE obj_type = ? AND obj_id = ? ORDER BY ts DESC LIMIT 50',
      [objType, objId],
    );
    final cols = result.columnNames;
    final rows = [
      for (final r in result) {for (final c in cols) c: r[c]},
    ];
    return jsonEncode({
      'obj_type': objType,
      'obj_id': objId,
      'count': rows.length,
      'evidence': rows,
    });
  }

  Future<String> _cmdNotesSync() async {
    final ns = notesSync;
    if (ns == null) return jsonEncode({'error': 'notes_sync unavailable'});
    final updated = await ns.syncNotes();
    return jsonEncode({'updated': updated});
  }

  /// reindex：全量强制重建记忆索引（真机验证用，清历史边权膨胀/旧标签残留）。
  Future<String> _cmdReindex() async {
    final idx = indexer;
    if (idx == null) return jsonEncode({'error': 'memory_indexer unavailable'});
    final n = await idx.forceReindexAll();
    return jsonEncode({'reindexed': n});
  }

  /// read_doc：本地文档→Markdown 提取（PDF/DOCX/PPTX/XLSX 验证用）。
  Future<String> _cmdReadDoc(Object? args) async {
    final path = _argStr(args, 'path');
    if (path == null || path.isEmpty) {
      return jsonEncode({'error': 'read_doc: path required'});
    }
    try {
      final text = await readDocTool(path, maxChars: _argInt(args, 'max_chars') ?? 5000);
      return jsonEncode({'path': path, 'extracted': text.substring(0, text.length > 2000 ? 2000 : text.length)});
    } catch (e) {
      return jsonEncode({'error': 'read_doc failed: $e'});
    }
  }

  // ------------------------------------------------------------------
  // 参数辅助
  // ------------------------------------------------------------------

  static String? _argStr(Object? args, String key) {
    if (args is Map) {
      final v = args[key];
      if (v is String) return v;
    }
    return null;
  }

  static int? _argInt(Object? args, String key) {
    if (args is Map) {
      final v = args[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
    }
    return null;
  }
}
