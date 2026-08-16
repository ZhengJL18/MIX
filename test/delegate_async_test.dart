import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/memory_db.dart';
import 'package:mix/tools/delegate_tool.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;

  setUpAll(() {
    sqfliteFfiInit();
    memoryDbFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_delegate_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
    delegateDb = db;
  });

  tearDown(() async {
    delegateHandler = null;
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> decode(String json) =>
      jsonDecode(json) as Map<String, dynamic>;

  group('delegate_task_async', () {
    test('handler 未注册 → 报错', () async {
      delegateHandler = null;
      final res = decode(await registry.dispatch('delegate_task_async', {
        'task': 'x',
      }));
      expect(res['error'], isNotNull);
    });

    test('派发后立即返回 delegation_id（running）', () async {
      delegateHandler = (task, toolsets, depth) async {
        await Future.delayed(const Duration(milliseconds: 50));
        return '子任务结果：$task';
      };
      final res = decode(await registry.dispatch('delegate_task_async', {
        'task': '分析这个教材',
      }));
      expect(res['success'], true);
      expect(res['delegation_id'], isNotNull);
      // 后台运行中或已完成——查状态。
      final status = decode(await registry.dispatch('delegation_status', {
        'delegation_id': res['delegation_id'],
      }));
      expect(status['delegation_id'], res['delegation_id']);
      expect(['running', 'done', 'failed'], contains(status['status']));
    });

    test('后台完成后 status=done 且含结果', () async {
      delegateHandler = (task, toolsets, depth) async {
        await Future.delayed(const Duration(milliseconds: 100));
        return '完成：$task';
      };
      final res = decode(await registry.dispatch('delegate_task_async', {
        'task': '写一段代码',
      }));
      final id = res['delegation_id'] as int;
      // 轮询等待完成（后台 fire-and-forget）。
      String? status;
      for (var i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        final s = decode(await registry.dispatch('delegation_status', {
          'delegation_id': id,
        }));
        status = s['status'] as String?;
        if (status == 'done') {
          expect(s['result'], '完成：写一段代码');
          break;
        }
      }
      expect(status, 'done');
    });

    test('失败委派 → status=failed', () async {
      delegateHandler = (task, toolsets, depth) async {
        throw Exception('子代理挂了');
      };
      final res = decode(await registry.dispatch('delegate_task_async', {
        'task': 'x',
      }));
      final id = res['delegation_id'] as int;
      String? status;
      for (var i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        final s = decode(await registry.dispatch('delegation_status', {
          'delegation_id': id,
        }));
        status = s['status'] as String?;
        if (status == 'failed') break;
      }
      expect(status, 'failed');
    });

    test('delegation_status 未找到 → 报错', () async {
      final res = decode(await registry.dispatch('delegation_status', {
        'delegation_id': 99999,
      }));
      expect(res['error'], isNotNull);
    });
  });
}
