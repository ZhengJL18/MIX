/// 会话控制器：把 BridgeClient 的事件流聚合成可直接渲染的状态。
///
/// 设计原则：UI 只读 [messages] / [status]，不感知 SSE 细节。
/// 断线重连、游标持久化、幂等去重全在这一层完成。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bridge_client.dart';
import 'bridge_events.dart';
import 'bridge_store.dart';

/// 连接状态（UI 用来显示横幅）。
enum BridgeStatus { idle, connecting, live, reconnecting, offline, failed }

/// 一条可渲染的消息（用户 / 助手 / 思考 / 系统提示 / 工具）。
class BridgeBubble {
  final String role; // user | assistant | thinking | system | tool
  String text;
  final int ts;
  final List<BridgeToolCall> tools;
  bool streaming;
  String? error;

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

  /// 用服务端投影覆盖本地消息（冷启动时比逐条 replay 更快）。
  Future<void> loadHistory() async {
    try {
      final list = await client.messages(sessionId);
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
            ),
        ]);
      notifyListeners();
    } catch (e) {
      lastError = '$e';
      notifyListeners();
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
        a.tools.add(BridgeToolCall(
          callId: ev.toolCallId,
          name: ev.toolName,
          input: ev.data['input'] is Map ? Map<String, dynamic>.from(ev.data['input'] as Map) : const {},
        ));
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
