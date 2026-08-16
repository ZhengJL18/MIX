import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/memory_db.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;

  setUpAll(() {
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_memory_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('upsertDoc / getDoc', () {
    test('新增并读取文档', () async {
      final id = await db.upsertDoc(
        path: 'memory/线性代数.md',
        title: '线性代数笔记',
        content: '行列式的性质与矩阵乘法',
        kind: 'topic',
      );
      final doc = await db.getDoc(id);
      expect(doc, isNotNull);
      expect(doc!['title'], '线性代数笔记');
      expect(doc['kind'], 'topic');
    });

    test('同 path 更新不重复插入', () async {
      final id1 = await db.upsertDoc(path: 'a.md', title: 'A', content: 'x');
      final id2 = await db.upsertDoc(path: 'a.md', title: 'A2', content: 'y');
      expect(id1, id2);
      final doc = await db.getDoc(id1);
      expect(doc!['title'], 'A2');
      expect(doc['content'], 'y');
    });
  });

  group('searchMemories', () {
    test('LIKE 降级检索（无分词器时中文子串匹配）', () async {
      await db.upsertDoc(
        path: 'm1.md',
        title: '矩阵笔记',
        content: '矩阵乘法的结合律',
      );
      await db.upsertDoc(
        path: 'm2.md',
        title: '概率论',
        content: '贝叶斯公式',
      );
      final hits = await db.searchMemories('矩阵', limit: 10);
      expect(hits, isNotEmpty);
      expect(hits.first['title'], '矩阵笔记');
      final miss = await db.searchMemories('行列式', limit: 10);
      expect(miss, isEmpty);
    });

    test('kind 过滤', () async {
      await db.upsertDoc(path: 'a.md', title: 'A', content: 'x', kind: 'memory');
      await db.upsertDoc(path: 'b.md', title: 'B', content: 'x', kind: 'daily');
      final hits = await db.searchMemories('x', kind: 'daily', limit: 10);
      expect(hits.length, 1);
      expect(hits.first['kind'], 'daily');
    });
  });

  group('tags', () {
    test('addTag / getTags / searchByTag', () async {
      final id = await db.upsertDoc(path: 't.md', title: 'T', content: 'c');
      await db.addTag(id, '线性代数', score: 0.9);
      await db.addTag(id, '考试重点');
      final tags = await db.getTags(id);
      expect(tags, containsAll(['线性代数', '考试重点']));
      final byTag = await db.searchByTag('线性代数');
      expect(byTag.length, 1);
      expect(byTag.first['id'], id);
      // 移除。
      await db.removeTag(id, '考试重点');
      final tags2 = await db.getTags(id);
      expect(tags2, ['线性代数']);
    });
  });

  group('links', () {
    test('addLink / getNeighbors + Hebbian 强化', () async {
      final a = await db.upsertDoc(path: 'a.md', title: 'A', content: 'c');
      final b = await db.upsertDoc(path: 'b.md', title: 'B', content: 'c');
      final c = await db.upsertDoc(path: 'c.md', title: 'C', content: 'c');
      await db.addLink(a, b, kind: 'tag');
      await db.addLink(a, c, kind: 'tag');
      await db.addLink(a, b, kind: 'tag'); // 强化 b。
      final nb = await db.getNeighbors(a);
      expect(nb.length, 2);
      expect(nb.first['id'], b); // weight 高者在前。
      expect(nb.first['link_weight'], 2.0);
      // 自环拒绝。
      await db.addLink(a, a);
      final nb2 = await db.getNeighbors(a);
      expect(nb2.length, 2);
    });
  });

  group('evidence', () {
    test('addEvidence 记录事件流', () async {
      final id = await db.upsertDoc(path: 'e.md', title: 'E', content: 'c');
      await db.addEvidence('doc', id, 'adopted');
      await db.addEvidence('doc', id, 'hit');
      final rows = await db.db.select(
        'SELECT * FROM memory_evidence WHERE obj_type = ? AND obj_id = ?',
        ['doc', id],
      );
      expect(rows.length, 2);
    });
  });

  group('summaries', () {
    test('upsertSummary / getSummary + stale 判断', () async {
      final id = await db.upsertDoc(path: 's.md', title: 'S', content: 'long');
      await db.upsertSummary(id, '摘要', 1);
      final summary = await db.getSummary(id);
      // doc mtime 是插入时刻（非 1）→ stale → null。
      expect(summary, isNull);
      final doc = await db.getDoc(id);
      final mtime = doc!['mtime'] as int;
      await db.upsertSummary(id, '摘要', mtime);
      final ok = await db.getSummary(id);
      expect(ok, isNotNull);
      expect(ok!['summary'], '摘要');
    });
  });

  group('deleteDoc', () {
    test('删除文档并清理关联', () async {
      final id = await db.upsertDoc(path: 'd.md', title: 'D', content: 'c');
      final other = await db.upsertDoc(path: 'e.md', title: 'E', content: 'c');
      await db.addTag(id, 't');
      await db.addLink(id, other, kind: 'tag');
      await db.addEvidence('doc', id, 'hit');
      await db.deleteDoc(id);
      expect(await db.getDoc(id), isNull);
      final rows = await db.db.select(
        'SELECT * FROM memory_tags WHERE doc_id = ?',
        [id],
      );
      expect(rows, isEmpty);
      final links = await db.db.select(
        'SELECT * FROM memory_links WHERE src = ? OR dst = ?',
        [id, id],
      );
      expect(links, isEmpty);
      final evs = await db.db.select(
        'SELECT * FROM memory_evidence WHERE obj_id = ?',
        [id],
      );
      expect(evs, isEmpty);
      // 其他文档不受影响。
      expect(await db.getDoc(other), isNotNull);
    });
  });

  group('spreadActivate', () {
    test('沿边扩散带出关联文档（含跨词关联）', () async {
      final seed = await db.upsertDoc(
          path: 's.md', title: '行列式', content: '行列式的性质');
      final linked = await db.upsertDoc(
          path: 'l.md', title: '矩阵', content: '矩阵乘法与求逆');
      final unrelated = await db.upsertDoc(
          path: 'u.md', title: '概率', content: '贝叶斯公式');
      // seed ↔ linked 建边（标签互连模拟）。
      await db.addLink(seed, linked, kind: 'tag');
      final spread = await db.spreadActivate([seed]);
      final ids = spread.map((s) => s['id'] as int).toSet();
      expect(ids, contains(seed)); // 种子自身。
      expect(ids, contains(linked)); // 关联文档被带出。
      expect(ids, isNot(contains(unrelated))); // 无关文档不带出。
      // 能量排序：种子 > 邻居。
      final seedEntry = spread.firstWhere((s) => s['id'] == seed);
      final linkedEntry = spread.firstWhere((s) => s['id'] == linked);
      expect(seedEntry['energy'], greaterThan(linkedEntry['energy']));
    });

    test('2 跳扩散 + 衰减', () async {
      final a = await db.upsertDoc(path: 'a.md', title: 'A', content: 'x');
      final b = await db.upsertDoc(path: 'b.md', title: 'B', content: 'x');
      final c = await db.upsertDoc(path: 'c.md', title: 'C', content: 'x');
      await db.addLink(a, b, kind: 'tag');
      await db.addLink(b, c, kind: 'tag');
      final spread = await db.spreadActivate([a], maxDepth: 2);
      final ids = spread.map((s) => s['id'] as int).toSet();
      expect(ids, containsAll([a, b, c]));
      // 能量：a > b > c（每跳 ×0.5）。
      final eA = spread.firstWhere((s) => s['id'] == a)['energy'] as num;
      final eB = spread.firstWhere((s) => s['id'] == b)['energy'] as num;
      final eC = spread.firstWhere((s) => s['id'] == c)['energy'] as num;
      expect(eA, greaterThan(eB));
      expect(eB, greaterThan(eC));
    });

    test('空种子返回空', () async {
      expect(await db.spreadActivate([]), isEmpty);
    });
  });
}
