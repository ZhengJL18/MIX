/// 格式转换工具集：md → docx / md → PDF。
///
/// 把笔记/内容导出成通用文档（Word / PDF），借鉴开源方案选型：
///   - docx：纯 Dart 生成 OOXML（word/document.xml），archive 打包 zip，
///     零原生依赖、零网络（不依赖 pub.dev 的 docx 包——此环境解析不到）。
///   - PDF：HeadlessInAppWebView.createPdf（flutter_inappwebview 自带，
///     底层走 Chromium printToPdf），md → HTML → 打印成 PDF。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'docx_builder.dart';
import 'file_safety.dart';
import 'registry.dart';

/// 云端 /extract 服务器默认值（与 remote_code_block 的 remote-exec 同源）。
const String _officialExtractUrl = 'http://43.139.179.58';
const String _officialExtractToken = 'hVoHDStIXsUiTXb2rBMvpVvyipq29wDU';

// ============================================================================
// 路径解析
// ============================================================================

String _expandUserPath(String p) {
  if (p == '~') return homePath();
  if (p.startsWith('~/') || p.startsWith(r'~\')) return '${homePath()}/${p.substring(2)}';
  return p;
}

/// 输出路径解析：绝对路径直接用；相对路径基于 [base]（App documents）；
/// 为空时用 source（去掉扩展名）+ [ext]；content-only 时放 base 下默认文件名。
Future<String> _resolveOutput(
  String? output,
  String? source,
  String ext,
) async {
  final base = await getApplicationDocumentsDirectory();
  if (output != null && output.trim().isNotEmpty) {
    final p = _expandUserPath(output.trim());
    if (p.startsWith('/') || RegExp(r'^[A-Za-z]:[/\\]').hasMatch(p)) return p;
    return '${base.path}/$p';
  }
  if (source != null && source.trim().isNotEmpty) {
    final s = _expandUserPath(source.trim());
    return s.replaceFirst(RegExp(r'\.md$'), ext);
  }
  return '${base.path}/converted$ext';
}

String _readSource(String? path, String? content) {
  if (content != null && content.trim().isNotEmpty) return content;
  if (path == null || path.trim().isEmpty) {
    throw const FormatException('需要 path（md 文件）或 content（md 文本）之一');
  }
  final p = _expandUserPath(path.trim());
  final f = File(p);
  if (!f.existsSync()) throw FormatException('文件不存在: $p');
  return f.readAsStringSync();
}


// ============================================================================
// md → PDF（HeadlessInAppWebView.createPdf）
// ============================================================================

/// KaTeX 自动渲染配置（raw string：`$`/`\` 全部字面量，避免 Dart 插值转义地狱）。
const String _katexScript = r'''
<script>
document.addEventListener('DOMContentLoaded', function () {
  if (window.renderMathInElement) {
    renderMathInElement(document.body, {
      delimiters: [
        {left: '$$', right: '$$', display: true},
        {left: '$', right: '$', display: false},
        {left: '\[', right: '\]', display: true},
        {left: '\(', right: '\)', display: false}
      ],
      throwOnError: false
    });
  }
});
</script>
''';

/// md 文本 → HTML。KaTeX 打包在 APK（assets/katex），baseUrl 指向
/// file:///android_asset/flutter_assets/，完全离线，不依赖 CDN（Obsidian 式）。
String _buildPdfHtml(String mdText) {
  final body = md.markdownToHtml(mdText, extensionSet: md.ExtensionSet.gitHubFlavored);
  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<link rel="stylesheet" href="katex/katex.min.css">
<script src="katex/katex.min.js"></script>
<script src="katex/auto-render.min.js"></script>
<style>
  body { font-family: -apple-system, 'Segoe UI', 'Noto Sans CJK SC', sans-serif;
         font-size: 14px; line-height: 1.7; color: #1a1a1a;
         padding: 32px; max-width: 720px; margin: 0 auto; }
  h1, h2, h3 { color: #111; line-height: 1.3; }
  h1 { font-size: 24px; border-bottom: 2px solid #ddd; padding-bottom: 6px; }
  h2 { font-size: 20px; }
  h3 { font-size: 17px; }
  pre { background: #f5f5f5; padding: 12px; border-radius: 6px; overflow-x: auto; }
  code { font-family: 'SF Mono', Consolas, monospace; font-size: 13px; }
  p code { background: #f5f5f5; padding: 2px 4px; border-radius: 4px; }
  blockquote { border-left: 3px solid #ccc; margin: 0; padding-left: 14px; color: #555; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #ccc; padding: 6px 10px; font-size: 13px; }
  th { background: #f0f0f0; }
  img { max-width: 100%; }
  hr { border: none; border-top: 1px solid #ddd; margin: 20px 0; }
</style>
</head>
<body>
$body
$_katexScript
</body>
</html>''';
}

Future<String> _mdToPdf(String mdText, String outPath) async {
  final html = _buildPdfHtml(mdText);
  final completer = Completer<Uint8List>();
  final headless = HeadlessInAppWebView(
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      allowFileAccess: true,
      allowFileAccessFromFileURLs: true,
      allowUniversalAccessFromFileURLs: true,
    ),
    onWebViewCreated: (controller) async {
      await controller.loadData(
        data: html,
        // KaTeX 打包在 APK：Android 的 file:///android_asset/flutter_assets/。
        baseUrl: WebUri('file:///android_asset/flutter_assets/'),
      );
    },
    onLoadStop: (controller, url) async {
      // 给 KaTeX auto-render 一点渲染时间（本地文件加载很快，等 400ms 足够）。
      await Future.delayed(const Duration(milliseconds: 400));
      try {
        final bytes = await controller.createPdf();
        completer.complete(bytes);
      } catch (e) {
        completer.completeError(e);
      }
    },
  );
  await headless.run();
  try {
    final bytes = await completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw StateError('md→PDF 转换超时（60s）'),
    );
    await File(outPath).writeAsBytes(bytes, flush: true);
    return outPath;
  } finally {
    await headless.dispose();
  }
}

// ============================================================================
// 工具 handler + 注册
// ============================================================================

Future<String> _handleMdToDocx(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  try {
    final source = args['path'] as String?;
    final content = args['content'] as String?;
    if ((source == null || source.isEmpty) && (content == null || content.isEmpty)) {
      return toolError('md_to_docx: 需要 path（md 文件）或 content（md 文本）');
    }
    final mdText = _readSource(source, content);
    final outPath = await _resolveOutput(
        args['output'] as String?, source, '.docx');
    final bytes = buildDocxFromMarkdown(mdText);
    await File(outPath).writeAsBytes(bytes, flush: true);
    return toolResult({
      'output': outPath,
      'size_bytes': bytes.length,
      'paragraphs': mdText.split('\n').length,
      'hint': 'docx 已生成。Word/WPS 可直接打开；LaTeX 数学公式保留为文本（docx 原生公式转换未做）。',
    });
  } catch (e) {
    return toolError('md_to_docx failed: $e');
  }
}

Future<String> _handleMdToPdf(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  try {
    final source = args['path'] as String?;
    final content = args['content'] as String?;
    if ((source == null || source.isEmpty) && (content == null || content.isEmpty)) {
      return toolError('md_to_pdf: 需要 path（md 文件）或 content（md 文本）');
    }
    final mdText = _readSource(source, content);
    final outPath = await _resolveOutput(
        args['output'] as String?, source, '.pdf');
    if (Platform.isLinux) {
      return toolError('md_to_pdf: Linux 桌面版暂无 WebView，无法生成 PDF。可转 docx。');
    }
    await _mdToPdf(mdText, outPath);
    final size = File(outPath).lengthSync();
    return toolResult({
      'output': outPath,
      'size_bytes': size,
      'hint': 'PDF 已生成。LaTeX 公式通过 KaTeX CDN 渲染；离线或网络差时公式会显示为原始文本。',
    });
  } catch (e) {
    return toolError('md_to_pdf failed: $e');
  }
}

/// 读取云端 /extract 服务器配置（与 remote_code_block 共用键）。
Future<Map<String, String>> _loadExtractConfig() async {
  final prefs = await SharedPreferences.getInstance();
  final url = prefs.getString('remote_exec_url')?.trim().replaceAll(RegExp(r'/+$'), '');
  final token = prefs.getString('remote_exec_token');
  return {
    'url': (url == null || url.isEmpty) ? _officialExtractUrl : url,
    'token': (token == null || token.isEmpty) ? _officialExtractToken : token,
  };
}

/// cloud_extract：把大 PDF / 扫描件 / 格式转换丢给云端 /extract 处理。
Future<String> _handleCloudExtract(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  try {
    final path = args['path'] as String?;
    final task = args['task'] as String?;
    if (path == null || path.trim().isEmpty) {
      return toolError('cloud_extract: 需要 path（要处理的文件）');
    }
    const tasks = ['pdf_text', 'ocr', 'md_to_docx', 'md_to_pdf'];
    if (task == null || !tasks.contains(task)) {
      return toolError('cloud_extract: task 必须是 ${tasks.join('/')}');
    }
    final p = _expandUserPath(path.trim());
    final f = File(p);
    if (!f.existsSync()) return toolError('cloud_extract: 文件不存在: $p');
    if (f.lengthSync() > 25 * 1024 * 1024) {
      return toolError('cloud_extract: 文件 >25MB，服务器请求体上限 30MB（base64 后膨胀 33%），请先拆分');
    }
    final bytes = await f.readAsBytes();
    final cfg = await _loadExtractConfig();
    final resp = await http
        .post(
          Uri.parse('${cfg['url']}/extract'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'token': cfg['token'],
            'task': task,
            'filename': p.split('/').last,
            'data': base64Encode(bytes),
          }),
        )
        .timeout(const Duration(minutes: 3));
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return toolError('cloud_extract: 服务器响应异常 HTTP ${resp.statusCode}（服务器未部署 /extract？）');
    }
    if (json['error'] != null) {
      return toolError('cloud_extract: ${json['error']}');
    }
    // 转换任务：返回 base64 文件 → 存盘。
    final outB64 = json['output'];
    if (outB64 is String && outB64.isNotEmpty) {
      final outName = json['output_name'] as String? ?? 'converted';
      var outPath = (args['output'] as String? ?? '').trim();
      if (outPath.isEmpty) {
        outPath = p.replaceFirst(RegExp(r'\.[^.]+$'), '');
        if (outName.contains('.')) {
          outPath += outName.substring(outName.lastIndexOf('.'));
        } else {
          outPath += '.out';
        }
      } else {
        outPath = _expandUserPath(outPath);
      }
      final outBytes = base64Decode(outB64);
      await File(outPath).writeAsBytes(outBytes, flush: true);
      return toolResult({
        'output': outPath,
        'size_bytes': outBytes.length,
        'hint': '已由云端转换并保存。',
      });
    }
    // 提取任务：返回文本。
    final text = json['text'] as String? ?? '';
    return toolResult({
      'path': p,
      'task': task,
      'pages': json['pages'],
      'chars': text.length,
      'text': text,
    });
  } catch (e) {
    return toolError('cloud_extract failed: $e');
  }
}

const Map<String, dynamic> _mdToDocxSchema = {
  'name': 'md_to_docx',
  'description':
      'Convert a Markdown file or text to a Word (.docx) document. Pure Dart, '
      'works offline. Use for exporting notes/study materials as Word docs.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Path to the .md file to convert (absolute or relative to notes root)',
      },
      'content': {
        'type': 'string',
        'description': 'Raw markdown text to convert (use instead of path when there is no file)',
      },
      'output': {
        'type': 'string',
        'description': 'Optional output path; defaults to the source path with .docx extension',
      },
    },
    'required': [],
  },
};

const Map<String, dynamic> _mdToPdfSchema = {
  'name': 'md_to_pdf',
  'description':
      'Convert a Markdown file or text to a PDF document. Renders via headless '
      'WebView (createPdf) with KaTeX for LaTeX math (needs network on first use '
      'for the KaTeX CDN; math degrades to raw text offline). Use for exporting '
      'notes as clean PDF.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Path to the .md file to convert (absolute or relative to notes root)',
      },
      'content': {
        'type': 'string',
        'description': 'Raw markdown text to convert (use instead of path when there is no file)',
      },
      'output': {
        'type': 'string',
        'description': 'Optional output path; defaults to the source path with .pdf extension',
      },
    },
    'required': [],
  },
};

const Map<String, dynamic> _cloudExtractSchema = {
  'name': 'cloud_extract',
  'description':
      'Send a file to the cloud format-conversion server for heavy work: '
      'pdf_text (extract text from large PDFs via PyMuPDF), ocr (extract text '
      'from scanned PDFs/images via tesseract chi_sim+eng), md_to_docx / md_to_pdf '
      '(convert markdown via pandoc). Use for files too big/slow for local '
      'processing or for OCR. Requires the remote runner with /extract deployed.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Path to the file to process (absolute or relative to notes root)',
      },
      'task': {
        'type': 'string',
        'description': 'Task: pdf_text | ocr | md_to_docx | md_to_pdf',
      },
      'output': {
        'type': 'string',
        'description': 'Optional output path for conversion tasks (md_to_docx/md_to_pdf); defaults next to the source',
      },
    },
    'required': ['path', 'task'],
  },
};

/// 注册转换工具集（toolset: convert）。
void registerConvertTools() {
  registry.register(
    name: 'md_to_docx',
    toolset: 'convert',
    schema: _mdToDocxSchema,
    handler: _handleMdToDocx,
    emoji: '📄',
    maxResultSizeChars: 5000,
  );
  registry.register(
    name: 'md_to_pdf',
    toolset: 'convert',
    schema: _mdToPdfSchema,
    handler: _handleMdToPdf,
    emoji: '🖨️',
    maxResultSizeChars: 5000,
  );
  registry.register(
    name: 'cloud_extract',
    toolset: 'convert',
    schema: _cloudExtractSchema,
    handler: _handleCloudExtract,
    emoji: '☁️',
    maxResultSizeChars: 300000,
  );
}
