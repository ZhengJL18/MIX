import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/db/session_db.dart';
import 'package:mix/services/memory_db.dart';
import 'package:mix/services/memory_learning.dart';
import 'package:mix/services/study_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;
  late StudyEngine engine;
  late MemoryLearning learning;

  setUpAll(() {
    sqfliteFfiInit();
    sessionDbFactory = databaseFactoryFfi;
    memoryDbFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_learning_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
    engine = StudyEngine(dbPath: '${tmp.path}/study.db');
    await engine.init();
    learning = MemoryLearning(db: db, studyEngine: engine);
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<int> makeKp(String name) async {
    final sid = await engine.ensureSubject('测试科目');
    return engine.ensureKnowledgePoint(sid, name);
  }

  group('deriveStates', () {
    test('无证据 → unknown', () async {
      await makeKp('行列式');
      final states = await learning.deriveStates();
      expect(states.length, 1);
      expect(states.first.status, 'unknown');
      expect(states.first.mastery, closeTo(0.5, 1e-9));
      expect(states.first.evidenceCount, 0);
    });

    test('correct 主导 → mastered/learning', () async {
      final kpId = await makeKp('矩阵');
      for (var i = 0; i < 4; i++) {
        await db.addEvidence('knowledge', kpId, 'correct');
      }
      final states = await learning.deriveStates();
      final s = states.firstWhere((s) => s.kpId == kpId);
      // (4+1)/(4+0+2) = 5/6 ≈ 0.83 ≥ 0.7，且新鲜 → mastered。
      expect(s.status, 'mastered');
      expect(s.mastery, closeTo(5 / 6, 1e-9));
    });

    test('wrong 主导 → weak', () async {
      final kpId = await makeKp('概率');
      for (var i = 0; i < 3; i++) {
        await db.addEvidence('knowledge', kpId, 'wrong');
      }
      final states = await learning.deriveStates();
      final s = states.firstWhere((s) => s.kpId == kpId);
      expect(s.status, 'weak');
    });

    test('曾经掌握但长期未激活 → review_due', () async {
      final kpId = await makeKp('微积分');
      await db.addEvidence('knowledge', kpId, 'correct');
      await db.addEvidence('knowledge', kpId, 'correct');
      // 证据老化（20 天前）。
      await db.db.rawUpdate(
        'UPDATE memory_evidence SET ts = ts - ?1 WHERE obj_id = ?2',
        [20 * 24 * 3600.0, kpId],
      );
      final states = await learning.deriveStates();
      final s = states.firstWhere((s) => s.kpId == kpId);
      // 置信度高但遗忘到期。
      expect(s.status, 'review_due');
      expect(s.ageSeconds, greaterThan(kReviewDueSeconds));
    });
  });

  group('reviewDue', () {
    test('只推荐 weak/review_due，weak 优先', () async {
      final weakKp = await makeKp('薄弱点');
      await db.addEvidence('knowledge', weakKp, 'wrong');
      final dueKp = await makeKp('到期点');
      await db.addEvidence('knowledge', dueKp, 'correct');
      await db.db.rawUpdate(
        'UPDATE memory_evidence SET ts = ts - ?1 WHERE obj_id = ?2',
        [10 * 24 * 3600.0, dueKp],
      );
      final normalKp = await makeKp('正常点');
      await db.addEvidence('knowledge', normalKp, 'correct');
      final due = await learning.reviewDue();
      expect(due.length, 2);
      expect(due.first.kpId, weakKp); // weak 优先于 review_due。
      final ids = due.map((s) => s.kpId).toSet();
      expect(ids, containsAll([weakKp, dueKp]));
    });
  });

  group('retrievabilityOf', () {
    test('新鲜高命中 → 高可提取性，老化衰减', () {
      final fresh = retrievabilityOf(1.0, 3600);
      final old = retrievabilityOf(1.0, 30 * 24 * 3600.0);
      expect(fresh, greaterThan(0.9));
      expect(old, lessThan(0.2));
    });
  });
}
