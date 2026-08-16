/// 笔记库同步服务（v4 设计稿 §1/§5："记忆 = 笔记库中的多份 Markdown 文档"）。
///
/// 把 printnotes 的笔记库（`documents/notes`）增量同步进记忆网：
/// 每篇 .md 笔记 → 记忆文档（kind='note'，path='notes/<相对路径>'），
/// 使笔记可被 `memory_search` 检索、进标签图/知识层级边。
///
/// - **增量**：mtime 变化才更新（记录到 memory_docs.mtime 比对）；
/// - **排除**：记忆库自身文档（memory/profile.md 等）、subject_library 之外
///   的二进制/隐藏文件；
/// - 可选的自动标签：复用 MemoryIndexer 的热词管线（由调用方决定）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'memory_db.dart';
import 'memory_indexer.dart';

/// 笔记库中需排除的目录名。
const Set<String> kNotesExcludedDirs = {
  '.obsidian',
  '.trash',
  '.git',
  'node_modules',
};

/// 笔记同步服务。
class NotesSyncService {
  final MemoryDB db;
  final String notesRoot;
  final MemoryIndexer? indexer; // 可选：自动标签/知识点边。

  NotesSyncService({
    required this.db,
    required this.notesRoot,
    this.indexer,
  });

  /// 全量/增量同步笔记库。返回本次更新的笔记数。
  Future<int> syncNotes() async {
    var updated = 0;
    try {
      final root = Directory(notesRoot);
      if (!root.existsSync()) return 0;
      await for (final file in _walkMd(root)) {
        try {
          final rel = p.relative(file.path, from: notesRoot);
          final stat = file.statSync();
          final mtime = stat.modified.millisecondsSinceEpoch;
          // 增量：mtime 未变则跳过。
          final rows = await db.db.query(
            'memory_docs',
            where: 'path = ?',
            whereArgs: ['notes/$rel'],
            limit: 1,
          );
          if (rows.isNotEmpty && (rows.first['mtime'] as int?) == mtime) {
            continue;
          }
          final content = await file.readAsString();
          final title = p.basenameWithoutExtension(file.path);
          final idx = indexer;
          final int? newId;
          if (idx != null) {
            // 自动标签 + 知识点边 + upsert 一步完成（mtime 用文件时间戳，
            // 供下次增量比对）。
            newId = await idx.indexEntry(
              path: 'notes/$rel',
              title: title,
              content: content,
              kind: 'note',
              mtime: mtime,
            );
          } else {
            newId = await db.upsertDoc(
              path: 'notes/$rel',
              title: title,
              content: content,
              kind: 'note',
              mtime: mtime,
            );
          }
          if (newId != null) updated++;
        } catch (_) {
          continue; // 单文件失败不中断。
        }
      }
    } catch (_) {}
    return updated;
  }

  /// 递归遍历笔记库 .md 文件（排除特殊目录）。
  Stream<File> _walkMd(Directory dir) async* {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is Directory) {
        if (kNotesExcludedDirs.contains(p.basename(entity.path))) continue;
        yield* _walkMd(entity);
      } else if (entity is File &&
          (p.extension(entity.path).toLowerCase() == '.md')) {
        yield entity;
      }
    }
  }
}
