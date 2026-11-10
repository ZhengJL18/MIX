/// 对话页的 Claude 式外壳：用户气泡、思考行、工具/事件行、空态、细通知条。
///
/// 状态不做成小卡片。工具和思考是对话里的一行，点开才展开；空态和离线
/// 通知在主对话和服务器对话页共用，避免两处各写一套。
library;

import 'package:flutter/material.dart';

import 'package:mix/theme/app_theme.dart';
import 'package:mix/theme/theme_ext.dart';

/// 用户消息。右对齐暖灰气泡，正文由调用方放进同一条渲染管线
/// （[MIXMarkdown]），这里只负责气泡形状。
class ChatUserBubble extends StatelessWidget {
  const ChatUserBubble({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final width = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14, left: 56),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        constraints: BoxConstraints(maxWidth: width * 0.78),
        decoration: BoxDecoration(
          color: palette.bubble,
          borderRadius: BorderRadius.circular(18),
        ),
        child: child,
      ),
    );
  }
}

/// 助手正文的外边距。正文直接落在画布上，不套气泡。
class AssistantBlock extends StatelessWidget {
  const AssistantBlock({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, right: 8),
      child: child,
    );
  }
}

/// 思考过程：一行「思考中 / 已思考」，展开后用左侧细线承接正文。
/// 没有底色、没有圆角方块。
class ThinkingBlock extends StatelessWidget {
  const ThinkingBlock({
    super.key,
    required this.text,
    required this.streaming,
    required this.expanded,
    this.onToggle,
  });

  final String text;
  final bool streaming;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final showBody = streaming || expanded;
    final ink = palette.inkTertiary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: streaming ? null : onToggle,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.psychology_outlined, size: 15, color: ink),
                  const SizedBox(width: 8),
                  Text(
                    streaming ? '思考中…' : '已思考',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      fontWeight: FontWeight.w500,
                      color: ink,
                    ),
                  ),
                  if (streaming) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.4,
                        color: ink,
                      ),
                    ),
                  ] else
                    Icon(
                      showBody ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: ink.withValues(alpha: 0.7),
                    ),
                ],
              ),
            ),
          ),
          if (showBody && text.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 6, top: 2, bottom: 4),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: palette.border, width: 1.5),
                ),
              ),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.55,
                  color: ink,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 工具调用或短事件。一行图标 + 动词 + 参数，不带边框和底色。
class ChatEventRow extends StatelessWidget {
  const ChatEventRow({
    super.key,
    required this.running,
    required this.ok,
    required this.verb,
    this.detail = '',
    this.expanded = false,
    this.monoDetail = true,
    this.onToggle,
    this.onTap,
    this.details,
  });

  final bool running;
  final bool ok;
  final String verb;
  final String detail;
  final bool expanded;
  final bool monoDetail;
  final VoidCallback? onToggle;
  final VoidCallback? onTap;
  final Widget? details;

  bool get _failed => !running && !ok;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final tint = _failed ? palette.danger : palette.inkTertiary;
    final toggle = onToggle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: toggle ?? onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statusIcon(palette),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: verb,
                          style: TextStyle(
                            color: tint,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (detail.isNotEmpty)
                          TextSpan(
                            text: ' $detail',
                            style: TextStyle(
                              color: tint.withValues(alpha: 0.72),
                              fontFamily: monoDetail ? 'monospace' : null,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, height: 1.35),
                  ),
                ),
                if (toggle != null) ...[
                  const SizedBox(width: 6),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: palette.inkTertiary.withValues(alpha: 0.55),
                  ),
                ] else if (onTap != null) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.north_east_rounded,
                    size: 13,
                    color: palette.inkTertiary.withValues(alpha: 0.55),
                  ),
                ],
              ],
            ),
          ),
        ),
        ?details,
      ],
    );
  }

  Widget _statusIcon(AppPalette palette) {
    if (running) {
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
        ok ? Icons.check_rounded : Icons.close_rounded,
        size: 13,
        color: ok ? palette.success : palette.danger,
      ),
    );
  }
}

/// 系统提示或错误。同样是一行，不做成卡片。
class ChatMetaLine extends StatelessWidget {
  const ChatMetaLine({super.key, required this.text, this.failed = false});

  final String text;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final scheme = Theme.of(context).colorScheme;
    final color = failed ? scheme.error : palette.inkTertiary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              failed ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              size: 14,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, height: 1.45, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// 会话空态。问候和「连不上」用同一套排版，只换文案和动作。
class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({
    super.key,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
    this.largeTitle = false,
  });

  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final bool largeTitle;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Image(
              image: AssetImage('assets/brand/mix_mark.png'),
              width: 44,
              height: 44,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: largeTitle ? 28 : 18,
                fontWeight: FontWeight.w600,
                letterSpacing: largeTitle ? -0.6 : -0.2,
                height: 1.2,
                color: palette.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                height: 1.55,
                color: palette.textSecondary,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: palette.primary,
                  foregroundColor: palette.onPrimary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                ),
                child: Text(actionLabel!),
              ),
            ],
            if (secondaryLabel != null && onSecondary != null) ...[
              const SizedBox(height: 4),
              TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 输入区上方的一条状态。全宽细条，不是圆角卡片。
class SessionNotice extends StatelessWidget {
  const SessionNotice({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: palette.inkTertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: palette.textPrimary,
                    ),
                  ),
                  if (detail != null && detail!.isNotEmpty)
                    Text(
                      detail!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: palette.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (actionLabel != null && onAction != null)
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ),
      ),
    );
  }
}

/// 工具名 + 入参 → 「动词 + 参数」。
///
/// 运行中用现在时，完成后用完成时，失败把动词换成「…失败」。
class ToolPhrase {
  const ToolPhrase({
    required this.verb,
    required this.arg,
    required this.failed,
  });

  final String verb;
  final String arg;
  final bool failed;
}

ToolPhrase describeToolPhrase({
  required String name,
  required bool running,
  required bool ok,
  Map<String, dynamic> input = const {},
}) {
  String pick(List<String> keys) {
    for (final k in keys) {
      final v = input[k];
      if (v is String && v.trim().isNotEmpty) return _oneLine(v);
    }
    return '';
  }

  final n = name.toLowerCase();
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
    'file_path',
    'path',
    'file',
    'target_file',
    'notebook_path',
    'dir',
    'cwd',
    'command',
    'cmd',
    'script',
    'query',
    'pattern',
    'glob',
    'regex',
    'url',
    'href',
    'prompt',
    'description',
  ]);
  if (arg.isEmpty && zh == '调用' && name.isNotEmpty) arg = name;

  final failed = !running && !ok;
  final String verb;
  if (failed) {
    verb = '$zh失败';
  } else if (running) {
    verb = '正在$zh';
  } else {
    verb = '已$zh';
  }
  return ToolPhrase(verb: verb, arg: arg, failed: failed);
}

String _oneLine(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 64 ? '${t.substring(0, 64)}…' : t;
}

// 顺序有意义：先认「任务」，否则 TodoWrite 会被 write 抢走。
final RegExp _reTask = RegExp(r'todo|task|plan');
final RegExp _reThink = RegExp(r'think|reason');
final RegExp _reRead = RegExp(r'read|cat|view|open|^ls$|list|stat');
final RegExp _reWrite = RegExp(r'write|create|save|append|touch|mkdir');
final RegExp _reEdit = RegExp(r'edit|patch|replace|update|insert|modify');
final RegExp _reRun = RegExp(r'bash|shell|exec|^run|command|terminal');
final RegExp _reSearch = RegExp(r'grep|search|find|glob|query|locate');
final RegExp _reFetch = RegExp(r'fetch|http|curl|download|browse|web');
