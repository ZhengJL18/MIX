// 公式占位符保护：在 markdown 解析之前把 LaTeX 公式（$...$ / $$...$$）
// 提取成 PUA 私有区占位符，等 markdown 解析完成后在渲染层还原成公式节点。
//
// 这是 Obsidian/MathJax 处理行内/块级公式的标准思路，能一次性解决：
//   1. markdown 转义层破坏 LaTeX（\\、\{ 被吃反斜杠）；
//   2. 扩展语法与公式冲突（_ 下标、&、~、== 高亮等吞掉公式内符号）；
//   3. 原 LatexSyntax 贪婪正则 \$\$[\s\S]+\$\$ 把同段落多个公式吞并；
//   4. 多行 $...$（单美元）公式因 . 不匹配换行而解析失败。
//
// 同时跳过 fenced code block 和 inline code，避免把代码里的 $ 误判成公式。

import 'dart:convert';

const String _phStart = '\uE000'; // 公式占位符起始（PUA 私有区）
const String _phTag = 'MXL';
const String _phEnd = '\uE001'; // 公式占位符结束
const String _codeStart = '\uE002'; // 代码占位符起始
const String _codeEnd = '\uE003'; // 代码占位符结束

// 块级 $$...$$（非贪婪，避免吞并多个公式；[\s\S] 允许跨行）
final RegExp _blockLatexReg = RegExp(r'\$\$[\s\S]+?\$\$');
// 行内 $...$（单行、不含 $、排除 \$ 转义）
final RegExp _inlineLatexReg = RegExp(r'(?<!\\)\$[^$\n]+\$');
final RegExp _placeholderReg =
    RegExp('\uE000MXL([ib])([0-9a-f]+)\uE001');
final RegExp _codePlaceholderReg = RegExp('\uE002\\d+\uE003');
final RegExp _fenceReg = RegExp(r'```[\s\S]*?```|~~~[\s\S]*?~~~');
final RegExp _inlineCodeReg = RegExp(r'`[^`\n]*`');

/// 把 [input] 中所有 LaTeX 公式替换为占位符，返回保护后的文本。
/// 代码块与行内代码中的 $ 不受影响。
String protectLatex(String input) {
  // 1. 先把 fenced code block 和 inline code 整体换成占位符，
  //    避免后续公式替换误伤代码里的 $。
  final codeMap = <String, String>{};
  var codeIdx = 0;
  String takeCode(String code) {
    final key = '$_codeStart${codeIdx++}$_codeEnd';
    codeMap[key] = code;
    return key;
  }

  var tmp = input.replaceAllMapped(_fenceReg, (m) => takeCode(m.group(0)!));
  tmp = tmp.replaceAllMapped(_inlineCodeReg, (m) => takeCode(m.group(0)!));

  // 2. 公式替换（此时文本中已无代码干扰）
  tmp = tmp.replaceAllMapped(_blockLatexReg, (m) {
    final s = m.group(0)!;
    return _encode(s.substring(2, s.length - 2), isInline: false);
  });
  tmp = tmp.replaceAllMapped(_inlineLatexReg, (m) {
    final s = m.group(0)!;
    return _encode(s.substring(1, s.length - 1), isInline: true);
  });

  // 3. 还原代码占位符，让 markdown 正常解析代码块/行内代码
  tmp = tmp.replaceAllMapped(
      _codePlaceholderReg, (m) => codeMap[m.group(0)!] ?? '');
  return tmp;
}

/// 拆分文本：普通文本段与公式占位符段交替返回。
/// 返回列表里 [LatexPart.latex] 非 null 的是公式段。
List<LatexPart> splitLatex(String text) {
  final parts = <LatexPart>[];
  var last = 0;
  for (final m in _placeholderReg.allMatches(text)) {
    if (m.start > last) {
      parts.add(LatexPart(text: text.substring(last, m.start)));
    }
    parts.add(LatexPart(
      latex: _decodeHex(m.group(2)!),
      isInline: m.group(1) == 'i',
    ));
    last = m.end;
  }
  if (last < text.length) parts.add(LatexPart(text: text.substring(last)));
  return parts;
}

String _encode(String content, {required bool isInline}) {
  var c = content;
  if (isInline) {
    // 行内公式剥离 \tag{...}：KaTeX（flutter_math_fork 移植）不允许
    // 行内模式使用 \tag，会直接解析失败（红色原文）。行内公式的编号
    // 无意义，Obsidian/MathJax 同样忽略，这里剥掉保证公式本体正常渲染。
    c = c.replaceAll(RegExp(r'\\tag\s*\{[^}]*\}'), '');
  }
  final hex = utf8
      .encode(c)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '$_phStart$_phTag${isInline ? 'i' : 'b'}$hex$_phEnd';
}

String _decodeHex(String hex) {
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return utf8.decode(bytes);
}

/// 一段文本：要么是普通文本，要么是一个公式。
class LatexPart {
  /// 普通文本内容；当 [latex] 非 null 时表示这是一个公式段。
  final String text;
  final String? latex;
  final bool isInline;

  LatexPart({this.text = '', this.latex, this.isInline = true});
}
