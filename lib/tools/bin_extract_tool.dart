/// 通用二进制读取工具：让 agent 读取各种二进制格式文件（此前 read_file 对
/// 非 UTF-8 文本直接报错，PDF/ZIP/SQLite 等完全无法读）。
///
/// 覆盖格式（magic bytes 自动检测，无需扩展名）：
///   - PDF                    → pdf.js 逐页提取文本层
///   - ZIP（含 docx/xlsx/epub）→ fflate 解压，按容器类型提取可读文本
///   - gzip / tar / tar.gz    → fflate 解压/解包，递归检测内部格式
///   - SQLite                 → sql.js（wasm 内联）列出表结构 + 抽样数据
///   - UTF-16 LE/BE、UTF-8 BOM→ 编码探测转码
///   - GBK 中文文本           → TextDecoder('gbk')（Chromium 内置）
///   - 单行大 JSON            → 自动美化（pretty print）
///   - 图片                   → 提示用 vision_analyze
///   - 未知二进制             → magic bytes + hex dump + ASCII 预览
///
/// 架构与 pdf_extract 同构：HeadlessInAppWebView 后台运行，JS 侧 fetch(file://)
/// 读文件字节 → 检测 → 按需动态加载 JS 库（RemoteAssetManager 已下载到
/// remote_assets 目录，baseUrl 指向该目录）→ 提取 → JavaScriptHandler 回传。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// 顶层格式检测（读文件头 512 字节；与 JS 侧 detect 保持一致）。
/// 返回: pdf / zip / gzip / tar / sqlite / utf16le / utf16be / utf8bom /
///       image / text / binary
String _detectTopLevel(Uint8List head) {
  String ascii(int start, int len) {
    final end = start + len;
    if (end > head.length) return '';
    return String.fromCharCodes(head.sublist(start, end));
  }

  if (head.length >= 5 && ascii(0, 5) == '%PDF-') return 'pdf';
  if (head.length >= 4 &&
      head[0] == 0x50 &&
      head[1] == 0x4b &&
      (head[2] == 0x03 || head[2] == 0x05 || head[2] == 0x07)) {
    return 'zip';
  }
  if (head.length >= 2 && head[0] == 0x1f && head[1] == 0x8b) return 'gzip';
  if (head.length >= 16 && ascii(0, 15) == 'SQLite format 3') return 'sqlite';
  if (head.length >= 262 && ascii(257, 5) == 'ustar') return 'tar';
  if (head.length >= 2 && head[0] == 0xff && head[1] == 0xfe) return 'utf16le';
  if (head.length >= 2 && head[0] == 0xfe && head[1] == 0xff) return 'utf16be';
  if (head.length >= 3 &&
      head[0] == 0xef &&
      head[1] == 0xbb &&
      head[2] == 0xbf) {
    return 'utf8bom';
  }
  if (head.length >= 4 && head[0] == 0x89 && ascii(1, 3) == 'PNG') {
    return 'image';
  }
  if (head.length >= 3 && head[0] == 0xff && head[1] == 0xd8 && head[2] == 0xff) {
    return 'image';
  }
  if (head.length >= 4 && ascii(0, 4) == 'GIF8') return 'image';
  if (head.length >= 2 && head[0] == 0x42 && head[1] == 0x4d) return 'image';
  // 文本：前 64KB 无 null 字节
  final probe = head.length > 65536 ? 65536 : head.length;
  for (var i = 0; i < probe; i++) {
    if (head[i] == 0) return 'binary';
  }
  return 'text';
}

/// 通用二进制提取（Headless WebView + JS 侧全部逻辑）。
Future<Map<String, dynamic>> extractBinary(
  String filePath, {
  int maxChars = 30000,
}) async {
  final file = File(filePath);
  if (!await file.exists()) return {'error': '文件不存在: $filePath'};
  final size = await file.length();

  // 读文件头判断顶层类型（512 字节覆盖 tar ustar 偏移 257）。
  final raf = await file.open();
  final head = Uint8List(512);
  final read = await raf.readInto(head);
  await raf.close();
  final headBytes = read < 512 ? head.sublist(0, read) : head;
  final type = _detectTopLevel(headBytes);

  // 按顶层类型按需下载 JS 库（文本类不需要任何库，零下载）。
  final libs = <String>[];
  if (type == 'pdf') {
    libs.add('pdfjs');
    libs.add('pdfjs-worker');
  } else if (type == 'zip' || type == 'gzip' || type == 'tar') {
    libs.add('fflate');
  } else if (type == 'sqlite') {
    libs.add('sqljs');
    libs.add('sqljs-wasm');
  }

  final libPaths = <String, String>{};
  for (final k in libs) {
    libPaths[k] = await RemoteAssetManager.instance.ensure(k);
  }
  final jsDir =
      libPaths.isEmpty ? '' : File(libPaths.values.first).parent.path;
  final workerB64 = libPaths.containsKey('pdfjs-worker')
      ? base64Encode(await File(libPaths['pdfjs-worker']!).readAsBytes())
      : '';
  final wasmB64 = libPaths.containsKey('sqljs-wasm')
      ? base64Encode(await File(libPaths['sqljs-wasm']!).readAsBytes())
      : '';

  final html = _buildExtractHtml(
    Uri.file(filePath).toString(),
    type,
    maxChars,
    workerB64,
    wasmB64,
  );
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
        handlerName: 'binExtractDone',
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
            completer.complete({'error': '提取结果解析失败'});
          } else {
            completer.complete({'error': '提取未返回结果'});
          }
        },
      );
      await controller.loadData(
        data: html,
        baseUrl: WebUri('file://$jsDir/'),
      );
    },
  );

  await headless.run();
  try {
    return await completer.future.timeout(
      const Duration(seconds: 180),
      onTimeout: () => {'error': '二进制提取超时（180s）'},
    );
  } finally {
    await headless.dispose();
  }
}

/// 构造提取 HTML：JS 侧全部检测与提取逻辑。
String _buildExtractHtml(
  String fileUrl,
  String initType,
  int maxChars,
  String workerB64,
  String wasmB64,
) {
  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
</head>
<body>
<script>
const FILE_URL = '$fileUrl';
const MAX_CHARS = $maxChars;
const INIT_TYPE = '$initType';
const WORKER_B64 = '$workerB64';
const WASM_B64 = '$wasmB64';

function done(obj) {
  window.flutter_inappwebview.callHandler('binExtractDone', JSON.stringify(obj));
}

function loadScript(src) {
  return new Promise(function(res, rej) {
    var s = document.createElement('script');
    s.src = src;
    s.onload = res;
    s.onerror = function() { rej(new Error('加载库失败: ' + src)); };
    document.head.appendChild(s);
  });
}

function trunc(s, max) {
  if (s.length <= max) return {text: s, truncated: false};
  return {text: s.slice(0, max) + '\\n\\n...[截断: ' + s.length + ' 字符 > ' + max + ']', truncated: true};
}

function b2s(bytes) {
  var s = '';
  var CH = 0x8000;
  for (var i = 0; i < bytes.length; i += CH) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + CH));
  }
  return s;
}

function decodeText(bytes, enc) {
  try { return new TextDecoder(enc).decode(bytes); } catch (e) { return null; }
}

function detect(bytes) {
  var head = b2s(bytes.subarray(0, 16));
  if (bytes.length >= 5 && b2s(bytes.subarray(0, 5)) === '%PDF-') return 'pdf';
  if (bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b &&
      (bytes[2] === 0x03 || bytes[2] === 0x05 || bytes[2] === 0x07)) return 'zip';
  if (bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b) return 'gzip';
  if (bytes.length >= 15 && b2s(bytes.subarray(0, 15)) === 'SQLite format 3') return 'sqlite';
  if (bytes.length >= 262 && b2s(bytes.subarray(257, 262)) === 'ustar') return 'tar';
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) return 'utf16le';
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) return 'utf16be';
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return 'utf8bom';
  if (bytes.length >= 4 && bytes[0] === 0x89 && b2s(bytes.subarray(1, 4)) === 'PNG') return 'image';
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image';
  if (bytes.length >= 4 && b2s(bytes.subarray(0, 4)) === 'GIF8') return 'image';
  if (bytes.length >= 2 && bytes[0] === 0x42 && bytes[1] === 0x4d) return 'image';
  var hasNull = false;
  for (var i = 0; i < Math.min(bytes.length, 65536); i++) {
    if (bytes[i] === 0) { hasNull = true; break; }
  }
  if (!hasNull) {
    var u8 = decodeText(bytes, 'utf-8');
    if (u8 !== null) return 'text';
    var gbk = decodeText(bytes, 'gbk');
    if (gbk !== null) return 'gbktext';
  }
  return 'binary';
}

// ---------- 文本 ----------
function handleText(bytes, enc) {
  var s = decodeText(bytes, enc || 'utf-8');
  if (s === null) s = decodeText(bytes, 'gbk') || '(无法解码)';
  if (enc === 'utf8bom') s = s.replace(/^\\uFEFF/, '');
  var trimmed = s.trim();
  if (trimmed.length > 0 && (trimmed[0] === '{' || trimmed[0] === '[')) {
    try { s = JSON.stringify(JSON.parse(trimmed), null, 2); } catch (e) {}
  }
  return {text: s, encoding: enc || 'utf-8'};
}

// ---------- PDF ----------
async function handlePdf(bytes) {
  var workerBytes = Uint8Array.from(atob(WORKER_B64), function(c) { return c.charCodeAt(0); });
  pdfjsLib.GlobalWorkerOptions.workerSrc =
    URL.createObjectURL(new Blob([workerBytes], {type: 'application/javascript'}));
  var pdf = await pdfjsLib.getDocument({data: bytes}).promise;
  var total = pdf.numPages;
  var out = [];
  for (var i = 1; i <= total; i++) {
    var page = await pdf.getPage(i);
    var tc = await page.getTextContent();
    var text = tc.items.map(function(it) { return it.str || ''; }).join(' ');
    out.push('--- 第 ' + i + ' 页 ---\\n' + text);
  }
  return {kind: 'pdf', text: out.join('\\n\\n'), totalPages: total};
}

// ---------- ZIP 容器 ----------
function xmlDoc(bytes) {
  var s = new TextDecoder('utf-8').decode(bytes);
  return new DOMParser().parseFromString(s, 'application/xml');
}

function getText(el, tag) {
  var nodes = el.getElementsByTagNameNS('*', tag);
  var s = '';
  for (var i = 0; i < nodes.length; i++) s += nodes[i].textContent || '';
  return s;
}

function handleDocx(unzip, out) {
  var doc = xmlDoc(unzip['word/document.xml']);
  var paras = doc.getElementsByTagNameNS('*', 'p');
  var text = [];
  for (var i = 0; i < paras.length; i++) {
    var line = getText(paras[i], 't');
    if (line.trim()) text.push(line);
  }
  out.push('\\n== DOCX 正文 (' + text.length + ' 段) ==');
  for (var j = 0; j < text.length; j++) out.push(text[j]);
}

function handleXlsx(unzip, out) {
  var shared = [];
  if (unzip['xl/sharedStrings.xml']) {
    var doc = xmlDoc(unzip['xl/sharedStrings.xml']);
    var sis = doc.getElementsByTagNameNS('*', 'si');
    for (var i = 0; i < sis.length; i++) shared.push(getText(sis[i], 't'));
  }
  var sheetKeys = Object.keys(unzip).filter(function(n) {
    return /^xl\\/worksheets\\/sheet[0-9]+\\.xml$/.test(n);
  }).sort(function(a, b) {
    var na = parseInt(a.match(/sheet([0-9]+)/)[1]);
    var nb = parseInt(b.match(/sheet([0-9]+)/)[1]);
    return na - nb;
  });
  out.push('\\n== XLSX (' + sheetKeys.length + ' 个 sheet, ' + shared.length + ' 个共享字符串) ==');
  for (var si = 0; si < sheetKeys.length && si < 5; si++) {
    var doc = xmlDoc(unzip[sheetKeys[si]]);
    var rows = doc.getElementsByTagNameNS('*', 'row');
    out.push('### ' + sheetKeys[si] + ' (前 ' + Math.min(rows.length, 50) + ' 行)');
    for (var ri = 0; ri < Math.min(rows.length, 50); ri++) {
      var cells = rows[ri].getElementsByTagNameNS('*', 'c');
      var line = [];
      for (var ci = 0; ci < cells.length; ci++) {
        var c = cells[ci];
        var t = c.getAttribute('t');
        var v = c.getElementsByTagNameNS('*', 'v')[0];
        var is = c.getElementsByTagNameNS('*', 'is');
        var val = '';
        if (t === 's' && v) val = shared[parseInt(v.textContent)] || '';
        else if (is.length > 0) val = getText(is[0], 't');
        else if (v) val = v.textContent;
        line.push(val);
      }
      out.push(line.join(' | '));
    }
  }
}

function handleEpub(unzip, out) {
  var keys = Object.keys(unzip).filter(function(n) {
    return /\\.(x?html?|htm)$/i.test(n);
  }).sort();
  out.push('\\n== EPUB 文本 (' + keys.length + ' 个 html) ==');
  for (var i = 0; i < keys.length && i < 30; i++) {
    var s = new TextDecoder('utf-8').decode(unzip[keys[i]]);
    var doc = new DOMParser().parseFromString(s, 'text/html');
    var bodyText = doc.body ? doc.body.textContent : '';
    bodyText = bodyText.replace(/\\s+/g, ' ').trim();
    if (bodyText) out.push('\\n### ' + keys[i] + '\\n' + bodyText.slice(0, 2000));
  }
}

var TEXT_EXT = /\\\\.(txt|md|markdown|csv|json|xml|html?|js|mjs|ts|dart|py|java|c|cc|cpp|h|hpp|kt|swift|go|rs|rb|php|sql|yaml|yml|toml|ini|conf|log|sh|bat|ps1|css|scss|less)$/i;

function handleGenericZip(unzip, out) {
  var names = Object.keys(unzip);
  out.push('ZIP 文件清单 (' + names.length + ' 项):');
  for (var i = 0; i < Math.min(names.length, 80); i++) {
    out.push('  - ' + names[i] + ' (' + unzip[names[i]].length + ' B)');
  }
  var textFiles = names.filter(function(n) { return TEXT_EXT.test(n); });
  if (textFiles.length) {
    out.push('\\n== 文本文件内容 ==');
    for (var j = 0; j < Math.min(textFiles.length, 20); j++) {
      var name = textFiles[j];
      var content = decodeText(unzip[name], 'utf-8');
      if (content === null) content = decodeText(unzip[name], 'gbk');
      if (content === null) continue;
      out.push('\\n### ' + name);
      out.push(content.slice(0, 2000));
    }
  }
}

async function handleZip(bytes) {
  var unzip = fflate.unzipSync(bytes);
  var out = ['ZIP 文件 (' + bytes.length + ' B)'];
  if (unzip['word/document.xml']) { handleDocx(unzip, out); return {kind: 'docx', text: out.join('\\n')}; }
  var hasXlsx = Object.keys(unzip).some(function(n) { return /^xl\\/worksheets\\/sheet[0-9]+\\.xml$/.test(n); });
  if (hasXlsx) { handleXlsx(unzip, out); return {kind: 'xlsx', text: out.join('\\n')}; }
  var hasEpub = unzip['META-INF/container.xml'] ||
    Object.keys(unzip).some(function(n) { return /^(OEBPS|EPUB)\\//.test(n) && /\\.(x?html?)$/i.test(n); });
  if (hasEpub) { handleEpub(unzip, out); return {kind: 'epub', text: out.join('\\n')}; }
  handleGenericZip(unzip, out);
  return {kind: 'zip', text: out.join('\\n')};
}

// ---------- gzip / tar ----------
function handleTar(bytes) {
  var files = fflate.untarSync(bytes);
  var out = ['TAR 文件 (' + files.length + ' 项):'];
  for (var i = 0; i < Math.min(files.length, 80); i++) {
    out.push('  - ' + files[i].name + ' (' + files[i].data.length + ' B)');
  }
  var textFiles = files.filter(function(f) { return TEXT_EXT.test(f.name); });
  if (textFiles.length) {
    out.push('\\n== 文本文件内容 ==');
    for (var j = 0; j < Math.min(textFiles.length, 20); j++) {
      var f = textFiles[j];
      var content = decodeText(f.data, 'utf-8');
      if (content === null) content = decodeText(f.data, 'gbk');
      if (content === null) continue;
      out.push('\\n### ' + f.name);
      out.push(content.slice(0, 2000));
    }
  }
  return {kind: 'tar', text: out.join('\\n')};
}

function handleGzip(bytes) {
  var inner = fflate.gunzipSync(bytes);
  var type2 = detect(inner);
  if (type2 === 'tar') return handleTar(inner);
  if (type2 === 'zip') return handleZip(inner);
  if (type2 === 'text' || type2 === 'gbktext' || type2 === 'utf16le' ||
      type2 === 'utf16be' || type2 === 'utf8bom') {
    return handleText(inner, type2 === 'gbktext' ? 'gbk' : 'utf-8');
  }
  return {kind: 'gzip', text: 'GZIP 解压后 (' + inner.length + ' B) 内部格式: ' + type2};
}

// ---------- SQLite ----------
async function handleSqlite(bytes) {
  var wasmBytes = Uint8Array.from(atob(WASM_B64), function(c) { return c.charCodeAt(0); });
  var SQL = await initSqlJs({wasmBinary: wasmBytes});
  var db = new SQL.Database(bytes);
  var out = ['SQLite 数据库 (' + bytes.length + ' B)'];
  var tablesRes = db.exec("SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name");
  var names = [];
  if (tablesRes.length && tablesRes[0].values.length) {
    names = tablesRes[0].values.map(function(r) { return r[0]; });
  }
  out.push('表/视图 (' + names.length + '): ' + names.join(', '));
  for (var i = 0; i < Math.min(names.length, 20); i++) {
    var name = names[i];
    try {
      var info = db.exec('PRAGMA table_info("' + name.replace(/"/g, '""') + '")');
      var cols = (info.length && info[0].values.length) ? info[0].values.map(function(r) { return r[1]; }) : [];
      out.push('\\n### ' + name + ' (列: ' + cols.join(', ') + ')');
      var rows = db.exec('SELECT * FROM "' + name.replace(/"/g, '""') + '" LIMIT 30');
      if (rows.length && rows[0].values.length) {
        for (var ri = 0; ri < rows[0].values.length; ri++) {
          out.push('  ' + rows[0].values[ri].map(function(v) {
            return v === null ? 'NULL' : String(v);
          }).join(' | '));
        }
      } else {
        out.push('  (空表)');
      }
    } catch (e) {
      out.push('  读取 ' + name + ' 失败: ' + e);
    }
  }
  db.close();
  return {kind: 'sqlite', text: out.join('\\n')};
}

// ---------- 未知二进制 ----------
function handleBinary(bytes) {
  var hex = Array.from(bytes.slice(0, 64)).map(function(b) {
    return (b < 16 ? '0' : '') + b.toString(16);
  }).join(' ');
  var ascii = Array.from(bytes.slice(0, 64)).map(function(b) {
    return (b >= 32 && b < 127) ? String.fromCharCode(b) : '.';
  }).join('');
  return {kind: 'binary', text: '未知二进制文件 (' + bytes.length + ' B)\\nHex: ' + hex +
    '\\nAscii: ' + ascii + '\\n提示: 该格式暂不支持文本提取，可尝试 vision_analyze（图片）或告知 MIX 增加支持。'};
}

// ---------- 主流程 ----------
async function run() {
  try {
    var resp = await fetch(FILE_URL);
    if (!resp.ok) throw new Error('读取文件失败: HTTP ' + resp.status);
    var buf = await resp.arrayBuffer();
    var bytes = new Uint8Array(buf);
    var type = detect(bytes);
    var result;
    switch (type) {
      case 'pdf':
        await loadScript('pdf.min.js');
        result = await handlePdf(bytes);
        break;
      case 'zip':
        await loadScript('fflate.min.js');
        result = await handleZip(bytes);
        break;
      case 'gzip':
        await loadScript('fflate.min.js');
        result = handleGzip(bytes);
        break;
      case 'tar':
        await loadScript('fflate.min.js');
        result = handleTar(bytes);
        break;
      case 'sqlite':
        await loadScript('sql-wasm.js');
        result = await handleSqlite(bytes);
        break;
      case 'utf16le': result = handleText(bytes, 'utf-16le'); break;
      case 'utf16be': result = handleText(bytes, 'utf-16be'); break;
      case 'utf8bom': result = handleText(bytes, 'utf-8'); break;
      case 'gbktext': result = handleText(bytes, 'gbk'); break;
      case 'text': result = handleText(bytes, 'utf-8'); break;
      case 'image':
        result = {kind: 'image', text: '图片文件 (' + bytes.length + ' B)：文本提取无意义，请用 vision_analyze 分析图片内容。'};
        break;
      default: result = handleBinary(bytes);
    }
    var r = trunc(result.text, MAX_CHARS);
    done({kind: result.kind, type: type, size: bytes.length,
          totalPages: result.totalPages || null,
          encoding: result.encoding || null,
          truncated: r.truncated, text: r.text});
  } catch (e) {
    done({error: String(e)});
  }
}
run();
</script>
</body>
</html>''';
}

// ---------------------------------------------------------------------------
// bin_extract 工具注册
// ---------------------------------------------------------------------------

Future<String> _handleBinExtract(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  try {
    final pathArg = (args['path'] as String? ?? '').trim();
    if (pathArg.isEmpty) {
      return toolError('bin_extract: 缺少 path 参数');
    }
    final path = await _resolvePath(pathArg);
    if (!await File(path).exists()) {
      return toolError('bin_extract: 文件不存在: $path');
    }

    final maxChars = (args['max_chars'] as num?)?.toInt() ?? 30000;

    final result = await extractBinary(path, maxChars: maxChars);

    if (result['error'] != null) {
      return toolError('bin_extract: ${result['error']}');
    }

    final text = result['text'] as String? ?? '';
    return toolResult({
      'path': path,
      'size_bytes': result['size'],
      'type': result['type'],
      'kind': result['kind'],
      'total_pages': result['totalPages'],
      'encoding': result['encoding'],
      'chars': text.length,
      'truncated': result['truncated'] == true,
      'text': text,
    });
  } catch (e) {
    return toolError('bin_extract failed: $e');
  }
}

const Map<String, dynamic> _binExtractSchema = {
  'name': 'bin_extract',
  'description':
      'Universal binary file reader. Extracts readable text from any file by '
      'auto-detecting its format (magic bytes, no extension needed): PDF, '
      'ZIP (including DOCX/XLSX/EPUB), gzip, tar, tar.gz, SQLite databases, '
      'UTF-16 / GBK encoded text, single-line JSON (pretty-printed). Use '
      'whenever read_file fails on a binary or non-UTF8 file. Path can be '
      'absolute or relative to the notes root. For images use vision_analyze '
      'instead. Returns extracted text plus format metadata.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'File path (absolute, or relative to notes root)',
      },
      'max_chars': {
        'type': 'integer',
        'description':
            'Max chars of text to return (default 30000; stops at a '
            'page/entry boundary where possible)',
      },
    },
    'required': ['path'],
  },
};

/// 注册 bin_extract 工具。
void registerBinExtractTool() {
  registry.register(
    name: 'bin_extract',
    toolset: 'file',
    schema: _binExtractSchema,
    handler: _handleBinExtract,
    isAsync: true,
    emoji: '📦',
  );
}
