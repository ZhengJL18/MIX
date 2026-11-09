/// Anthropic Messages API 客户端 —— Claude Code 原生协议的 Dart 移植。
///
/// 与 `openai_llm.dart` 的 `OpenAiLlmClient` 同接口（[LlmClient]），差异在 wire 层：
///
/// | 维度 | OpenAI 兼容 | Anthropic Messages |
/// |---|---|---|
/// | 系统提示 | `messages` 里的 system 消息 | 顶层 `system` 参数 |
/// | 内容 | `content: String` | `content: [{type: text/tool_use/tool_result}]` |
/// | 工具定义 | `parameters` | `input_schema` |
/// | 工具调用 | `tool_calls[].function.arguments`（JSON 串） | `tool_use` block `input`（对象） |
/// | 工具结果 | `role: tool` 消息 | user 消息里的 `tool_result` block |
/// | 停止原因 | `finish_reason` | `stop_reason`（end_turn/tool_use/max_tokens） |
/// | 输出上限 | 可选 | **必填** `max_tokens` |
/// | 缓存 | 服务端自动 | 显式 `cache_control: {type: ephemeral}` |
///
/// 流式事件（SSE）与 OpenAI 的 `choices[].delta` 完全不同，按
/// `content_block_start` / `content_block_delta` / `content_block_stop` 聚合：
/// 文本走 `text_delta`，思考走 `thinking_delta`，工具入参走
/// `input_json_delta.partial_json` 增量拼接。
///
/// 消息与 schema 的搬运全部交给 `anthropic_wire.dart`，本类只负责 HTTP + SSE。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'anthropic_wire.dart';
import 'llm_client.dart';
import 'openai_llm.dart';

/// Anthropic 客户端配置。
class AnthropicConfig {
  /// 端点：接受 `https://api.anthropic.com`、`.../v1`、`.../v1/messages`
  /// 三种写法，内部统一规范化（兼容自建网关 / 中转站）。
  final String baseUrl;
  final String apiKey;
  final String model;

  /// 必填输出上限。Anthropic 拒绝不带 max_tokens 的请求。
  final int maxTokens;

  /// 额外 beta 头（如 `prompt-caching-2024-07-31`、`interleaved-thinking-2025-05-14`）。
  final List<String> betas;

  /// 是否给 system / tools 打 prompt caching 标记。
  final bool promptCaching;

  /// 思考强度（MIX effort 键：minimal/low/medium/high/max）。null = 不发 thinking。
  final String? reasoningEffort;

  const AnthropicConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.maxTokens = 8192,
    this.betas = const [
      'prompt-caching-2024-07-31',
      'interleaved-thinking-2025-05-14',
    ],
    this.promptCaching = true,
    this.reasoningEffort,
  });

  /// 规范化后的 Messages 端点。
  String get messagesEndpoint {
    var u = baseUrl.trim();
    if (u.isEmpty) return 'https://api.anthropic.com/v1/messages';
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    if (u.endsWith('/messages')) return u;
    if (u.endsWith('/v1')) return '$u/messages';
    return '$u/v1/messages';
  }
}

/// Anthropic Messages 客户端（流式 + 非流式）。
class AnthropicLlmClient implements LlmClient {
  final AnthropicConfig config;
  final http.Client _client;

  AnthropicLlmClient({required this.config, http.Client? client})
      : _client = client ?? http.Client();

  @override
  Future<LlmTurnResult> chatStream({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? isCancelled,
    int? maxTokens,
    void Function(String delta)? onReasoning,
    String? reasoningEffort,
  }) async {
    final body = _buildBody(
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
      reasoningEffort: reasoningEffort ?? config.reasoningEffort,
    );

    final request = http.Request('POST', Uri.parse(config.messagesEndpoint))
      ..headers.addAll(_headers())
      ..body = jsonEncode(body);

    http.StreamedResponse response;
    try {
      response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw LlmException('Anthropic network error: $e');
    }
    if (response.statusCode != 200) {
      final errBody = await response.stream.bytesToString();
      throw LlmException(
        'Anthropic request failed: ${response.statusCode} $errBody',
        statusCode: response.statusCode,
        body: errBody,
      );
    }

    try {
      return await _parseSse(
        response,
        onDelta: onDelta,
        onReasoning: onReasoning,
        isCancelled: isCancelled,
      );
    } catch (e) {
      if (e is LlmException) rethrow;
      throw LlmException('Anthropic stream error: $e');
    }
  }

  /// 非流式（流式失败兜底 / 一次性摘要场景）。
  Future<LlmTurnResult> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int? maxTokens,
    String? reasoningEffort,
  }) async {
    final body = _buildBody(
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
      reasoningEffort: reasoningEffort ?? config.reasoningEffort,
    )..['stream'] = false;

    final request = http.Request('POST', Uri.parse(config.messagesEndpoint))
      ..headers.addAll(_headers()..remove('Accept'))
      ..body = jsonEncode(body);

    http.StreamedResponse response;
    try {
      response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw LlmException('Anthropic network error: $e');
    }
    final raw = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw LlmException(
        'Anthropic request failed: ${response.statusCode} $raw',
        statusCode: response.statusCode,
        body: raw,
      );
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      throw LlmException('Anthropic response parse error: $e', body: raw);
    }
    return _fromMessage(json);
  }

  // ── request 构造 ────────────────────────────────────────────────────────

  Map<String, String> _headers() {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      'anthropic-version': '2023-06-01',
    };
    if (config.apiKey.isNotEmpty) h['x-api-key'] = config.apiKey;
    if (config.betas.isNotEmpty) h['anthropic-beta'] = config.betas.join(',');
    return h;
  }

  Map<String, dynamic> _buildBody({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int? maxTokens,
    String? reasoningEffort,
  }) {
    final payload = buildAnthropicMessages(
      messages,
      cacheSystem: config.promptCaching,
    );
    final anthropicTools = toAnthropicTools(
      tools,
      cacheLast: config.promptCaching,
    );

    final thinkingBudget = _thinkingBudget(reasoningEffort);
    // thinking 启用时 max_tokens 必须大于 budget_tokens。
    var maxOut = maxTokens ?? config.maxTokens;
    if (thinkingBudget > 0 && maxOut <= thinkingBudget) {
      maxOut = thinkingBudget + 4096;
    }

    return <String, dynamic>{
      'model': config.model,
      'max_tokens': maxOut,
      'stream': true,
      if (payload.system.isNotEmpty)
        'system': systemBlocks(
          payload.system,
          cache: config.promptCaching && payload.cacheSystem,
        ),
      'messages': payload.messages,
      if (anthropicTools.isNotEmpty) 'tools': anthropicTools,
      if (thinkingBudget > 0)
        'thinking': {'type': 'enabled', 'budget_tokens': thinkingBudget},
    };
  }

  /// effort 键 → thinking budget。minimal/未设置 = 不启用思考。
  int _thinkingBudget(String? effort) {
    switch (effort) {
      case 'low':
        return 2048;
      case 'medium':
        return 4096;
      case 'high':
        return 8192;
      case 'max':
        return 16384;
      default:
        return 0;
    }
  }

  // ── SSE 聚合 ────────────────────────────────────────────────────────────

  Future<LlmTurnResult> _parseSse(
    http.StreamedResponse response, {
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
    bool Function()? isCancelled,
  }) async {
    final textBuf = StringBuffer();
    final thinkingBuf = StringBuffer();
    // index -> {type, id, name, json}
    final blocks = <int, Map<String, dynamic>>{};
    String stopReason = 'end_turn';
    String? usageJson;

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (isCancelled != null && isCancelled()) break;
      if (line.isEmpty) continue;
      if (!line.startsWith('data:')) continue; // 忽略 event: / comment 行
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;

      Map<String, dynamic> ev;
      try {
        ev = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue; // 半截帧 / keep-alive：跳过而不是中断整条流
      }

      final type = ev['type'] as String? ?? '';
      switch (type) {
        case 'message_start':
          final msg = ev['message'];
          if (msg is Map && msg['usage'] is Map) {
            usageJson = jsonEncode(msg['usage']);
          }
          break;

        case 'content_block_start':
          final idx = (ev['index'] as num?)?.toInt() ?? 0;
          final cb = ev['content_block'];
          if (cb is Map<String, dynamic>) {
            blocks[idx] = {
              'type': cb['type'],
              'id': cb['id'],
              'name': cb['name'],
              'json': StringBuffer(),
            };
            // 非流式工具块可能直接带完整 input。
            final input = cb['input'];
            if (input is Map && input.isNotEmpty) {
              blocks[idx]!['json'] = StringBuffer(jsonEncode(input));
            }
            final initialText = cb['text'];
            if (initialText is String && initialText.isNotEmpty) {
              textBuf.write(initialText);
              onDelta?.call(initialText);
            }
          }
          break;

        case 'content_block_delta':
          final idx = (ev['index'] as num?)?.toInt() ?? 0;
          final delta = ev['delta'];
          if (delta is! Map) break;
          final dt = delta['type'] as String? ?? '';
          if (dt == 'text_delta') {
            final t = delta['text'] as String? ?? '';
            if (t.isNotEmpty) {
              textBuf.write(t);
              onDelta?.call(t);
            }
          } else if (dt == 'thinking_delta') {
            final t = delta['thinking'] as String? ?? '';
            if (t.isNotEmpty) {
              thinkingBuf.write(t);
              onReasoning?.call(t);
            }
          } else if (dt == 'input_json_delta') {
            final part = delta['partial_json'] as String? ?? '';
            if (part.isNotEmpty) {
              final slot = blocks.putIfAbsent(
                idx,
                () => {'type': 'tool_use', 'json': StringBuffer()},
              );
              (slot['json'] as StringBuffer).write(part);
            }
          }
          break;

        case 'message_delta':
          final d = ev['delta'];
          if (d is Map && d['stop_reason'] != null) {
            stopReason = d['stop_reason'] as String? ?? stopReason;
          }
          if (ev['usage'] is Map) {
            usageJson = jsonEncode(ev['usage']);
          }
          break;

        case 'error':
          final err = ev['error'];
          final msg = err is Map ? (err['message'] ?? err['type']) : err;
          throw LlmException('Anthropic stream error: $msg');

        default:
          break; // ping / content_block_stop / message_stop
      }
    }

    final toolCalls = <ToolCallData>[];
    final indices = blocks.keys.toList()..sort();
    for (final i in indices) {
      final b = blocks[i]!;
      if (b['type'] != 'tool_use') continue;
      final raw = (b['json'] as StringBuffer).toString();
      toolCalls.add(ToolCallData(
        id: (b['id'] as String?) ?? 'toolu_$i',
        name: (b['name'] as String?) ?? '',
        arguments: raw.isEmpty ? '{}' : raw,
      ));
    }

    final text = textBuf.toString();
    return LlmTurnResult(
      content: text.isEmpty ? null : text,
      toolCalls: toolCalls,
      finishReason: _mapStopReason(stopReason, hasTools: toolCalls.isNotEmpty),
      usageJson: usageJson,
    );
  }

  /// 非流式响应体 → 聚合结果。
  LlmTurnResult _fromMessage(Map<String, dynamic> json) {
    final buf = StringBuffer();
    final toolCalls = <ToolCallData>[];
    final content = json['content'];
    if (content is List) {
      var i = 0;
      for (final b in content) {
        if (b is! Map) continue;
        if (b['type'] == 'text') {
          buf.write((b['text'] as String?) ?? '');
        } else if (b['type'] == 'tool_use') {
          toolCalls.add(ToolCallData(
            id: (b['id'] as String?) ?? 'toolu_$i',
            name: (b['name'] as String?) ?? '',
            arguments: jsonEncode(b['input'] ?? const {}),
          ));
        }
        i++;
      }
    }
    final text = buf.toString();
    final usage = json['usage'];
    return LlmTurnResult(
      content: text.isEmpty ? null : text,
      toolCalls: toolCalls,
      finishReason: _mapStopReason(
        (json['stop_reason'] as String?) ?? 'end_turn',
        hasTools: toolCalls.isNotEmpty,
      ),
      usageJson: usage is Map ? jsonEncode(usage) : null,
    );
  }

  /// Anthropic stop_reason → OpenAI finish_reason（上层按后者判断）。
  String _mapStopReason(String r, {required bool hasTools}) {
    switch (r) {
      case 'tool_use':
        return 'tool_calls';
      case 'max_tokens':
        return 'length';
      case 'stop_sequence':
      case 'end_turn':
        return hasTools ? 'tool_calls' : 'stop';
      default:
        return r;
    }
  }
}
