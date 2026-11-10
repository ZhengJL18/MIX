// 本地缓存的语义测试：**服务端覆盖，不合并**。
//
// 用 sqflite_common_ffi 在主机上跑真 SQLite，不 mock —— 这里要验证的正是
// SQL（事务、排序、主键冲突）本身的行为，mock 掉了就什么都没测。

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/bridge/bridge_cache.dart';
import 'package:mix/bridge/bridge_events.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

BridgeMessage _msg(int ord, String role, String text, {Map<String, dynamic> meta = const {}}) =>
    BridgeMessage(ord: ord, role: role, text: text, ts: 1000 + ord, meta: meta);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    // 每个用例一个全新的内存库。
    BridgeCache.usePathForTest(inMemoryDatabasePath);
  });

  tearDown(() async {
    await BridgeCache.close();
  });

  test('没有缓存时返回 null（区别于空会话）', () async {
    expect(await BridgeCache.load('s1'), isNull);
  });

  test('写入后可读回，消息与水位都保留', () async {
    await BridgeCache.replaceAll(
      's1',
      [_msg(1, 'user', '你好'), _msg(2, 'assistant', '在')],
      lastSeq: 42,
      appliedSeq: 42,
    );

    final c = await BridgeCache.load('s1');
    expect(c, isNotNull);
    expect(c!.messages.length, 2);
    expect(c.messages.first.role, 'user');
    expect(c.messages.first.text, '你好');
    expect(c.messages.last.text, '在');
    expect(c.lastSeq, 42);
    expect(c.appliedSeq, 42);
    expect(c.syncedAt, greaterThan(0));
  });

  test('第二次写入是覆盖而不是合并（服务端是金标准）', () async {
    await BridgeCache.replaceAll(
      's1',
      [_msg(1, 'user', '旧'), _msg(2, 'assistant', '旧回复')],
      lastSeq: 10,
      appliedSeq: 10,
    );
    // 服务端改写/删除了历史：本地必须跟着变，不能残留旧行。
    await BridgeCache.replaceAll(
      's1',
      [_msg(1, 'user', '新')],
      lastSeq: 20,
      appliedSeq: 20,
    );

    final c = await BridgeCache.load('s1');
    expect(c!.messages.length, 1);
    expect(c.messages.single.text, '新');
    expect(c.lastSeq, 20);
  });

  test('ord 缺失（本地乐观消息）时按顺序补，不撞主键', () async {
    await BridgeCache.replaceAll(
      's1',
      [_msg(0, 'user', 'a'), _msg(0, 'user', 'b'), _msg(0, 'user', 'c')],
      lastSeq: 0,
      appliedSeq: 0,
    );

    final c = await BridgeCache.load('s1');
    expect(c!.messages.map((m) => m.text).toList(), ['a', 'b', 'c']);
    expect(c.messages.map((m) => m.ord).toList(), [1, 2, 3]);
  });

  test('长会话只取最新 limit 条，且翻回正序', () async {
    await BridgeCache.replaceAll(
      's1',
      [for (var i = 1; i <= 50; i++) _msg(i, 'user', 'm$i')],
      lastSeq: 50,
      appliedSeq: 50,
    );

    final c = await BridgeCache.load('s1', limit: 10);
    expect(c!.messages.length, 10);
    expect(c.messages.first.text, 'm41');
    expect(c.messages.last.text, 'm50');
  });

  test('meta 里的工具与错误能原样往返', () async {
    await BridgeCache.replaceAll(
      's1',
      [
        _msg(1, 'assistant', '跑了两个工具', meta: {
          'tools': [
            {'call': 'c1', 'name': 'read_file', 'ok': true},
            {'call': 'c2', 'name': 'bash', 'ok': false},
          ],
        }),
        _msg(2, 'system', '出错：boom', meta: {'error': 'boom'}),
      ],
      lastSeq: 5,
      appliedSeq: 5,
    );

    final c = await BridgeCache.load('s1');
    final tools = c!.messages.first.meta['tools'] as List;
    expect(tools.length, 2);
    expect((tools[0] as Map)['name'], 'read_file');
    expect((tools[1] as Map)['ok'], false);
    expect(c.messages.last.meta['error'], 'boom');
  });

  test('会话之间互不影响', () async {
    await BridgeCache.replaceAll('s1', [_msg(1, 'user', 'A')], lastSeq: 1, appliedSeq: 1);
    await BridgeCache.replaceAll('s2', [_msg(1, 'user', 'B')], lastSeq: 9, appliedSeq: 9);

    expect((await BridgeCache.load('s1'))!.messages.single.text, 'A');
    expect((await BridgeCache.load('s2'))!.messages.single.text, 'B');
    expect((await BridgeCache.load('s2'))!.lastSeq, 9);
  });

  test('clear 后回到无缓存状态', () async {
    await BridgeCache.replaceAll('s1', [_msg(1, 'user', 'A')], lastSeq: 1, appliedSeq: 1);
    await BridgeCache.clear('s1');
    expect(await BridgeCache.load('s1'), isNull);
  });

  test('pruneOrphans 只清理服务端已不存在的会话', () async {
    await BridgeCache.replaceAll('alive', [_msg(1, 'user', 'A')], lastSeq: 1, appliedSeq: 1);
    await BridgeCache.replaceAll('dead', [_msg(1, 'user', 'B')], lastSeq: 1, appliedSeq: 1);

    final removed = await BridgeCache.pruneOrphans({'alive'});
    expect(removed, 1);
    expect(await BridgeCache.load('alive'), isNotNull);
    expect(await BridgeCache.load('dead'), isNull);
  });

  test('touchSync 能在没有消息时先建水位行', () async {
    await BridgeCache.touchSync('s9', lastSeq: 7, appliedSeq: 3);
    final c = await BridgeCache.load('s9');
    expect(c, isNotNull);
    expect(c!.messages, isEmpty);
    expect(c.lastSeq, 7);
    expect(c.appliedSeq, 3);
  });
}
