/// 教材导入服务：从 GitHub 下载开源数学教材（markdown/ipynb + LaTeX），
/// 解压/转换后写入笔记库 subject_library/，供 AI 出题与用户阅读。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:html/dom.dart' show Element, Node, Text;
import 'package:html/parser.dart' show parse;

import '../../notes/notes_paths.dart';

/// 一个教材源。
class TextbookSource {
  final String name; // 教材名（也是导入到 subject_library 的目录名）
  final String subject; // 科目
  final String description; // 一句话描述
  final String license; // 许可证
  final String tarballUrl; // GitHub codeload tarball（兜底）
  final String? serverTarballUrl; // 自有云服务器镜像（优先，快且稳）
  final String sourceUrl; // 源仓库主页
  final bool isIpynb; // 源是否 ipynb（需转 md）
  final int chapterCount; // 预估章节数
  final String? subdir; // 解压后取哪个子目录（null = 全仓库取 md）
  final String kind; // 'githubTarball' | 'html312233'
  final String? baseUrl; // html312233: 站点根
  final String? manifestUrl; // html312233: index.json 地址

  const TextbookSource({
    required this.name,
    required this.subject,
    required this.description,
    required this.license,
    required this.tarballUrl,
    required this.sourceUrl,
    this.serverTarballUrl,
    this.isIpynb = false,
    this.chapterCount = 0,
    this.subdir,
    this.kind = 'githubTarball',
    this.baseUrl,
    this.manifestUrl,
  });
}

/// 自有云服务器教材镜像根（nginx 静态托管，见 assets/remote-runner / nginx
/// /textbooks/ 路由）。优先从这里拉，GitHub codeload 仅兜底（国内访问不稳）。
const String kTextbookServerRoot = 'http://43.139.179.58/textbooks';

/// 内置教材源清单（中文为主，英文 CC BY 备用）。
const List<TextbookSource> kTextbookSources = [
  TextbookSource(
    name: '线性代数（MIT 18.06）',
    subject: '线性代数',
    description: 'zlotus 中文笔记，35 讲，LaTeX 公式 + Python 示例',
    license: '无明确许可（来源 zlotus/notes-linear-algebra）',
    serverTarballUrl: '$kTextbookServerRoot/notes-linear-algebra.tar.gz',
    tarballUrl:
        'https://codeload.github.com/zlotus/notes-linear-algebra/tar.gz/refs/heads/master',
    sourceUrl: 'https://github.com/zlotus/notes-linear-algebra',
    isIpynb: true,
    chapterCount: 35,
  ),
  TextbookSource(
    name: '高等数学+线性代数（obsidian_math）',
    subject: '高数+线代',
    description: 'Obsidian 讲义，高数/线代完整，张宇体系≈同济教材',
    license: 'GPL-3.0',
    serverTarballUrl: '$kTextbookServerRoot/obsidian_math.tar.gz',
    tarballUrl:
        'https://codeload.github.com/BlandAlpha/obsidian_math/tar.gz/refs/heads/master',
    sourceUrl: 'https://github.com/BlandAlpha/obsidian_math',
    chapterCount: 13,
  ),
  TextbookSource(
    name: '概率论（Prob140 中译）',
    subject: '概率论',
    description: 'Berkeley Prob140 中文翻译，25 章',
    license: 'CC BY-NC-SA 4.0',
    serverTarballUrl: '$kTextbookServerRoot/prob140-textbook-zh.tar.gz',
    tarballUrl:
        'https://codeload.github.com/fly-fisher/prob140-textbook-zh/tar.gz/refs/heads/master',
    sourceUrl: 'https://github.com/fly-fisher/prob140-textbook-zh',
    chapterCount: 25,
    subdir: 'docs',
  ),
  TextbookSource(
    name: '312233 教材库',
    subject: '综合',
    description: r'312233.xyz 全库教材（HTML 章拆 → 转 Markdown，公式 $...$ 原样保留）',
    license: '见各书（站点 312233.xyz）',
    tarballUrl: '',
    sourceUrl: 'https://312233.xyz',
    kind: 'html312233',
    baseUrl: 'https://312233.xyz',
    manifestUrl: 'https://312233.xyz/index.json',
  ),
];

/// 导入一本教材到 subject_library/<name>。
/// 返回导入结果描述；失败抛异常。
Future<String> importTextbook(
  TextbookSource src, {
  void Function(double progress)? onProgress,
}) async {
  if (src.kind == 'html312233') {
    return _importHtmlSite(src, onProgress: onProgress);
  }
  final docs = (await getApplicationDocumentsDirectory()).path;
  final libDir = Directory(subjectLibraryPath(docs));
  await libDir.create(recursive: true);

  final targetName = _sanitizeDirName(src.name);
  final targetDir = Directory('${libDir.path}/$targetName');

  // 下载 tarball 到临时文件：优先自有服务器镜像，失败兜底 GitHub codeload。
  final tmp = File('${libDir.path}/.tmp_$targetName.tar.gz');
  onProgress?.call(0.05);
  final urls = <String>[
    if (src.serverTarballUrl != null) src.serverTarballUrl!,
    src.tarballUrl,
  ];
  String? lastErr;
  for (final url in urls) {
    try {
      await _downloadToFile(url, tmp);
      lastErr = null;
      break;
    } catch (e) {
      lastErr = '$url → $e';
    }
  }
  if (lastErr != null) {
    throw StateError('教材下载失败（服务器与 GitHub 均不可用）: $lastErr');
  }
  onProgress?.call(0.4);

  // 解压 + TarDecoder 解析 + 逐文件解码写盘是 CPU 密集活（大教材几十 MB、
  // 上百个 ipynb JSON 解析），丢后台 isolate 执行，主 isolate 只收结果，
  // 避免导入过程中 UI 卡死。进度在 isolate 外按阶段推进：0.55 = 解压解析中，
  // 完成后 1.0。（原 0.6 细分提示点被合并，无实际影响。）
  onProgress?.call(0.55);
  final imported = await Isolate.run(() => _extractAndWrite(
        tmpPath: tmp.path,
        tarTmpPath: '${libDir.path}/.tmp_$targetName.tar',
        targetDirPath: targetDir.path,
        name: src.name,
        subject: src.subject,
        description: src.description,
        sourceUrl: src.sourceUrl,
        license: src.license,
        subdir: src.subdir,
        isIpynb: src.isIpynb,
      ));
  onProgress?.call(1.0);

  return '已导入 $imported 章/篇到 subject_library/$targetName';
}

/// 后台 isolate 内执行教材导入核心：gzip 解压 → tar 解析 → 逐文件转写。
///
/// 全参数均为可发送的 primitive（TextbookSource 对象不能跨 isolate），
/// 与 [importTextbook] 的进度回调解耦。gzip 用 dart:io 流式管道解到中间
/// tar 文件（不整包读内存），再 InputFileStream + TarDecoder.decodeStream
/// 懒加载解析——文件内容只在访问时按需读，处理完立即 clear 释放，
/// 内存占用恒定。（旧实现整包驻留内存，大教材在低内存设备上 OOM/卡死。）
Future<int> _extractAndWrite({
  required String tmpPath,
  required String tarTmpPath,
  required String targetDirPath,
  required String name,
  required String subject,
  required String description,
  required String sourceUrl,
  required String license,
  String? subdir,
  required bool isIpynb,
}) async {
  final tmp = File(tmpPath);
  final tarTmp = File(tarTmpPath);
  final targetDir = Directory(targetDirPath);
  var imported = 0;
  try {
    await tmp
        .openRead()
        .transform(gzip.decoder)
        .pipe(tarTmp.openWrite());

    final input = InputFileStream(tarTmp.path);
    try {
      final archive = TarDecoder().decodeStream(input);

      // 解压后顶层目录名（GitHub tarball 是 <repo>-<branch>/）。
      final topDir = archive.files.first.name.split('/').first;
      final subPrefix = subdir != null ? '$topDir/$subdir/' : '$topDir/';

      await targetDir.create(recursive: true);
      for (final file in archive.files) {
        if (!file.isFile) continue;
        final rel = file.name.replaceAll('\\', '/');
        // 防御 tar slip。
        if (rel.contains('..') || rel.startsWith('/')) continue;
        // 只取源子目录内的文件（md 源取 .md，ipynb 源取 .ipynb）。
        final isInScope =
            subdir != null ? rel.startsWith(subPrefix) : rel.startsWith(topDir);
        if (!isInScope) continue;
        final isMd = rel.endsWith('.md');
        final isIpynbFile = rel.endsWith('.ipynb');
        if (!isMd && !isIpynbFile) continue;
        // 跳过非章节文件（README/LICENSE/欢迎页/说明）。
        final base = rel.split('/').last.toLowerCase();
        if (isMd &&
            (base == 'readme.md' ||
                base == 'license' ||
                base == 'license.md' ||
                base == '欢迎.md' ||
                base == 'welcome.md' ||
                base == '说明.md' ||
                base == 'index.md' ||
                base == 'introduction.md')) {
          continue;
        }

        final outRel = _outPath(rel, topDir, isIpynb);
        final out = File('$targetDirPath/$outRel');
        await out.parent.create(recursive: true);

        // 懒加载读单个文件内容（此刻才真正从磁盘读），用完立即释放，
        // 避免全部文件内容驻留内存。
        if (isMd) {
          final content = _decodeUtf8(file.content as List<int>);
          await out.writeAsString(content);
          imported++;
        } else if (isIpynbFile) {
          final content = _decodeUtf8(file.content as List<int>);
          final md = _ipynbToMarkdown(content);
          if (md.trim().isNotEmpty) {
            await out.writeAsString(md);
            imported++;
          }
        }
        file.clear();
      }

      // 许可/来源标注。
      await _writeLicenseFile(
        targetDirPath,
        name: name,
        subject: subject,
        sourceUrl: sourceUrl,
        license: license,
        description: description,
      );
    } finally {
      input.closeSync();
    }
  } finally {
    try {
      if (tarTmp.existsSync()) await tarTmp.delete();
    } catch (_) {}
  }

  // 清理下载的 gzip 临时文件。
  try {
    if (tmp.existsSync()) await tmp.delete();
  } catch (_) {}
  return imported;
}

/// 计算解压后文件的相对输出路径（去掉 GitHub tarball 顶层目录前缀）。
String _outPath(String rel, String topDir, bool isIpynb) {
  var out = rel;
  if (out.startsWith(topDir)) {
    out = out.substring(topDir.length + 1);
  }
  if (isIpynb && out.endsWith('.ipynb')) {
    out = out.replaceAll('.ipynb', '.md');
  }
  return out;
}

/// ipynb JSON → markdown。
/// markdown cell → 原文（含 LaTeX）；code cell → ```python 代码块（剥离 % 魔法）。
String _ipynbToMarkdown(String json) {
  final sb = StringBuffer();
  try {
    final nb = jsonDecode(json) as Map<String, dynamic>;
    final cells = nb['cells'] as List? ?? [];
    for (final cell in cells) {
      if (cell is! Map<String, dynamic>) continue;
      final cellType = cell['cell_type'];
      final source = cell['source'];
      if (source == null) continue;
      final text = source is List ? source.join() : source.toString();
      if (cellType == 'markdown') {
        sb.writeln(text);
        sb.writeln();
      } else if (cellType == 'code') {
        final code = _stripJupyterMagic(text);
        if (code.trim().isNotEmpty) {
          sb.writeln('```python');
          sb.writeln(code.trimRight());
          sb.writeln('```');
          sb.writeln();
        }
      }
    }
  } catch (_) {}
  return sb.toString();
}

/// 剥离 Jupyter 魔法（%matplotlib inline / !shell / ?帮助），对齐云端 runner。
String _stripJupyterMagic(String code) {
  final lines = <String>[];
  for (final line in code.split('\n')) {
    final s = line.trim();
    if (s.isEmpty) {
      lines.add(line);
      continue;
    }
    if (s.startsWith('%') || s.startsWith('!')) continue;
    if (RegExp(r'^[\w\s\.\(\)\[\],=+\-*/<>:]*\?\s*$').hasMatch(line)) continue;
    lines.add(line);
  }
  return lines.join('\n');
}

/// 目录名安全化（去路径分隔符等）。
String _sanitizeDirName(String name) {
  return name
      .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), '_');
}

/// 流式下载到文件（照 webDownloadTool，超时放宽，避免大 tarball 占内存）。
Future<void> _downloadToFile(String url, File file) async {
  final request = http.Request('GET', Uri.parse(url));
  final resp = await http.Client()
      .send(request)
      .timeout(const Duration(minutes: 5));
  if (resp.statusCode != 200) {
    throw StateError('下载失败 HTTP ${resp.statusCode}');
  }
  final sink = file.openWrite();
  await for (final chunk in resp.stream) {
    sink.add(chunk);
  }
  await sink.flush();
  await sink.close();
}

String _decodeUtf8(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: true);

/// 写许可与来源标注文件（isolate 内调用，参数全为 primitive）。
Future<void> _writeLicenseFile(
  String dirPath, {
  required String name,
  required String subject,
  required String sourceUrl,
  required String license,
  required String description,
}) async {
  final content = '''
# $name

- 科目：$subject
- 来源：$sourceUrl
- 许可证：$license
- 说明：由 MIX 一键导入功能从开源仓库下载。

$description
''';
  await File('$dirPath/教材来源说明.txt').writeAsString(content);
}

// ─────────────────────────────────────────────────────────────
// 312233.xyz 教材库导入（HTML 章拆 → Markdown，公式 $...$ 原样保留）
// 适配本文件已有的 isolate 化结构：_importHtmlSite 在主 isolate 走 HTTP
// 逐章下载+解析（单章轻量，不塞 Isolate.run 以免跨 isolate 传巨大内容）。
// ─────────────────────────────────────────────────────────────

/// 导入 312233.xyz 全库：读 index.json → 遍历 books → 逐本解析目录页 →
/// 逐章下载 HTML 转 Markdown → 落盘 subject_library/312233/<subject>/<book>/chN.md。
Future<String> _importHtmlSite(
  TextbookSource src, {
  void Function(double progress)? onProgress,
}) async {
  final libDir = Directory(subjectLibraryPath(
      (await getApplicationDocumentsDirectory()).path));
  final base = (src.baseUrl ?? 'https://312233.xyz').replaceAll(RegExp(r'/$'), '');
  final manifestUrl = src.manifestUrl ?? '$base/index.json';

  final manifest =
      jsonDecode(await _downloadText(manifestUrl)) as Map<String, dynamic>;
  final books = (manifest['books'] as List?) ?? <dynamic>[];

  var importedBooks = 0;
  var importedChapters = 0;
  final total = books.length;
  for (var i = 0; i < total; i++) {
    final book = books[i] as Map<String, dynamic>;
    final title = (book['title'] as String?) ?? '未命名教材';
    final subjectId = (book['subject'] as String?) ?? '综合';
    final file = (book['file'] as String?) ?? '';
    if (file.isEmpty) continue;
    final segs = file.split('/');
    final bookDirUrl = '$base/${segs.take(segs.length - 1).join('/')}';
    onProgress?.call((i / (total == 0 ? 1 : total)) * 0.9);
    final n = await _import312233Book(
      bookDirUrl: bookDirUrl,
      subjectId: subjectId,
      title: title,
      libDir: libDir,
    );
    if (n > 0) {
      importedBooks++;
      importedChapters += n;
    }
  }
  onProgress?.call(1.0);
  return '已导入 312233 教材库：$importedBooks 本 / $importedChapters 章 → '
      'subject_library/312233';
}

/// 导入单本 312233 教材：解析目录页提取 chN.html 链接 → 逐章转 md 落盘。
Future<int> _import312233Book({
  required String bookDirUrl,
  required String subjectId,
  required String title,
  required Directory libDir,
}) async {
  final indexHtml = await _downloadText('$bookDirUrl/index.html');
  final links = _extractChapterLinks(indexHtml);
  if (links.isEmpty) return 0;

  final bookDir = Directory(
      '${libDir.path}/312233/$subjectId/${_sanitizeDirName(title)}');
  await bookDir.create(recursive: true);

  var count = 0;
  for (final ch in links) {
    final html = await _downloadText('$bookDirUrl/$ch');
    final md = _htmlToMarkdown(html);
    if (md.trim().isEmpty) continue;
    final out = File('${bookDir.path}/${ch.replaceAll('.html', '.md')}');
    await out.writeAsString(md);
    count++;
  }
  return count;
}

/// 解析目录页，提取 chN.html 章节链接（去重、按章号排序）。
/// 注意：index.json 的 chapters 字段与实际不符，必须解析目录页 <a href>。
List<String> _extractChapterLinks(String html) {
  final links = <String>[];
  final re = RegExp(r'href="(ch\d+\.html)"');
  for (final m in re.allMatches(html)) {
    final l = m.group(1)!;
    if (!links.contains(l)) links.add(l);
  }
  int numOf(String s) =>
      int.tryParse(RegExp(r'ch(\d+)\.html').firstMatch(s)?.group(1) ?? '0') ??
      0;
  links.sort((a, b) => numOf(a).compareTo(numOf(b)));
  return links;
}

/// 下载文本（UTF-8 容错）。
Future<String> _downloadText(String url) async {
  final resp = await http
      .get(_safeUri(url))
      .timeout(const Duration(minutes: 2));
  if (resp.statusCode != 200) {
    throw StateError('下载失败 HTTP ${resp.statusCode}: $url');
  }
  return _decodeUtf8(resp.bodyBytes);
}

/// 对含中文路径段的 URL 做各段 percent-encode，避免 Uri.parse 抛异常。
Uri _safeUri(String url) {
  final u = Uri.parse(url);
  return u.replace(
    pathSegments: u.pathSegments.map((s) => Uri.encodeComponent(s)).toList(),
  );
}

/// HTML → Markdown（去壳保文本，公式 $...$ 原样保留）。
String _htmlToMarkdown(String html) {
  final doc = parse(html);
  final buf = StringBuffer();
  final root = doc.body ?? doc.documentElement;
  if (root != null) _walkHtml(root, buf);
  return buf
          .toString()
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim() +
      '\n';
}

/// 递归遍历 HTML 节点，转为 Markdown 文本。
void _walkHtml(Node node, StringBuffer buf) {
  if (node is Text) {
    final t = node.text.trim();
    if (t.isNotEmpty) buf.write(t);
    return;
  }
  if (node is! Element) return;
  final tag = node.localName;
  if (tag == 'script' ||
      tag == 'style' ||
      tag == 'nav' ||
      tag == 'header' ||
      tag == 'footer' ||
      tag == 'head') {
    return;
  }
  switch (tag) {
    case 'h1':
      _block(buf, node, '# ');
      break;
    case 'h2':
      _block(buf, node, '## ');
      break;
    case 'h3':
      _block(buf, node, '### ');
      break;
    case 'h4':
      _block(buf, node, '#### ');
      break;
    case 'h5':
      _block(buf, node, '##### ');
      break;
    case 'h6':
      _block(buf, node, '###### ');
      break;
    case 'p':
    case 'div':
      _block(buf, node, '');
      break;
    case 'li':
      buf.writeln('- ${_inlineText(node)}');
      break;
    case 'blockquote':
    case 'q':
      _block(buf, node, '> ');
      break;
    case 'pre':
      buf.writeln('```');
      buf.writeln(_inlineText(node));
      buf.writeln('```');
      buf.writeln();
      break;
    case 'br':
      buf.writeln();
      break;
    case 'table':
      // 表格保留原始 HTML，交 MIX 的 HTML 渲染兜底。
      buf.writeln(node.outerHtml);
      buf.writeln();
      break;
    case 'a':
      final href = node.attributes['href'] ?? '';
      buf.write('[${_inlineText(node)}]($href)');
      break;
    case 'img':
      final src = node.attributes['src'] ?? '';
      final alt = node.attributes['alt'] ?? '';
      buf.write('![$alt]($src)');
      break;
    case 'strong':
    case 'b':
      buf.write('**${_inlineText(node)}**');
      break;
    case 'em':
    case 'i':
      buf.write('*${_inlineText(node)}*');
      break;
    case 'code':
      buf.write('`${_inlineText(node)}`');
      break;
    case 'hr':
      buf.writeln('\n---\n');
      break;
    default:
      for (final child in node.nodes) {
        _walkHtml(child, buf);
      }
  }
}

/// 取元素内联纯文本（递归，去标签，保留公式 $...$ 等文本）。
String _inlineText(Element e) {
  final sb = StringBuffer();
  for (final child in e.nodes) {
    if (child is Text) {
      sb.write(child.text);
    } else if (child is Element) {
      sb.write(_inlineText(child));
    }
  }
  return sb.toString().trim();
}

/// 块级输出：先空行，再前缀 + 内容。
void _block(StringBuffer buf, Element e, String prefix) {
  buf.writeln();
  buf.write(prefix);
  buf.writeln(_inlineText(e));
  buf.writeln();
}
