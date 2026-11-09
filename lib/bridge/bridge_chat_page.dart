/// 桥接验收页：直连 harnessd，验证断点续传与事件渲染。
///
/// 独立新增文件，不改动任何现有页面 —— 从任意入口 push 即可测试。
/// 验收要点：断网再恢复后消息不丢不重；切后台再回来能续上。
library;

import 'package:flutter/material.dart';

import 'bridge_client.dart';
import 'bridge_config.dart';
import 'bridge_events.dart';
import 'bridge_session_controller.dart';
import 'bridge_settings_page.dart';
import 'package:mix/theme/theme_ext.dart';

import 'bridge_transcript.dart';

class BridgeChatPage extends StatefulWidget {
  const BridgeChatPage({super.key});

  @override
  State<BridgeChatPage> createState() => _BridgeChatPageState();
}

class _BridgeChatPageState extends State<BridgeChatPage> {
  BridgeClient? _client;
  BridgeSessionController? _ctl;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String? _fatal;
  bool _booting = true;

  @override
  void initState() {
    super.initState();
    _boot();
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
    _client = BridgeClient(baseUrl: cfg.baseUrl, token: cfg.token);
    final ok = await _client!.health();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _booting = false;
        _fatal = '连不上 ${cfg.baseUrl}/healthz\n检查隧道与服务状态';
      });
      return;
    }
    try {
      final session = await _client!.createSession(
        harness: cfg.harness,
        model: cfg.model.isEmpty ? null : cfg.model,
        title: 'Claude bridge',
      );
      if (!mounted) return;
      final ctl = BridgeSessionController(client: _client!, sessionId: session.id);
      ctl.addListener(_onChange);
      _ctl = ctl;
      await ctl.loadHistory();
      await ctl.start();
      setState(() => _booting = false);
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
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const BridgeSettingsPage()),
    );
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
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bridge 验收'),
        actions: [
          if (_ctl != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: Text(_statusLabel(_ctl!.status), style: const TextStyle(fontSize: 12))),
            ),
          IconButton(
            tooltip: '重新拉投影',
            icon: const Icon(Icons.refresh),
            onPressed: _ctl == null ? null : () => _ctl!.loadHistory(),
          ),
          IconButton(
            tooltip: '桥接配置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: _booting
          ? const Center(child: CircularProgressIndicator())
          : _fatal != null
              ? _ErrorView(message: _fatal!, onConfigure: _openSettings)
              : Column(
                  children: [
                    Expanded(child: _messageList()),
                    _composer(),
                  ],
                ),
    );
  }

  Widget _messageList() {
    final ctl = _ctl;
    return BridgeTranscript(
      messages: ctl?.messages ?? const <BridgeBubble>[],
      scrollController: _scroll,
      onToggleThinking: ctl?.toggleThinking,
      empty: const Center(child: Text('发一条消息试试')),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: '发消息给服务器上的 harness',
                  filled: true,
                  fillColor: context.appPalette.inset,
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: context.appPalette.primary,
                foregroundColor: context.appPalette.onPrimary,
                shape: const CircleBorder(),
              ),
              icon: const Icon(Icons.arrow_upward_rounded),
              onPressed: _send,
            ),
          ],
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
    await ctl.send(text);
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

class _ErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function()? onConfigure;
  const _ErrorView({required this.message, this.onConfigure});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 40, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onConfigure != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => onConfigure!(),
                icon: const Icon(Icons.settings),
                label: const Text('去配置'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 生成 BridgeClient 的便捷入口（供其它页面接线用）。
BridgeClient createBridgeClient(BridgeConfig cfg) =>
    BridgeClient(baseUrl: cfg.baseUrl, token: cfg.token);

/// 便于外部按事件类型过滤（如只订阅 turn.end 做通知）。
bool isTerminalEvent(BridgeEvent ev) => ev.type == 'turn.end' || ev.type == 'error';
