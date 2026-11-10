// 全局统一 markdown 渲染组件。
//
// 内部用 printnotes 完整渲染引擎（lib/printnotes/markdown/，含 LaTeX/wiki-link/
// #tag/高亮/HTML/代码复制等扩展）。需要 provider 上下文（printnotes 的
// ThemeProvider/SettingsProvider/EditorConfigProvider），hermes 主 App 已包
// MultiProvider。字号/LaTeX 开关等由 printnotes 设置页控制。
//
// 2026-11 起增加 HTML 直出：整段内容是 HTML（```html 围栏，或裸 <div>/<table>
// 之类的块）时交给 WebView 原生排版 —— CSS/flex/SVG/<details> 全部保真，
// 这是 markdown 子集渲染做不到的上限。普通 markdown 仍走原引擎（更快、
// 可选中、原生交互）。
import 'package:flutter/material.dart';

import '../printnotes/markdown/build_markdown.dart';
import 'html_rich.dart';

class MIXMarkdown extends StatefulWidget {
  final String data;
  final bool selectable;

  const MIXMarkdown({super.key, required this.data, this.selectable = true});

  @override
  State<MIXMarkdown> createState() => _MIXMarkdownState();
}

class _MIXMarkdownState extends State<MIXMarkdown> {
  /// 一旦判定为 HTML 就锁定，直到内容被整体替换。
  ///
  /// 流式输出时 HTML 是逐步到达的：开头 `<div ...>` 已经能认出来，
  /// 但这时候闭合标签还没来，isHtmlBlock 会是 false。如果每帧都重新判断，
  /// 就会在「markdown 原文 ↔ WebView」之间来回抖。所以按「开头」锁一次。
  bool _htmlLocked = false;

  @override
  void didUpdateWidget(covariant MIXMarkdown old) {
    super.didUpdateWidget(old);
    // 内容被整体替换（不是继续追加）→ 重新判断，例如切换会话。
    if (old.data.isNotEmpty && !widget.data.startsWith(old.data)) {
      _htmlLocked = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (!_htmlLocked && (isHtmlBlock(data) || startsWithHtmlBlock(data))) {
      _htmlLocked = true;
    }
    if (_htmlLocked) {
      return HtmlRichView(html: htmlFromMarkdown(data), fontSize: 15);
    }
    return buildMarkdownWidget(
      context,
      data: data,
      fileUri: Uri.file(''),
      selectable: widget.selectable,
      // 引擎内部是 ListView，嵌在自适应高度容器（聊天气泡）里必须 shrinkWrap，
      // 否则高度塌陷成 0 导致内容不可见。
      shrinkWrap: true,
    );
  }
}
