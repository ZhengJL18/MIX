import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/memory_db.dart';
import 'package:mix/services/notes_sync.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;

  setUpAll(() {
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_notes_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Directory> makeNotes() async {
    final notes = Directory('${tmp.path}/notes');
    await notes.create(recursive: true);
    await File('${notes.path}/线性代数.md').writeAsString(
        '行列式的性质，矩阵乘法。');
    await File('${notes.path}/概率.md').writeAsString('贝叶斯公式。');
    return notes;
  }

  group('syncNotes', () {
    test('笔记文件同步为 kind=note 记忆文档', () async {
      final notes = await makeNotes();
      final sync = NotesSyncService(db: db, notesRoot: notes.path);
      final count = await sync.syncNotes();
      expect(count, 2);
      final docs = await db.listDocs(kind: 'note');
      expect(docs.length, 2);
      expect(docs.any((d) => d['title'] == '线性代数'), isTrue);
      expect(docs.any((d) => d['title'] == '概率'), isTrue);
    });

    test('增量：mtime 未变不重复更新', () async {
      final notes = await makeNotes();
      final sync = NotesSyncService(db: db, notesRoot: notes.path);
      await sync.syncNotes();
      // 第二次同步：内容未变 → 0 更新。
      final count2 = await sync.syncNotes();
      expect(count2, 0);
      final docs = await db.listDocs(kind: 'note');
      expect(docs.length, 2); // 不重复插入。
    });

    test('内容变化触发更新（同一 path 覆盖）', () async {
      final notes = await makeNotes();
      final sync = NotesSyncService(db: db, notesRoot: notes.path);
      await sync.syncNotes();
      await File('${notes.path}/线性代数.md').writeAsString('更新后的内容。');
      // mtime 可能同毫秒 → 手动等 20ms 保证 mtime 变化。
      await Future.delayed(const Duration(milliseconds: 20));
      final count = await sync.syncNotes();
      expect(count, 1);
      final result = await db.db.select(
        "SELECT * FROM memory_docs WHERE path = 'notes/线性代数.md'",
      );
      final rows = result.toList();
      expect(rows.length, 1); // 覆盖而非新增。
      expect((rows.first['content'] as String), contains('更新后'));
    });

    test('排除特殊目录', () async {
      final notes = Directory('${tmp.path}/notes');
      await notes.create(recursive: true);
      await File('${notes.path}/正常.md').writeAsString('内容');
      final trash = Directory('${notes.path}/.trash');
      await trash.create(recursive: true);
      await File('${trash.path}/垃圾.md').writeAsString('垃圾');
      final sync = NotesSyncService(db: db, notesRoot: notes.path);
      final count = await sync.syncNotes();
      expect(count, 1); // .trash 被排除。
    });

    test('notes 根不存在 → 0', () async {
      final sync = NotesSyncService(
        db: db,
        notesRoot: '${tmp.path}/not_exist',
      );
      expect(await sync.syncNotes(), 0);
    });
  });
}
