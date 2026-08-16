/// 本地文档 → Markdown（2026-08：云算力弱，全部改本地）。
///
/// 覆盖 DOCX / PPTX / XLSX / PDF（纯文字层），全部手机端完成、零服务器：
/// - DOCX → 结构化 Markdown（docx_to_markdown 纯 Dart 包，表格/列表/标题）
/// - PPTX → 逐页文本大纲（OOXML = zip + XML，archive + 正则提取）
/// - XLSX → Markdown 表格（sharedStrings + sheet 解析，对齐管道表）
/// - PDF → 纯文字提取（pdfrx / pdfium 原生引擎，正文 + 可提取的 Unicode
///   数学符号；公式语义/扫描件不做——本地算力天花板）
///
/// 全部函数失败返回 null（调用方降级：read_doc 走云端 fallback）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docx_to_markdown/docx_to_markdown.dart';
import 'package:pdfrx/pdfrx.dart';

// ---------------------------------------------------------------------------
// DOCX → Markdown（docx_to_markdown 包）
// ---------------------------------------------------------------------------

/// DOCX 字节 → 结构化 Markdown。失败返回 null。
Future<String?> docxToMarkdown(Uint8List bytes) async {
  try {
    final md = await DocxConverter(bytes).convert();
    return (md == null || md.trim().isEmpty) ? null : md;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// PPTX → Markdown（zip + slide XML 逐页文本大纲）
// ---------------------------------------------------------------------------

/// PPTX 字节 → Markdown 大纲（每页标题 + 文本）。失败返回 null。
String? pptxToMarkdown(Uint8List bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final slideNames = archive.files
        .map((f) => f.name)
        .where((n) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(n))
        .toList()
      ..sort((a, b) {
        final na = int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '0') ?? 0;
        final nb = int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '0') ?? 0;
        return na.compareTo(nb);
      });
    if (slideNames.isEmpty) return null;
    final out = StringBuffer();
    for (var i = 0; i < slideNames.length; i++) {
      final xml = utf8.decode(
          archive.findFile(slideNames[i])!.content as List<int>,
          allowMalformed: true);
      // 每页标题（t 文本，按行组合）。
      final texts = <String>[];
      for (final m in RegExp(r'<a:t>(.*?)</a:t>', dotAll: true)
          .allMatches(xml)) {
        final t = m.group(1)!
            .replaceAll('&amp;', '&').replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>').replaceAll('&quot;', '"')
            .replaceAll('&apos;', "'")
            .trim();
        if (t.isNotEmpty) texts.add(t);
      }
      if (texts.isEmpty) continue;
      out.writeln('## 第 ${i + 1} 页');
      // 第一段文本作为标题，其余作为列表。
      out.writeln('${texts.first}');
      for (final t in texts.skip(1)) {
        out.writeln('- $t');
      }
      out.writeln();
    }
    final md = out.toString().trim();
    return md.isEmpty ? null : md;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// XLSX → Markdown 表格（sharedStrings + sheet）
// ---------------------------------------------------------------------------

/// XLSX 字节 → Markdown 表格（多 sheet 分节）。失败返回 null。
String? xlsxToMarkdown(Uint8List bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((f) => f.name).toList();
    final shared = <String>[];
    final sf = archive.findFile('xl/sharedStrings.xml');
    if (sf != null) {
      for (final m in RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true)
          .allMatches(utf8.decode(sf.content as List<int>, allowMalformed: true))) {
        shared.add(m.group(1)!
            .replaceAll('&amp;', '&').replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>').replaceAll('&quot;', '"')
            .replaceAll('&apos;', "'"));
      }
    }
    final sheets = names.where((n) => n.startsWith('xl/worksheets/sheet'))
        .toList()..sort();
    if (sheets.isEmpty) return null;
    final out = StringBuffer();
    for (final sn in sheets) {
      final xml = utf8.decode(
          archive.findFile(sn)!.content as List<int>, allowMalformed: true);
      final rows = <List<String>>[];
      for (final row in RegExp(r'<row[^>]*>(.*?)</row>', dotAll: true)
          .allMatches(xml)) {
        final line = <String>[];
        for (final c in RegExp(r'<c[^>]*>(.*?)</c>', dotAll: true)
            .allMatches(row.group(1)!)) {
          final cell = c.group(1)!;
          final tAttr = RegExp(r't="(\w+)"').firstMatch(c.group(0)!);
          final v = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(cell);
          final inline = RegExp(r'<is><t[^>]*>(.*?)</t></is>', dotAll: true)
              .firstMatch(cell);
          String? val;
          if (tAttr?.group(1) == 's' && v != null) {
            final idx = int.tryParse(v.group(1) ?? '');
            val = idx != null && idx < shared.length ? shared[idx] : (v.group(1) ?? '');
          } else if (inline != null) {
            val = inline.group(1)!;
          } else if (v != null) {
            val = v.group(1)!;
          }
          line.add(val?.trim() ?? '');
        }
        if (line.any((c) => c.isNotEmpty)) rows.add(line);
      }
      if (rows.isEmpty) continue;
      final sheetName = sn.split('/').last.replaceAll('.xml', '');
      out.writeln('### $sheetName');
      // 表头 + 分隔行（Markdown 表格）。
      final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
      String esc(String s) => s.replaceAll('|', '\\|');
      out.writeln('| ${rows.first.map(esc).join(' | ')} |');
      out.writeln('| ${List.filled(width, '---').join(' | ')} |');
      for (final r in rows.skip(1)) {
        final padded = List<String>.from(r);
        while (padded.length < width) {
          padded.add('');
        }
        out.writeln('| ${padded.map(esc).join(' | ')} |');
      }
      out.writeln();
    }
    final md = out.toString().trim();
    return md.isEmpty ? null : md;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// PDF → Markdown（pdfrx / pdfium 本地文本提取，纯文字层）
// ---------------------------------------------------------------------------

/// PDF 本地文本提取 → 纯文字 Markdown（段落保留）。
///
/// 说明：正文文本完整提取；LaTeX 排版的数学公式取决于字体 ToUnicode 映射
/// （现代 pdflatex 常可提取为 Unicode 符号，子集化字体则乱码）——本地算力
/// 的纯文字上限，复杂版面/扫描件请用视觉分析。失败返回 null（read_doc
/// 会走云端 fallback）。
Future<String?> pdfTextToMarkdown(
  String path, {
  int maxChars = 30000,
}) async {
  try {
    final doc = await PdfDocument.openFile(path);
    try {
      final out = StringBuffer();
      for (final page in doc.pages) {
        final raw = await page.loadText();
        if (raw == null) continue;
        final text = raw.fullText.trim();
        if (text.isEmpty) continue;
        // 页码标记 + 段落（连续文本按行折叠，空行分段落）。
        final paragraphs = text
            .split(RegExp(r'\n\s*\n'))
            .map((p) => p.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim())
            .where((p) => p.isNotEmpty);
        for (final p in paragraphs) {
          out.writeln(p);
          out.writeln();
        }
        if (out.length > maxChars) break;
      }
      final md = out.toString().trim();
      if (md.isEmpty) return null;
      return md.length > maxChars
          ? '${md.substring(0, maxChars)}\n…[已截断]'
          : md;
    } finally {
      await doc.dispose();
    }
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 统一入口（read_doc 调用）
// ---------------------------------------------------------------------------

/// 统一入口（read_doc 调用）：OOXML 容器（docx/pptx/xlsx）→ Markdown。
/// docx 走 docx_to_markdown 包（async），pptx/xlsx 本地同步解析。
/// 非 OOXML 返回 null（调用方走通用 zip 清单/云端）。
Future<String?> parseOfficeToMarkdown(Uint8List bytes) async {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((f) => f.name).toList();
    if (names.contains('word/document.xml')) {
      return await docxToMarkdown(bytes);
    }
    if (names.any((n) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(n))) {
      return pptxToMarkdown(bytes);
    }
    if (names.any((n) => n.startsWith('xl/worksheets/sheet'))) {
      return xlsxToMarkdown(bytes);
    }
    return null;
  } catch (_) {
    return null;
  }
}
