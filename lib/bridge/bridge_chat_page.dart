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
import 'package:mix/widgets/markdown_math.dart';

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
    _config = cfg;
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
        title: 'MIX bridge',
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
    final msgs = _ctl?.messages ?? const <BridgeBubble>[];
    if (msgs.isEmpty) {
      return const Center(child: Text('发一条消息试试', style: TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: msgs.length,
      itemBuilder: (context, i) => _bubble(msgs[i]),
    );
  }

  Widget _bubble(BridgeBubble b) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = b.isUser;
    final isSystem = b.isSystem || b.error != null;
    final bg = isUser
        ? scheme.primaryContainer
        : isSystem
            ? scheme.errorContainer.withValues(alpha: 0.35)
            : scheme.surfaceContainerHighest;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.86),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (b.isThinking)
              Text('思考', style: TextStyle(fontSize: 11, color: scheme.outline))
            else if (isSystem)
              Text('系统', style: TextStyle(fontSize: 11, color: scheme.error)),
            if (b.text.isNotEmpty)
              if (b.isAssistant)
                // 助手输出走 MIX 自己的渲染引擎（与主对话一致：LaTeX/代码高亮/表格/复制）
                MIXMarkdown(data: b.text, selectable: true)
              else
                SelectableText(
                  b.text,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: b.isThinking ? scheme.outline : null,
                    fontStyle: b.isThinking ? FontStyle.italic : null,
                  ),
                ),
            for (final t in b.tools) _toolChip(t),
            if (b.streaming)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: scheme.outline),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolChip(BridgeToolCall t) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            t.running
                ? Icons.hourglass_top
                : (t.ok ? Icons.check_circle_outline : Icons.error_outline),
            size: 14,
            color: t.running ? scheme.outline : (t.ok ? Colors.green : scheme.error),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              t.running ? '${t.name} 运行中' : '${t.name}${t.ok ? '' : ' 失败'}',
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
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
                decoration: const InputDecoration(
                  hintText: '发消息给服务器上的 harness',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              icon: const Icon(Icons.send),
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
