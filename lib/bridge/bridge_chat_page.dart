/// 服务器对话页：直连 harnessd（SSE 断点续传），本机只做渲染。
///
/// 消息列表复用 [BridgeTranscript] —— 与主对话页同一套气泡实现，避免两处
/// 风格漂移。本文件只负责外壳：连接状态、输入区、滚动策略、空态与错误态。
library;

import 'package:flutter/material.dart';

import 'bridge_client.dart';
import 'bridge_config.dart';
import 'bridge_events.dart';
import 'bridge_session_controller.dart';
import 'bridge_settings_page.dart';

import 'package:mix/theme/app_theme.dart';
import 'package:mix/theme/theme_ext.dart';
import 'package:mix/widgets/chat_chrome.dart';

import 'bridge_transcript.dart';

class BridgeChatPage extends StatefulWidget {
  const BridgeChatPage({super.key});

  @override
  State<BridgeChatPage> createState() => _BridgeChatPageState();
}

class _BridgeChatPageState extends State<BridgeChatPage> {
  BridgeConfig? _config;
  BridgeClient? _client;
  BridgeSessionController? _ctl;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  String? _fatal;
  bool _booting = true;
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _boot();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final atBottom = (p.maxScrollExtent - p.pixels) < 120;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  Future<void> _boot() async {
    final cfg = await BridgeConfig.load();
    if (!mounted) return;
    if (!cfg.isComplete) {
      setState(() {
        _booting = false;
        _fatal = '未配置桥接地址与 token（bridge_base_url / bridge_token）';
      });
      return;
    }
    _config = cfg;
    _client = BridgeClient(baseUrl: cfg.baseUrl, token: cfg.token);
    final ok = await _client!.health();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _booting = false;
        _fatal = '连不上 ${cfg.baseUrl}/healthz\n'
            '原因：${_client?.lastHealthError ?? '未知'}\n'
            '检查隧道与服务状态';
      });
      return;
    }
    try {
      final session = await _client!.createSession(
        harness: cfg.harness,
        model: cfg.model.isEmpty ? null : cfg.model,
        title: 'MIX bridge',
      );
      if (!mounted) return;
      final ctl = BridgeSessionController(
        client: _client!,
        sessionId: session.id,
      );
      ctl.addListener(_onChange);
      _ctl = ctl;
      await ctl.loadHistory();
      await ctl.start();
      if (!mounted) return;
      setState(() => _booting = false);
      _jumpToBottom(animate: false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _fatal = '建会话失败：$e';
      });
    }
  }

  /// 打开配置页；保存后重新走一遍启动流程。
  Future<void> _openSettings() async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const BridgeSettingsPage()));
    if (!mounted || saved != true) return;
    _ctl?.removeListener(_onChange);
    _ctl?.dispose();
    _ctl = null;
    _client?.close();
    _client = null;
    setState(() {
      _booting = true;
      _fatal = null;
    });
    await _boot();
  }

  void _onChange() {
    if (!mounted) return;
    // 只有本来就在底部才跟着滚 —— 用户翻上去看历史时不该被拽下来。
    final nearBottom =
        !_scroll.hasClients ||
        (_scroll.position.maxScrollExtent - _scroll.position.pixels) < 200;
    setState(() {});
    if (nearBottom) _jumpToBottom();
  }

  void _jumpToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  @override
  void dispose() {
    _ctl?.removeListener(_onChange);
    _ctl?.dispose();
    _client?.close();
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 最后一条助手消息是否还在流式输出（决定发送键变「停止」）。
  bool get _streaming {
    final msgs = _ctl?.messages;
    if (msgs == null || msgs.isEmpty) return false;
    final last = msgs.last;
    return last.role == 'assistant' && last.streaming;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '服务器对话',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            _statusLine(palette),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '重新拉取服务端消息',
            icon: const Icon(Icons.sync_rounded),
            onPressed: _ctl == null ? null : () => _ctl!.loadHistory(),
          ),
          IconButton(
            tooltip: '桥接配置',
            icon: const Icon(Icons.tune_rounded),
            onPressed: _openSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _booting
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : _fatal != null
          ? ChatEmptyState(
              title: '连不上云端',
              body: _fatal!,
              actionLabel: '去配置',
              onAction: _openSettings,
            )
          : Column(
              children: [
                Expanded(child: _messageList()),
                _composer(),
              ],
            ),
      floatingActionButton: _atBottom || _fatal != null || _booting
          ? null
          : Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FloatingActionButton.small(
                onPressed: () => _jumpToBottom(),
                tooltip: '回到最新',
                child: const Icon(Icons.arrow_downward_rounded, size: 18),
              ),
            ),
    );
  }

  /// 标题下方常驻的状态行：状态点 + 状态 + harness 名。
  ///
  /// 放常驻而不是只在下拉刷新时才看见 —— 断线重连这种事必须一眼能看到。
  Widget _statusLine(AppPalette palette) {
    final s = _ctl?.status ?? BridgeStatus.idle;
    final color = switch (s) {
      BridgeStatus.live => palette.success,
      BridgeStatus.connecting ||
      BridgeStatus.reconnecting => const Color(0xFFD9A441),
      BridgeStatus.offline || BridgeStatus.failed => palette.danger,
      BridgeStatus.idle => palette.inkTertiary,
    };
    final label = _statusLabel(s);
    final harness = _config?.harness ?? '';
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          harness.isEmpty ? label : '$label · $harness',
          style: TextStyle(fontSize: 11.5, color: palette.textSecondary),
        ),
      ],
    );
  }

  Widget _messageList() {
    final ctl = _ctl;
    return BridgeTranscript(
      messages: ctl?.messages ?? const <BridgeBubble>[],
      scrollController: _scroll,
      onToggleThinking: ctl?.toggleThinking,
      empty: _emptyState(),
    );
  }

  Widget _emptyState() {
    return const ChatEmptyState(
      title: 'MIX',
      body: '从这里开始。思考、工具和公式都留在这条对话里。',
      largeTitle: true,
    );
  }

  Widget _composer() {
    final palette = context.appPalette;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: palette.inset,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: palette.border),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 2,
                ),
                child: TextField(
                  controller: _input,
                  focusNode: _inputFocus,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  // 发送键的可用态跟着输入内容走
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.5,
                    color: palette.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: '发消息',
                    hintStyle: TextStyle(
                      fontSize: 16,
                      color: palette.inkTertiary,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _sendButton(palette, streaming: _streaming),
          ],
        ),
      ),
    );
  }

  Widget _sendButton(AppPalette palette, {required bool streaming}) {
    final enabled = streaming || _input.text.trim().isNotEmpty;
    final bg = streaming
        ? palette.sidebar
        : (enabled ? palette.primary : palette.inset);
    final fg = streaming
        ? palette.textPrimary
        : (enabled ? palette.onPrimary : palette.inkTertiary);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(
          color: enabled ? Colors.transparent : palette.border,
        ),
      ),
      // 用 InkWell 而不是 IconButton：IconButton 自带 48dp 触摸区，
      // 塞进 44dp 圆里会报约束冲突。
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? (streaming ? _stop : _send) : null,
          child: Center(
            child: Icon(
              streaming ? Icons.stop_rounded : Icons.arrow_upward_rounded,
              size: 20,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _send() async {
    final ctl = _ctl;
    if (ctl == null) return;
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    setState(() {});
    await ctl.send(text);
    _jumpToBottom();
  }

  Future<void> _stop() async {
    await _ctl?.interrupt();
  }

  String _statusLabel(BridgeStatus s) {
    switch (s) {
      case BridgeStatus.idle:
        return '未连接';
      case BridgeStatus.connecting:
        return '连接中';
      case BridgeStatus.live:
        return '在线';
      case BridgeStatus.reconnecting:
        return '重连中';
      case BridgeStatus.offline:
        return '已断开';
      case BridgeStatus.failed:
        return '失败';
    }
  }
}

/// 生成 BridgeClient 的便捷入口（供其它页面接线用）。
BridgeClient createBridgeClient(BridgeConfig cfg) =>
    BridgeClient(baseUrl: cfg.baseUrl, token: cfg.token);

/// 便于外部按事件类型过滤（如只订阅 turn.end 做通知）。
bool isTerminalEvent(BridgeEvent ev) =>
    ev.type == 'turn.end' || ev.type == 'error';
