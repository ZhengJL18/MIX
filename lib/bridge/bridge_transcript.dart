/// 云端会话的消息列表。
///
/// 助手正文走 printnotes 渲染（代码块、公式与主对话同一条管线）。
/// 思考块在 `think.delta` 期间展开，正文到来后收起。
library;

import 'package:flutter/material.dart';

import 'package:mix/theme/theme_ext.dart';
import 'package:mix/widgets/markdown_math.dart';

import 'bridge_session_controller.dart';

class BridgeTranscript extends StatelessWidget {
  const BridgeTranscript({
    super.key,
    required this.messages,
    required this.scrollController,
    this.onToggleThinking,
    this.lastKey,
    this.empty,
  });

  final List<BridgeBubble> messages;
  final ScrollController scrollController;
  final void Function(BridgeBubble bubble)? onToggleThinking;
  final Key? lastKey;
  final Widget? empty;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return empty ?? const SizedBox.shrink();
    }
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final child = _BridgeBubbleView(
          bubble: messages[i],
          onToggleThinking: onToggleThinking,
        );
        if (i == messages.length - 1 && lastKey != null) {
          return KeyedSubtree(key: lastKey, child: child);
        }
        return child;
      },
    );
  }
}

class _BridgeBubbleView extends StatelessWidget {
  const _BridgeBubbleView({
    required this.bubble,
    this.onToggleThinking,
  });

  final BridgeBubble bubble;
  final void Function(BridgeBubble bubble)? onToggleThinking;

  @override
  Widget build(BuildContext context) {
    if (bubble.isThinking) return _thinking(context);
    if (bubble.isUser) return _user(context);
    if (bubble.isSystem || bubble.error != null) return _system(context);
    return _assistant(context);
  }

  Widget _user(BuildContext context) {
    final palette = context.appPalette;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12, left: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        decoration: BoxDecoration(
          color: palette.bubble,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          bubble.text,
          style: TextStyle(color: palette.textPrimary, height: 1.4),
        ),
      ),
    );
  }

  Widget _thinking(BuildContext context) {
    final palette = context.appPalette;
    final showBody = bubble.streaming || !bubble.collapsed;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.92),
        decoration: BoxDecoration(
          color: palette.sidebar,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: bubble.streaming ? null : () => onToggleThinking?.call(bubble),
              child: Row(
                children: [
                  Icon(Icons.psychology_outlined, size: 14, color: palette.inkTertiary),
                  const SizedBox(width: 6),
                  Text(
                    bubble.streaming ? '思考中…' : '已思考',
                    style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: palette.inkTertiary,
                    ),
                  ),
                  if (bubble.streaming) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: palette.inkTertiary,
                      ),
                    ),
                  ] else
                    Icon(
                      showBody ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: palette.inkTertiary,
                    ),
                ],
              ),
            ),
            if (showBody && bubble.text.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                bubble.text,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                  color: palette.inkTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _assistant(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bubble.text.isNotEmpty)
            MIXMarkdown(data: bubble.text, selectable: true),
          for (final t in bubble.tools) _toolChip(context, t),
          if (bubble.streaming && bubble.text.isEmpty && bubble.tools.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '正在回复…',
                style: TextStyle(fontSize: 13, color: palette.inkTertiary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toolChip(BuildContext context, BridgeToolCall t) {
    final palette = context.appPalette;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: palette.border),
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
            color: t.running
                ? palette.inkTertiary
                : (t.ok ? palette.success : scheme.error),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              t.running ? '${t.name} 运行中' : '${t.name}${t.ok ? '' : ' 失败'}',
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _system(BuildContext context) {
    final palette = context.appPalette;
    final scheme = Theme.of(context).colorScheme;
    final failed = bubble.error != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        bubble.text,
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: failed ? scheme.error : palette.inkTertiary,
        ),
      ),
    );
  }
}
