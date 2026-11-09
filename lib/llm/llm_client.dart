/// LLM 客户端协议接口。
///
/// 底座从「只认 OpenAI 兼容 chat.completions」换成「按 transport 可替换」：
/// - [OpenAiLlmClient]（openai_llm.dart）：OpenAI 兼容 chat.completions
/// - [AnthropicLlmClient]（anthropic_llm.dart）：Anthropic Messages API
///   （Claude Code 的原生协议：content blocks / tool_use / prompt caching）
///
/// [MIXAgent] 只依赖本接口，因此上层 agent 循环、会话落库、上下文压缩、
/// UI 流式回调全部不需要感知具体 wire 协议 —— 换底座 = 换一个实现类。
///
/// 消息与工具 schema 在两种协议间由 `anthropic_wire.dart` 双向转换，
/// 内部统一维护 OpenAI 风格历史（现有 session DB / 压缩器 / 记忆都基于它）。
library;

import 'openai_llm.dart';

/// 一次流式对话调用协议。[LlmTurnResult] / [ToolCallData] 见 openai_llm.dart
/// （跨协议共享的中性聚合结构）。
abstract class LlmClient {
  /// 发起一次流式请求，返回聚合后的 turn 结果。
  ///
  /// [messages] 统一为 OpenAI 风格消息列表（system/user/assistant/tool），
  /// 具体实现负责转成自家 wire 格式。
  /// [tools] 统一为 OpenAI function 格式的定义（name/description/parameters），
  /// 具体实现负责转成自家 schema（Anthropic 为 input_schema）。
  Future<LlmTurnResult> chatStream({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? isCancelled,
    int? maxTokens,
    void Function(String delta)? onReasoning,
    String? reasoningEffort,
  });

  /// 非流式一次性调用（摘要、判分等内部任务用）。
  Future<LlmTurnResult> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int? maxTokens,
    String? reasoningEffort,
  });
}
