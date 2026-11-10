/// harnessd 客户端：REST 控制 + SSE 事件流（断点续传 / 自动重连）。
///
/// 与服务端约定：
/// - 所有请求带 `Authorization: Bearer <token>`
/// - 事件流 `GET /v1/sessions/:id/events?after=<seq>`，SSE 帧为
///   `id: <seq>` + `data: <json>`，服务端每 15s 发一条 `: hb` 注释帧
/// - `seq` 会话内单调递增，客户端只需记住 last_seq
///
/// 重连策略（借 openbot RemoteEventStream）：指数退避、单次上限 30s、
/// 总预算 5 分钟；**收到任何事件即清零**（说明链路是活的，不该继续罚）。
/// 超过 45s 完全无字节视为死链（服务端心跳都断了），主动断开重连。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bridge_events.dart';
import 'happy_eyeballs.dart';

/// 桥接层异常（网络/协议/服务端错误统一成这一类）。
class BridgeException implements Exception {
  final String message;
  final int? statusCode;

  BridgeException(this.message, {this.statusCode});

  @override
  String toString() =>
      statusCode != null ? 'BridgeException($statusCode): $message' : 'BridgeException: $message';
}

/// 与服务端的连接。
class BridgeClient {
  /// 形如 `http://127.0.0.1:8787`（经 SSH 隧道）或反代后的 https 地址。
  final String baseUrl;
  final String token;
  final http.Client _client;
  final BackoffPolicy _backoff;

  /// 超过这个时长没有任何字节（含心跳）就认为链路已死。
  final Duration idleTimeout;

  bool _disposed = false;

  BridgeClient({
    required this.baseUrl,
    required this.token,
    http.Client? client,
    BackoffPolicy backoff = const BackoffPolicy(),
    this.idleTimeout = const Duration(seconds: 45),
  })  : _client = client ?? buildHardenedHttpClient(),
        _backoff = backoff;

  /// 最近一次健康检查的失败原因（UI 用来区分「没网」「token 错」「服务没起」）。
  String? lastHealthError;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  // ── REST ──────────────────────────────────────────────────────────────

  /// 健康检查。
  ///
  /// 失败原因记到 [lastHealthError]：`catch` 里直接吞掉异常的话，UI 只能显示
  /// 一句「连不上」，用户和排查的人都拿不到线索（究竟是 DNS、连接超时、
  /// token 错还是服务没起）。
  Future<bool> health() async {
    lastHealthError = null;
    try {
      final r = await _client
          .get(_uri('/healthz'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) {
        lastHealthError = r.statusCode == 401
            ? 'token 被拒绝（401）'
            : 'HTTP ${r.statusCode}';
        return false;
      }
      final j = jsonDecode(r.body);
      final ok = j is Map && j['ok'] == true;
      if (!ok) lastHealthError = '响应不是 healthz 格式';
      return ok;
    } catch (e) {
      lastHealthError = '$e';
      return false;
    }
  }

  /// 会话列表。
  Future<List<BridgeSession>> listSessions() async {
    final r = await _client
        .get(_uri('/v1/sessions'), headers: _headers)
        .timeout(const Duration(seconds: 12));
    _ensureOk(r, 'listSessions');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final list = j['sessions'];
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map<String, dynamic>) BridgeSession.fromJson(e),
    ];
  }

  /// 新建会话。
  Future<BridgeSession> createSession({
    required String harness,
    String? cwd,
    String? model,
    String? title,
    String permissionMode = 'auto',
  }) async {
    final r = await _client
        .post(
          _uri('/v1/sessions'),
          headers: _headers,
          body: jsonEncode({
            'harness': harness,
            if (cwd != null) 'cwd': cwd,
            if (model != null) 'model': model,
            if (title != null) 'title': title,
            'permissionMode': permissionMode,
          }),
        )
        .timeout(const Duration(seconds: 12));
    _ensureOk(r, 'createSession');
    return BridgeSession.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// 取单个会话（含 last_seq / provider_session_id）。
  Future<BridgeSession> getSession(String sessionId) async {
    final r = await _client
        .get(_uri('/v1/sessions/$sessionId'), headers: _headers)
        .timeout(const Duration(seconds: 12));
    _ensureOk(r, 'getSession');
    return BridgeSession.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// 发消息。服务端立刻 202，turn 在后台跑（客户端可断开）。
  Future<void> sendMessage(String sessionId, String text) async {
    final r = await _client
        .post(
          _uri('/v1/sessions/$sessionId/messages'),
          headers: _headers,
          body: jsonEncode({'text': text}),
        )
        .timeout(const Duration(seconds: 15));
    _ensureOk(r, 'sendMessage');
  }

  /// 打断当前 turn。
  Future<void> interrupt(String sessionId) async {
    final r = await _client
        .post(_uri('/v1/sessions/$sessionId/interrupt'), headers: _headers, body: '{}')
        .timeout(const Duration(seconds: 12));
    _ensureOk(r, 'interrupt');
  }

  /// 投影消息（服务端读模型，比自行拼事件更省事）。
  ///
  /// 只取消息列表的便捷版。需要水位（判断投影是否追平、推进本地游标）时用
  /// [messagesPage]。
  Future<List<BridgeMessage>> messages(String sessionId, {int limit = 200}) async =>
      (await messagesPage(sessionId, limit: limit)).messages;

  /// 投影消息 + 服务端水位。
  ///
  /// `applied_seq < last_seq` 表示读模型还没追平，这批消息是旧的 —— 调用方
  /// 不应该把它当成「已同步」写进本地缓存。
  Future<BridgeMessagePage> messagesPage(
    String sessionId, {
    int limit = 200,
    int? before,
  }) async {
    final query = {'limit': '$limit', if (before != null) 'before': '$before'};
    final r = await _client
        .get(_uri('/v1/sessions/$sessionId/messages', query), headers: _headers)
        .timeout(const Duration(seconds: 15));
    _ensureOk(r, 'messages');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final list = j['messages'];
    final messages = <BridgeMessage>[
      if (list is List)
        for (final e in list)
          if (e is Map<String, dynamic>) BridgeMessage.fromJson(e),
    ];
    int asInt(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
    return BridgeMessagePage(
      messages: messages,
      appliedSeq: asInt(j['applied_seq']),
      lastSeq: asInt(j['last_seq']),
    );
  }

  // ── SSE 事件流 ────────────────────────────────────────────────────────

  /// 订阅事件流。**永不主动结束**（除非 [close] 或退避预算耗尽），
  /// 断线自动重连并从 [fromSeq] 之后续上。
  ///
  /// [fromSeq] 为 0 表示从头补发（服务端会分页 replay 历史，再切实时）。
  /// [onCursor] 每收到一条事件回调一次，用于把游标写进 [BridgeCursorStore]。
  Stream<BridgeEvent> stream(
    String sessionId, {
    int fromSeq = 0,
    void Function(int seq)? onCursor,
    void Function()? onConnected,
  }) async* {
    var cursor = fromSeq;
    var attempt = 0;

    while (!_disposed) {
      var receivedAny = false;
      try {
        await for (final ev in _openSse(sessionId, cursor, onConnected)) {
          if (_disposed) return;
          receivedAny = true;
          attempt = 0; // 链路活着 → 清零退避
          if (ev.seq <= cursor) continue; // 幂等：重复帧丢弃
          cursor = ev.seq;
          onCursor?.call(cursor);
          yield ev;
        }
        // 服务端关流（正常 EOF）→ 继续走下面的重连
      } catch (e) {
        if (_disposed) return;
        // 记录但不抛：下一轮重连会带上 cursor 续传
        if (!receivedAny) attempt++;
      }
      if (_disposed) return;

      if (_backoff.exhausted(attempt)) {
        throw BridgeException('事件流重连预算耗尽（${_backoff.totalBudget.inMinutes} 分钟），已放弃');
      }
      await Future<void>.delayed(_backoff.delayFor(attempt));
      if (!receivedAny) {
        // 本轮一条都没收到：继续加大退避（receivedAny=true 时 attempt 已被清零）
      } else {
        attempt = 0;
      }
    }
  }

  /// 单次 SSE 连接：从 [after] 之后补发 + 接实时。
  Stream<BridgeEvent> _openSse(
    String sessionId,
    int after,
    void Function()? onConnected,
  ) async* {
    final req = http.Request(
      'GET',
      _uri('/v1/sessions/$sessionId/events', {'after': '$after'}),
    )..headers.addAll({
        'Authorization': 'Bearer $token',
        'Accept': 'text/event-stream',
      });

    final resp = await _client.send(req).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      // 401/404 是配置问题，重连没用 —— 直接抛出终止。
      if (resp.statusCode == 401 || resp.statusCode == 404) {
        final body = await resp.stream.bytesToString();
        throw BridgeException('SSE $resp.statusCode: $body', statusCode: resp.statusCode);
      }
      throw BridgeException('SSE ${resp.statusCode}', statusCode: resp.statusCode);
    }

    // 已建立 SSE（200）：即便此刻没有任何事件，连接也是活的。
    onConnected?.call();
    final lines = resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(idleTimeout);

    await for (final line in lines) {
      if (_disposed) return;
      if (line.isEmpty || line.startsWith(':')) continue; // 心跳/注释
      if (!line.startsWith('data:')) continue; // id: / event: 行忽略（seq 在 data 里）
      final raw = line.substring(5).trim();
      if (raw.isEmpty) continue;
      Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        json = decoded;
      } catch (_) {
        continue; // 半截帧：跳过而不是断流
      }
      yield BridgeEvent.fromJson(json);
    }
  }

  void _ensureOk(http.Response r, String op) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    throw BridgeException('$op failed: ${r.statusCode} ${r.body}', statusCode: r.statusCode);
  }

  /// 关闭连接（终止所有进行中的事件流）。
  void close() {
    _disposed = true;
    try {
      _client.close();
    } catch (_) {}
  }
}
