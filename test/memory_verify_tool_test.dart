import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/memory_db.dart';
import 'package:mix/tools/memory_verify_tool.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;

  setUpAll(() {
    sqfliteFfiInit();
    memoryDbFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_verify_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
    memoryVerifyDb = db;
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> decode(String json) =>
      jsonDecode(json) as Map<String, dynamic>;

  group('memory_verify', () {
    test('check 返回可靠度报告', () async {
      final id = await db.upsertDoc(path: 'a.md', title: 'A', content: 'x');
      await db.addEvidence('doc', id, 'hit');
      final res = decode(await memoryVerifyTool(
        action: 'check',
        objType: 'doc',
        objId: id,
        db: db,
      ));
      expect(res['success'], true);
      expect(res['confidence'], closeTo(2 / 3, 1e-9)); // (1+1)/(1+0+2)
      expect(res['obj_id'], id);
    });

    test('verify 写入正证据提升置信度', () async {
      final id = await db.upsertDoc(path: 'b.md', title: 'B', content: 'x');
      await db.addEvidence('doc', id, 'rejected'); // 先有负证据。
      final before = decode(await memoryVerifyTool(
        action: 'check', docId: id, db: db));
      final res = decode(await memoryVerifyTool(
        action: 'verify', docId: id, db: db));
      expect(res['success'], true);
      // verified 是正证据 → 置信度比 verify 前高。
      expect(res['confidence'],
          greaterThan(before['confidence'] as num));
    });

    test('stale 写入负证据降低置信度', () async {
      final id = await db.upsertDoc(path: 'c.md', title: 'C', content: 'x');
      await db.addEvidence('doc', id, 'hit');
      final before = decode(await memoryVerifyTool(
        action: 'check', docId: id, db: db));
      final res = decode(await memoryVerifyTool(
        action: 'stale', docId: id, db: db));
      expect(res['success'], true);
      expect(res['confidence'], lessThan(before['confidence'] as num));
    });

    test('缺参数报错', () async {
      final res = decode(await memoryVerifyTool(action: 'check', db: db));
      expect(res['error'], isNotNull);
    });

    test('未知 action 报错', () async {
      final id = await db.upsertDoc(path: 'd.md', title: 'D', content: 'x');
      final res = decode(await memoryVerifyTool(
        action: 'foo', docId: id, db: db));
      expect(res['error'], isNotNull);
    });
  });
}
