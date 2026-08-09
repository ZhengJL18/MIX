/// OpenAI 兼容 LLM 客户端（Hermes chat_completion_helpers 流式解析核心复刻）。
///
/// 参考 `ref/hermes-agent/agent/chat_completion_helpers.py` 的
/// `interruptible_streaming_api_call` tool_calls 聚合逻辑：
/// - 按 index 聚合 tool_calls，name 用**赋值**（原子标识符，防 provider 重发拼接），
///   arguments 用 `+=` 增量拼接
/// - Ollama 兼容端点每个工具调用复用 index 0，仅靠 id 区分 —— 检测到同 index
///   新 id 时重定向到新 slot
/// - id 首次记录（Poolside 可能发 int id → 转 str）
/// - content 用 content_parts join
/// - 完成帧后按 index 排序
///
/// SSE 解析沿用 MIX `OpenAiCompatibleAiService.chatStream` 的逐行 buffer 模式。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 单次工具调用（OpenAI wire 格式聚合后）。
class ToolCallData {
  String id;
  String name;
  String arguments; // 未解析的 JSON 字符串

  ToolCallData({this.id = '', this.name = '', this.arguments = ''});

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };
}

/// 一次流式 turn 的完整结果。
class LlmTurnResult {
  final String? content; // 已聚合文本（无则 null）
  final List<ToolCallData> toolCalls;
  final String finishReason;
  final String? usageJson; // usage chunk（stream_options include_usage）

  LlmTurnResult({
    this.content,
    this.toolCalls = const [],
    this.finishReason = 'stop',
    this.usageJson,
  });

  bool get hasToolCalls => toolCalls.isNotEmpty;

  /// 转 OpenAI assistant message（用于回填对话历史）。
  Map<String, dynamic> toAssistantMessage() {
    // OpenAI 兼容 API 要求 assistant 消息必须含 content 或 tool_calls。
    // 空 turn（content=null 且无 tool_calls）会导致 "content or tool_calls
    // must be sent" 400。content 兜底为空串。
    return {
      'role': 'assistant',
      'content': content ?? '',
      if (toolCalls.isNotEmpty)
        'tool_calls': [for (final tc in toolCalls) tc.toJson()],
    };
  }
}

/// OpenAI 兼容 LLM 客户端配置。
class LlmConfig {
  final String baseUrl; // 如 https://api.deepseek.com/v1/chat/completions
  final String apiKey;
  final String model;
  /// 思考强度（'low'/'medium'/'high'）。null = 不传 reasoning_effort。
  /// 支持的后端据此调整推理深度；不支持的通常忽略未知字段。
  final String? reasoningEffort;

  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.reasoningEffort,
  });
}

/// 调用返回（工具执行后回填）。
class ToolResultMessage {
  final String toolCallId;
  final String name;
  final String content;

  ToolResultMessage({
    required this.toolCallId,
    required this.name,
    required this.content,
  });

  Map<String, dynamic> toJson() => {
        'role': 'tool',
        'tool_call_id': toolCallId,
        'content': content,
      };
}

/// OpenAI 兼容 LLM 客户端：流式 chat.completions + tool_calls 聚合。
class OpenAiLlmClient {
  final LlmConfig config;
  final http.Client _client;

  OpenAiLlmClient({
    required this.config,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// 发起一次流式 chat.completions 请求。
  ///
  /// [messages] OpenAI 格式消息列表；[tools] OpenAI 格式工具定义（可选）。
  /// 返回聚合后的 [LlmTurnResult]。流式文本逐 delta 经 [onDelta] 回调。
  ///
  /// [isCancelled] 每次收到 chunk 时检查，返回 true 则立即中断流式读取。
  /// [maxTokens] 可选输出上限（默认 null 不发 `max_tokens`，用 provider 默认）。
  /// [onReasoning] 可选：reasoning_content 逐块回调（DeepSeek 类先思考后输出）。
  /// [reasoningEffort] 可选思考强度覆盖：优先于 [LlmConfig.reasoningEffort]。
  Future<LlmTurnResult> chatStream({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? isCancelled,
    int? maxTokens,
    void Function(String delta)? onReasoning,
    String? reasoningEffort,
  }) async {
    final effort = reasoningEffort ?? config.reasoningEffort;
    final body = <String, dynamic>{
      'model': config.model,
      'stream': true,
      'messages': messages,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (effort != null) 'reasoning_effort': effort,
    };

    final request = http.Request('POST', Uri.parse(config.baseUrl))
      ..headers.addAll({
        'Content-Type': 'application/json',
        // 部分 provider/网关按此头决定是否真正逐 token 流式（缺省可能缓冲整段）。
        'Accept': 'text/event-stream',
        'Authorization': 'Bearer ${config.apiKey}',
      })
      ..body = jsonEncode(body);

    http.StreamedResponse response;
    try {
      // 建连+响应头超时（connect 15s）：鸿蒙 QoE/弱网下请求可能无限挂起。
      // 挂起比报错更糟 —— 用户看到「无回应」而非「出错了」。超时抛
      // LlmException 走 agent 重试。
      response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      // 网络错误（SocketException/ClientException/TimeoutException）统一包成
      // LlmException，让调用方（agent 主循环）能捕获并重试。
      throw LlmException('LLM network error: $e');
    }
    if (response.statusCode != 200) {
      final errBody = await response.stream.bytesToString();
      throw LlmException(
        'LLM request failed: ${response.statusCode} $errBody',
        statusCode: response.statusCode,
        body: errBody,
      );
    }

    try {
      return await _parseStreamStream(
        response,
        onDelta: onDelta,
        isCancelled: isCancelled,
        onReasoning: onReasoning,
      );
    } catch (e) {
      // 流中断/解析错误也包成 LlmException。
      if (e is LlmException) {
        rethrow;
      }
      throw LlmException('LLM stream error: $e');
    }
  }

  /// 非流式 chat.completions（流式失败的兜底，Hermes 同样提供）。
  /// [maxTokens] 可选输出上限（默认 null 不发 `max_tokens`）。
  /// [reasoningEffort] 可选思考强度覆盖：优先于 [LlmConfig.reasoningEffort]。
  Future<LlmTurnResult> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int? maxTokens,
    String? reasoningEffort,
  }) async {
    final effort = reasoningEffort ?? config.reasoningEffort;
    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (effort != null) 'reasoning_effort': effort,
    };

    final http.Response response;
    try {
      response = await _client.post(
        Uri.parse(config.baseUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.apiKey}',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw LlmException('LLM request timeout after 30s');
    }
    if (response.statusCode != 200) {
      throw LlmException(
        'LLM request failed: ${response.statusCode} ${response.body}',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final choice = (data['choices'] as List? ?? const []).isEmpty
        ? null
        : (data['choices'] as List).first as Map<String, dynamic>;
    final message = choice?['message'] as Map<String, dynamic>?;
    final content = message?['content'] as String?;
    final finish = choice?['finish_reason'] as String? ?? 'stop';

    final toolCalls = <ToolCallData>[];
    final rawCalls = message?['tool_calls'];
    if (rawCalls is List) {
      for (final raw in rawCalls) {
        if (raw is! Map<String, dynamic>) {
          continue;
        }
        final fn = raw['function'] as Map<String, dynamic>?;
        toolCalls.add(ToolCallData(
          id: raw['id'] as String? ?? '',
          name: fn?['name'] as String? ?? '',
          arguments: fn?['arguments'] as String? ?? '',
        ));
      }
    }

    return LlmTurnResult(content: content, toolCalls: toolCalls, finishReason: finish);
  }

  List<ToolCallData> _finalizeToolCalls(Map<int, Map<String, dynamic>> acc) {
    final idxs = acc.keys.toList()..sort();
    final result = <ToolCallData>[];
    for (final idx in idxs) {
      final entry = acc[idx]!;
      result.add(ToolCallData(
        id: entry['id'] as String? ?? '',
        name: (entry['function'] as Map)['name'] as String? ?? '',
        arguments: (entry['function'] as Map)['arguments'] as String? ?? '',
      ));
    }
    return result;
  }

  /// 真实 async 流式解析入口。
  Future<LlmTurnResult> _parseStreamStream(
    http.StreamedResponse response, {
    void Function(String delta)? onDelta,
    bool Function()? isCancelled,
    void Function(String delta)? onReasoning,
  }) async {
    var buffer = '';
    final contentParts = <String>[];
    final reasoningParts = <String>[];
    final toolCallsAcc = <int, Map<String, dynamic>>{};
    final lastIdAtIdx = <int, String>{};
    final activeSlotByIdx = <int, int>{};
    var finishReason = 'stop';
    // 是否收到明确的流结束标记（finish_reason 帧或 [DONE]）。连接中途干净
    // EOF（无结束标记）会被识别为中断而非成功，触发 agent 重试。
    var sawCompletion = false;
    String? usageObj;

    void handleLine(String line) {
      // 复用 processLine 逻辑（行处理）。
      _processSseLine(
        line,
        contentParts: contentParts,
        reasoningParts: reasoningParts,
        toolCallsAcc: toolCallsAcc,
        lastIdAtIdx: lastIdAtIdx,
        activeSlotByIdx: activeSlotByIdx,
        onDelta: onDelta,
        onReasoning: onReasoning,
        finishReason: (v) {
          finishReason = v;
          if (v.isNotEmpty) sawCompletion = true;
        },
        onDone: () => sawCompletion = true,
        usageObj: (v) => usageObj = v,
      );
    }

    // 流式读取空闲超时：AI 中途卡住（网络断/服务端挂起）时不会无限等待。
    // 正常流式每几秒都有 chunk，30s 空闲远超正常间隔，不会误杀。
    final timedStream = utf8.decoder
        .bind(response.stream)
        .timeout(const Duration(seconds: 30));
    // 总时长兜底（180s）：推理模型思考可能超 60s，原 60s 硬截断会把
    // 正常长思考误判为超时。
    final totalTimeout = Duration(seconds: 180);
    final totalDeadline = DateTime.now().add(totalTimeout);
    await for (final chunk in timedStream) {
      if (DateTime.now().isAfter(totalDeadline)) {
        throw LlmException('LLM stream timeout after 180s');
      }
      if (isCancelled?.call() ?? false) {
        break; // 用户中断：丢弃剩余流，返回已聚合内容。
      }
      buffer += chunk;
      while (buffer.contains('\n')) {
        final nl = buffer.indexOf('\n');
        final line = buffer.substring(0, nl);
        buffer = buffer.substring(nl + 1);
        handleLine(line);
      }
    }
    if (buffer.trim().isNotEmpty) {
      handleLine(buffer);
    }

    // 连接干净关闭但从未收到结束标记 → 视为中断，抛错让 agent 重试，
    // 否则部分截断内容会被当成功回答上屏。
    if (!sawCompletion && !(isCancelled?.call() ?? false)) {
      throw LlmException('LLM stream ended without completion marker');
    }

    return LlmTurnResult(
      content: contentParts.isEmpty ? null : contentParts.join(),
      toolCalls: _finalizeToolCalls(toolCallsAcc),
      finishReason: finishReason,
      usageJson: usageObj,
    );
  }
}

/// 单行 SSE 处理（共享给流式解析）。
void _processSseLine(
  String rawLine, {
  required List<String> contentParts,
  required List<String> reasoningParts,
  required Map<int, Map<String, dynamic>> toolCallsAcc,
  required Map<int, String> lastIdAtIdx,
  required Map<int, int> activeSlotByIdx,
  void Function(String delta)? onDelta,
  void Function(String delta)? onReasoning,
  required void Function(String) finishReason,
  required void Function(String) usageObj,
  void Function()? onDone,
}) {
  final line = rawLine.trim();
  if (line.isEmpty || !line.startsWith('data:')) {
    return;
  }
  final data = line.substring(5).trim();
  if (data == '[DONE]') {
    onDone?.call();
    return;
  }
  Map<String, dynamic> json;
  try {
    json = jsonDecode(data) as Map<String, dynamic>;
  } catch (_) {
    return;
  }
  if (json.containsKey('usage')) {
    usageObj(jsonEncode(json['usage']));
  }
  final choices = json['choices'];
  if (choices is! List || choices.isEmpty) {
    return;
  }
  final choice = choices.first as Map<String, dynamic>;
  final fr = choice['finish_reason'];
  if (fr is String && fr.isNotEmpty) {
    finishReason(fr);
  }
  final delta = choice['delta'];
  if (delta is! Map<String, dynamic>) {
    return;
  }
  final content = delta['content'];
  if (content is String && content.isNotEmpty) {
    contentParts.add(content);
    onDelta?.call(content);
  }
  final reasoning = delta['reasoning_content'];
  if (reasoning is String && reasoning.isNotEmpty) {
    reasoningParts.add(reasoning);
    onReasoning?.call(reasoning);
  }
  final rawCalls = delta['tool_calls'];
  if (rawCalls is! List) {
    return;
  }
  for (final rawCall in rawCalls) {
    if (rawCall is! Map<String, dynamic>) {
      continue;
    }
    final rawIdx = rawCall['index'] is int ? rawCall['index'] as int : 0;
    final deltaId = rawCall['id'] as String? ?? '';

    if (!activeSlotByIdx.containsKey(rawIdx)) {
      activeSlotByIdx[rawIdx] = rawIdx;
    }
    if (deltaId.isNotEmpty &&
        lastIdAtIdx.containsKey(rawIdx) &&
        deltaId != lastIdAtIdx[rawIdx]) {
      final newSlot = toolCallsAcc.isEmpty
          ? 0
          : toolCallsAcc.keys.reduce((a, b) => a > b ? a : b) + 1;
      activeSlotByIdx[rawIdx] = newSlot;
    }
    if (deltaId.isNotEmpty) {
      lastIdAtIdx[rawIdx] = deltaId;
    }
    final idx = activeSlotByIdx[rawIdx]!;

    if (!toolCallsAcc.containsKey(idx)) {
      var tcId = rawCall['id'];
      if (tcId is int) {
        tcId = tcId.toString();
      }
      toolCallsAcc[idx] = {
        'id': tcId as String? ?? '',
        'type': 'function',
        'function': {'name': '', 'arguments': ''},
        'extra_content': null,
      };
    }
    final entry = toolCallsAcc[idx]!;
    final callId = rawCall['id'];
    if (callId is int) {
      entry['id'] = callId.toString();
    } else if (callId is String && callId.isNotEmpty) {
      entry['id'] = callId;
    }
    final fn = rawCall['function'];
    if (fn is Map<String, dynamic>) {
      final name = fn['name'];
      if (name is String && name.isNotEmpty) {
        entry['function']['name'] = name;
      }
      final arguments = fn['arguments'];
      if (arguments is String && arguments.isNotEmpty) {
        entry['function']['arguments'] += arguments;
      }
    }
    final extra = rawCall['extra_content'];
    if (extra != null) {
      entry['extra_content'] = extra;
    }
  }
}

/// LLM 请求异常。
class LlmException implements Exception {
  final String message;
  final int? statusCode; // 可选：HTTP 状态码（供 error_classifier 分类）。
  final String? body; // 可选：错误响应体。

  LlmException(this.message, {this.statusCode, this.body});
  @override
  String toString() => message;
}
