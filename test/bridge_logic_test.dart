// lib/bridge 纯逻辑单测：退避策略、事件解析、会话/消息模型、游标持久化。
//
// 这些不需要网络也不需要 UI，CI 的 `flutter test` 直接能跑；
// 网络路径（SSE 重连、幂等）由服务端的 test/resume-stress.mjs 覆盖。
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mix/bridge/bridge_client.dart';
import 'package:mix/bridge/bridge_config.dart';
import 'package:mix/bridge/bridge_events.dart';
import 'package:mix/bridge/bridge_session_controller.dart';
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

  group('BridgeConfig', () {
    test('没保存地址时用 harness.312233.xyz，token 仍必填', () async {
      SharedPreferences.setMockInitialValues({});
      final cfg = await BridgeConfig.load();
      expect(cfg.baseUrl, 'https://harness.312233.xyz');
      expect(cfg.isComplete, isFalse);

      SharedPreferences.setMockInitialValues({'bridge_token': 'secret'});
      final withToken = await BridgeConfig.load();
      expect(withToken.baseUrl, BridgeConfig.defaultBaseUrl);
      expect(withToken.isComplete, isTrue);
      expect(withToken.token, 'secret');
    });

    test('自定义地址去掉末尾斜杠', () async {
      SharedPreferences.setMockInitialValues({
        'bridge_base_url': 'http://127.0.0.1:8787/',
        'bridge_token': 't',
      });
      final cfg = await BridgeConfig.load();
      expect(cfg.baseUrl, 'http://127.0.0.1:8787');
    });

    test('会话 id 可保存和清除', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await BridgeConfig.loadSessionId(), isNull);
      await BridgeConfig.saveSessionId('sess_1');
      expect(await BridgeConfig.loadSessionId(), 'sess_1');
      await BridgeConfig.clearSessionId();
      expect(await BridgeConfig.loadSessionId(), isNull);
    });
  });

  group('BridgeSessionController.applyEvent', () {
    late BridgeSessionController ctl;

    setUp(() {
      ctl = BridgeSessionController(
        client: BridgeClient(
          baseUrl: 'https://harness.312233.xyz',
          token: 't',
          client: _NoNetwork(),
        ),
        sessionId: 's',
      );
    });

    tearDown(() => ctl.dispose());

    BridgeEvent ev(int seq, String type, Map<String, dynamic> data) {
      return BridgeEvent.fromJson({'seq': seq, 'type': type, 'data': data});
    }

    test('think.delta 展开思考，text.delta 收起并用正文接上', () {
      ctl.applyEvent(ev(1, 'think.delta', {'text': '想'}));
      ctl.applyEvent(ev(2, 'think.delta', {'text': '一下'}));
      expect(ctl.messages, hasLength(1));
      expect(ctl.messages.single.isThinking, isTrue);
      expect(ctl.messages.single.streaming, isTrue);
      expect(ctl.messages.single.collapsed, isFalse);
      expect(ctl.messages.single.text, '想一下');

      ctl.applyEvent(ev(3, 'text.delta', {'text': '你好'}));
      expect(ctl.messages.first.collapsed, isTrue);
      expect(ctl.messages.first.streaming, isFalse);
      expect(ctl.messages.last.isAssistant, isTrue);
      expect(ctl.messages.last.text, '你好');
      expect(ctl.messages.last.streaming, isTrue);
      expect(ctl.turnActive, isTrue);
    });

    test('tool.start / tool.end 挂在助手消息上，turn.end 结束回合', () {
      ctl.applyEvent(ev(1, 'text.delta', {'text': '看文件'}));
      ctl.applyEvent(ev(2, 'tool.start', {
        'name': 'read_file',
        'call': 'c1',
        'input': {'path': 'a.md'},
      }));
      expect(ctl.messages.single.tools.single.running, isTrue);
      expect(ctl.messages.single.tools.single.name, 'read_file');

      ctl.applyEvent(ev(3, 'tool.end', {'call': 'c1', 'name': 'read_file', 'ok': true}));
      expect(ctl.messages.single.tools.single.running, isFalse);
      expect(ctl.messages.single.tools.single.ok, isTrue);

      ctl.applyEvent(ev(4, 'turn.end', {'stop': 'end_turn'}));
      expect(ctl.messages.single.streaming, isFalse);
      expect(ctl.turnActive, isFalse);
    });
  });
}

class _NoNetwork extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw StateError('test client must not hit the network');
  }
}
