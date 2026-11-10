/// 会话消息的本地只读镜像。
///
/// 定位：**服务端是金标准，本地只是一份缓存**。
///
/// 服务端的权威结构是事件日志（`events`，seq 单调）加派生投影
/// （`projection_messages`，ord 单调）。客户端不去重建事件，只把投影拉下来
/// 存一份，语义是「全量覆盖」而不是「合并」—— 任何本地分歧都以服务端为准，
/// 不需要冲突解决，也不会有对不齐的中间态。
///
/// 缓存解决的问题只有一个：**断网/服务不可达时，会话不能是空白**。所以
/// 读取路径是「先渲染盘上的，再等网络覆盖」，写入路径是「拿到服务端结果就整
/// 表替换」。
///
/// 用 sqflite 而不是 JSON 快照：一条会话几百条消息，全量序列化在流式过程中
/// 反复触发会很浪费；SQLite 事务批量替换是毫秒级，而且测试可以用
/// `sqflite_common_ffi` 在主机上跑真库。
library;

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'bridge_events.dart';

/// 盘上一份会话快照。
class BridgeCachedConversation {
  const BridgeCachedConversation({
    required this.messages,
    required this.lastSeq,
    required this.appliedSeq,
    required this.syncedAt,
  });

  final List<BridgeMessage> messages;

  /// 上次同步时服务端的 `last_seq`。
  final int lastSeq;

  /// 上次同步时服务端的 `applied_seq`（投影已折叠到哪）。
  final int appliedSeq;

  /// 本地写入时间（毫秒）。UI 可以据此提示「离线，显示的是 x 分钟前的内容」。
  final int syncedAt;

  bool get isEmpty => messages.isEmpty;
}

class BridgeCache {
  BridgeCache._();

  static const int _version = 1;
  static const String _dbName = 'bridge_cache.db';

  static Database? _db;

  /// 测试注入：换成内存库或临时路径，避免污染真实数据。
  static String? _pathOverride;

  static void usePathForTest(String path) {
    _pathOverride = path;
    _db = null;
  }

  static Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;

    final path = _pathOverride ?? p.join(await getDatabasesPath(), _dbName);
    final db = await openDatabase(
      path,
      version: _version,
      onCreate: (db, _) async {
        // 结构与服务端 projection_messages 对齐：本地就是那张表的副本，
        // 字段含义一致，出问题时可以直接和 `/v1/sessions/:id/messages` 比对。
        await db.execute('''
          CREATE TABLE bridge_messages (
            session_id TEXT NOT NULL,
            ord INTEGER NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            ts INTEGER NOT NULL DEFAULT 0,
            meta TEXT NOT NULL DEFAULT '{}',
            PRIMARY KEY (session_id, ord)
          )
        ''');
        await db.execute('''
          CREATE TABLE bridge_sync (
            session_id TEXT PRIMARY KEY,
            last_seq INTEGER NOT NULL DEFAULT 0,
            applied_seq INTEGER NOT NULL DEFAULT 0,
            synced_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
    _db = db;
    return db;
  }

  /// 用一份完整会话替换盘上内容（服务端投影 → 本地）。
  ///
  /// 单事务：先删该会话全部旧行，再批量插入，最后更新水位。中途被杀不会留下
  /// 「删了一半」的会话 —— 要么是旧的完整快照，要么是新的完整快照。
  static Future<void> replaceAll(
    String sessionId,
    List<BridgeMessage> messages, {
    required int lastSeq,
    required int appliedSeq,
    int? syncedAt,
  }) async {
    final db = await _open();
    final now = syncedAt ?? DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.delete('bridge_messages', where: 'session_id = ?', whereArgs: [sessionId]);
      final batch = txn.batch();
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        batch.insert(
          'bridge_messages',
          {
            'session_id': sessionId,
            // 服务端没给 ord（本地乐观插入的行）时按顺序补，保证排序稳定。
            'ord': m.ord > 0 ? m.ord : i + 1,
            'role': m.role,
            'text': m.text,
            'ts': m.ts,
            'meta': _encodeMeta(m.meta),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      await txn.insert(
        'bridge_sync',
        {
          'session_id': sessionId,
          'last_seq': lastSeq,
          'applied_seq': appliedSeq,
          'synced_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// 读盘上的会话。没有缓存返回 null（区别于「有缓存但为空会话」）。
  static Future<BridgeCachedConversation?> load(
    String sessionId, {
    int limit = 600,
  }) async {
    final db = await _open();
    final syncRows = await db.query(
      'bridge_sync',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (syncRows.isEmpty) return null;

    // 取最新的 limit 条再翻回正序：长会话也要能秒开，不能把整表读进内存。
    final rows = await db.query(
      'bridge_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'ord DESC',
      limit: limit,
    );
    final messages = [
      for (final r in rows.reversed)
        BridgeMessage(
          ord: (r['ord'] as int?) ?? 0,
          role: (r['role'] as String?) ?? '',
          text: (r['text'] as String?) ?? '',
          ts: (r['ts'] as int?) ?? 0,
          meta: _decodeMeta(r['meta']),
        ),
    ];
    final s = syncRows.first;
    return BridgeCachedConversation(
      messages: messages,
      lastSeq: (s['last_seq'] as int?) ?? 0,
      appliedSeq: (s['applied_seq'] as int?) ?? 0,
      syncedAt: (s['synced_at'] as int?) ?? 0,
    );
  }

  /// 只更新水位（流式过程里消息由 turn.end 统一落盘，不必每条事件都整表重写）。
  static Future<void> touchSync(
    String sessionId, {
    int? lastSeq,
    int? appliedSeq,
  }) async {
    final db = await _open();
    final rows = await db.query(
      'bridge_sync',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (rows.isEmpty) {
      await db.insert('bridge_sync', {
        'session_id': sessionId,
        'last_seq': lastSeq ?? 0,
        'applied_seq': appliedSeq ?? 0,
        'synced_at': now,
      });
      return;
    }
    await db.update(
      'bridge_sync',
      {
        if (lastSeq != null) 'last_seq': lastSeq,
        if (appliedSeq != null) 'applied_seq': appliedSeq,
        'synced_at': now,
      },
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  static Future<void> clear(String sessionId) async {
    final db = await _open();
    await db.transaction((txn) async {
      await txn.delete('bridge_messages', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.delete('bridge_sync', where: 'session_id = ?', whereArgs: [sessionId]);
    });
  }

  /// 会话被服务端删除后清理孤儿缓存。返回删掉的会话数。
  static Future<int> pruneOrphans(Set<String> liveSessionIds) async {
    final db = await _open();
    final rows = await db.query('bridge_sync', columns: ['session_id']);
    var n = 0;
    for (final r in rows) {
      final id = (r['session_id'] as String?) ?? '';
      if (id.isNotEmpty && !liveSessionIds.contains(id)) {
        await clear(id);
        n++;
      }
    }
    return n;
  }

  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  static String _encodeMeta(Map<String, dynamic> meta) {
    if (meta.isEmpty) return '{}';
    try {
      return const JsonCodec().encode(meta);
    } catch (_) {
      return '{}';
    }
  }

  static Map<String, dynamic> _decodeMeta(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final v = const JsonCodec().decode(raw);
      return v is Map ? Map<String, dynamic>.from(v) : const {};
    } catch (_) {
      return const {};
    }
  }
}
