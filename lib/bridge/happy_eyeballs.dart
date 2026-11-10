/// 连接层：地址族竞争（happy eyeballs）。
///
/// 移动网络里「域名同时有 A/AAAA，但其中一族路由是黑洞」非常常见：SYN 发出去
/// 没有任何回包，只能等内核超时（Android 上约 130s）。Dart 默认按
/// `InternetAddress.lookup` 的顺序逐个连接，第一个地址黑洞就会把整次请求拖死；
/// `HttpClient.connectionTimeout` 又是**整体**超时而非逐地址超时，救不回来。
///
/// harness.312233.xyz 就是这种双栈：AAAA 正常，A 段在当前网络被黑洞，
/// 于是 App 侧直接超时，而 `curl -6` 一秒就回 401。
///
/// 做法：自己解析地址，首个先连，[stagger] 内没连上就并行连下一个，
/// 谁先握手成功算谁的，赢家交给 HttpClient（`ConnectionTask.fromSocket`），
/// 输掉的那些连上后立刻销毁，不留半开连接。
///
/// 注意：一旦设置 [HttpClient.connectionFactory]，SDK 就不再替你套 TLS
/// （它只在「没有 factory」的分支里用 `SecureSocket.startConnect`），
/// https 必须自己 [SecureSocket.secure] 升级，否则就是明文打 443 端口，
/// 服务端只会回一个 400。
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 建一个会做地址族竞争的 [http.Client]。
///
/// [onBadCertificate] 对应 [HttpClient.badCertificateCallback]：dart:io 只提供
/// setter 没有 getter，自己套 TLS 时拿不到原值，需要时由调用方显式传入。
http.Client buildHardenedHttpClient({
  Duration connectTimeout = const Duration(seconds: 8),
  Duration stagger = const Duration(milliseconds: 250),
  bool Function(X509Certificate cert, String host, int port)? onBadCertificate,
}) {
  final io = HttpClient()..connectionTimeout = connectTimeout;

  io.connectionFactory = (uri, proxyHost, proxyPort) async {
    // 走代理时不参与竞争：握手目标不是域名本身，TLS 由 SDK 在 CONNECT 之后处理。
    if (proxyHost != null && proxyPort != null) {
      return ConnectionTask.fromSocket(Socket.connect(proxyHost, proxyPort), () {});
    }

    final raw = _raceForUri(uri, stagger: stagger, budget: connectTimeout);
    if (uri.scheme != 'https') return ConnectionTask.fromSocket(raw, () {});

    final secure = raw.then(
      (s) => SecureSocket.secure(
        s,
        host: uri.host,
        context: SecurityContext.defaultContext,
        onBadCertificate: onBadCertificate == null
            ? null
            : (cert) => onBadCertificate(cert, uri.host, uri.port),
      ),
    );
    return ConnectionTask.fromSocket(secure, () {});
  };
  return IOClient(io);
}

Future<Socket> _raceForUri(
  Uri uri, {
  required Duration stagger,
  required Duration budget,
}) async {
  List<InternetAddress> addrs;
  try {
    addrs = await InternetAddress.lookup(uri.host);
  } on Object {
    addrs = const <InternetAddress>[];
  }
  if (addrs.isEmpty) {
    // 解析交给系统默认路径，错误信息保持原样。
    return Socket.connect(uri.host, uri.port);
  }
  return raceConnect(addrs, uri.port, stagger: stagger, budget: budget);
}

/// 并发尝试 [addrs]，返回最先握手成功的 Socket。
///
/// 首个地址立刻发出，之后每 [stagger] 补发一个；某个地址快速失败
/// （RST / 无路由）时不等 [stagger]，立即补下一个。
/// [budget] 到点仍未连上则抛 [SocketException]。
Future<Socket> raceConnect(
  List<InternetAddress> addrs,
  int port, {
  Duration stagger = const Duration(milliseconds: 250),
  Duration budget = const Duration(seconds: 8),
}) {
  final done = Completer<Socket>();
  var settled = false;
  var index = 0;
  Timer? next;
  Timer? guard;

  void succeed(Socket s) {
    if (settled) {
      // 迟到的赢家：销毁，别留半开连接占内核资源。
      s.destroy();
      return;
    }
    settled = true;
    next?.cancel();
    guard?.cancel();
    done.complete(s);
  }

  void pump() {
    if (settled || index >= addrs.length) return;
    final addr = addrs[index++];
    Socket.connect(addr, port).then(succeed, onError: (Object _) {
      // 该地址立刻失败（RST / 无路由），不用等 stagger，直接试下一个。
      if (!settled) pump();
    });
    if (index < addrs.length) {
      next?.cancel();
      next = Timer(stagger, pump);
    }
  }

  guard = Timer(budget, () {
    if (settled) return;
    settled = true;
    next?.cancel();
    done.completeError(const SocketException('连接超时（候选地址均无响应）'));
  });

  pump();
  return done.future;
}
