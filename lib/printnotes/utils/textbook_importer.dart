/// 教材导入服务：从 GitHub 下载开源数学教材（markdown/ipynb + LaTeX），
/// 解压/转换后写入笔记库 subject_library/，供 AI 出题与用户阅读。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../notes/notes_paths.dart';

/// 一个教材源。
class TextbookSource {
  final String name; // 教材名（也是导入到 subject_library 的目录名）
  final String subject; // 科目
  final String description; // 一句话描述
  final String license; // 许可证
  final String tarballUrl; // GitHub codeload tarball
  final String sourceUrl; // 源仓库主页
  final bool isIpynb; // 源是否 ipynb（需转 md）
  final int chapterCount; // 预估章节数
  final String? subdir; // 解压后取哪个子目录（null = 全仓库取 md）

  const TextbookSource({
    required this.name,
    required this.subject,
    required this.description,
    required this.license,
    required this.tarballUrl,
    required this.sourceUrl,
    this.isIpynb = false,
    this.chapterCount = 0,
    this.subdir,
  });
}

/// 内置教材源清单（中文为主，英文 CC BY 备用）。
const List<TextbookSource> kTextbookSources = [
  TextbookSource(
    name: '线性代数（MIT 18.06）',
    subject: '线性代数',
    description: 'zlotus 中文笔记，35 讲，LaTeX 公式 + Python 示例',
    license: '无明确许可（来源 zlotus/notes-linear-algebra）',
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
    tarballUrl:
        'https://codeload.github.com/fly-fisher/prob140-textbook-zh/tar.gz/refs/heads/master',
    sourceUrl: 'https://github.com/fly-fisher/prob140-textbook-zh',
    chapterCount: 25,
    subdir: 'docs',
  ),
];

/// 导入一本教材到 subject_library/<name>。
/// 返回导入结果描述；失败抛异常。
Future<String> importTextbook(
  TextbookSource src, {
  void Function(double progress)? onProgress,
}) async {
  final docs = (await getApplicationDocumentsDirectory()).path;
  final libDir = Directory(subjectLibraryPath(docs));
  await libDir.create(recursive: true);

  final targetName = _sanitizeDirName(src.name);
  final targetDir = Directory('${libDir.path}/$targetName');

  // 下载 tarball 到临时文件。
  final tmp = File('${libDir.path}/.tmp_$targetName.tar.gz');
  onProgress?.call(0.05);
  await _downloadToFile(src.tarballUrl, tmp);
  onProgress?.call(0.4);

  // 解压。
  final bytes = await tmp.readAsBytes();
  final archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
  onProgress?.call(0.6);

  // 解压后顶层目录名（GitHub tarball 是 <repo>-<branch>/）。
  final topDir = archive.files.first.name.split('/').first;
  final subPrefix = src.subdir != null ? '$topDir/${src.subdir}/' : '$topDir/';

  await targetDir.create(recursive: true);
  var imported = 0;
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final rel = file.name.replaceAll('\\', '/');
    // 防御 tar slip。
    if (rel.contains('..') || rel.startsWith('/')) continue;
    // 只取源子目录内的文件（md 源取 .md，ipynb 源取 .ipynb）。
    final isInScope = src.subdir != null
        ? rel.startsWith(subPrefix)
        : rel.startsWith(topDir);
    if (!isInScope) continue;
    final isMd = rel.endsWith('.md');
    final isIpynb = rel.endsWith('.ipynb');
    if (!isMd && !isIpynb) continue;

    final outRel = _outPath(src, rel, topDir);
    final out = File('${targetDir.path}/$outRel');
    await out.parent.create(recursive: true);

    if (isMd) {
      final content = _decodeUtf8(file.content as List<int>);
      await out.writeAsString(content);
      imported++;
    } else if (isIpynb) {
      final content = _decodeUtf8(file.content as List<int>);
      final md = _ipynbToMarkdown(content);
      if (md.trim().isNotEmpty) {
        await out.writeAsString(md);
        imported++;
      }
    }
  }

  // 许可/来源标注。
  await _writeLicense(targetDir, src);

  // 清理临时文件。
  try {
    if (tmp.existsSync()) await tmp.delete();
  } catch (_) {}
  onProgress?.call(1.0);

  return '已导入 $imported 章/篇到 subject_library/$targetName';
}

/// 计算解压后文件的相对输出路径（去掉 GitHub tarball 顶层目录前缀）。
String _outPath(TextbookSource src, String rel, String topDir) {
  var out = rel;
  if (out.startsWith(topDir)) {
    out = out.substring(topDir.length + 1);
  }
  if (src.isIpynb && out.endsWith('.ipynb')) {
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

/// 流式下载到文件（照 webDownloadTool，超时放宽）。
Future<void> _downloadToFile(String url, File file) async {
  final resp = await http
      .get(Uri.parse(url))
      .timeout(const Duration(minutes: 5));
  if (resp.statusCode != 200) {
    throw StateError('下载失败 HTTP ${resp.statusCode}');
  }
  await file.writeAsBytes(resp.bodyBytes, flush: true);
}

String _decodeUtf8(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: true);

/// 写许可与来源标注文件。
Future<void> _writeLicense(Directory dir, TextbookSource src) async {
  final content = '''
# $src.name

- 科目：$src.subject
- 来源：${src.sourceUrl}
- 许可证：$src.license
- 说明：由 MIX 一键导入功能从开源仓库下载。

$src.description
''';
  await File('${dir.path}/教材来源说明.txt').writeAsString(content);
}
