/// PDF 文本提取工具：让 agent 读取 PDF 教材正文（此前 read_file 对 PDF 二进制直接报错）。
///
/// 复用 pdf_viewer 同款 pdf.js 架构：RemoteAssetManager 按需下载 pdf.min.js +
/// pdf.worker.min.js（已注册），worker 以 base64 内联 Blob URL 规避 file:// 限制，
/// HeadlessInAppWebView 后台运行（与 webview_extract 同构），逐页 getTextContent
/// 提取文本层，通过 JavaScriptHandler 回传 Dart。
///
/// 设计要点：
/// - 路径：绝对路径直接读；相对路径按笔记库根（documents/notes）解析。
/// - pages 参数：如 "1-10" / "5" / "1,3,5-8"，默认全部页。
/// - max_chars 截断：JS 侧页级累计，超限即停（避免整本教材提取超时）。
/// - 超时 180s（300 页级教材逐页提取耗时）；Headless 用后 dispose。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../notes/notes_paths.dart';
import '../services/remote_asset_manager.dart';
import 'registry.dart';

String? _notesRootCached;

Future<String> _notesRoot() async {
  if (_notesRootCached != null) return _notesRootCached!;
  final docs = (await getApplicationDocumentsDirectory()).path;
  _notesRootCached = notesRootPath(docs);
  await Directory(_notesRootCached!).create(recursive: true);
  return _notesRootCached!;
}

/// 解析路径：绝对路径直接用；相对路径按笔记库根解析。
Future<String> _resolvePath(String input) async {
  if (p.isAbsolute(input)) return input;
  final root = await _notesRoot();
  return p.normalize(p.join(root, input));
}

/// 解析页码范围 "1-10" / "5" / "1,3,5-8" → 页号列表；null/空 → null（全部页）。
List<int>? _parsePages(String? spec) {
  if (spec == null || spec.trim().isEmpty) return null;
  final result = <int>{};
  for (final part in spec.split(',')) {
    final t = part.trim();
    if (t.isEmpty) continue;
    final range = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(t);
    if (range != null) {
      final a = int.parse(range.group(1)!);
      final b = int.parse(range.group(2)!);
      if (a <= b) {
        for (var i = a; i <= b; i++) {
          result.add(i);
        }
      }
    } else {
      final n = int.tryParse(t);
      if (n != null && n > 0) result.add(n);
    }
  }
  if (result.isEmpty) return null;
  final list = result.toList()..sort();
  return list;
}

/// 提取 PDF 文本（Headless WebView + pdf.js）。
///
/// 返回 Map：{text, totalPages, truncated, error?}
Future<Map<String, dynamic>> extractPdfText(
  String pdfPath, {
  List<int>? pages,
  int maxChars = 30000,
}) async {
  // 1. 按需下载 pdf.js 内核（首次下载，之后走缓存）。
  final jsPath = await RemoteAssetManager.instance.ensure('pdfjs');
  final workerPath = await RemoteAssetManager.instance.ensure('pdfjs-worker');
  final workerB64 = base64Encode(await File(workerPath).readAsBytes());
  final pdfFileUrl = Uri.file(pdfPath).toString();
  final jsDir = File(jsPath).parent.path;
  final pagesJson = pages == null ? 'null' : jsonEncode(pages);

  final html = _buildExtractHtml(workerB64, pdfFileUrl, pagesJson, maxChars);
  final completer = Completer<Map<String, dynamic>>();
  var completed = false;

  final headless = HeadlessInAppWebView(
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      allowFileAccess: true,
      allowFileAccessFromFileURLs: true,
      allowUniversalAccessFromFileURLs: true,
      supportMultipleWindows: false,
      isInspectable: false,
    ),
    onWebViewCreated: (controller) async {
      controller.addJavaScriptHandler(
        handlerName: 'pdfExtractDone',
        callback: (args) {
          if (completed) return;
          completed = true;
          if (args.isNotEmpty && args.first is String) {
            try {
              final decoded = jsonDecode(args.first as String);
              if (decoded is Map<String, dynamic>) {
                completer.complete(decoded);
                return;
              }
            } catch (_) {}
            completer.complete({'error': 'PDF 提取结果解析失败'});
          } else {
            completer.complete({'error': 'PDF 提取未返回结果'});
          }
        },
      );
      await controller.loadData(data: html, baseUrl: WebUri('file://$jsDir/'));
    },
  );

  await headless.run();
  try {
    return await completer.future.timeout(
      const Duration(seconds: 180),
      onTimeout: () => {'error': 'PDF 文本提取超时（180s）'},
    );
  } finally {
    await headless.dispose();
  }
}

/// 构造提取 HTML：worker base64 内联 Blob URL + 逐页 getTextContent。
String _buildExtractHtml(
  String workerB64,
  String pdfUrl,
  String pagesJson,
  int maxChars,
) {
  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
</head>
<body>
<script src="pdf.min.js"></script>
<script>
const PDF_PATH = '$pdfUrl';
const WORKER_B64 = '$workerB64';
const PAGES_JSON = $pagesJson;
const MAX_CHARS = $maxChars;

// worker 用 Blob URL：file:// 页面里 new Worker('file://…') 会被 Chromium 拒绝。
const workerBytes = Uint8Array.from(atob(WORKER_B64), c => c.charCodeAt(0));
pdfjsLib.GlobalWorkerOptions.workerSrc =
  URL.createObjectURL(new Blob([workerBytes], {type: 'application/javascript'}));

async function extract() {
  try {
    const pdf = await pdfjsLib.getDocument({url: PDF_PATH}).promise;
    const total = pdf.numPages;
    // 页号列表：显式指定或全部。
    let pages = Array.isArray(PAGES_JSON) ? PAGES_JSON : [];
    if (pages.length === 0) {
      for (let i = 1; i <= total; i++) pages.push(i);
    }
    let out = [];
    let len = 0;
    let truncated = false;
    for (const n of pages) {
      if (n < 1 || n > total) continue;
      const page = await pdf.getPage(n);
      const tc = await page.getTextContent();
      const text = tc.items.map(it => it.str || '').join(' ');
      const block = '--- 第 ' + n + ' 页 ---\\n' + text;
      if (len + block.length > MAX_CHARS) {
        truncated = true;
        break;
      }
      out.push(block);
      len += block.length;
    }
    window.flutter_inappwebview.callHandler('pdfExtractDone', JSON.stringify({
      totalPages: total,
      text: out.join('\\n\\n'),
      truncated: truncated,
    }));
  } catch (e) {
    window.flutter_inappwebview.callHandler('pdfExtractDone', JSON.stringify({error: String(e)}));
  }
}
extract();
</script>
</body>
</html>''';
}

// ---------------------------------------------------------------------------
// pdf_extract 工具注册
// ---------------------------------------------------------------------------

Future<String> _handlePdfExtract(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  try {
    final pathArg = (args['path'] as String? ?? '').trim();
    if (pathArg.isEmpty) {
      return toolError('pdf_extract: 缺少 path 参数');
    }
    final pdfPath = await _resolvePath(pathArg);
    if (!await File(pdfPath).exists()) {
      return toolError('pdf_extract: 文件不存在: $pdfPath');
    }
    if (!pdfPath.toLowerCase().endsWith('.pdf')) {
      return toolError('pdf_extract: 不是 PDF 文件: $pdfPath');
    }

    final pages = _parsePages(args['pages'] as String?);
    final maxChars = (args['max_chars'] as num?)?.toInt() ?? 30000;

    final result = await extractPdfText(
      pdfPath,
      pages: pages,
      maxChars: maxChars,
    );

    if (result['error'] != null) {
      return toolError('pdf_extract: ${result['error']}');
    }

    final totalPages = result['totalPages'];
    final text = result['text'] as String? ?? '';
    final truncated = result['truncated'] == true;
    return toolResult({
      'path': pdfPath,
      'total_pages': totalPages,
      'pages_extracted': pages?.length ?? '全部',
      'chars': text.length,
      'truncated': truncated,
      'text': text,
    });
  } catch (e) {
    return toolError('pdf_extract failed: $e');
  }
}

const Map<String, dynamic> _pdfExtractSchema = {
  'name': 'pdf_extract',
  'description':
      'Extract searchable text from a PDF file (textbook PDFs in the notes '
      'library). Returns the OCR/text-layer content of requested pages, so the '
      'agent can read PDF textbooks that read_file cannot handle. Path can be '
      'absolute or relative to the notes root (e.g. '
      '"subject_library/高等数学/高等数学教材上册【第七版】【高清OCR可检索版本】.pdf"). '
      'Use pages like "1-10" or "5,12-18" to limit extraction (default: all).',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description':
            'PDF path (absolute, or relative to notes root)',
      },
      'pages': {
        'type': 'string',
        'description':
            'Page range, e.g. "1-10", "5", "1,3,5-8". Empty = all pages',
      },
      'max_chars': {
        'type': 'integer',
        'description':
            'Max chars of text to return (default 30000; stops at page boundary)',
      },
    },
    'required': ['path'],
  },
};

/// 注册 pdf_extract 工具。
void registerPdfExtractTool() {
  registry.register(
    name: 'pdf_extract',
    toolset: 'file',
    schema: _pdfExtractSchema,
    handler: _handlePdfExtract,
    isAsync: true,
    emoji: '📄',
  );
}
