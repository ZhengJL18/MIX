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

/// 公式怎么排。块级用 display（上下标、大型运算符），行内用 text，
/// 避免把正文行高撑开。行内里若塞了矩阵或换行，仍按块级处理。
class LatexLayout {
  const LatexLayout({
    required this.block,
    required this.mathStyle,
    required this.scale,
  });

  final bool block;
  final MathStyle mathStyle;
  final double scale;

  factory LatexLayout.of({required bool isInline, required String content}) {
    final block =
        !isInline || content.contains('\\begin') || content.contains('\n');
    return LatexLayout(
      block: block,
      // display 自己会把运算符放大，不要再叠一层 1.2 的 textScale，
      // 否则块公式会比正文大出一圈。行内保持 1.0，跟着正文字号走。
      mathStyle: block ? MathStyle.display : MathStyle.text,
      scale: block ? 1.05 : 1.0,
    );
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
    final layout = LatexLayout.of(isInline: isInline, content: content);
    // 把周围正文的颜色传进去。不传的话 flutter_math 默认黑色，
    // 深色画布上公式会看不见。
    final paint = style.copyWith(
      color: style.color,
      fontSize: style.fontSize ?? 16,
      height: 1,
    );
    final latex = Math.tex(
      content,
      mathStyle: layout.mathStyle,
      textScaleFactor: layout.scale,
      textStyle: paint,
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
      child: layout.block
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
