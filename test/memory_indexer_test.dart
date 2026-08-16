import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/db/session_db.dart';
import 'package:mix/services/chinese_segmenter.dart';
import 'package:mix/services/memory_db.dart';
import 'package:mix/services/memory_indexer.dart';
import 'package:mix/services/memory_tagger.dart';
import 'package:mix/services/study_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sessionDbFactory = databaseFactoryFfi;
  memoryDbFactory = databaseFactoryFfi;

  final tmp = Directory.systemTemp.createTempSync('mix_indexer_test_');
  final segReady = await initChineseSegmenter(tmp.path);
  final ready = segReady;

  late MemoryDB mdb;
  late StudyEngine engine;
  late MemoryIndexer indexer;

  setUp(() async {
    mdb = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await mdb.init();
    engine = StudyEngine(dbPath: '${tmp.path}/study.db');
    await engine.init();
    final tagger = MemoryTagger(); // 无 idf 表：纯 TF + log 饱和。
    indexer = MemoryIndexer(db: mdb, tagger: tagger, studyEngine: engine);
  });

  tearDown(() async {
    await mdb.close();
  });

  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('indexEntry', () {
    test('写入文档并生成自动标签', () async {
      final id = await indexer.indexEntry(
        path: 'memory/e1',
        title: '线性代数',
        content: '行列式的性质与矩阵乘法，行列式转置不变，矩阵求逆。',
      );
      expect(id, isNotNull);
      final doc = await mdb.getDoc(id!);
      expect(doc!['title'], '线性代数');
      final tags = await mdb.getTags(id);
      expect(tags, isNotEmpty);
    }, skip: !ready);

    test('同标签文档自动互连（tag 边）', () async {
      final a = await indexer.indexEntry(
        path: 'memory/a',
        title: '笔记A',
        content: '行列式计算：行列式按行展开与三角化。',
      );
      final b = await indexer.indexEntry(
        path: 'memory/b',
        title: '笔记B',
        content: '行列式与矩阵的关系，行列式为零则矩阵奇异。',
      );
      // 两篇都含"行列式"标签 → 应存在 tag 边。
      final nb = await mdb.getNeighbors(a!);
      final tagLinks = nb.where((l) => l['link_kind'] == 'tag').toList();
      expect(tagLinks, isNotEmpty);
      final hasB = tagLinks.any((l) => l['id'] == b);
      expect(hasB, isTrue);
    }, skip: !ready);

    test('知识点匹配生成 knowledge 边', () async {
      // 建一个知识点。
      final subjId = await engine.ensureSubject('线性代数');
      final kpId = await engine.ensureKnowledgePoint(subjId, '行列式');
      // 同步知识点进记忆网。
      await indexer.syncKnowledgePoints();
      // 索引包含该知识点名的文档。
      final id = await indexer.indexEntry(
        path: 'memory/c',
        title: '复习',
        content: '今天复习了行列式的性质。',
      );
      final nb = await mdb.getNeighbors(id!);
      final kpLinks = nb.where((l) => l['link_kind'] == 'knowledge').toList();
      expect(kpLinks, isNotEmpty);
    }, skip: !ready);

    test('syncKnowledgePoints 知识点成为 knowledge 文档', () async {
      final subjId = await engine.ensureSubject('概率论');
      await engine.ensureKnowledgePoint(subjId, '贝叶斯公式');
      final count = await indexer.syncKnowledgePoints();
      expect(count, greaterThanOrEqualTo(1));
      final kpDocs = await mdb.listDocs(kind: 'knowledge');
      expect(kpDocs, isNotEmpty);
    });
  });
}
