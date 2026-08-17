/// 对话历史管理页：浏览/继续聊天/删除会话。
///
/// 会话列表：首条消息做标题 + 友好时间 + 消息数。
/// 会话详情：消息气泡（用户右/助手左），底部「继续聊天」。
library;

import 'package:flutter/material.dart';

import '../main.dart' show resumeSessionHandler;
import '../services/services.dart';
import '../theme/theme_ext.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;
  final _searchController = TextEditingController();
  // 搜索命中的会话 id → 匹配片段（空 = 未搜索）。
  Map<String, List<String>>? _searchHits;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 搜索会话内容。
  Future<void> _search(String query) async {
    final sdb = Services.instance.sessionDb;
    if (sdb == null) return;
    final q = query.trim();
    if (q.isEmpty) {
      setState(() => _searchHits = null);
      return;
    }
    setState(() => _searching = true);
    try {
      final rows = await sdb.searchMessages(q, roleFilter: 'user,assistant', limit: 30);
      final hits = <String, List<String>>{};
      for (final r in rows) {
        final sid = r['session_id'] as String? ?? '';
        final content = r['content'] as String? ?? '';
        if (sid.isEmpty || content.isEmpty) continue;
        final clipped = content.length > 60 ? '${content.substring(0, 60)}…' : content;
        hits.putIfAbsent(sid, () => []).add(clipped);
      }
      if (!mounted) return;
      setState(() {
        _searchHits = hits;
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searching = false);
    }
  }

  Future<void> _load() async {
    final sdb = Services.instance.sessionDb;
    if (sdb == null) {
      setState(() => _loading = false);
      return;
    }
    final sessions = await sdb.listSessions(limit: 100);
    // 给每个会话预取首条 user 消息做标题预览。
    for (final s in sessions) {
      final id = s['id'] as String? ?? '';
      final title = s['title'] as String?;
      if (title == null || title.isEmpty) {
        final msgs = await sdb.getMessages(id, limit: 5);
        final firstUser = msgs.firstWhere(
          (m) => m['role'] == 'user' && (m['content'] as String? ?? '').isNotEmpty,
          orElse: () => const {},
        );
        s['_preview'] = (firstUser['content'] as String? ?? '').trim();
      } else {
        s['_preview'] = title;
      }
    }
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _loading = false;
    });
  }

  /// 继续聊天：切回主对话页并加载该会话历史。
  Future<void> _continueChat(String sessionId) async {
    final handler = resumeSessionHandler;
    if (handler == null) return;
    await handler(sessionId);
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _viewSession(String sessionId) async {
    final sdb = Services.instance.sessionDb;
    if (sdb == null) return;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SessionDetailScreen(
          sessionId: sessionId,
          onContinue: () => _continueChat(sessionId),
        ),
      ),
    );
  }

  Future<void> _deleteSession(String sessionId) async {
    final sdb = Services.instance.sessionDb;
    if (sdb == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: const Text('确定删除这个会话吗？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: context.appPalette.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await sdb.deleteSession(sessionId);
    await _load();
  }

  String _sessionTitle(Map<String, dynamic> s) {
    final id = s['id'] as String? ?? '';
    final preview = (s['_preview'] as String? ?? '').trim();
    if (preview.isNotEmpty) {
      return preview.length > 24 ? '${preview.substring(0, 24)}…' : preview;
    }
    return '会话 ${id.length > 8 ? id.substring(0, 8) : id}';
  }

  String _formatTime(double? ts) {
    if (ts == null) return '';
    final t = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (day == today) return '今天 $hm';
    if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm';
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}年${t.month}月${t.day}日';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('对话历史')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索会话内容…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchHits = null);
                            },
                          )
                        : null,
              ),
              onChanged: _search,
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _searchHits != null
                    ? _buildSearchResults()
                    : _sessions.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.forum_outlined, size: 56, color: context.appPalette.textSecondary),
                                SizedBox(height: 12),
                                Text('暂无历史会话', style: TextStyle(color: context.appPalette.textSecondary)),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: _sessions.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final s = _sessions[i];
                              final id = s['id'] as String? ?? '';
                              final count = s['message_count'] as int? ?? 0;
                              final ts = s['started_at'] as num?;
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                                  child: const Icon(Icons.chat_bubble_outline, size: 20),
                                ),
                                title: Text(
                                  _sessionTitle(s),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text('${_formatTime(ts?.toDouble())} · $count 条消息'),
                                isThreeLine: false,
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'continue') _continueChat(id);
                          if (v == 'delete') _deleteSession(id);
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'continue',
                            child: ListTile(
                              leading: Icon(Icons.play_arrow, color: context.appPalette.primary),
                              title: Text('继续聊天'),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              leading: Icon(Icons.delete_outline, color: context.appPalette.danger),
                              title: Text('删除'),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                            ),
                          ),
                        ],
                      ),
                      onTap: () => _viewSession(id),
                    );
                  },
                ),
            ),
        ],
      ),
    );
  }

  /// 搜索结果列表（命中会话 + 匹配片段）。
  Widget _buildSearchResults() {
    final hits = _searchHits ?? {};
    if (hits.isEmpty) {
      return Center(
        child: Text('没有找到匹配的会话', style: TextStyle(color: context.appPalette.textSecondary)),
      );
    }
    // 按 _sessions 顺序显示命中会话。
    final matched = _sessions.where((s) => hits.containsKey(s['id'])).toList();
    return ListView.separated(
      itemCount: matched.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = matched[i];
        final id = s['id'] as String? ?? '';
        final ts = s['started_at'] as num?;
        final snippets = hits[id] ?? [];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: const Icon(Icons.search, size: 18),
          ),
          title: Text(_sessionTitle(s), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_formatTime(ts?.toDouble())),
              if (snippets.isNotEmpty)
                Text(
                  snippets.take(2).join(' / '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: context.appPalette.primary),
                ),
            ],
          ),
          isThreeLine: snippets.isNotEmpty,
          onTap: () => _viewSession(id),
        );
      },
    );
  }
}

/// 会话详情：消息气泡 + 底部「继续聊天」。
class _SessionDetailScreen extends StatefulWidget {
  final String sessionId;
  final VoidCallback onContinue;

  const _SessionDetailScreen({required this.sessionId, required this.onContinue});

  @override
  State<_SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<_SessionDetailScreen> {
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sdb = Services.instance.sessionDb;
    if (sdb != null) {
      final msgs = await sdb.getMessages(widget.sessionId);
      if (mounted) {
        setState(() {
          _messages = msgs;
          _loading = false;
        });
      }
    } else if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('会话详情')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _messages.isEmpty
              ? const Center(child: Text('这个会话还没有消息'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) {
                    final m = _messages[i];
                    final role = m['role'] as String? ?? 'user';
                    final content = m['content'] as String? ?? '';
                    if (role == 'user') {
                      return _bubble(content, isUser: true);
                    }
                    if (role == 'assistant') {
                      return _bubble(content, isUser: false);
                    }
                    // tool 消息 → 小标签。
                    final toolName = m['tool_name'] as String? ?? 'tool';
                    return Align(
                      alignment: Alignment.center,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: context.appPalette.textSecondary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '🔧 $toolName',
                          style: TextStyle(fontSize: 11, color: context.appPalette.textSecondary),
                        ),
                      ),
                    );
                  },
                ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: widget.onContinue,
            icon: const Icon(Icons.play_arrow),
            label: const Text('继续这个对话'),
            style: FilledButton.styleFrom(
              minimumSize: Size.fromHeight(48),
              backgroundColor: context.appPalette.primary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubble(String text, {required bool isUser}) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
        ),
        child: Text(
          text.isEmpty ? '（空消息）' : text,
          style: const TextStyle(fontSize: 14, height: 1.4),
        ),
      ),
    );
  }
}
