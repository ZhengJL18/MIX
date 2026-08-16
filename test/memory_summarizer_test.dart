import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/memory_db.dart';
import 'package:mix/services/memory_summarizer.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;

  setUpAll(() {
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_summarizer_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('summarizeActivated', () {
    test('只总结激活过的文档', () async {
      final id1 = await db.upsertDoc(
        path: 'a.md', title: 'A', content: '内容一很长' * 10);
      await db.upsertDoc(path: 'b.md', title: 'B', content: '内容二很长' * 10);
      // 只有 a 被激活过。
      await db.addEvidence('doc', id1, 'activated');

      final summarized = <String>[];
      final s = MemorySummarizer(
        db: db,
        summarizeFn: (title, content) async {
          summarized.add(title);
          return '摘要$title';
        },
      );
      final count = await s.summarizeActivated();
      expect(count, 1);
      expect(summarized, ['A']); // 只总结激活过的 A，B 不总结。
      final summary = await db.getSummary(id1);
      expect(summary, isNotNull);
      expect(summary!['summary'], '摘要A');
    });

    test('已有有效摘要的文档不重复总结', () async {
      final id = await db.upsertDoc(path: 'c.md', title: 'C', content: 'x' * 50);
      await db.addEvidence('doc', id, 'activated');
      final doc = await db.getDoc(id);
      final mtime = doc!['mtime'] as int;
      await db.upsertSummary(id, '已有摘要', mtime);

      var calls = 0;
      final s = MemorySummarizer(
        db: db,
        summarizeFn: (t, c) async {
          calls++;
          return '新摘要';
        },
      );
      await s.summarizeActivated();
      expect(calls, 0); // 已有有效摘要 → 不重复调用 LLM。
    });

    test('knowledge 文档不总结', () async {
      final id = await db.upsertDoc(
        path: 'knowledge://1', title: '行列式', content: '知识点内容',
        kind: 'knowledge');
      await db.addEvidence('doc', id, 'activated');
      var calls = 0;
      final s = MemorySummarizer(
        db: db,
        summarizeFn: (t, c) async {
          calls++;
          return '摘要';
        },
      );
      await s.summarizeActivated();
      expect(calls, 0);
    });

    test('摘要函数失败返回 0 且不落库', () async {
      final id = await db.upsertDoc(path: 'd.md', title: 'D', content: 'y' * 30);
      await db.addEvidence('doc', id, 'activated');
      final s = MemorySummarizer(
        db: db,
        summarizeFn: (t, c) async => null, // 模拟 LLM 失败。
      );
      final count = await s.summarizeActivated();
      expect(count, 0);
      expect(await db.getSummary(id), isNull);
    });

    test('无 summarizeFn 时安全返回 0', () async {
      final id = await db.upsertDoc(path: 'e.md', title: 'E', content: 'z' * 30);
      await db.addEvidence('doc', id, 'activated');
      final s = MemorySummarizer(db: db); // 未注入。
      expect(await s.summarizeActivated(), 0);
    });
  });
}
