import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/memory_db.dart';
import 'package:mix/tools/memory_manager.dart';
import 'package:mix/tools/memory_tool.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;
  late MemoryManager manager;

  setUpAll(() {
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_mm_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
    final store = MemoryStore(baseDir: tmp.path);
    manager = MemoryManager(store: store, memoryDb: db);
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('isTrivialPrompt', () {
    test('寒暄/确认类被识别', () {
      expect(isTrivialPrompt('hi'), isTrue);
      expect(isTrivialPrompt('好的'), isTrue);
      expect(isTrivialPrompt('谢谢'), isTrue);
      expect(isTrivialPrompt('OK'), isTrue);
      expect(isTrivialPrompt('嗯'), isTrue);
      expect(isTrivialPrompt('😄'), isTrue);
    });

    test('实质内容不被误判', () {
      expect(isTrivialPrompt('帮我复习线性代数第二章'), isFalse);
      expect(isTrivialPrompt('为什么矩阵不可逆'), isFalse);
      expect(isTrivialPrompt('好的，那继续讲解行列式'), isFalse);
      expect(isTrivialPrompt('a' * 30), isFalse); // 长消息。
    });
  });

  group('prefetchRecall', () {
    test('寒暄消息跳过检索（不含 memory-context）', () async {
      await db.upsertDoc(
        path: 'm.md',
        title: '矩阵',
        content: '矩阵乘法的结合律',
      );
      final block = await manager.prefetchRecall('好的');
      expect(block, isNot(contains('<memory-context>')));
    });

    test('实质消息触发检索（含 memory-context）', () async {
      await db.upsertDoc(
        path: 'm.md',
        title: '矩阵',
        content: '矩阵乘法的结合律，矩阵的逆与行列式。',
      );
      // 无分词器时走 LIKE 降级——用文档子串查询保证命中。
      final block = await manager.prefetchRecall('结合律');
      expect(block, contains('<memory-context>'));
      expect(block, contains('矩阵'));
    });

    test('无命中退回纯快照', () async {
      final block = await manager.prefetchRecall('不存在的主题xyzabc');
      expect(block, isNot(contains('<memory-context>')));
    });
  });
}
