// 全局统一 markdown 渲染组件。
//
// 内部用 printnotes 完整渲染引擎（lib/printnotes/markdown/，含 LaTeX/wiki-link/
// #tag/高亮/HTML/代码复制等扩展）。需要 provider 上下文（printnotes 的
// ThemeProvider/SettingsProvider/EditorConfigProvider），hermes 主 App 已包
// MultiProvider。字号/LaTeX 开关等由 printnotes 设置页控制。
//
// HTML 直出（2026-11）：CSS/flex/SVG/<details> 这类东西只有真正的浏览器排版
// 能还原，markdown 子集做不到，所以这部分交给 WebView。
//
// 分派粒度是**块**而不是整条消息：一条回答里「先一张 HTML 卡片、后面接着用
// markdown 写说明」是常见形态，整条走 WebView 会让后面的 markdown 落到第二套
// 实现（package:markdown 的 GFM）上，排版跟其他消息不是一个观感。切块规则见
// html_rich.dart 的 splitHtmlBlocks。
//
// 流式输出期间不切块：token 是逐个到的，块边界每帧都在变，来回切会让内容在
// 「原生 ↔ WebView」之间抖。这一段沿用「按开头锁定」（_htmlLocked）。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/markdown/build_markdown.dart';
import 'package:mix/printnotes/providers/editor_config_provider.dart';

import 'html_rich.dart';

class MIXMarkdown extends StatefulWidget {
  final String data;
  final bool selectable;

  /// 这条内容还在流式追加。
  ///
  /// true 时不切块，按开头锁定一次 HTML 方向；false（默认，含从历史恢复的
  /// 消息）才做块级分派。
  final bool streaming;

  const MIXMarkdown({
    super.key,
    required this.data,
    this.selectable = true,
    this.streaming = false,
  });

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
    // 字号跟 printnotes 设置走。原生引擎正文用的就是
    // `inEditor ? EditorConfigProvider.fontSize : 16`，而 buildMarkdownWidget
    // 内部固定传 inEditor: true —— 所以这里读同一个值才能对齐。
    final fontSize = context.watch<EditorConfigProvider>().fontSize;
    final data = widget.data;

    if (widget.streaming) {
      if (!_htmlLocked && (isHtmlBlock(data) || startsWithHtmlBlock(data))) {
        _htmlLocked = true;
      }
      if (_htmlLocked) {
        return HtmlRichView(html: htmlFromMarkdown(data), fontSize: fontSize);
      }
      return _native(context, data);
    }

    // 完成态：按块分派。纯 markdown 只有一段，零额外开销。
    final pieces = splitHtmlBlocks(data);
    if (pieces.length == 1) {
      final only = pieces.first;
      if (!only.isHtml) return _native(context, data);
      return HtmlRichView(html: only.text, fontSize: fontSize);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < pieces.length; i++)
          if (pieces[i].isHtml)
            Padding(
              padding: EdgeInsets.only(
                top: i == 0 ? 0 : 6,
                bottom: i == pieces.length - 1 ? 0 : 6,
              ),
              child: HtmlRichView(html: pieces[i].text, fontSize: fontSize),
            )
          else
            _native(context, pieces[i].text),
      ],
    );
  }

  Widget _native(BuildContext context, String md) => buildMarkdownWidget(
        context,
        data: md,
        fileUri: Uri.file(''),
        selectable: widget.selectable,
        // 引擎内部是 ListView，嵌在自适应高度容器（聊天气泡）里必须 shrinkWrap，
        // 否则高度塌陷成 0 导致内容不可见。分块后会有多个并列引擎，滚动一律
        // 交给外层列表。
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
      );
}
