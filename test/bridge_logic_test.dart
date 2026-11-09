// lib/bridge 纯逻辑单测：退避策略、事件解析、会话/消息模型、游标持久化。
//
// 这些不需要网络也不需要 UI，CI 的 `flutter test` 直接能跑；
// 网络路径（SSE 重连、幂等）由服务端的 test/resume-stress.mjs 覆盖。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mix/bridge/bridge_events.dart';
import 'package:mix/bridge/bridge_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackoffPolicy', () {
    const p = BackoffPolicy();

    test('指数增长且不超过单次上限', () {
      expect(p.delayFor(0), const Duration(seconds: 1));
      expect(p.delayFor(1), const Duration(seconds: 2));
      expect(p.delayFor(2), const Duration(seconds: 4));
      expect(p.delayFor(3), const Duration(seconds: 8));
      expect(p.delayFor(4), const Duration(seconds: 16));
      // 32s 超过 max(30s) → 被夹住
      expect(p.delayFor(5), const Duration(seconds: 30));
      expect(p.delayFor(50), const Duration(seconds: 30));
    });

    test('累计预算耗尽后放弃重连', () {
      // 1+2+4+8+16 = 31s，远小于 5 分钟
      expect(p.exhausted(5), isFalse);
      // 1+2+4+8+16+30*8 ≈ 271s 还不够，再两轮就过 300s
      expect(p.exhausted(13), isFalse);
      expect(p.exhausted(14), isTrue);
    });

    test('自定义参数生效', () {
      const fast = BackoffPolicy(
        initial: Duration(milliseconds: 100),
        max: Duration(seconds: 2),
        totalBudget: Duration(seconds: 5),
      );
      expect(fast.delayFor(0), const Duration(milliseconds: 100));
      expect(fast.delayFor(3), const Duration(milliseconds: 800));
      expect(fast.delayFor(10), const Duration(seconds: 2));
      expect(fast.exhausted(30), isTrue);
    });
  });

  group('BridgeEvent.fromJson', () {
    test('完整字段', () {
      final ev = BridgeEvent.fromJson({
        'seq': 7,
        'ts': 1700000000000,
        'type': 'text.delta',
        'data': {'text': '你好'},
      });
      expect(ev.seq, 7);
      expect(ev.ts, 1700000000000);
      expect(ev.type, 'text.delta');
      expect(ev.text, '你好');
    });

    test('seq 传成字符串也能解析', () {
      final ev = BridgeEvent.fromJson({'seq': '42', 'ts': '1', 'type': 'notice', 'data': {}});
      expect(ev.seq, 42);
      expect(ev.ts, 1);
    });

    test('缺 data / data 非 map 时降级为空 map', () {
      expect(BridgeEvent.fromJson({'seq': 1, 'type': 'x'}).data, isEmpty);
      final ev = BridgeEvent.fromJson({'seq': 1, 'type': 'x', 'data': 'oops'});
      expect(ev.data, isEmpty);
      expect(ev.text, '');
      expect(ev.toolName, '');
      expect(ev.errorMessage, '');
    });

    test('工具与结束事件的便捷读取', () {
      final tool = BridgeEvent.fromJson({
        'seq': 3,
        'type': 'tool.end',
        'data': {'call': 'call_1', 'name': 'read_file', 'ok': true},
      });
      expect(tool.toolCallId, 'call_1');
      expect(tool.toolName, 'read_file');
      expect(tool.toolOk, isTrue);

      final end = BridgeEvent.fromJson({
        'seq': 4,
        'type': 'turn.end',
        'data': {
          'stop': 'end_turn',
          'usage': {'output_tokens': 12},
        },
      });
      expect(end.stopReason, 'end_turn');
      expect(end.usage?['output_tokens'], 12);
    });

    test('usage 不是 map 时为 null（不抛）', () {
      final ev = BridgeEvent.fromJson({'seq': 5, 'type': 'turn.end', 'data': {'usage': 'n/a'}});
      expect(ev.usage, isNull);
    });
  });

  group('BridgeSession.fromJson', () {
    test('默认值', () {
      final s = BridgeSession.fromJson({'id': 's_1'});
      expect(s.id, 's_1');
      expect(s.harness, '');
      expect(s.permissionMode, 'auto');
      expect(s.status, 'idle');
      expect(s.lastSeq, 0);
      expect(s.providerSessionId, isNull);
      expect(s.isRunning, isFalse);
    });

    test('running 状态识别', () {
      final s = BridgeSession.fromJson({
        'id': 's_2',
        'harness': 'claude',
        'status': 'running',
        'last_seq': 99,
        'provider_session_id': 'p-1',
      });
      expect(s.isRunning, isTrue);
      expect(s.lastSeq, 99);
      expect(s.providerSessionId, 'p-1');
    });
  });

  group('BridgeMessage.fromJson', () {
    test('角色判定与 meta', () {
      final m = BridgeMessage.fromJson({
        'ord': 2,
        'role': 'assistant',
        'text': 'hi',
        'ts': 1,
        'meta': {
          'tools': [
            {'name': 'bash', 'call': 'c1', 'ok': true},
          ],
        },
      });
      expect(m.isAssistant, isTrue);
      expect(m.isUser, isFalse);
      expect(m.meta['tools'], isA<List<dynamic>>());
      expect((m.meta['tools'] as List).length, 1);
    });

    test('缺 meta 时为空 map', () {
      final m = BridgeMessage.fromJson({'ord': 1, 'role': 'user', 'text': 'x'});
      expect(m.meta, isEmpty);
      expect(m.isUser, isTrue);
    });
  });

  group('BridgeCursorStore', () {
    test('保存 → 读取 → 清空', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await BridgeCursorStore.load('s_a'), 0);
      await BridgeCursorStore.save('s_a', 42);
      expect(await BridgeCursorStore.load('s_a'), 42);
      // 不同会话互不影响
      expect(await BridgeCursorStore.load('s_b'), 0);
      await BridgeCursorStore.clear('s_a');
      expect(await BridgeCursorStore.load('s_a'), 0);
    });

    test('游标可被覆盖（重连推进）', () async {
      SharedPreferences.setMockInitialValues({});
      await BridgeCursorStore.save('s_c', 10);
      await BridgeCursorStore.save('s_c', 11);
      expect(await BridgeCursorStore.load('s_c'), 11);
    });
  });
}
