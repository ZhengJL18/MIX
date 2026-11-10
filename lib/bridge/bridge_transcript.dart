/// 云端会话的消息列表。
///
/// 助手正文走 printnotes 渲染（代码块、公式与主对话同一条管线）。
/// 思考块在 `think.delta` 期间展开，正文到来后收起。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:mix/theme/app_theme.dart';
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
        // 用户消息走同一条渲染管线：公式/代码块/HTML 与助手侧观感一致。
        child: bubble.text.isEmpty
            ? const SizedBox.shrink()
            : MIXMarkdown(data: bubble.text, selectable: true),
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
    final segs = bubble.segments;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, right: 4),
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
    final palette = context.appPalette;
    final t = widget.call;
    final label = _describe(t);
    final tint = label.failed ? palette.danger : palette.inkTertiary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statusIcon(t, palette),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: label.verb,
                          style: TextStyle(
                            color: tint,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (label.arg.isNotEmpty)
                          TextSpan(
                            text: ' ${label.arg}',
                            style: TextStyle(
                              color: tint.withValues(alpha: 0.72),
                              fontFamily: 'monospace',
                            ),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, height: 1.35),
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: palette.inkTertiary.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open) _details(context, t),
      ],
    );
  }

  /// 状态位：运行中是转圈，完成是对勾，失败是叉。固定 14×14，让每一行的
  /// 文字起点对齐。
  Widget _statusIcon(BridgeToolCall t, AppPalette palette) {
    if (t.running) {
      return SizedBox(
        width: 14,
        height: 14,
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: CircularProgressIndicator(
            strokeWidth: 1.4,
            color: palette.inkTertiary,
          ),
        ),
      );
    }
    return SizedBox(
      width: 14,
      height: 14,
      child: Icon(
        t.ok ? Icons.check_rounded : Icons.close_rounded,
        size: 13,
        color: t.ok ? palette.success : palette.danger,
      ),
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

  /// 工具名 + input → 一行「动词 + 参数」。参照 Claude 的动词化文案：
  /// 运行中用现在时，完成后用完成时，失败直接把动词换成「…失败」。
  _ToolLabel _describe(BridgeToolCall t) {
    final input = t.input;
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = input[k];
        if (v is String && v.trim().isNotEmpty) return _oneLine(v);
      }
      return '';
    }

    final n = t.name.toLowerCase();
    String zh;
    if (_reTask.hasMatch(n)) {
      zh = '更新任务';
    } else if (_reThink.hasMatch(n)) {
      zh = '思考';
    } else if (_reRead.hasMatch(n)) {
      zh = '读取';
    } else if (_reWrite.hasMatch(n)) {
      zh = '写入';
    } else if (_reEdit.hasMatch(n)) {
      zh = '修改';
    } else if (_reRun.hasMatch(n)) {
      zh = '运行';
    } else if (_reSearch.hasMatch(n)) {
      zh = '搜索';
    } else if (_reFetch.hasMatch(n)) {
      zh = '抓取';
    } else {
      zh = '调用';
    }

    var arg = pick(const [
      'file_path', 'path', 'file', 'target_file', 'notebook_path',
      'dir', 'cwd', 'command', 'cmd', 'script',
      'query', 'pattern', 'glob', 'regex',
      'url', 'href', 'prompt', 'description',
    ]);
    // 通用动词没有参数时用工具名兜底，否则「已调用」后面空着没有信息量。
    if (arg.isEmpty && zh == '调用') arg = t.name;

    final failed = !t.running && !t.ok;
    final String verb;
    if (failed) {
      verb = '$zh失败';
    } else if (t.running) {
      verb = '正在$zh';
    } else {
      verb = '已$zh';
    }
    return _ToolLabel(verb: verb, arg: arg, failed: failed);
  }

  /// 参数摘要只能占一行：换行会把整块顶高，也不再是「一行工具调用」。
  static String _oneLine(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 64 ? '${t.substring(0, 64)}…' : t;
  }
}

class _ToolLabel {
  const _ToolLabel({
    required this.verb,
    required this.arg,
    required this.failed,
  });

  final String verb;
  final String arg;
  final bool failed;
}

// 工具名归类。放文件级是因为流式输出时这条行每帧都会重建，在 build 里现造
// RegExp 是纯浪费。顺序有意义：先认「任务」，否则 TodoWrite 会被 write 抢走。
final RegExp _reTask = RegExp(r'todo|task|plan');
final RegExp _reThink = RegExp(r'think|reason');
final RegExp _reRead = RegExp(r'read|cat|view|open|^ls$|list|stat');
final RegExp _reWrite = RegExp(r'write|create|save|append|touch|mkdir');
final RegExp _reEdit = RegExp(r'edit|patch|replace|update|insert|modify');
final RegExp _reRun = RegExp(r'bash|shell|exec|^run|command|terminal');
final RegExp _reSearch = RegExp(r'grep|search|find|glob|query|locate');
final RegExp _reFetch = RegExp(r'fetch|http|curl|download|browse|web');
