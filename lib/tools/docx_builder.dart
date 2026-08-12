/// 纯 Dart Markdown → .docx 生成器（OOXML + zip）。
///
/// 只依赖 archive（zip）和 markdown（AST 解析），不碰 Flutter/插件，
/// 可在纯 Dart 环境独立测试。
///
/// 输出一个最小合法 .docx（[Content_Types].xml + _rels/.rels +
/// word/document.xml）：标题、段落、粗/斜/行内代码、代码块（等宽+底纹）、
/// 有序/无序列表（手动符号 + 缩进）、表格、引用、分隔线。
/// 局限：LaTeX 公式保留为文本（Word 原生公式转换未实现）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:markdown/markdown.dart' as md;

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// 构造一个 w:r run。
String _run(String text,
    {bool bold = false, bool italic = false, bool mono = false}) {
  if (text.isEmpty) return '';
  final rpr = StringBuffer('<w:rPr>');
  if (bold) rpr.write('<w:b/>');
  if (italic) rpr.write('<w:i/>');
  if (mono) {
    rpr.write('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>');
    rpr.write('<w:sz w:val="20"/>');
  }
  rpr.write('</w:rPr>');
  return '<w:r>$rpr<w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r>';
}

/// 段落（可带样式 / 缩进 / 底纹）。
String _para(String runs, {String? style, int indentLeft = 0, String? shade}) {
  final ppr = StringBuffer('<w:pPr>');
  if (style != null) ppr.write('<w:pStyle w:val="$style"/>');
  if (indentLeft > 0) ppr.write('<w:ind w:left="$indentLeft"/>');
  if (shade != null) {
    ppr.write('<w:shd w:val="clear" w:color="auto" w:fill="$shade"/>');
  }
  ppr.write('</w:pPr>');
  return '<w:p>$ppr$runs</w:p>';
}

/// 递归渲染单个 inline 节点 → run XML。
String _inline(md.Node node) {
  if (node is md.Text) return _run(node.text);
  if (node is! md.Element) return _run(node.textContent);
  switch (node.tag) {
    case 'em':
      return _inlineAll(node.children, italic: true);
    case 'strong':
      return _inlineAll(node.children, bold: true);
    case 'code':
      return _run(node.textContent, mono: true);
    case 'a':
      return _run(node.textContent);
    default:
      return _inlineAll(node.children);
  }
}

/// 渲染 inline 节点列表，带可继承的粗/斜。
String _inlineAll(List<md.Node>? nodes,
    {bool bold = false, bool italic = false}) {
  final sb = StringBuffer();
  for (final n in nodes ?? const <md.Node>[]) {
    if (n is md.Text) {
      sb.write(_run(n.text, bold: bold, italic: italic));
    } else if (n is md.Element) {
      switch (n.tag) {
        case 'em':
          sb.write(_inlineAll(n.children, italic: italic || true));
          break;
        case 'strong':
          sb.write(_inlineAll(n.children, bold: bold || true));
          break;
        case 'code':
          sb.write(_run(n.textContent, mono: true));
          break;
        default:
          sb.write(_inline(n));
      }
    }
  }
  return sb.toString();
}

/// 渲染代码块（每行一段等宽字 + 浅灰底纹）。
String _codeBlock(String code) {
  final lines = code.trimRight().split('\n');
  final sb = StringBuffer();
  for (final line in lines) {
    sb.write(_para(_run(line.isEmpty ? ' ' : line, mono: true), shade: 'F2F2F2'));
  }
  return sb.toString();
}

/// 渲染列表（手动符号 + 缩进，避免引入 numbering.xml）。
String _list(md.Element node, int depth) {
  final ordered = node.tag == 'ol';
  final sb = StringBuffer();
  final indent = 360 + depth * 360;
  var idx = 1;
  for (final child in node.children ?? const <md.Node>[]) {
    if (child is md.Element && child.tag == 'li') {
      final marker = ordered ? '$idx. ' : '• ';
      final runs = _run(marker, bold: true) + _inlineAll(child.children);
      sb.write(_para(runs, indentLeft: indent));
      idx++;
    } else if (child is md.Element &&
        (child.tag == 'ul' || child.tag == 'ol')) {
      sb.write(_list(child, depth + 1));
    }
  }
  return sb.toString();
}

/// 渲染表格。
String _table(md.Element node) {
  final rows = node.children ?? const <md.Node>[];
  final sb = StringBuffer();
  sb.write('<w:tbl><w:tblPr><w:tblBorders>');
  for (final edge in const ['top', 'left', 'bottom', 'right', 'insideH', 'insideV']) {
    sb.write('<w:$edge w:val="single" w:sz="4" w:color="999999"/>');
  }
  sb.write('</w:tblBorders></w:tblPr>');
  for (final row in rows) {
    if (row is! md.Element) continue;
    sb.write('<w:tr>');
    for (final cell in row.children ?? const <md.Node>[]) {
      if (cell is! md.Element) continue;
      sb.write('<w:tc><w:tcPr><w:tcW w:w="0" w:type="auto"/></w:tcPr>');
      sb.write(_para(_inlineAll(cell.children)));
      sb.write('</w:tc>');
    }
    sb.write('</w:tr>');
  }
  sb.write('</w:tbl>');
  return sb.toString();
}

/// 渲染一个块级节点。
void _block(md.Node node, StringBuffer sb, {int depth = 0}) {
  if (node is md.Text) {
    final t = node.text.trim();
    if (t.isNotEmpty) sb.write(_para(_run(t)));
    return;
  }
  if (node is! md.Element) return;
  switch (node.tag) {
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      sb.write(_para(_inlineAll(node.children),
          style: 'Heading${node.tag.substring(1)}'));
      break;
    case 'p':
      final t = _inlineAll(node.children);
      if (t.isNotEmpty) sb.write(_para(t));
      break;
    case 'ul':
    case 'ol':
      sb.write(_list(node, depth));
      break;
    case 'blockquote':
      sb.write(_para(_run('│ ') + _inlineAll(node.children), indentLeft: 360));
      break;
    case 'pre':
      sb.write(_codeBlock(node.textContent));
      break;
    case 'table':
      sb.write(_table(node));
      sb.write(_para(''));
      break;
    case 'hr':
      sb.write(_para('', style: 'Heading1'));
      break;
    case 'li':
      sb.write(_para(_inlineAll(node.children), indentLeft: 360 + depth * 360));
      break;
    default:
      final t = _inlineAll(node.children);
      if (t.isNotEmpty) sb.write(_para(t));
  }
}

/// Markdown 文本 → .docx 文件字节（纯 Dart OOXML + zip）。
Uint8List buildDocxFromMarkdown(String mdText) {
  // GFM 扩展：解析表格、任务列表等（默认 CommonMark 不解析表格）。
  final nodes = md
      .Document(extensionSet: md.ExtensionSet.gitHubFlavored)
      .parseLines(mdText.split('\n'));
  final body = StringBuffer();
  for (final n in nodes) {
    _block(n, body);
  }

  const contentTypes = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';

  const rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

  final documentXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
$body
</w:body>
</w:document>''';

  final archive = Archive()
    ..addFile(ArchiveFile(
        '[Content_Types].xml', utf8.encode(contentTypes).length, utf8.encode(contentTypes)))
    ..addFile(ArchiveFile(
        '_rels/.rels', utf8.encode(rels).length, utf8.encode(rels)))
    ..addFile(ArchiveFile(
        'word/document.xml', utf8.encode(documentXml).length, utf8.encode(documentXml)));
  final zip = ZipEncoder().encode(archive);
  return Uint8List.fromList(zip);
}
