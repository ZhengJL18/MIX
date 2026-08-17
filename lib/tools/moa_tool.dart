/// moa_discuss 工具：多子代理真对话（Kimi 式）。
///
/// 多个子代理（各带视角人设）逐轮并行讨论：每轮看到彼此发言再回应，
/// N 轮后主模型综合给出最终结论。
/// 通过全局 [moaHandler] 由 ChatScreen 提供执行器。
library;

import '../services/services.dart';
import 'registry.dart';

/// moa_discuss 工具 handler。
Future<String> _handleMoa(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final handler = Services.instance.moaHandler;
  if (handler == null) {
    return toolError('moa_discuss: 讨论执行器未注册');
  }
  final topic = args['topic'] as String? ?? '';
  if (topic.isEmpty) {
    return toolError('moa_discuss: missing topic');
  }
  final rounds = args['rounds'] as int? ?? 2;
  try {
    return await handler(topic, rounds);
  } catch (e) {
    return toolError('moa_discuss failed: $e');
  }
}

const Map<String, dynamic> _moaSchema = {
  'name': 'moa_discuss',
  'description':
      'Organize a multi-agent discussion (Kimi-style) to deeply analyze a '
      'complex question. Spawns several sub-agents with different perspectives '
      'who debate over rounds, then synthesizes a final conclusion. '
      'Use for hard problems where a single pass may miss angles: architecture '
      'decisions, tradeoff analysis, code review, ambiguous requirements. '
      'Returns the synthesized conclusion.',
  'parameters': {
    'type': 'object',
    'properties': {
      'topic': {
        'type': 'string',
        'description': 'The question or problem to discuss',
      },
      'rounds': {
        'type': 'integer',
        'description': 'Number of discussion rounds (default 2, max 4)',
      },
    },
    'required': ['topic'],
  },
};

/// 注册 moa_discuss 工具。
void registerMoaTool() {
  registry.register(
    name: 'moa_discuss',
    toolset: 'moa',
    schema: _moaSchema,
    handler: _handleMoa,
    isAsync: true,
    emoji: '🗣️',
    // 长讨论结果截断，防污染主 agent 上下文（对齐官方 _truncate_tool_result）。
    maxResultSizeChars: 8000,
  );
}
