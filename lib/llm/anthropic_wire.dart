/// OpenAI ↔ Anthropic wire 格式转换。
///
/// MIX 内部（session DB / 上下文压缩 / 记忆 / UI）统一维护 **OpenAI 风格**消息：
/// `{role: system|user|assistant|tool, content: String, tool_calls?, tool_call_id?}`。
/// Anthropic Messages API 的 wire 形态完全不同：
///
/// - `system` 是顶层参数，不是一条消息
/// - `content` 是 block 数组：`text` / `tool_use` / `tool_result` / `image` / `thinking`
/// - 工具结果走 `user` 消息里的 `tool_result` block，用 `tool_use_id` 关联
/// - 工具定义用 `input_schema`（不是 `parameters`）
/// - `max_tokens` 必填
///
/// 本文件只做纯函数转换，不发网络请求，便于单测与复用。
library;

import 'dart:convert';

/// 转换结果：顶层 system + Anthropic messages 数组。
class AnthropicMessagesPayload {
  /// 合并后的 system 文本（Anthropic 只接受一个 system，多段用空行拼接）。
  final String system;

  /// Anthropic messages：role 仅 user/assistant，content 为 block 数组。
  final List<Map<String, dynamic>> messages;

  /// system 是否应打 prompt caching 标记。
  final bool cacheSystem;

  const AnthropicMessagesPayload({
    required this.system,
    required this.messages,
    this.cacheSystem = true,
  });
}

/// 把 OpenAI 风格消息列表转成 Anthropic Messages 载荷。
///
/// [cacheSystem] 为 true 时给 system 块打 `cache_control: ephemeral`
/// （Claude Code 的 prompt caching 行为：稳定前缀缓存命中可省 90% 输入成本）。
AnthropicMessagesPayload buildAnthropicMessages(
  List<Map<String, dynamic>> openAiMessages, {
  bool cacheSystem = true,
}) {
  final systemParts = <String>[];
  // 输出队列：role -> blocks。相邻同 role 合并（Anthropic 要求严格交替）。
  final out = <Map<String, dynamic>>[];

  void appendBlocks(String role, List<Map<String, dynamic>> blocks) {
    if (blocks.isEmpty) return;
    if (out.isNotEmpty && out.last['role'] == role) {
      (out.last['content'] as List).addAll(blocks);
    } else {
      out.add({'role': role, 'content': blocks});
    }
  }

  for (final m in openAiMessages) {
    final role = (m['role'] as String?) ?? 'user';
    switch (role) {
      case 'system':
        final s = _textOf(m['content']);
        if (s.trim().isNotEmpty) systemParts.add(s);
        break;

      case 'tool':
        // 工具结果必须落在 user turn 的 tool_result block 里。
        final id = (m['tool_call_id'] as String?) ?? '';
        if (id.isEmpty) break;
        appendBlocks('user', [
          {
            'type': 'tool_result',
            'tool_use_id': id,
            'content': [
              {'type': 'text', 'text': _stringifyToolResult(m['content'])},
            ],
          }
        ]);
        break;

      case 'assistant':
        final blocks = <Map<String, dynamic>>[];
        final text = _textOf(m['content']);
        if (text.trim().isNotEmpty) {
          blocks.add({'type': 'text', 'text': text});
        }
        final calls = m['tool_calls'];
        if (calls is List) {
          for (final c in calls) {
            if (c is! Map) continue;
            final fn = c['function'];
            final name = fn is Map ? (fn['name'] as String? ?? '') : '';
            if (name.isEmpty) continue;
            blocks.add({
              'type': 'tool_use',
              'id': (c['id'] as String?) ?? 'toolu_${blocks.length}',
              'name': name,
              'input': _parseArgs(fn is Map ? fn['arguments'] : null),
            });
          }
        }
        if (blocks.isEmpty) break;
        appendBlocks('assistant', blocks);
        break;

      default: // user 及其它未知 role 一律当 user
        final text = _textOf(m['content']);
        if (text.isEmpty) {
          // 图片等非文本 content：原样透传（调用方已给出 block 数组时）。
          final raw = m['content'];
          if (raw is List) {
            final blocks = <Map<String, dynamic>>[];
            for (final b in raw) {
              if (b is Map<String, dynamic>) blocks.add(b);
            }
            appendBlocks('user', blocks);
          }
          break;
        }
        appendBlocks('user', [
          {'type': 'text', 'text': text},
        ]);
        break;
    }
  }

  // Anthropic 不接受空 messages；空则补一条空 user。
  if (out.isEmpty) {
    out.add({
      'role': 'user',
      'content': [
        {'type': 'text', 'text': ''}
      ],
    });
  }

  // 首条若是 assistant（prefill），Anthropic 允许但要求必须由 user 开头的前缀；
  // 这里若首条不是 user，插入一条占位 user 保证协议合法。
  if (out.first['role'] != 'user') {
    out.insert(0, {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': ''}
      ],
    });
  }

  final systemText = systemParts.join('\n\n');
  return AnthropicMessagesPayload(
    system: systemText,
    messages: out,
    cacheSystem: cacheSystem && systemText.isNotEmpty,
  );
}

/// 把 system 文本包装成 Anthropic 块数组（带 cache_control）。
List<Map<String, dynamic>> systemBlocks(String system, {bool cache = true}) {
  if (system.isEmpty) return const [];
  if (!cache) {
    return [
      {'type': 'text', 'text': system}
    ];
  }
  return [
    {
      'type': 'text',
      'text': system,
      'cache_control': {'type': 'ephemeral'},
    }
  ];
}

/// OpenAI function 工具定义 → Anthropic tools 数组。
///
/// 兼容两种输入形态：
/// - `{type: 'function', function: {name, description, parameters}}`（标准 OpenAI）
/// - `{name, description, parameters}`（部分内部 provider 直给）
///
/// [cacheLast] 为 true 时给最后一个工具打 `cache_control`（工具定义整体缓存）。
List<Map<String, dynamic>> toAnthropicTools(
  List<Map<String, dynamic>>? openAiTools, {
  bool cacheLast = true,
}) {
  if (openAiTools == null || openAiTools.isEmpty) return const [];
  final out = <Map<String, dynamic>>[];
  for (final t in openAiTools) {
    // 非空 Map：t 本身是 Map，function 分支也保证是 Map，声明成 Map? 会让
    // 后面的 fn['x'] 变成「可能对 null 调用 []」—— 那是编译错误（analyze 直接失败）。
    final Map fn = t['function'] is Map ? t['function'] as Map : t;
    final name = _sanitizeToolName((fn['name'] as String?) ?? '');
    if (name.isEmpty) continue;
    final desc = (fn['description'] as String?) ?? '';
    final params = fn['parameters'];
    final schema = params is Map
        ? _cleanSchema(Map<String, dynamic>.from(params))
        : <String, dynamic>{'type': 'object', 'properties': {}};
    out.add({
      'name': name,
      if (desc.isNotEmpty) 'description': desc,
      'input_schema': schema,
    });
  }
  if (cacheLast && out.isNotEmpty) {
    out.last['cache_control'] = {'type': 'ephemeral'};
  }
  return out;
}

/// 工具名合法化：Anthropic 要求 `^[a-zA-Z0-9_-]{1,64}$`。
String _sanitizeToolName(String raw) {
  final s = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  return s.length > 64 ? s.substring(0, 64) : s;
}

/// 递归清理 JSON Schema 中 Anthropic 不接受的键（`$schema`、`$id`）。
Map<String, dynamic> _cleanSchema(Map<String, dynamic> schema) {
  schema.remove(r'$schema');
  schema.remove(r'$id');
  final props = schema['properties'];
  if (props is Map) {
    final cleaned = <String, dynamic>{};
    props.forEach((k, v) {
      if (v is Map) {
        cleaned[k as String] = _cleanSchema(Map<String, dynamic>.from(v));
      } else {
        cleaned[k as String] = v;
      }
    });
    schema['properties'] = cleaned;
  }
  final defs = schema[r'$defs'] ?? schema['definitions'];
  if (defs is Map) {
    final cleaned = <String, dynamic>{};
    defs.forEach((k, v) {
      if (v is Map) {
        cleaned[k as String] = _cleanSchema(Map<String, dynamic>.from(v));
      } else {
        cleaned[k as String] = v;
      }
    });
    if (schema.containsKey(r'$defs')) schema[r'$defs'] = cleaned;
    if (schema.containsKey('definitions')) schema['definitions'] = cleaned;
  }
  return schema;
}

String _textOf(Object? content) {
  if (content is String) return content;
  if (content is List) {
    final buf = StringBuffer();
    for (final b in content) {
      if (b is Map) {
        final t = b['text'];
        if (t is String) buf.write(t);
      } else if (b is String) {
        buf.write(b);
      }
    }
    return buf.toString();
  }
  return '';
}

String _stringifyToolResult(Object? content) {
  if (content == null) return '';
  if (content is String) return content.isEmpty ? ' ' : content;
  return content.toString();
}

Map<String, dynamic> _parseArgs(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 参数不是合法 JSON：保留原文交给 provider 校验，比静默丢弃更有用。
      return {'_raw': raw};
    }
  }
  return <String, dynamic>{};
}
