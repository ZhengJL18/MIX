/// read_doc 工具：通用文件读取，替换原 bin_extract（WebView+pdf.js 方案）。
///
/// 本地处理不再套 WebView：
///   - 文本（UTF-8 / UTF-16LE/BE / UTF-8 BOM）→ 纯 Dart 解码，JSON 自动美化
///   - tar / tar.gz / gzip / zip（含 docx/xlsx/epub）→ archive 包纯 Dart 解
///   - PDF / SQLite / OCR / GBK 文本 → 云端 /extract（原生 PyMuPDF / python）
/// 云端调用复用 convert_tools.dart 的 cloudExtractRequest / cloudExtractBytes。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../services/local_doc_parser.dart';
import 'convert_tools.dart' show cloudExtractBytes, cloudExtractRequest;
import 'registry.dart';

const int _maxDefault = 30000;

String _detect(Uint8List head) {
  String ascii(int s, int l) {
    if (s + l > head.length) return '';
    return String.fromCharCodes(head.sublist(s, s + l));
  }

  if (head.length >= 5 && ascii(0, 5) == '%PDF-') return 'pdf';
  if (head.length >= 4 &&
      head[0] == 0x50 && head[1] == 0x4b &&
      (head[2] == 0x03 || head[2] == 0x05 || head[2] == 0x07)) {
    return 'zip';
  }
  if (head.length >= 2 && head[0] == 0x1f && head[1] == 0x8b) return 'gzip';
  if (head.length >= 15 && ascii(0, 15) == 'SQLite format 3') return 'sqlite';
  if (head.length >= 262 && ascii(257, 5) == 'ustar') return 'tar';
  if (head.length >= 2 && head[0] == 0xff && head[1] == 0xfe) return 'utf16le';
  if (head.length >= 2 && head[0] == 0xfe && head[1] == 0xff) return 'utf16be';
  if (head.length >= 3 &&
      head[0] == 0xef && head[1] == 0xbb && head[2] == 0xbf) {
    return 'utf8bom';
  }
  if (head.length >= 4 && head[0] == 0x89 && ascii(1, 3) == 'PNG') return 'image';
  if (head.length >= 3 && head[0] == 0xff && head[1] == 0xd8 && head[2] == 0xff) {
    return 'image';
  }
  if (head.length >= 4 && ascii(0, 4) == 'GIF8') return 'image';
  if (head.length >= 2 && head[0] == 0x42 && head[1] == 0x4d) return 'image';
  final probe = head.length > 65536 ? 65536 : head.length;
  for (var i = 0; i < probe; i++) {
    if (head[i] == 0) return 'binary';
  }
  return 'text';
}

String _maybePrettyJson(String text) {
  final t = text.trim();
  if (t.isEmpty) return text;
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(t));
    } catch (_) {}
  }
  return text;
}

String _readTextLocal(Uint8List bytes, String type) {
  switch (type) {
    case 'utf16le':
      final sb = StringBuffer();
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        sb.writeCharCode(bytes[i] | (bytes[i + 1] << 8));
      }
      return sb.toString();
    case 'utf16be':
      final sb = StringBuffer();
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        sb.writeCharCode((bytes[i] << 8) | bytes[i + 1]);
      }
      return sb.toString();
    case 'utf8bom':
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    default:
      return utf8.decode(bytes, allowMalformed: true);
  }
}

String _truncate(String s, int maxChars) => s.length > maxChars
    ? '${s.substring(0, maxChars)}\n…[已截断 ${s.length - maxChars} 字符]'
    : s;

List<String> _xmlTexts(String xml, String tag) {
  final re = RegExp('<$tag[^>]*>(.*?)</$tag>', dotAll: true);
  return [
    for (final m in re.allMatches(xml))
      m.group(1)!
          .replaceAll('&amp;', '&').replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>').replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'"),
  ];
}

bool _isTextFile(String name) {
  const exts = {
    '.md', '.txt', '.csv', '.json', '.xml', '.html', '.htm', '.yaml',
    '.yml', '.py', '.dart', '.js', '.ts', '.sql', '.log', '.ini',
  };
  final lower = name.toLowerCase();
  return exts.any(lower.endsWith);
}

// ============================================================================
// 本地纯 Dart 读取
// ============================================================================

String _readTar(Uint8List bytes, int maxChars) {
  final archive = TarDecoder().decodeBytes(bytes);
  final out = StringBuffer('TAR 文件（${archive.files.length} 项）:\n');
  for (final f in archive.files.take(80)) {
    out.writeln('  - ${f.name}');
  }
  for (final f in archive.files.where((f) => _isTextFile(f.name)).take(20)) {
    try {
      final content = utf8.decode(f.content as List<int>, allowMalformed: true);
      out.writeln('\n### ${f.name}\n${_truncate(content, 2000)}');
    } catch (_) {}
  }
  return _truncate(out.toString(), maxChars);
}

String _readZip(Uint8List bytes, int maxChars) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final names = archive.files.map((f) => f.name).toList();

  // docx
  if (names.contains('word/document.xml')) {
    final xml = utf8.decode(
        archive.findFile('word/document.xml')!.content as List<int>,
        allowMalformed: true);
    final texts = _xmlTexts(xml, 'w:t').where((t) => t.trim().isNotEmpty);
    return _truncate(texts.join('\n'), maxChars);
  }
  // xlsx
  if (names.any((n) => n.startsWith('xl/worksheets/sheet'))) {
    final shared = <String>[];
    final sf = archive.findFile('xl/sharedStrings.xml');
    if (sf != null) {
      shared.addAll(
          _xmlTexts(utf8.decode(sf.content as List<int>, allowMalformed: true), 't'));
    }
    final out = StringBuffer('XLSX（${shared.length} 个共享字符串）:\n');
    final sheets = names.where((n) => n.startsWith('xl/worksheets/sheet'))
        .toList()..sort();
    for (final sn in sheets.take(5)) {
      final xml = utf8.decode(
          archive.findFile(sn)!.content as List<int>, allowMalformed: true);
      out.writeln('### $sn');
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
          if (tAttr?.group(1) == 's' && v != null) {
            final idx = int.tryParse(v.group(1) ?? '');
            line.add(idx != null && idx < shared.length ? shared[idx] : (v.group(1) ?? ''));
          } else if (inline != null) {
            line.add(inline.group(1)!);
          } else if (v != null) {
            line.add(v.group(1)!);
          }
        }
        if (line.isNotEmpty) out.writeln(line.join(' | '));
      }
    }
    return _truncate(out.toString(), maxChars);
  }
  // epub
  if (names.contains('META-INF/container.xml')) {
    final htmlFiles = names.where((n) =>
        n.endsWith('.html') || n.endsWith('.xhtml')).toList()..sort();
    final out = StringBuffer('EPUB 文本（${htmlFiles.length} 个 html）:\n');
    for (final n in htmlFiles.take(30)) {
      final html = utf8.decode(
          archive.findFile(n)!.content as List<int>, allowMalformed: true);
      final text = html.replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isNotEmpty) out.writeln('\n### $n\n${_truncate(text, 2000)}');
    }
    return _truncate(out.toString(), maxChars);
  }
  // 通用 zip
  final out = StringBuffer('ZIP 文件清单（${archive.files.length} 项）:\n');
  for (final f in archive.files.take(80)) {
    out.writeln('  - ${f.name}');
  }
  for (final f in archive.files.where((f) => _isTextFile(f.name)).take(20)) {
    try {
      final content = utf8.decode(f.content as List<int>, allowMalformed: true);
      out.writeln('\n### ${f.name}\n${_truncate(content, 2000)}');
    } catch (_) {}
  }
  return _truncate(out.toString(), maxChars);
}

String _handleArchive(Uint8List bytes, String type, int maxChars) {
  // gzip 先解一层。
  Uint8List inner = bytes;
  if (type == 'gzip') {
    inner = GZipDecoder().decodeBytes(bytes);
  }
  if (inner.length >= 262) {
    final ustar = String.fromCharCodes(inner.sublist(257, 262));
    if (ustar == 'ustar') return _readTar(inner, maxChars);
  }
  if (inner.length >= 4 &&
      inner[0] == 0x50 && inner[1] == 0x4b &&
      (inner[2] == 0x03 || inner[2] == 0x05 || inner[2] == 0x07)) {
    return _readZip(inner, maxChars);
  }
  // 解压后是文本。
  final probe = inner.length > 65536 ? 65536 : inner.length;
  var hasNull = false;
  for (var i = 0; i < probe; i++) {
    if (inner[i] == 0) {
      hasNull = true;
      break;
    }
  }
  if (!hasNull) {
    return _truncate(
        _maybePrettyJson(utf8.decode(inner, allowMalformed: true)), maxChars);
  }
  return 'gzip 解压后为未知二进制（${inner.length} 字节）';
}

// ============================================================================
// 云端 /extract 路由
// ============================================================================

Future<String> _cloudFile(String path, String task, int maxChars) async {
  final r = await cloudExtractRequest(task, filePath: path);
  if (r == null) return '文件不存在';
  if (r['error'] != null) return 'read_doc 云端处理失败: ${r['error']}';
  return _truncate(r['text'] as String? ?? '', maxChars);
}

Future<String> _cloudTextDecode(Uint8List bytes, String filename) async {
  final r = await cloudExtractBytes('text_decode', bytes: bytes, filename: filename);
  if (r == null) return '云端解码失败';
  if (r['error'] != null) return '云端解码失败: ${r['error']}';
  return _truncate(r['text'] as String? ?? '', _maxDefault);
}

// ============================================================================
// 工具入口 + 注册
// ============================================================================

Future<String> readDocTool(String path, {int maxChars = _maxDefault}) async {
  final f = File(path);
  if (!await f.exists()) return '文件不存在: $path';
  final size = await f.length();
  if (size > 25 * 1024 * 1024) {
    return '文件 >25MB，服务器请求体上限 30MB（base64 膨胀 33%），请先拆分';
  }

  final raf = await f.open();
  final head = Uint8List(512);
  final read = await raf.readInto(head);
  await raf.close();
  final headBytes = read < 512 ? head.sublist(0, read) : head;
  final type = _detect(headBytes);

  switch (type) {
    case 'text':
    case 'utf16le':
    case 'utf16be':
    case 'utf8bom':
      final bytes = await f.readAsBytes();
      if (type == 'text') {
        try {
          return _truncate(_maybePrettyJson(utf8.decode(bytes)), maxChars);
        } on FormatException {
          // 非 UTF-8（可能 GBK）→ 云端解码。
          return _cloudTextDecode(bytes, path.split('/').last);
        }
      }
      return _truncate(
          _maybePrettyJson(_readTextLocal(bytes, type)), maxChars);
    case 'gzip':
    case 'tar':
    case 'zip':
      if (size > 8 * 1024 * 1024) {
        final task = (type == 'tar' || type == 'gzip') ? 'tar_text' : 'zip_text';
        return _cloudFile(path, task, maxChars);
      }
      final bytes = await f.readAsBytes();
      // 本地 OOXML → 结构化 Markdown（docx/pptx/xlsx 优先）。
      if (type == 'zip') {
        final officeMd = await parseOfficeToMarkdown(bytes);
        if (officeMd != null) return _truncate(officeMd, maxChars);
      }
      return _handleArchive(bytes, type, maxChars);
    case 'pdf':
      // 本地纯文字提取优先（pdfrx/pdfium）；失败 fallback 云端。
      final localPdf = await pdfTextToMarkdown(path, maxChars: maxChars);
      if (localPdf != null) return localPdf;
      return _cloudFile(path, 'pdf_text', maxChars);
    case 'sqlite':
      return _cloudFile(path, 'sqlite_text', maxChars);
    case 'image':
      return '图片文件（$size 字节）：文本提取无意义，请用 vision_analyze 分析图片内容。';
    default:
      final bytes = await f.readAsBytes();
      final hex = bytes.take(64)
          .map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      final ascii = String.fromCharCodes(bytes.take(64)
          .map((b) => b >= 32 && b < 127 ? b : 46));
      return '未知二进制文件（$size 字节）\nHex: $hex\nAscii: $ascii\n该格式暂不支持文本提取。';
  }
}

const Map<String, dynamic> _readDocSchema = {
  'name': 'read_doc',
  'description':
      'Read any file and return its text content (magic-byte detection, no '
      'extension needed). Text/UTF-16/GBK, JSON (pretty-printed), tar/gzip/zip '
      'are read locally in pure Dart; DOCX/PPTX/XLSX convert to structured '
      'Markdown locally; PDF text extracted locally (pdfium) with cloud '
      'fallback; SQLite and OCR go to the cloud extract server. Use whenever '
      'read_file fails on a binary or non-UTF8 file. For images use '
      'vision_analyze instead.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Path to the file to read (absolute or relative to notes root)',
      },
      'max_chars': {
        'type': 'integer',
        'description': 'Max chars of extracted text to return (default 30000)',
      },
    },
    'required': ['path'],
  },
};

/// 注册 read_doc 工具（file 工具集，替换原 bin_extract）。
void registerReadDocTool() {
  registry.register(
    name: 'read_doc',
    toolset: 'file',
    schema: _readDocSchema,
    handler: (args, [kwargs]) async {
      final path = (args['path'] as String? ?? '').trim();
      if (path.isEmpty) return toolError('read_doc: 缺少 path 参数');
      final maxChars = (args['max_chars'] as num?)?.toInt() ?? _maxDefault;
      try {
        return await readDocTool(path, maxChars: maxChars);
      } catch (e) {
        return toolError('read_doc failed: $e');
      }
    },
    emoji: '📖',
    maxResultSizeChars: 120000,
  );
}
