import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/goal_store.dart';
import 'package:mix/services/memory_db.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;
  late GoalStore goals;

  setUpAll(() {
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_goal_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
    goals = GoalStore(db);
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('GoalStore', () {
    test('创建 + 读取目标', () async {
      final id = await goals.createGoal('掌握线性代数第二章', maxRounds: 10);
      expect(id, isNotNull);
      final g = await goals.getGoal(id!);
      expect(g, isNotNull);
      expect(g!['objective'], '掌握线性代数第二章');
      expect(g['phase'], 'active');
      expect(g['revision'], 1);
      expect(g['rounds'], 0);
    });

    test('空 objective 拒绝', () async {
      expect(await goals.createGoal('   '), isNull);
    });

    test('乐观锁：revision 不匹配拒绝更新', () async {
      final id = (await goals.createGoal('目标A'))!;
      // 正确 revision 更新成功。
      expect(await goals.setPhase(id, 1, 'paused'), isTrue);
      // 携带旧 revision（1）再更新 → 失败（当前已是 2）。
      expect(await goals.setPhase(id, 1, 'active'), isFalse);
      final g = await goals.getGoal(id);
      expect(g!['revision'], 2); // 仍停留在 2。
      expect(g['phase'], 'paused');
    });

    test('advanceRound 续跑递增', () async {
      final id = (await goals.createGoal('目标B', maxRounds: 3))!;
      expect(await goals.advanceRound(id, 1), isTrue);
      expect(await goals.advanceRound(id, 2), isTrue);
      final g = await goals.getGoal(id);
      expect(g!['rounds'], 2);
      expect(g['revision'], 3);
    });

    test('listActiveGoals 只返回 active', () async {
      final a = (await goals.createGoal('目标1'))!;
      final b = (await goals.createGoal('目标2'))!;
      await goals.setPhase(b, 1, 'done');
      final active = await goals.listActiveGoals();
      expect(active.length, 1);
      expect(active.first['id'], a);
    });

    test('deriveProgress 无证据对象返回 null', () async {
      final id = (await goals.createGoal('目标C'))!;
      expect(await goals.deriveProgress(id), isNull);
    });

    test('deriveProgress 关联证据对象 → Beta 置信度进度', () async {
      final docId = await db.upsertDoc(path: 'kp.md', title: 'K', content: 'x');
      await db.addEvidence('knowledge', docId, 'correct');
      await db.addEvidence('knowledge', docId, 'correct');
      final id = (await goals.createGoal(
        '掌握行列式',
        evidenceObj: 'knowledge:$docId',
      ))!;
      final p = await goals.deriveProgress(id);
      expect(p, isNotNull);
      // (2+1)/(2+0+2) = 0.75。
      expect(p!.$1, closeTo(0.75, 1e-9));
      expect(p.$2, 2);
    });

    test('无活跃 goal → 渲染空串', () async {
      expect(await goals.renderActiveGoalsBlock(), '');
    });

    test('活跃 goal 渲染块含目标 + 证据进度', () async {
      final docId = await db.upsertDoc(path: 'k.md', title: 'K', content: 'x');
      await db.addEvidence('knowledge', docId, 'correct');
      final id = (await goals.createGoal(
        '掌握线性代数第二章',
        maxRounds: 10,
        evidenceObj: 'knowledge:$docId',
      ))!;
      final block = await goals.renderActiveGoalsBlock();
      expect(block, contains('<active-goals>'));
      expect(block, contains('掌握线性代数第二章'));
      expect(block, contains('进度 67%')); // (1+1)/(1+0+2)=2/3。
      expect(block, contains('轮次 0/10'));
      // 完成的目标不渲染。
      await goals.setPhase(id, 1, 'done');
      expect(await goals.renderActiveGoalsBlock(), '');
    });
  });
}
