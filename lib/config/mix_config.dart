/// MIX 配置持久化 —— 复用 MIX `AiSettings` 的 SharedPreferences 模式。
///
/// 存储 vendor/model/key/baseUrl，经 [providers.dart] 的解析链解析成 LlmConfig。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../llm/openai_llm.dart';
import 'providers.dart';

/// 思考强度档位定义。
class EffortFlow {
  final String id;
  final String label;
  final int defaultValue; // 0-100
  const EffortFlow({
    required this.id,
    required this.label,
    required this.defaultValue,
  });
}

/// MIX 配置。
class MIXConfig {
  /// 各流程的思考强度档位（设置页滑块 0-100，可各自独立调整）。
  static const List<EffortFlow> effortFlows = [
    EffortFlow(id: 'chat', label: '聊天回答', defaultValue: 50),
    EffortFlow(id: 'plan', label: '计划生成', defaultValue: 50),
    EffortFlow(id: 'study_question', label: '出题', defaultValue: 50),
    EffortFlow(id: 'study_profile', label: '画像更新', defaultValue: 50),
    EffortFlow(id: 'refine', label: '自进化建议', defaultValue: 25),
    EffortFlow(id: 'agent', label: '多代理讨论', defaultValue: 75),
    EffortFlow(id: 'fast_agent', label: '子代理快模型', defaultValue: 25),
  ];

  /// 滑块值(0-100) → reasoning_effort 字符串。
  static String effortValueToKey(int v) {
    if (v < 20) return 'minimal';
    if (v < 40) return 'low';
    if (v < 60) return 'medium';
    if (v < 80) return 'high';
    return 'max';
  }

  /// reasoning_effort 字符串 → 滑块值（兼容旧配置）。
  static int effortKeyToValue(String k) {
    switch (k) {
      case 'minimal':
        return 0;
      case 'low':
        return 25;
      case 'high':
        return 75;
      case 'max':
        return 100;
      default:
        return 50;
    }
  }

  /// 滑块值显示名。
  static String effortValueLabel(int v) {
    if (v < 20) return '极低';
    if (v < 40) return '低';
    if (v < 60) return '中';
    if (v < 80) return '高';
    return '极高';
  }

  final String vendorId;
  final String model;
  final String apiKey;
  final String baseUrl;
  /// 思考强度（'low'/'medium'/'high'，默认 'medium'）。
  final String reasoningEffort;

  const MIXConfig({
    required this.vendorId,
    required this.model,
    required this.apiKey,
    required this.baseUrl,
    this.reasoningEffort = 'medium',
  });

  /// 旧版思考强度 key（单值字符串，迁移用）。
  static const String reasoningEffortKey = 'mix_reasoning_effort';

  /// 读取某个流程的思考强度滑块值(0-100)。
  static Future<int> loadEffort(String flowId) async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt('mix_effort_$flowId');
    if (v != null) return v.clamp(0, 100);
    // 兼容旧配置：chat 流程读取旧版单值字符串 key。
    if (flowId == 'chat') {
      final old = prefs.getString(reasoningEffortKey);
      if (old != null) return effortKeyToValue(old);
    }
    for (final f in effortFlows) {
      if (f.id == flowId) return f.defaultValue;
    }
    return 50;
  }

  /// 保存某个流程的思考强度滑块值(0-100)。
  static Future<void> saveEffort(String flowId, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('mix_effort_$flowId', value.clamp(0, 100));
  }

  /// 是否完整可用。
  bool get isComplete =>
      vendorId.isNotEmpty && model.isNotEmpty && apiKey.isNotEmpty;

  /// 快速模型配置（分级委派：子任务用快/便宜模型）。
  /// 未配置时 fallback 主模型。[effort] 为 reasoning_effort 字符串。
  static Future<LlmConfig?> loadFastConfig({String? effort}) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('fast_api_key') ?? '';
    final model = prefs.getString('fast_model') ?? '';
    if (apiKey.isEmpty || model.isEmpty) {
      return null;
    }
    final baseUrl = prefs.getString('fast_base_url') ?? '';
    return LlmConfig(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      reasoningEffort: effort,
    );
  }

  /// 从 SharedPreferences 读取。
  static Future<MIXConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final vendorId = prefs.getString('mix_vendor') ?? '';
    final model = prefs.getString('mix_model') ?? '';
    final apiKey = prefs.getString('mix_api_key') ?? '';
    final baseUrl = prefs.getString('mix_base_url') ?? '';
    final config = MIXConfig(
      vendorId: vendorId,
      model: model,
      apiKey: apiKey,
      baseUrl: baseUrl,
      reasoningEffort: effortValueToKey(await loadEffort('chat')),
    );
    return config.isComplete ? config : null;
  }

  /// 写入 SharedPreferences。
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mix_vendor', vendorId);
    await prefs.setString('mix_model', model);
    await prefs.setString('mix_api_key', apiKey);
    await prefs.setString('mix_base_url', baseUrl);
  }

  /// 转换成 LlmConfig。
  /// [effort] 可选思考强度覆盖：内部任务（出题/refine/子代理/画像）传
  /// 'medium' 固定中档，不随用户聊天时的选择变化；省略则用 [reasoningEffort]。
  LlmConfig toLlmConfig({String? effort}) {
    // 用 baseUrl（自定义优先），否则用 provider 预设。
    final pdef = resolveProviderFull(vendorId);
    final effectiveBaseUrl = baseUrl.isNotEmpty
        ? baseUrl
        : (pdef?.baseUrl ?? '');
    return LlmConfig(
      baseUrl: effectiveBaseUrl,
      apiKey: apiKey,
      model: model,
      reasoningEffort: effort ?? reasoningEffort,
    );
  }

  /// 从 provider 的 `/models` 端点拉取可用模型（OpenAI 兼容）。
  ///
  /// baseUrl 如 `.../v1/chat/completions` → 派生 `.../v1/models`。
  /// 失败返回 null（调用方 fallback 到预设列表）。
  Future<List<String>?> fetchModels() async {
    final llm = toLlmConfig();
    final uri = Uri.parse(llm.baseUrl);
    // 把 `/chat/completions`（或 `/completions`）换成 `/models`。
    // 注意 pathSegments 会把 "chat/completions" 拆成两段，last 是 'completions'，
    // 原实现比较 'chat/completions' 恒不匹配，导致拼出 .../completions/models。
    final segments = uri.pathSegments.toList();
    if (segments.isNotEmpty && segments.last == 'completions') {
      segments.removeLast();
    }
    if (segments.isNotEmpty && segments.last == 'chat') {
      segments.removeLast();
    }
    segments.add('models');
    final modelsUri = uri.replace(pathSegments: segments);

    try {
      final resp = await http.get(
        modelsUri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${llm.apiKey}',
        },
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        return null;
      }
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final list = data['data'];
      if (list is! List) {
        return null;
      }
      final models = <String>[];
      for (final item in list) {
        if (item is Map<String, dynamic> && item['id'] is String) {
          models.add(item['id'] as String);
        }
      }
      models.sort();
      return models.isEmpty ? null : models;
    } catch (_) {
      return null;
    }
  }
}

/// 把 keyResolver 钩子接到 App 配置读取。
Future<void> initConfig() async {
  final prefs = await SharedPreferences.getInstance();
  keyResolver = (envVar) {
    // env var 名 → 单一存储 key（App 只有一个 key 槽）。
    return prefs.getString('mix_api_key');
  };
}

/// 常用模型预设（按 vendor）。
const Map<String, List<String>> vendorModels = {
  'deepseek': ['deepseek-v4-flash', 'deepseek-v4-flash-0731', 'deepseek-chat', 'deepseek-reasoner'],
  'alibaba': ['qwen-plus', 'qwen-max', 'qwen-turbo'],
  'openai': ['gpt-4o', 'gpt-4o-mini', 'o3-mini'],
  'kimi-for-coding': ['moonshot-v1-8k', 'moonshot-v1-32k', 'moonshot-v1-128k'],
  'zai': ['glm-4-plus', 'glm-4-flash'],
  'google': ['gemini-3.6-flash', 'gemini-3.1-pro', 'gemini-2.0-flash', 'gemini-1.5-pro'],
  'openrouter': ['openrouter/auto'],
  'anthropic': ['claude-sonnet-4-6', 'claude-opus-5', 'claude-opus-4-5'],
};

/// vendor 显示名（配置页下拉用）。
const Map<String, String> vendorLabels = {
  'deepseek': 'DeepSeek',
  'alibaba': '通义千问 (DashScope)',
  'openai': 'OpenAI',
  'kimi-for-coding': 'Kimi (Moonshot)',
  'zai': '智谱 GLM (Z.ai)',
  'google': 'Gemini (Google)',
  'openrouter': 'OpenRouter',
  'anthropic': 'Anthropic Claude',
};
