import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/memory_confidence.dart';
import 'package:mix/services/memory_db.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;
  late MemoryConfidence confidence;

  setUpAll(() {
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_conf_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
    confidence = MemoryConfidence(db);
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ConfidenceScore', () {
    test('无证据 → 置信度 0.5（保守），允许注入', () async {
      final id = await db.upsertDoc(path: 'a.md', title: 'A', content: 'x');
      final cs = await confidence.score('doc', id);
      expect(cs.confidence, closeTo(0.5, 1e-9)); // (0+1)/(0+0+2)
      expect(cs.positive, 0);
      expect(cs.negative, 0);
      expect(confidence.shouldInject(cs), isTrue); // 新记忆给机会
    });

    test('正证据提升置信度，负证据压制', () async {
      final id = await db.upsertDoc(path: 'b.md', title: 'B', content: 'x');
      await db.addEvidence('doc', id, 'hit');
      await db.addEvidence('doc', id, 'adopted');
      final cs = await confidence.score('doc', id);
      expect(cs.confidence, closeTo(3 / 4, 1e-9)); // (2+1)/(2+0+2)
      expect(cs.reliability, greaterThan(0.2));

      // 负证据压制 → 低于门控。
      await db.addEvidence('doc', id, 'rejected');
      await db.addEvidence('doc', id, 'stale');
      final cs2 = await confidence.score('doc', id);
      expect(cs2.confidence, closeTo(3 / 6, 1e-9)); // (2+1)/(4+2)
      expect(cs2.reliability, lessThan(cs.reliability));
    });

    test('大量负证据 → shouldInject 拒绝（宁可缺不可杂）', () async {
      final id = await db.upsertDoc(path: 'c.md', title: 'C', content: 'x');
      for (var i = 0; i < 6; i++) {
        await db.addEvidence('doc', id, 'rejected');
      }
      final cs = await confidence.score('doc', id);
      expect(cs.confidence, closeTo(1 / 8, 1e-9)); // (0+1)/(6+2)
      expect(confidence.shouldInject(cs), isFalse);
    });

    test('时间衰减：新鲜度随证据老化下降', () async {
      final id = await db.upsertDoc(path: 'd.md', title: 'D', content: 'x');
      await db.addEvidence('doc', id, 'hit');
      // 直接改 ts 模拟老化（1 年前）。
      db.db.execute(
        'UPDATE memory_evidence SET ts = ts - ?1 WHERE obj_id = ?2',
        [365 * 24 * 3600.0, id],
      );
      final cs = await confidence.score('doc', id, tauSeconds: 90 * 24 * 3600.0);
      expect(cs.ageSeconds, greaterThan(300 * 24 * 3600.0));
      expect(cs.freshness, lessThan(0.05)); // exp(-365/90) ≈ 0.017
    });
  });
}
