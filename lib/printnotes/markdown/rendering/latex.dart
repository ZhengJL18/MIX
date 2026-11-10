//
// Code is from asjqkkkk/markdown_widget examples, modified it a bit
// https://github.com/asjqkkkk/markdown_widget/blob/dev/example/lib/markdown_custom/latex.dart
//

import 'package:flutter/material.dart';

import '../markdown_widget/markdown_widget.dart';

import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as m;

SpanNodeGeneratorWithTag latexGenerator = SpanNodeGeneratorWithTag(
  tag: _latexTag,
  generator: (e, config, visitor) =>
      LatexNode(e.attributes, e.textContent, config),
);

const _latexTag = 'latex';

class LatexSyntax extends m.InlineSyntax {
  LatexSyntax() : super(r'(\$\$[\s\S]+\$\$)|(\$.+?\$)');

  @override
  bool onMatch(m.InlineParser parser, Match match) {
    final input = match.input;
    final matchValue = input.substring(match.start, match.end);
    String content = '';
    bool isInline = true;
    const blockSyntax = '\$\$';
    const inlineSyntax = '\$';
    if (matchValue.startsWith(blockSyntax) &&
        matchValue.endsWith(blockSyntax) &&
        (matchValue != blockSyntax)) {
      content = matchValue.substring(2, matchValue.length - 2);
      isInline = false;
    } else if (matchValue.startsWith(inlineSyntax) &&
        matchValue.endsWith(inlineSyntax) &&
        matchValue != inlineSyntax) {
      content = matchValue.substring(1, matchValue.length - 1);
    }
    m.Element el = m.Element.text(_latexTag, matchValue);
    el.attributes['content'] = content;
    el.attributes['isInline'] = '$isInline';
    parser.addNode(el);
    return true;
  }
}

class LatexNode extends SpanNode {
  final Map<String, String> attributes;
  final String textContent;
  final MarkdownConfig config;

  LatexNode(this.attributes, this.textContent, this.config);

  @override
  InlineSpan build() {
    final content = attributes['content'] ?? '';
    final isInline = attributes['isInline'] == 'true';
    final style = parentStyle ?? config.p.textStyle;
    if (content.isEmpty) return TextSpan(style: style, text: textContent);
    // 行内公式里写了矩阵/方程组等大结构（\begin…\end 或含换行）时，
    // 仍按块级渲染：独占一行 + 大上下间距，避免 5 行高的矩阵把文本行
    // 撑爆、上下文字紧贴矩阵边缘（"叠在一起很难受"）。
    final isBlockLike =
        !isInline || content.contains('\\begin') || content.contains('\n');
    // 字号比例：原来统一 1.5，行内公式会把正文行高硬撑起来（正文 16px
    // 配 24px 公式），一行字下面拖一大块白 —— 这是"公式看着别扭"的根因。
    // 行内按 1.08 跟着正文走，块级给 1.22 保持可读。
    final scale = isBlockLike ? 1.22 : 1.08;
    final latex = Math.tex(
      content,
      mathStyle: MathStyle.text,
      textScaleFactor: scale,
      onErrorFallback: (error) {
        // 渲染失败时不要甩一行刺眼的纯红原文：标成错误色 + 等宽字体，
        // 至少让人看出"这是公式没渲染出来"，而不是以为回答里就写着这些符号。
        // 注：SpanNode.build() 没有 BuildContext，取不到主题色，这里用固定色值。
        return Text(
          textContent,
          style: style.copyWith(
            color: const Color(0xFFD3453B),
            fontFamily: 'monospace',
            fontSize: (style.fontSize ?? 16) * 0.9,
          ),
        );
      },
    );
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: isBlockLike
          ? Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 10),
              // 块级公式居中（MathJax/KaTeX 的默认排版），超宽时才横向滚动。
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Container(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    alignment: Alignment.center,
                    child: latex,
                  ),
                ),
              ),
            )
          : latex,
    );
  }
}
