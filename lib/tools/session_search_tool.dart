/// 对应 `ref/hermes-agent/tools/session_search_tool.py`（像素级复刻，核心）。
///
/// 会话搜索工具，四模式（从参数推断，无显式 mode）：
/// - **discover**（传 query）：关键词搜索会话 → 匹配消息 + snippet + 上下文
/// - **scroll**（session_id + around_message_id, window）：锚点上下文浏览
/// - **read**（仅 session_id）：整会话 dump
/// - **browse**（无参）：最近会话列表
///
/// 全部操作 SQLite 会话库（SessionDB），无 LLM 调用。
library;

import 'dart:convert';

import '../db/session_db.dart';
import '../services/services.dart';
import 'registry.dart';

/// session_search 工具。
Future<String> sessionSearchTool({
  String? query,
  String? sessionId,
  int? aroundMessageId,
  int? window,
  SessionDB? db,
  int limit = 20,
}) async {
  if (db == null) {
    return toolError('Session database not available');
  }

  // 四模式推断。
  if (query != null && query.isNotEmpty) {
    return _discover(db, query, limit);
  }
  if (sessionId != null && aroundMessageId != null) {
    return _scroll(db, sessionId, aroundMessageId, window ?? 5);
  }
  if (sessionId != null) {
    return _read(db, sessionId);
  }
  return _browse(db, limit);
}

/// discover：关键词搜索，返回会话 + 匹配消息。
Future<String> _discover(SessionDB db, String query, int limit) async {
  try {
    final results = await db.searchMessages(
      query,
      roleFilter: 'user,assistant',
      limit: limit,
    );
    final hits = <Map<String, dynamic>>[];
    for (final m in results) {
      hits.add({
        'session_id': m['session_id'],
        'role': m['role'],
        'message_id': m['id'],
        'content': m['content'],
        'timestamp': m['timestamp'],
      });
    }
    return jsonEncode({
      'mode': 'discover',
      'query': query,
      'count': hits.length,
      'matches': hits,
    });
  } catch (e) {
    return toolError('Session search failed: $e');
  }
}

/// scroll：锚点上下文。
Future<String> _scroll(SessionDB db, String sessionId, int aroundMessageId, int window) async {
  try {
    final w = window < 1 ? 1 : (window > 20 ? 20 : window);
    final all = await db.getMessages(sessionId);
    // 找锚点位置。
    final idx = all.indexWhere((m) => m['id'] == aroundMessageId);
    if (idx == -1) {
      return jsonEncode({
        'mode': 'scroll',
        'session_id': sessionId,
        'around_message_id': aroundMessageId,
        'error': 'Anchor message not found in session',
      });
    }
    final start = idx - w < 0 ? 0 : idx - w;
    final end = idx + w + 1 > all.length ? all.length : idx + w + 1;
    final window_ = all.sublist(start, end).toList();
    final messages = <Map<String, dynamic>>[];
    for (var i = 0; i < window_.length; i++) {
      final m = window_[i];
      final originalIdx = start + i;
      messages.add({
        'id': m['id'],
        'role': m['role'],
        'content': m['content'],
        'is_anchor': originalIdx == idx,
      });
    }
    return jsonEncode({
      'mode': 'scroll',
      'session_id': sessionId,
      'around_message_id': aroundMessageId,
      'window': w,
      'messages': messages,
      'messages_before': idx,
      'messages_after': all.length - idx - 1,
    });
  } catch (e) {
    return toolError('Session scroll failed: $e');
  }
}

/// read：整会话 dump（>30 条时头20+尾10）。
Future<String> _read(SessionDB db, String sessionId) async {
  try {
    final sess = await db.getSession(sessionId);
    final all = await db.getMessages(sessionId);
    const maxDump = 30;
    final truncated = all.length > maxDump;
    List<Map<String, dynamic>> shown;
    if (truncated) {
      shown = [
        ...all.sublist(0, 20),
        {'id': -1, 'role': 'system', 'content': '... [truncated] ...'},
        ...all.sublist(all.length - 10),
      ];
    } else {
      shown = all;
    }
    final messages = <Map<String, dynamic>>[
      for (final m in shown)
        {
          'id': m['id'],
          'role': m['role'],
          'content': m['content'],
          'tool_name': m['tool_name'],
        },
    ];
    return jsonEncode({
      'mode': 'read',
      'session_id': sessionId,
      'title': sess?['title'],
      'model': sess?['model'],
      'message_count': all.length,
      'truncated': truncated,
      'messages': messages,
    });
  } catch (e) {
    return toolError('Session read failed: $e');
  }
}

/// browse：最近会话列表。
Future<String> _browse(SessionDB db, int limit) async {
  try {
    final sessions = await db.listSessions(limit: limit);
    final items = <Map<String, dynamic>>[];
    for (final s in sessions) {
      items.add({
        'session_id': s['id'],
        'title': s['title'],
        'source': s['source'],
        'started_at': s['started_at'],
        'message_count': s['message_count'],
        'model': s['model'],
      });
    }
    return jsonEncode({
      'mode': 'browse',
      'count': items.length,
      'sessions': items,
    });
  } catch (e) {
    return toolError('Session browse failed: $e');
  }
}

/// session_search 工具 schema。
const Map<String, dynamic> sessionSearchSchema = {
  'name': 'session_search',
  'description':
      'Search past conversations. Four modes inferred from args:\n'
      "- query: search for keyword matches in past sessions\n"
      '- session_id + around_message_id: scroll context around a message\n'
      '- session_id only: read a full session\n'
      '- no args: browse recent sessions',
  'parameters': {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'Search query for past conversations',
      },
      'session_id': {
        'type': 'string',
        'description': 'Session ID to read or scroll',
      },
      'around_message_id': {
        'type': 'integer',
        'description': 'Message ID to anchor scroll context around',
      },
      'window': {
        'type': 'integer',
        'description': 'Context window size for scroll (1-20, default 5)',
      },
      'limit': {
        'type': 'integer',
        'description': 'Max results for discover/browse (default 20)',
      },
    },
  },
};

/// 注册 session_search 工具。
void registerSessionSearchTool() {
  registry.register(
    name: 'session_search',
    toolset: 'session_search',
    schema: sessionSearchSchema,
    handler: (args, [kwargs]) {
      return sessionSearchTool(
        query: args['query'] as String?,
        sessionId: args['session_id'] as String?,
        aroundMessageId: args['around_message_id'] as int?,
        window: args['window'] as int?,
        db: Services.instance.sessionDb,
        limit: args['limit'] as int? ?? 20,
      );
    },
    checkFn: () => Services.instance.sessionDb != null,
    emoji: '🔍',
  );
}
