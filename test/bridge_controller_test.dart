// BridgeSessionController 的事件→状态映射测试。
//
// 用一个假 http.BaseClient 返回真实格式的 SSE 帧，验证：
// 用户消息/助手流式文本/工具卡片/结束提示 是否正确聚合成可渲染的 bubbles。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mix/bridge/bridge_client.dart';
import 'package:mix/bridge/bridge_session_controller.dart';

/// 每次 send 都返回同一段 SSE，然后 EOF（controller 会自行重连，由 dispose 终止）。
class _FakeSseClient extends http.BaseClient {
  _FakeSseClient(this.frames);
  final List<Map<String, dynamic>> frames;
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    final buf = StringBuffer(': connected\n\n');
    for (final f in frames) {
      buf.write('id: ${f['seq']}\n');
      buf.write('data: ${jsonEncode(f)}\n\n');
    }
    return http.StreamedResponse(Stream.value(utf8.encode(buf.toString())), 200);
  }
}

Map<String, dynamic> ev(int seq, String type, [Map<String, dynamic> data = const {}]) =>
    {'seq': seq, 'ts': 1700000000000 + seq, 'type': type, 'data': data};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('事件流聚合成气泡：文本/工具/结束提示', () async {
    SharedPreferences.setMockInitialValues({});

    final fake = _FakeSseClient([
      ev(1, 'user.message', {'text': '读一下 foo.txt'}),
      ev(2, 'turn.start', {'harness': 'claude', 'model': 'x'}),
      ev(3, 'provider.init', {'provider': 'claude', 'tools': ['Read']}),
      ev(4, 'text.delta', {'text': '好的，'}),
      ev(5, 'text.delta', {'text': '我来读。'}),
      ev(6, 'tool.start', {'call': 'c1', 'name': 'read_file', 'input': {'path': 'foo.txt'}}),
      ev(7, 'tool.end', {'call': 'c1', 'ok': true, 'preview': 'contents'}),
      ev(8, 'turn.end', {
        'stop': 'end_turn',
        'usage': {'output_tokens': 12},
      }),
    ]);

    final client = BridgeClient(baseUrl: 'http://127.0.0.1:1', token: 't', client: fake);
    final ctl = BridgeSessionController(client: client, sessionId: 's_test');

    await ctl.start();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // 期望：3 个气泡 —— user / assistant（含工具卡片）/ system（结束提示）
    expect(ctl.messages.length, 3, reason: '气泡数：${ctl.messages.map((m) => m.role).toList()}');
    expect(ctl.messages[0].isUser, isTrue);
    expect(ctl.messages[0].text, '读一下 foo.txt');

    final assistant = ctl.messages[1];
    expect(assistant.isAssistant, isTrue);
    expect(assistant.text, '好的，我来读。', reason: '流式增量应拼接到同一条气泡');
    expect(assistant.tools.length, 1);
    expect(assistant.tools.first.name, 'read_file');
    expect(assistant.tools.first.running, isFalse);
    expect(assistant.tools.first.ok, isTrue);
    expect(assistant.streaming, isFalse, reason: 'turn.end 后应关闭流式态');

    final sys = ctl.messages[2];
    expect(sys.isSystem, isTrue);
    expect(sys.text.contains('12'), isTrue, reason: '结束提示带 token 数');

    // 游标应落盘到最新 seq
    expect(ctl.cursor, 8);

    ctl.dispose();
    client.close();
  });

  test('think.delta 单独成气泡，且与 assistant 分开', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = _FakeSseClient([
      ev(1, 'user.message', {'text': 'q'}),
      ev(2, 'think.delta', {'text': '先想一下'}),
      ev(3, 'text.delta', {'text': '答'}),
      ev(4, 'turn.end', {'stop': 'end_turn'}),
    ]);
    final client = BridgeClient(baseUrl: 'http://127.0.0.1:1', token: 't', client: fake);
    final ctl = BridgeSessionController(client: client, sessionId: 's_think');
    await ctl.start();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final roles = ctl.messages.map((m) => m.role).toList();
    expect(roles.contains('thinking'), isTrue, reason: 'roles=$roles');
    expect(roles.contains('assistant'), isTrue);
    // usage 为空时不应产生结束提示气泡
    expect(roles.where((r) => r == 'system').isEmpty, isTrue, reason: 'roles=$roles');

    ctl.dispose();
    client.close();
  });

  test('error 事件产生可读错误气泡并关闭流式态', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = _FakeSseClient([
      ev(1, 'user.message', {'text': 'q'}),
      ev(2, 'text.delta', {'text': '半截'}),
      ev(3, 'error', {'message': 'claude CLI 未返回 result'}),
    ]);
    final client = BridgeClient(baseUrl: 'http://127.0.0.1:1', token: 't', client: fake);
    final ctl = BridgeSessionController(client: client, sessionId: 's_err');
    await ctl.start();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final last = ctl.messages.last;
    expect(last.isSystem, isTrue);
    expect(last.text.contains('claude CLI 未返回'), isTrue);
    expect(last.error, isNotNull);
    // 出错前半截文本仍在，且不再是 streaming
    final assistant = ctl.messages.firstWhere((m) => m.isAssistant);
    expect(assistant.text, '半截');
    expect(assistant.streaming, isFalse);

    ctl.dispose();
    client.close();
  });
}
