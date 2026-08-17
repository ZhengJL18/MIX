// 笔记库工具：让 Hermes agent 读写学习/工作笔记库（documents/notes）。
//
// 与 printnotes UI 共用同一目录（notes 根 = subject_library 同根），agent
// 写的笔记 UI 能看到，UI 编辑的笔记 agent 能读到。纯 dart:io 操作，不依赖
// printnotes 的 provider（agent 侧独立，无 UI 上下文）。
library;

import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:path_provider/path_provider.dart';

import '../notes/notes_paths.dart';
import 'registry.dart';

String? _notesRootCached;

/// 最近一次 notes_write 成功写入的笔记绝对路径（聊天侧深链「打开笔记」用）。
String? lastWrittenNotePath;

/// 工具最近一次成功写入某文件后的 (mtime, length) 快照，键为解析后的绝对路径。
/// 写入前用它比对文件是否在工具上次写入后被其他写入方（如 UI 自动保存）改过；
/// 改过则本次内容落同名 .conflict 副本，避免互相覆盖（last-write-wins）。
final Map<String, (DateTime, int)> _lastWriteState = {};

/// 解析笔记库根目录（documents/notes）。首次调用缓存。
Future<String> _notesRoot() async {
  if (_notesRootCached != null) return _notesRootCached!;
  final docs = (await getApplicationDocumentsDirectory()).path;
  _notesRootCached = notesRootPath(docs);
  await Directory(_notesRootCached!).create(recursive: true);
  return _notesRootCached!;
}

/// 把用户给的路由（相对笔记库根 或 绝对路径）规范化为绝对路径。
Future<String> _resolve(String input) async {
  final root = await _notesRoot();
  if (p.isAbsolute(input)) return input;
  return p.normalize(p.join(root, input));
}

/// 工具路径根（file_safety 外的第二层：笔记库限定在 notes 根内）。
Future<bool> _isWithinRoot(String path) async {
  final root = await _notesRoot();
  return p.isWithin(root, path);
}

/// 判断是否为隐藏路径（任一路径段以 . 开头）。
/// 过滤 .printnotes/.trash/.archive 等配置/回收目录，不暴露给 agent。
bool _isHiddenPath(String abs, String root) {
  final rel = p.relative(abs, from: root);
  return rel.split(p.separator).any((seg) => seg.startsWith('.'));
}

/// 递归列出笔记库可见条目（跳过隐藏目录），onEntry 收相对根路径。
/// followLinks: false —— 符号链接不跟随，避免环状链接无限递归死循环。
Future<void> _walkVisible(
  Directory dir,
  String root,
  void Function(bool isDir, String rel) onEntry,
) async {
  await for (final e in dir.list(followLinks: false)) {
    if (_isHiddenPath(e.path, root)) continue;
    final rel = p.relative(e.path, from: root);
    if (e is Directory) {
      onEntry(true, rel);
      await _walkVisible(e, root, onEntry);
    } else if (e is File) {
      onEntry(false, rel);
    }
  }
}

// ---------------------------------------------------------------------------
// notes_list：列出笔记库目录内容
// ---------------------------------------------------------------------------

Future<String> _handleNotesList(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  try {
    final dirArg = args['path'] as String? ?? '';
    final recursive = args['recursive'] == true;
    final dir = await _resolve(dirArg);
    if (!await Directory(dir).exists()) {
      return toolError('notes_list: 目录不存在: $dir');
    }
    if (!await _isWithinRoot(dir)) {
      return toolError('notes_list: 路径超出笔记库根目录');
    }
    final root = await _notesRoot();
    final lines = <String>[];
    if (recursive) {
      await _walkVisible(Directory(dir), root, (isDir, rel) {
        lines.add(isDir ? '[目录] $rel/' : '[文件] $rel');
      });
    } else {
      await for (final e in Directory(dir).list(followLinks: false)) {
        if (_isHiddenPath(e.path, root)) continue;
        final rel = p.relative(e.path, from: root);
        lines.add(e is Directory ? '[目录] $rel/' : '[文件] $rel');
      }
    }
    if (lines.isEmpty) return toolResult({'path': dir, 'items': const <String>[]});
    return toolResult({
      'path': dir,
      'items': lines,
    });
  } catch (e) {
    return toolError('notes_list failed: $e');
  }
}

// ---------------------------------------------------------------------------
// notes_search：在笔记库内全文搜索
// ---------------------------------------------------------------------------

Future<String> _handleNotesSearch(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  try {
    final query = (args['query'] as String? ?? '').trim();
    if (query.isEmpty) return toolError('notes_search: 缺少 query');
    final root = await _notesRoot();
    final results = <String>[];
    await _walkVisible(Directory(root), root, (isDir, rel) {
      if (isDir) return;
      final e = File(p.join(root, rel));
      final ext = p.extension(e.path).toLowerCase();
      if (!['.md', '.markdown', '.txt'].contains(ext)) return;
      try {
        final content = e.readAsStringSync();
        if (content.toLowerCase().contains(query.toLowerCase())) {
          results.add(rel);
        }
      } catch (_) {}
    });
    return toolResult({'query': query, 'matches': results});
  } catch (e) {
    return toolError('notes_search failed: $e');
  }
}

// ---------------------------------------------------------------------------
// notes_read：读笔记内容
// ---------------------------------------------------------------------------

Future<String> _handleNotesRead(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  try {
    final pathArg = args['path'] as String? ?? '';
    if (pathArg.isEmpty) return toolError('notes_read: 缺少 path');
    final path = await _resolve(pathArg);
    if (!await _isWithinRoot(path)) {
      return toolError('notes_read: 路径超出笔记库根目录');
    }
    final f = File(path);
    if (!await f.exists()) return toolError('notes_read: 文件不存在: $pathArg');
    final content = await f.readAsString();
    final maxChars = (args['max_chars'] as num?)?.toInt() ?? 20000;
    final truncated = content.length > maxChars;
    return toolResult({
      'path': p.relative(path, from: await _notesRoot()),
      'content': truncated ? content.substring(0, maxChars) : content,
      'truncated': truncated,
    });
  } catch (e) {
    return toolError('notes_read failed: $e');
  }
}

// ---------------------------------------------------------------------------
// notes_write：写入/追加笔记（创建目录 + 文件）
// ---------------------------------------------------------------------------

Future<String> _handleNotesWrite(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  try {
    final pathArg = args['path'] as String? ?? '';
    final content = args['content'] as String? ?? '';
    final mode = args['mode'] as String? ?? 'write'; // write | append
    if (pathArg.isEmpty) return toolError('notes_write: 缺少 path');
    final path = await _resolve(pathArg);
    if (!await _isWithinRoot(path)) {
      return toolError('notes_write: 路径超出笔记库根目录');
    }
    await Directory(p.dirname(path)).create(recursive: true);
    final f = File(path);

    // 写入前比对 mtime/length：文件在工具上次写入后被其他写入方（如 UI 自动
    // 保存整文件写）改过，则本次内容落同名 .conflict 副本，不直接覆盖对方。
    if (await f.exists()) {
      final prev = _lastWriteState[path];
      if (prev != null) {
        final curMod = await f.lastModified();
        final curLen = await f.length();
        if (curMod != prev.$1 || curLen != prev.$2) {
          final conflictPath = '$path.conflict';
          final conflictFile = File(conflictPath);
          await conflictFile.writeAsString(content);
          return toolResult({
            'path': p.relative(path, from: await _notesRoot()),
            'mode': mode,
            'conflict': true,
            'conflict_path':
                p.relative(conflictPath, from: await _notesRoot()),
            'bytes': (await conflictFile.length()).toString(),
          });
        }
      }
    }

    if (mode == 'append' && await f.exists()) {
      await f.writeAsString('\n$content', mode: FileMode.append);
    } else {
      await f.writeAsString(content);
    }
    _lastWriteState[path] = (await f.lastModified(), await f.length());
    lastWrittenNotePath = path;
    return toolResult({
      'path': p.relative(path, from: await _notesRoot()),
      'mode': mode,
      'bytes': (await f.length()).toString(),
    });
  } catch (e) {
    return toolError('notes_write failed: $e');
  }
}

// ---------------------------------------------------------------------------
// Schema 定义
// ---------------------------------------------------------------------------

const Map<String, dynamic> _notesListSchema = {
  'name': 'notes_list',
  'description':
      'List contents of the notes library (documents/notes, which contains '
      'the subject_library). Pass a relative path from the notes root (e.g. '
      '"subject_library/数学") or empty for root. Returns directories and files.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Relative path from notes root, or empty for root',
      },
      'recursive': {
        'type': 'boolean',
        'description': 'List recursively (default false)',
      },
    },
    'required': [],
  },
};

const Map<String, dynamic> _notesSearchSchema = {
  'name': 'notes_search',
  'description':
      'Full-text search across all markdown notes in the notes library '
      '(including subject_library 讲义). Returns matching file paths.',
  'parameters': {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'Text to search for',
      },
    },
    'required': ['query'],
  },
};

const Map<String, dynamic> _notesReadSchema = {
  'name': 'notes_read',
  'description':
      'Read a note file from the notes library. Path is relative to the notes '
      'root (e.g. "subject_library/数学/微积分.md"). Returns file content.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Relative path from notes root',
      },
      'max_chars': {
        'type': 'integer',
        'description': 'Max chars to return (default 20000)',
      },
    },
    'required': ['path'],
  },
};

const Map<String, dynamic> _notesWriteSchema = {
  'name': 'notes_write',
  'description':
      'Write or append a note file in the notes library. Creates parent '
      'directories. Use this to save study notes, summaries, or working notes '
      'that the user can then view in the notes app UI.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Relative path from notes root, e.g. "学习/线性代数/行列式.md"',
      },
      'content': {
        'type': 'string',
        'description': 'Markdown content to write',
      },
      'mode': {
        'type': 'string',
        'enum': ['write', 'append'],
        'description': 'write (default) overwrites; append adds to end',
      },
    },
    'required': ['path', 'content'],
  },
};

/// 注册笔记库工具。
void registerNotesTools() {
  registry.register(
    name: 'notes_list',
    toolset: 'notes',
    schema: _notesListSchema,
    handler: _handleNotesList,
    isAsync: true,
    emoji: '📁',
  );
  registry.register(
    name: 'notes_search',
    toolset: 'notes',
    schema: _notesSearchSchema,
    handler: _handleNotesSearch,
    isAsync: true,
    emoji: '🔍',
  );
  registry.register(
    name: 'notes_read',
    toolset: 'notes',
    schema: _notesReadSchema,
    handler: _handleNotesRead,
    isAsync: true,
    emoji: '📄',
  );
  registry.register(
    name: 'notes_write',
    toolset: 'notes',
    schema: _notesWriteSchema,
    handler: _handleNotesWrite,
    isAsync: true,
    emoji: '✍️',
  );
}
