/// 云端会话的消息列表。
///
/// 助手正文走 printnotes 渲染（代码块、公式与主对话同一条管线）。
/// 思考块在 `think.delta` 期间展开，正文到来后收起。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:mix/theme/theme_ext.dart';
import 'package:mix/widgets/chat_chrome.dart';
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
    if (bubble.text.isEmpty) return const SizedBox.shrink();
    // 用户消息走同一条渲染管线：公式/代码块/HTML 与助手侧观感一致。
    return ChatUserBubble(
      child: MIXMarkdown(data: bubble.text, selectable: true),
    );
  }

  Widget _thinking(BuildContext context) {
    final showBody = bubble.streaming || !bubble.collapsed;
    return ThinkingBlock(
      text: bubble.text,
      streaming: bubble.streaming,
      expanded: showBody,
      onToggle: bubble.streaming ? null : () => onToggleThinking?.call(bubble),
    );
  }

  Widget _assistant(BuildContext context) {
    final palette = context.appPalette;
    final segs = bubble.segments;
    return AssistantBlock(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 有分段表就按到达顺序交错渲染；历史恢复等只填了 text 的走旧路径。
          if (segs.isEmpty) ...[
            if (bubble.text.isNotEmpty)
              MIXMarkdown(data: bubble.text, selectable: true),
            for (final t in bubble.tools) _ToolRow(call: t),
          ] else
            for (var i = 0; i < segs.length; i++)
              _segment(context, segs[i], isLast: i == segs.length - 1),
          if (bubble.streaming && segs.isEmpty && bubble.text.isEmpty)
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

  Widget _segment(
    BuildContext context,
    BridgeSegment seg, {
    required bool isLast,
  }) {
    if (seg is BridgeToolSeg) {
      return _ToolRow(call: seg.call);
    }
    final text = (seg as BridgeTextSeg).buf.toString();
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return MIXMarkdown(
      data: text,
      selectable: true,
      // 只有最后一段可能还在追加；前面几段已经定型，可以按块分派。
      streaming: bubble.streaming && isLast,
    );
  }

  Widget _system(BuildContext context) {
    return ChatMetaLine(text: bubble.text, failed: bubble.error != null);
  }
}

// ============================================================================
// 工具调用行
// ============================================================================
//
// 视觉参照 Claude：**不是卡片** —— 没有边框、没有底色、没有圆角方块。
// 只有一行「状态图标 + 动词 + 参数摘要」，点按在原位展开详情，详情用一条极细
// 的竖线标示层级。理由：工具调用在一条回答里可能出现十几次，用小卡片会把
// 对话切成碎片；做成行才读得下去，也才有「Agent 在干活」的连续感。

class _ToolRow extends StatefulWidget {
  const _ToolRow({required this.call});

  final BridgeToolCall call;

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.call;
    final label = describeToolPhrase(
      name: t.name,
      running: t.running,
      ok: t.ok,
      input: t.input,
    );

    return ChatEventRow(
      running: t.running,
      ok: t.ok,
      verb: label.verb,
      detail: label.arg,
      expanded: _open,
      onToggle: () => setState(() => _open = !_open),
      details: _open ? _details(context, t) : null,
    );
  }

  Widget _details(BuildContext context, BridgeToolCall t) {
    final palette = context.appPalette;
    final rows = <Widget>[
      Text(
        t.name,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: palette.inkTertiary.withValues(alpha: 0.7),
        ),
      ),
    ];
    for (final e in t.input.entries) {
      rows.add(_kv(context, e.key, _stringify(e.value)));
    }
    if (t.preview.isNotEmpty) {
      rows.add(const SizedBox(height: 4));
      rows.add(_kv(context, '结果', _stringify(t.preview)));
    }
    return Container(
      margin: const EdgeInsets.only(left: 6, bottom: 2),
      padding: const EdgeInsets.only(left: 10, top: 3, bottom: 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: palette.border, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 74,
            child: Text(
              k,
              style: TextStyle(
                fontSize: 11,
                height: 1.45,
                color: palette.inkTertiary.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              v,
              maxLines: 12,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                fontFamily: 'monospace',
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 值可能是字符串，也可能是嵌套 Map/List —— 统一转成可读文本并截断。
  static String _stringify(Object? v) {
    if (v == null) return '';
    var s = v is String ? v : _tryJson(v);
    if (s.length > 1600) s = '${s.substring(0, 1600)}…';
    return s;
  }

  static String _tryJson(Object v) {
    try {
      return jsonEncode(v);
    } catch (_) {
      return '$v';
    }
  }
}
