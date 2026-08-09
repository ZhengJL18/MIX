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
        LatexNode(e.attributes, e.textContent, config));

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
    final latex = Math.tex(
      content,
      mathStyle: MathStyle.text,
      textScaleFactor: 1.5,
      onErrorFallback: (error) {
        return Text(
          textContent,
          style: style.copyWith(color: Colors.red),
        );
      },
    );
    return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: isBlockLike
            ? Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(vertical: 20),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: latex,
                ),
              )
            : latex);
  }
}
