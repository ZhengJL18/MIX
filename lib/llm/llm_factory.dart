/// LLM 客户端工厂：按 provider 的 transport 选 wire 协议实现。
///
/// 底座替换的接线点 —— UI / agent 层只调本文件，不直接 new 具体客户端，
/// 于是「换成 Claude Code 原生协议」= provider 的 transport 改成
/// [Transport.anthropicMessages]，无需改业务代码。
library;

import 'package:http/http.dart' as http;

import '../config/mix_config.dart';
import '../config/providers.dart';
import 'anthropic_llm.dart';
import 'llm_client.dart';
import 'openai_llm.dart';

/// 按用户配置构造客户端。
///
/// [effort] 思考强度覆盖（MIX effort 键：minimal/low/medium/high/max）。
/// [client] 可选注入 http.Client（测试用）。
LlmClient buildLlmClient({
  required MIXConfig config,
  String? effort,
  http.Client? client,
}) {
  final transport = config.transport;
  if (transport == Transport.anthropicMessages) {
    return AnthropicLlmClient(
      config: AnthropicConfig(
        baseUrl: config.effectiveBaseUrl,
        apiKey: config.apiKey,
        model: config.model,
        reasoningEffort: effort ?? config.reasoningEffort,
      ),
      client: client,
    );
  }
  final llmCfg = config.toLlmConfig(effort: effort);
  return OpenAiLlmClient(config: llmCfg, client: client);
}

/// 用已解析好的 [LlmConfig]（如快模型配置）构造，[transport] 需显式给出。
LlmClient buildLlmClientFromConfig(
  LlmConfig cfg, {
  Transport? transport,
  http.Client? client,
}) {
  if (transport == Transport.anthropicMessages) {
    return AnthropicLlmClient(
      config: AnthropicConfig(
        baseUrl: cfg.baseUrl,
        apiKey: cfg.apiKey,
        model: cfg.model,
        reasoningEffort: cfg.reasoningEffort,
      ),
      client: client,
    );
  }
  return OpenAiLlmClient(config: cfg, client: client);
}
