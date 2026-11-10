/// harnessd 事件模型。
///
/// 服务端 SSE 帧格式（`id: <seq>` + `data: <json>`），事件类型见 README：
/// user.message / turn.start / provider.init / text.delta / think.delta /
/// tool.start / tool.end / turn.end / error / notice
///
/// 本文件只做纯解析与类型包装，不碰网络 —— 便于单测与在任意 UI 里复用。
library;

/// 一条桥接事件。
class BridgeEvent {
  /// 会话内单调递增序号，断点续传的唯一游标。
  final int seq;

  /// 服务端毫秒时间戳。
  final int ts;

  /// 事件类型。
  final String type;

  /// 原始负载（各 type 的字段不同）。
  final Map<String, dynamic> data;

  const BridgeEvent({
    required this.seq,
    required this.ts,
    required this.type,
    required this.data,
  });

  factory BridgeEvent.fromJson(Map<String, dynamic> json) {
    final seqRaw = json['seq'];
    final tsRaw = json['ts'];
    final dataRaw = json['data'];
    return BridgeEvent(
      seq: seqRaw is int ? seqRaw : int.tryParse('$seqRaw') ?? 0,
      ts: tsRaw is int ? tsRaw : int.tryParse('$tsRaw') ?? 0,
      type: (json['type'] as String?) ?? '',
      data: dataRaw is Map<String, dynamic>
          ? dataRaw
          : (dataRaw is Map ? Map<String, dynamic>.from(dataRaw) : <String, dynamic>{}),
    );
  }

  // ── 便捷读取 ────────────────────────────────────────────────────────
  /// 流式文本增量（text.delta / think.delta）。
  String get text => (data['text'] as String?) ?? '';

  /// 工具名（tool.start / tool.end）。
  String get toolName => (data['name'] as String?) ?? '';

  /// 工具调用 id（tool.start / tool.end 配对用）。
  String get toolCallId => (data['call'] as String?) ?? '';

  /// 工具是否成功（tool.end）。
  bool get toolOk => data['ok'] == true;

  /// 结束原因（turn.end）。
  String get stopReason => (data['stop'] as String?) ?? '';

  /// 错误信息（error）。
  String get errorMessage => (data['message'] as String?) ?? '';

  /// token 用量（turn.end）。
  Map<String, dynamic>? get usage =>
      data['usage'] is Map ? Map<String, dynamic>.from(data['usage'] as Map) : null;

  @override
  String toString() => 'BridgeEvent($seq, $type, ${data.length} fields)';
}

/// 服务端会话元数据。
class BridgeSession {
  final String id;
  final String harness;
  final String cwd;
  final String model;
  final String permissionMode;
  final String status;
  final int lastSeq;
  final String title;
  final String? providerSessionId;

  const BridgeSession({
    required this.id,
    required this.harness,
    required this.cwd,
    required this.model,
    required this.permissionMode,
    required this.status,
    required this.lastSeq,
    required this.title,
    this.providerSessionId,
  });

  factory BridgeSession.fromJson(Map<String, dynamic> j) => BridgeSession(
        id: (j['id'] as String?) ?? '',
        harness: (j['harness'] as String?) ?? '',
        cwd: (j['cwd'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        permissionMode: (j['permission_mode'] as String?) ?? 'auto',
        status: (j['status'] as String?) ?? 'idle',
        lastSeq: (j['last_seq'] as int?) ?? 0,
        title: (j['title'] as String?) ?? '',
        providerSessionId: j['provider_session_id'] as String?,
      );

  bool get isRunning => status == 'running';
}

/// 投影消息（服务端读模型）。
class BridgeMessage {
  final int ord;
  final String role;
  final String text;
  final int ts;
  final Map<String, dynamic> meta;

  const BridgeMessage({
    required this.ord,
    required this.role,
    required this.text,
    required this.ts,
    this.meta = const {},
  });

  factory BridgeMessage.fromJson(Map<String, dynamic> j) => BridgeMessage(
        ord: (j['ord'] as int?) ?? 0,
        role: (j['role'] as String?) ?? '',
        text: (j['text'] as String?) ?? '',
        ts: (j['ts'] as int?) ?? 0,
        meta: j['meta'] is Map ? Map<String, dynamic>.from(j['meta'] as Map) : const {},
      );

  /// 落本地缓存用。字段与服务端投影一致，回读时能直接走 [fromJson]。
  Map<String, dynamic> toJson() => {
        'ord': ord,
        'role': role,
        'text': text,
        'ts': ts,
        'meta': meta,
      };

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isThinking => role == 'thinking';
  bool get isSystem => role == 'system';
}

/// 一次投影拉取的完整结果。
///
/// 除了消息本身，还必须带上服务端的两个水位：
/// - [appliedSeq]：投影已折叠到哪个事件。小于 [lastSeq] 说明读模型还没追平，
///   这时拿到的消息是**旧的**。
/// - [lastSeq]：会话最新事件号。客户端把它当作「已同步到哪」的权威值，
///   并据此推进本地 SSE 游标，避免重连时把历史事件再 replay 一遍。
class BridgeMessagePage {
  const BridgeMessagePage({
    required this.messages,
    required this.appliedSeq,
    required this.lastSeq,
  });

  final List<BridgeMessage> messages;
  final int appliedSeq;
  final int lastSeq;

  /// 投影落后于事件流：还需要继续消费 events 才能看到最新内容。
  bool get projectionBehind => appliedSeq < lastSeq;
}

/// 重连退避策略（借 openbot RemoteEventStream 的思路）：
/// 指数增长、有单次上限、有总时长上限；一旦成功收到事件即清零。
class BackoffPolicy {
  final Duration initial;
  final Duration max;
  final Duration totalBudget;

  const BackoffPolicy({
    this.initial = const Duration(seconds: 1),
    this.max = const Duration(seconds: 30),
    this.totalBudget = const Duration(minutes: 5),
  });

  /// 第 [attempt] 次（0 起）重连应等待多久。
  Duration delayFor(int attempt) {
    if (attempt <= 0) return initial;
    var ms = initial.inMilliseconds * (1 << (attempt > 10 ? 10 : attempt));
    if (ms > max.inMilliseconds) ms = max.inMilliseconds;
    return Duration(milliseconds: ms);
  }

  /// 累计等待是否已耗尽预算（超过就停止重连并让调用方报错）。
  bool exhausted(int attempt) {
    var total = 0;
    for (var i = 0; i < attempt; i++) {
      total += delayFor(i).inMilliseconds;
      if (total >= totalBudget.inMilliseconds) return true;
    }
    return false;
  }
}
