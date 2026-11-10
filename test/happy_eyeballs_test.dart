// 地址族竞速（happy eyeballs）的真 Socket 验证：不用 mock，直接连本地监听。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/bridge/happy_eyeballs.dart';

void main() {
  late ServerSocket server;

  setUp(() async {
    // 只绑 127.0.0.1：同端口的 127.0.0.2 不会被接受，可稳定造出「第一个被拒」。
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => s.destroy());
  });

  tearDown(() async {
    await server.close();
  });

  Future<Socket> connect(List<InternetAddress> addrs, {Duration? budget}) =>
      raceConnect(
        addrs,
        server.port,
        stagger: const Duration(milliseconds: 150),
        budget: budget ?? const Duration(seconds: 3),
      );

  test('第一个地址立刻被拒时，不等 stagger 直接补下一个', () async {
    final sw = Stopwatch()..start();
    final s = await raceConnect(
      [InternetAddress('127.0.0.2'), InternetAddress.loopbackIPv4],
      server.port,
      stagger: const Duration(seconds: 5), // 故意拉长：若靠 stagger 就会先撞预算
      budget: const Duration(seconds: 3),
    );
    sw.stop();
    expect(s.remoteAddress.address, '127.0.0.1');
    expect(sw.elapsedMilliseconds, lessThan(2000));
    s.destroy();
  });

  test('首个地址黑洞时，第二个地址在 stagger 后被拉起来并胜出', () async {
    // 198.51.100.0/24 是 RFC 5737 的 TEST-NET-2，公网不可路由，SYN 只会被丢掉。
    final s = await connect([InternetAddress('198.51.100.1'), InternetAddress.loopbackIPv4]);
    expect(s.remoteAddress.address, '127.0.0.1');
    s.destroy();
  });

  test('全部候选都无响应时按预算失败，而不是无限等', () async {
    final sw = Stopwatch()..start();
    await expectLater(
      connect([InternetAddress('198.51.100.1')], budget: const Duration(milliseconds: 600)),
      throwsA(isA<SocketException>()),
    );
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(2500));
  });

  test('只有一个好地址时直接连上，不额外耗 stagger', () async {
    final sw = Stopwatch()..start();
    final s = await connect([InternetAddress.loopbackIPv4]);
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(150));
    s.destroy();
  });
}
