import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/db/session_db.dart';
import 'package:mix/services/memory_db.dart';
import 'package:mix/services/memory_learning.dart';
import 'package:mix/services/memory_profile.dart';
import 'package:mix/services/study_engine.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;
  late StudyEngine engine;
  late MemoryProfileProjector projector;

  setUpAll(() {
    sessionDbFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_profile_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
    engine = StudyEngine(dbPath: '${tmp.path}/study.db');
    await engine.init();
    final learning = MemoryLearning(db: db, studyEngine: engine);
    projector = MemoryProfileProjector(learning: learning, db: db);
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('buildMarkdown', () {
    test('包含知识点统计与科目分组', () async {
      final sid = await engine.ensureSubject('线性代数');
      await engine.ensureKnowledgePoint(sid, '行列式');
      final sid2 = await engine.ensureSubject('概率论');
      await engine.ensureKnowledgePoint(sid2, '贝叶斯公式');
      final md = await projector.buildMarkdown();
      expect(md, contains('学习状态投影'));
      expect(md, contains('**知识点总数**：2'));
      expect(md, contains('## 线性代数'));
      expect(md, contains('## 概率论'));
      expect(md, contains('行列式'));
      expect(md, contains('贝叶斯公式'));
    });

    test('薄弱点进入复习推荐', () async {
      final sid = await engine.ensureSubject('科目');
      final kpId = await engine.ensureKnowledgePoint(sid, '薄弱知识点');
      await db.addEvidence('knowledge', kpId, 'wrong');
      await db.addEvidence('knowledge', kpId, 'wrong');
      final md = await projector.buildMarkdown();
      expect(md, contains('## 建议复习'));
      expect(md, contains('薄弱知识点'));
    });

    test('无知识点时仍生成框架', () async {
      final md = await projector.buildMarkdown();
      expect(md, contains('**知识点总数**：0'));
      expect(md, contains('学习状态投影'));
    });
  });

  group('saveToMemory', () {
    test('写入 kind=profile 文档，可被读取', () async {
      final sid = await engine.ensureSubject('科目');
      await engine.ensureKnowledgePoint(sid, '知识点A');
      final id = await projector.saveToMemory();
      expect(id, isNotNull);
      final doc = await db.getDoc(id!);
      expect(doc!['kind'], 'profile');
      expect(doc['title'], '学习状态投影');
      expect((doc['content'] as String), contains('知识点A'));
      // 重复生成更新同一 path。
      final id2 = await projector.saveToMemory();
      expect(id2, id);
    });
  });
}
