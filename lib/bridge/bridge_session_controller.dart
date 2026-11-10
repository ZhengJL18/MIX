/// 会话控制器：把 BridgeClient 的事件流聚合成可直接渲染的状态。
///
/// 设计原则：UI 只读 [messages] / [status]，不感知 SSE 细节。
/// 断线重连、游标持久化、幂等去重全在这一层完成。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bridge_cache.dart';
import 'bridge_client.dart';
import 'bridge_events.dart';
import 'bridge_store.dart';

/// 连接状态（UI 用来显示横幅）。
enum BridgeStatus { idle, connecting, live, reconnecting, offline, failed }

/// 助手消息里的一个内容片段。
///
/// 服务端事件是交错的（一段正文 → 一次工具调用 → 再一段正文），但旧模型把
/// 正文拍平成 `text`、工具放独立数组，渲染时只能「正文全部在前、工具全部在
/// 后」，跟真实发生的顺序不符。这里按到达顺序留一份分段表供渲染用；
/// `text` 仍保留全文，历史恢复等只填 text 的路径继续走旧渲染。
sealed class BridgeSegment {
  const BridgeSegment();
}

/// 一段正文增量。
class BridgeTextSeg extends BridgeSegment {
  final StringBuffer buf = StringBuffer();
  BridgeTextSeg([String initial = '']) {
    buf.write(initial);
  }
}

/// 一次工具调用。
class BridgeToolSeg extends BridgeSegment {
  final BridgeToolCall call;
  const BridgeToolSeg(this.call);
}

/// 一条可渲染的消息（用户 / 助手 / 思考 / 系统提示 / 工具）。
class BridgeBubble {
  final String role; // user | assistant | thinking | system | tool
  String text;
  final int ts;
  final List<BridgeToolCall> tools;
  bool streaming;
  String? error;

  /// 正文与工具按到达顺序交错的分段表（仅助手消息使用）。
  final List<BridgeSegment> segments = [];

  /// 思考块在正文到来或回合结束后收起，点按可再展开。
  bool collapsed;

  /// 本地乐观插入、等待服务端 user.message 事件认领的消息。
  bool optimistic;

  BridgeBubble({
    required this.role,
    this.text = '',
    required this.ts,
    List<BridgeToolCall>? tools,
    this.streaming = false,
    this.error,
    this.collapsed = false,
    this.optimistic = false,
  }) : tools = tools ?? <BridgeToolCall>[];

  /// 追加一段正文：并入末尾文本段，或在工具调用之后另起一段。
  void appendText(String delta) {
    if (delta.isEmpty) return;
    if (segments.isNotEmpty && segments.last is BridgeTextSeg) {
      (segments.last as BridgeTextSeg).buf.write(delta);
    } else {
      segments.add(BridgeTextSeg(delta));
    }
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isThinking => role == 'thinking';
  bool get isTool => role == 'tool';
  bool get isSystem => role == 'system';
}

/// 一次工具调用的渲染态。
class BridgeToolCall {
  final String callId;
  final String name;
  final Map<String, dynamic> input;
  bool running;
  bool ok;
  String preview;

  BridgeToolCall({
    required this.callId,
    required this.name,
    this.input = const {},
    this.running = true,
    this.ok = false,
    this.preview = '',
  });
}

/// 一次会话的 UI 状态机。
class BridgeSessionController extends ChangeNotifier {
  final BridgeClient client;
  final String sessionId;

  BridgeSessionController({required this.client, required this.sessionId});

  final List<BridgeBubble> messages = [];
  BridgeStatus status = BridgeStatus.idle;
  String? lastError;
  int cursor = 0;

  /// 本地缓存最后一次与服务端对齐的时间（毫秒）。UI 可据此提示「离线内容」。
  int cacheSyncedAt = 0;

  StreamSubscription<BridgeEvent>? _sub;
  BridgeBubble? _openAssistant;
  BridgeBubble? _openThinking;
  bool _disposed = false;

  /// 从发出消息到 turn.end / error。停止按钮看这个，而不是连接是否还活着。
  bool turnActive = false;

  bool get isBusy => status == BridgeStatus.connecting || status == BridgeStatus.live;

  /// 展开或收起一条思考块。
  void toggleThinking(BridgeBubble bubble) {
    bubble.collapsed = !bubble.collapsed;
    notifyListeners();
  }

  /// 启动：从持久化游标续传，然后把新事件一路追平。
  Future<void> start() async {
    if (_disposed) return;
    cursor = await BridgeCursorStore.load(sessionId);
    _setStatus(BridgeStatus.connecting);
    _sub = client
        .stream(
          sessionId,
          fromSeq: cursor,
          onCursor: (seq) {
            cursor = seq;
            // 游标落盘（不 await：高频路径上不阻塞事件处理）
            unawaited(BridgeCursorStore.save(sessionId, seq));
          },
          // TCP 一通就算在线：新会话没有历史事件，不能一直停在"连接中"。
          onConnected: () => _setStatus(BridgeStatus.live),
        )
        .listen(
          applyEvent,
          onError: (Object e) {
            lastError = '$e';
            _setStatus(BridgeStatus.failed);
          },
          onDone: () {
            if (!_disposed) _setStatus(BridgeStatus.offline);
          },
          cancelOnError: false,
        );
  }

  /// 发送一条用户消息（服务端 202 后 turn 在后台跑）。
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    messages.add(BridgeBubble(
      role: 'user',
      text: trimmed,
      ts: DateTime.now().millisecondsSinceEpoch,
      optimistic: true,
    ));
    _collapseThinking();
    _openAssistant = null;
    turnActive = true;
    notifyListeners();
    try {
      await client.sendMessage(sessionId, trimmed);
    } catch (e) {
      turnActive = false;
      lastError = '$e';
      messages.add(BridgeBubble(
        role: 'system',
        text: '发送失败：$e',
        ts: DateTime.now().millisecondsSinceEpoch,
        error: '$e',
      ));
      notifyListeners();
    }
  }

  Future<void> interrupt() async {
    try {
      await client.interrupt(sessionId);
    } catch (e) {
      lastError = '$e';
    }
    turnActive = false;
    _collapseThinking();
    _closeOpen();
    notifyListeners();
  }

  /// 冷启动加载会话。
  ///
  /// 两步，顺序不能反：
  /// 1. **先渲染盘上的缓存** —— 断网或服务不可达时，这是唯一能看的内容。
  /// 2. **再拉服务端投影覆盖** —— 服务端是金标准，本地任何分歧都以它为准，
  ///    不做合并也不需要冲突解决。
  ///
  /// 覆盖成功后把本地 SSE 游标对齐到服务端水位。少了这一步，`start()` 会从旧
  /// 游标重新 replay 历史事件，和刚拿到的投影叠成重复气泡。
  Future<void> loadHistory() async {
    // ── 1. 盘上的先上屏 ──
    // 正在出字的时候不铺缓存：那会把流式内容整段清掉、闪回旧快照。
    try {
      if (!turnActive) {
        final cached = await BridgeCache.load(sessionId);
        if (cached != null && cached.messages.isNotEmpty) {
          _replaceMessages(cached.messages);
          cacheSyncedAt = cached.syncedAt;
          notifyListeners();
        }
      }
    } catch (_) {
      // 缓存读失败不影响主路径：下面还有网络。
    }

    // ── 2. 服务端覆盖 ──
    try {
      final page = await client.messagesPage(sessionId);
      _replaceMessages(page.messages);
      cacheSyncedAt = DateTime.now().millisecondsSinceEpoch;
      lastError = null;

      // 落盘是旁路：写失败只说明缓存不可用，不能污染会话状态、更不能因此
      // 跳过下面的游标对齐（那会导致重连时重复 replay）。
      try {
        await BridgeCache.replaceAll(
          sessionId,
          page.messages,
          lastSeq: page.lastSeq,
          appliedSeq: page.appliedSeq,
        );
      } catch (_) {}

      // 投影落后于事件流时只能推到 applied_seq：再往前的那些事件还没被折叠，
      // 推过头就等于把它们跳过，客户端会永远缺一段内容。
      final safeCursor = page.projectionBehind ? page.appliedSeq : page.lastSeq;
      if (safeCursor > cursor) {
        cursor = safeCursor;
        await BridgeCursorStore.save(sessionId, cursor);
      }
      notifyListeners();
    } catch (e) {
      lastError = '$e';
      notifyListeners();
    }
  }

  /// 把投影消息铺成气泡（清空后重建）。
  void _replaceMessages(List<BridgeMessage> list) {
    messages
      ..clear()
      ..addAll([
        for (final m in list)
          BridgeBubble(
            role: m.role,
            text: m.text,
            ts: m.ts,
            collapsed: m.role == 'thinking',
            tools: [
              for (final t in (m.meta['tools'] is List ? m.meta['tools'] as List : const []))
                if (t is Map)
                  BridgeToolCall(
                    callId: '${t['call'] ?? ''}',
                    name: '${t['name'] ?? ''}',
                    running: false,
                    ok: t['ok'] == true,
                  ),
            ],
            error: m.meta['error'] is String ? m.meta['error'] as String : null,
          ),
      ]);
  }

  /// 把当前内存里的会话整份落盘（流式过程中不写，回合结束时写一次）。
  ///
  /// 中途被杀只丢当前 turn 的部分内容 —— 那个 turn 还在服务端跑，下次
  /// [loadHistory] 会从投影把它拉回来，不会丢结果。
  Future<void> _persistSnapshot() async {
    if (_disposed || messages.isEmpty) return;
    final snapshot = <BridgeMessage>[
      for (var i = 0; i < messages.length; i++)
        BridgeMessage(
          ord: i + 1,
          role: messages[i].role,
          text: messages[i].text,
          ts: messages[i].ts,
          meta: {
            if (messages[i].tools.isNotEmpty)
              'tools': [
                for (final t in messages[i].tools)
                  {'call': t.callId, 'name': t.name, 'ok': t.ok},
              ],
            if (messages[i].error != null) 'error': messages[i].error,
          },
        ),
    ];
    try {
      await BridgeCache.replaceAll(
        sessionId,
        snapshot,
        lastSeq: cursor,
        appliedSeq: cursor,
      );
      cacheSyncedAt = DateTime.now().millisecondsSinceEpoch;
    } catch (_) {
      // 落盘失败不该影响正在进行的对话。
    }
  }

  // ── 事件 → 状态 ────────────────────────────────────────────────────────
  /// 把一条 harness 事件折进 [messages]。单测直接调它，不走网络。
  void applyEvent(BridgeEvent ev) {
    if (_disposed) return;
    if (status != BridgeStatus.live) _setStatus(BridgeStatus.live);
    final now = ev.ts > 0 ? ev.ts : DateTime.now().millisecondsSinceEpoch;

    switch (ev.type) {
      case 'user.message':
        // send() 已乐观插入同文本气泡：这里认领它，避免显示两遍。
        final pendingIdx = messages.lastIndexWhere((m) => m.isUser && m.optimistic);
        if (pendingIdx >= 0 && messages[pendingIdx].text == ev.text) {
          messages[pendingIdx].optimistic = false;
        } else {
          messages.add(BridgeBubble(role: 'user', text: ev.text, ts: now));
        }
        _openAssistant = null;
        break;

      case 'turn.start':
        _collapseThinking();
        _openAssistant = null;
        turnActive = true;
        break;

      case 'text.delta':
        // 正文一到就把思考收起，避免推理全文一直摊在对话里。
        _collapseThinking();
        final a = _openAssistant ??= _newBubble('assistant', now);
        a.text += ev.text;
        a.appendText(ev.text);
        a.streaming = true;
        turnActive = true;
        break;

      case 'think.delta':
        final t = _openThinking ??= _newBubble('thinking', now);
        t.collapsed = false;
        t.text += ev.text;
        t.streaming = true;
        turnActive = true;
        break;

      case 'tool.start':
        final a = _openAssistant ??= _newBubble('assistant', now);
        final call = BridgeToolCall(
          callId: ev.toolCallId,
          name: ev.toolName,
          input: ev.data['input'] is Map ? Map<String, dynamic>.from(ev.data['input'] as Map) : const {},
        );
        a.tools.add(call);
        a.segments.add(BridgeToolSeg(call));
        break;

      case 'tool.end':
        for (final b in messages.reversed) {
          final hit = b.tools.where((t) => t.callId == ev.toolCallId).toList();
          if (hit.isEmpty) continue;
          hit.first
            ..running = false
            ..ok = ev.toolOk
            ..preview = (ev.data['preview'] as String?) ?? '';
          break;
        }
        break;

      case 'turn.end':
        _collapseThinking();
        _closeOpen();
        turnActive = false;
        final usage = ev.usage;
        if (usage != null) {
          messages.add(BridgeBubble(
            role: 'system',
            text: '完成 · stop=${ev.stopReason}'
                '${usage['output_tokens'] != null ? ' · 输出 ${usage['output_tokens']} tokens' : ''}',
            ts: now,
          ));
        }
        // 回合结束才落盘：流式期间每条 token 都写会白烧 IO，而回合之间
        // 被杀的情况，服务端投影能补回完整结果。
        unawaited(_persistSnapshot());
        break;

      case 'error':
        _collapseThinking();
        _closeOpen();
        turnActive = false;
        messages.add(BridgeBubble(
          role: 'system',
          text: '出错：${ev.errorMessage}',
          ts: now,
          error: ev.errorMessage,
        ));
        unawaited(_persistSnapshot());
        break;

      case 'notice':
        messages.add(BridgeBubble(
          role: 'system',
          text: '${ev.data['message'] ?? ''}',
          ts: now,
        ));
        break;

      default:
        break; // provider.init 等元数据不影响渲染
    }
    notifyListeners();
  }

  BridgeBubble _newBubble(String role, int ts) {
    final b = BridgeBubble(role: role, ts: ts);
    messages.add(b);
    return b;
  }

  void _collapseThinking() {
    final t = _openThinking;
    if (t == null) return;
    t.streaming = false;
    t.collapsed = true;
    _openThinking = null;
  }

  void _closeOpen() {
    _openAssistant?.streaming = false;
    _openThinking?.streaming = false;
    _openAssistant = null;
    _openThinking = null;
  }

  void _setStatus(BridgeStatus s) {
    if (status == s) return;
    status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
