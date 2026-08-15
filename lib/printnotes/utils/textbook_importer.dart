/// 教材导入服务：从 GitHub 下载开源数学教材（markdown/ipynb + LaTeX），
/// 解压/转换后写入笔记库 subject_library/，供 AI 出题与用户阅读。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
  final String tarballUrl; // GitHub codeload tarball（兜底）
  final String? serverTarballUrl; // 自有云服务器镜像（优先，快且稳）
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
    this.serverTarballUrl,
    this.isIpynb = false,
    this.chapterCount = 0,
    this.subdir,
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
