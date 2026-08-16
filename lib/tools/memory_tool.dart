/// 对应 `ref/hermes-agent/tools/memory_tool.py`（像素级复刻，核心逻辑）。
///
/// 有界精选记忆，文件持久化。每个 AIAgent 一个实例。
///
/// 维护两个并行状态：
/// - `_systemPromptSnapshot`：加载时冻结，用于 system prompt 注入，会话中不变。
/// - `memoryEntries` / `userEntries`：工具调用变更的实时状态，持久化到磁盘。
///
/// ## Dart 适配
/// - 文件锁（Python fcntl/flock）：Dart 单 isolate，省略。
/// - threat_patterns 注入扫描：App 记忆是 agent 自己写的，非外部注入，简化为
///   占位（保留 `_scanMemoryContent` 接口）。
/// - atomic_write_text：用临时文件 + rename（同 file_operations 原子写）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'registry.dart';

/// system prompt 记忆块的稳定头前缀。
const Map<String, String> memoryBlockHeaders = {
  'memory': 'MEMORY (your personal notes)',
  'user': 'USER PROFILE (who the user is)',
};

/// 条目分隔符。
const String entryDelimiter = '\n§\n';

/// 记忆内容注入扫描（简化：App 记忆为 agent 自写，保留接口）。
/// 未来接入威胁检测时实现。
String? Function(String content)? scanMemoryContentHook;

String? _scanMemoryContent(String content) {
  if (scanMemoryContentHook != null) {
    return scanMemoryContentHook!(content);
  }
  return null;
}

/// 有界精选记忆存储。
class MemoryStore {
  List<String> memoryEntries = [];
  List<String> userEntries = [];
  final int memoryCharLimit;
  final int userCharLimit;
  // 冻结的 system prompt 快照，load 时设置。
  Map<String, String> systemPromptSnapshot = {'memory': '', 'user': ''};

  /// 记忆文件根目录（App documents 目录）。
  final String baseDir;

  /// 本 turn 失败的合并次数（防模型反复重试拖死 turn）。
  int consolidationFailures = 0;
  static const int maxConsolidationFailuresPerTurn = 3;

  MemoryStore({
    this.memoryCharLimit = 2200,
    this.userCharLimit = 1375,
    required this.baseDir,
  }) {
    loadFromDisk();
  }

  /// 每个 turn 开始调用，重置合并失败计数。
  void resetConsolidationFailures() {
    consolidationFailures = 0;
  }

  /// 合并失败计数并在超上限时优雅降级。
  Map<String, dynamic> consolidationFailure(Map<String, dynamic> response) {
    consolidationFailures++;
    if (consolidationFailures <= maxConsolidationFailuresPerTurn) {
      return response;
    }
    return {
      'success': false,
      'done': true,
      'error': 'Memory consolidation failed $consolidationFailures times '
          'this turn. Stop retrying memory calls — leave memory unchanged for '
          'now and continue with your reply to the user. The fact can be saved '
          'in a later turn.',
    };
  }

  String _pathFor(String target) {
    final name = target == 'user' ? 'USER.md' : 'MEMORY.md';
    return p.join(baseDir, 'memories', name);
  }

  List<String> _entriesFor(String target) =>
      target == 'user' ? userEntries : memoryEntries;

  void _setEntries(String target, List<String> entries) {
    if (target == 'user') {
      userEntries = entries;
    } else {
      memoryEntries = entries;
    }
  }

  int _charCount(String target) {
    final entries = _entriesFor(target);
    if (entries.isEmpty) return 0;
    return entries.join(entryDelimiter).length;
  }

  int _charLimit(String target) =>
      target == 'user' ? userCharLimit : memoryCharLimit;

  /// 从磁盘加载 MEMORY.md / USER.md，捕获 system prompt 快照。
  void loadFromDisk() {
    final dir = p.join(baseDir, 'memories');
    Directory(dir).createSync(recursive: true);
    memoryEntries = _readFile(_pathFor('memory'));
    userEntries = _readFile(_pathFor('user'));
    // 去重（保持顺序，保留首次出现）。
    memoryEntries = memoryEntries.toSet().toList();
    userEntries = userEntries.toSet().toList();
    systemPromptSnapshot = {
      'memory': _renderBlock('memory', memoryEntries),
      'user': _renderBlock('user', userEntries),
    };
  }

  /// 渲染 system prompt 块（含头部 + 用量指示）。
  String _renderBlock(String target, List<String> entries) {
    if (entries.isEmpty) {
      return '';
    }
    final limit = _charLimit(target);
    final content = entries.join(entryDelimiter);
    final current = content.length;
    final pct = limit > 0
        ? (current / limit * 100).toInt().clamp(0, 100)
        : 0;
    final header = target == 'user'
        ? '${memoryBlockHeaders['user']} [$pct% — $current/$limit chars]'
        : '${memoryBlockHeaders['memory']} [$pct% — $current/$limit chars]';
    final separator = List.filled(46, '═').join();
    return '$separator\n$header\n$separator\n$content';
  }

  /// 读取记忆文件切分为条目（任何错误返回空列表）。
  static List<String> _readFile(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return [];
      final raw = f.readAsStringSync();
      if (raw.trim().isEmpty) return [];
      return raw
          .split(entryDelimiter)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 原子写记忆文件（临时文件 + rename）。失败返回错误串，成功返回 null。
  /// 原实现吞掉写盘异常并返回假成功，记忆只在内存、重启即丢，agent 却被告知成功。
  String? saveToDisk(String target) {
    final path = _pathFor(target);
    final content = _entriesFor(target).join(entryDelimiter);
    try {
      Directory(p.dirname(path)).createSync(recursive: true);
      final tmp = '$path.tmp.$pid';
      File(tmp).writeAsStringSync(content, flush: true);
      File(tmp).renameSync(path);
      return null;
    } catch (e) {
      return '写记忆文件失败: $e';
    }
  }

  /// 追加新条目。超字符限制返回错误。
  Map<String, dynamic> add(String target, String content) {
    content = content.trim();
    if (content.isEmpty) {
      return {'success': false, 'error': 'Content cannot be empty.'};
    }
    final scanError = _scanMemoryContent(content);
    if (scanError != null) {
      return {'success': false, 'error': scanError};
    }
    final entries = List<String>.of(_entriesFor(target));
    final limit = _charLimit(target);
    if (entries.contains(content)) {
      return successResponse(target, 'Entry already exists (no duplicate added).');
    }
    final newEntries = [...entries, content];
    final newTotal = newEntries.join(entryDelimiter).length;
    if (newTotal > limit) {
      final current = _charCount(target);
      return consolidationFailure({
        'success': false,
        'error': 'Memory at $current/$limit chars. '
            'Adding this entry (${content.length} chars) would exceed the limit. '
            "Consolidate now: use 'replace' to merge overlapping entries into "
            "shorter ones or 'remove' stale or less important entries (see "
            'current_entries below), then retry this add — all in this turn.',
        'current_entries': entries,
        'usage': '$current/$limit',
      });
    }
    _setEntries(target, newEntries);
    final err = saveToDisk(target);
    if (err != null) return {'success': false, 'error': err};
    return successResponse(target, 'Entry added.');
  }

  /// 找到含 old_text 子串的条目，替换为 new_content。
  Map<String, dynamic> replace(String target, String oldText, String newContent) {
    oldText = oldText.trim();
    newContent = newContent.trim();
    if (oldText.isEmpty) {
      return {'success': false, 'error': 'old_text cannot be empty.'};
    }
    if (newContent.isEmpty) {
      return {
        'success': false,
        'error': "new_content cannot be empty. Use 'remove' to delete entries.",
      };
    }
    final scanError = _scanMemoryContent(newContent);
    if (scanError != null) {
      return {'success': false, 'error': scanError};
    }
    final entries = List<String>.of(_entriesFor(target));
    final matches = <int>[
      for (var i = 0; i < entries.length; i++)
        if (entries[i].contains(oldText)) i,
    ];
    if (matches.isEmpty) {
      return consolidationFailure({
        'success': false,
        'error': "No entry matched '$oldText'. Check current_entries below and "
            'retry with the exact text of the entry you want to replace.',
        'current_entries': entries,
      });
    }
    if (matches.length > 1) {
      final uniqueTexts = matches.map((i) => entries[i]).toSet();
      if (uniqueTexts.length > 1) {
        final previews = matches.map((i) => entries[i]).toList();
        return {
          'success': false,
          'error': "Multiple entries matched '$oldText'. Be more specific.",
          'matches': previews,
        };
      }
    }
    final idx = matches.first;
    final limit = _charLimit(target);
    final testEntries = List<String>.of(entries);
    testEntries[idx] = newContent;
    final newTotal = testEntries.join(entryDelimiter).length;
    if (newTotal > limit) {
      final current = _charCount(target);
      return consolidationFailure({
        'success': false,
        'error': 'Replacement would put memory at $newTotal/$limit chars. '
            "Shorten the new content, or 'remove' other stale or less important "
            'entries to make room (see current_entries below), then retry — all '
            'in this turn.',
        'current_entries': entries,
        'usage': '$current/$limit',
      });
    }
    _setEntries(target, testEntries);
    final err = saveToDisk(target);
    if (err != null) return {'success': false, 'error': err};
    return successResponse(target, 'Entry replaced.');
  }

  /// 移除含 old_text 子串的条目。
  Map<String, dynamic> remove(String target, String oldText) {
    oldText = oldText.trim();
    if (oldText.isEmpty) {
      return {'success': false, 'error': 'old_text cannot be empty.'};
    }
    final entries = List<String>.of(_entriesFor(target));
    final matches = <int>[
      for (var i = 0; i < entries.length; i++)
        if (entries[i].contains(oldText)) i,
    ];
    if (matches.isEmpty) {
      return consolidationFailure({
        'success': false,
        'error': "No entry matched '$oldText'. Check current_entries below and "
            'retry with the exact text of the entry you want to remove.',
        'current_entries': entries,
      });
    }
    if (matches.length > 1) {
      final uniqueTexts = matches.map((i) => entries[i]).toSet();
      if (uniqueTexts.length > 1) {
        final previews = matches.map((i) => entries[i]).toList();
        return {
          'success': false,
          'error': "Multiple entries matched '$oldText'. Be more specific.",
          'matches': previews,
        };
      }
    }
    final idx = matches.first;
    entries.removeAt(idx);
    _setEntries(target, entries);
    final err = saveToDisk(target);
    if (err != null) return {'success': false, 'error': err};
    return successResponse(target, 'Entry removed.');
  }

  /// 原子应用一批 add/replace/remove（对最终预算检查）。
  Map<String, dynamic> applyBatch(String target, List<Map<String, dynamic>> operations) {
    if (operations.isEmpty) {
      return {'success': false, 'error': 'operations list is empty.'};
    }
    // 先扫描所有 add/replace 内容。
    for (var i = 0; i < operations.length; i++) {
      final op = operations[i];
      final act = op['action'];
      final newContent = op['content'];
      if ((act == 'add' || act == 'replace') && newContent is String) {
        final scanError = _scanMemoryContent(newContent);
        if (scanError != null) {
          return {'success': false, 'error': 'Operation ${i + 1}: $scanError'};
        }
      }
    }
    // 逐个应用到副本，最后检查预算。
    final entries = List<String>.of(_entriesFor(target));
    for (final op in operations) {
      final act = op['action'];
      final content = (op['content'] as String? ?? '').trim();
      final oldText = (op['old_text'] as String? ?? '').trim();
      if (act == 'add') {
        if (content.isEmpty) {
          return {'success': false, 'error': 'Content cannot be empty.'};
        }
        if (!entries.contains(content)) {
          entries.add(content);
        }
      } else if (act == 'replace') {
        final matches = <int>[
          for (var i = 0; i < entries.length; i++)
            if (entries[i].contains(oldText)) i,
        ];
        if (matches.isEmpty) {
          return {
            'success': false,
            'error': "No entry matched '$oldText'.",
            'current_entries': entries,
          };
        }
        if (matches.length > 1 &&
            matches.map((i) => entries[i]).toSet().length > 1) {
          return {
            'success': false,
            'error': "Multiple entries matched '$oldText'. Be more specific.",
            'matches': matches.map((i) => entries[i]).toList(),
          };
        }
        entries[matches.first] = content;
      } else if (act == 'remove') {
        final matches = <int>[
          for (var i = 0; i < entries.length; i++)
            if (entries[i].contains(oldText)) i,
        ];
        if (matches.isEmpty) {
          return {
            'success': false,
            'error': "No entry matched '$oldText'.",
            'current_entries': entries,
          };
        }
        entries.removeAt(matches.first);
      }
    }
    final newTotal = entries.join(entryDelimiter).length;
    final limit = _charLimit(target);
    if (newTotal > limit) {
      return consolidationFailure({
        'success': false,
        'error': 'Batch would put memory at $newTotal/$limit chars. '
            "Shorten entries or 'remove' stale ones, then retry.",
        'current_entries': entries,
        'usage': '$newTotal/$limit',
      });
    }
    _setEntries(target, entries);
    final err = saveToDisk(target);
    if (err != null) return {'success': false, 'error': err};
    return successResponse(target, 'Batch applied.');
  }

  /// 返回冻结快照用于 system prompt 注入。
  ///
  /// 返回 load_from_disk 时的状态，不是实时状态。会话中写入不影响它 ——
  /// 保持 system prompt 跨所有 turn 稳定，保住 prefix cache。
  /// 快照为空时返回 null。
  String? formatForSystemPrompt(String target) {
    final block = systemPromptSnapshot[target] ?? '';
    return block.isEmpty ? null : block;
  }

  Map<String, dynamic> successResponse(String target, String message) {
    return {
      'success': true,
      'message': message,
      'target': target,
      'memory': _entriesFor('memory'),
      'user': _entriesFor('user'),
      'usage': '${_charCount(target)}/${_charLimit(target)}',
    };
  }

  /// 当前记忆快照（memory_tool 的 current_entries 用）。
  Map<String, dynamic> toDict() {
    return {
      'memory': memoryEntries,
      'user': userEntries,
      'memory_usage': '${_charCount('memory')}/$memoryCharLimit',
      'user_usage': '${_charCount('user')}/$userCharLimit',
    };
  }
}

/// 记忆工具单入口，分发到 MemoryStore 方法。
///
/// 两种形状：
/// - 单操作：action + (content / old_text)
/// - 批处理：operations=[{action, content?, old_text?}, ...] 原子应用。
String memoryTool({
  String? action,
  String target = 'memory',
  String? content,
  String? oldText,
  List<Map<String, dynamic>>? operations,
  MemoryStore? store,
}) {
  if (store == null) {
    return toolError(
      'Memory is not available. It may be disabled in config or this environment.',
      extra: {'success': false},
    );
  }
  if (target != 'memory' && target != 'user') {
    return toolError("Invalid target '$target'. Use 'memory' or 'user'.",
        extra: {'success': false});
  }

  // 批处理路径。
  if (operations != null && operations.isNotEmpty) {
    final result = store.applyBatch(target, operations);
    return jsonEncode(result);
  }

  // 单操作路径。
  if (action == 'add' && (content == null || content.isEmpty)) {
    return toolError("Content is required for 'add' action.",
        extra: {'success': false});
  }
  if (action == 'replace' &&
      (oldText == null || oldText.isEmpty || content == null || content.isEmpty)) {
    return toolError(
        "old_text and content are required for 'replace' action.",
        extra: {'success': false});
  }
  if (action == 'remove' && (oldText == null || oldText.isEmpty)) {
    return toolError("old_text is required for 'remove' action.",
        extra: {'success': false});
  }

  Map<String, dynamic> result;
  switch (action) {
    case 'add':
      result = store.add(target, content ?? '');
      break;
    case 'replace':
      result = store.replace(target, oldText ?? '', content ?? '');
      break;
    case 'remove':
      result = store.remove(target, oldText ?? '');
      break;
    default:
      return toolError("Unknown action '$action'. Use: add, replace, remove",
          extra: {'success': false});
  }
  return jsonEncode(result);
}

/// memory 工具 schema（OpenAI 格式）。
const Map<String, dynamic> memorySchema = {
  'name': 'memory',
  'description':
      'Save durable facts to persistent memory that survive across sessions. '
      'Memory is injected into every future turn, so keep entries compact and '
      'high-signal.\n\n'
      "HOW: make ALL your changes in ONE call via an 'operations' array (each "
      'item: {action, content?, old_text?}). The batch applies atomically and '
      'the char limit is checked only on the FINAL result — so a single call '
      'can remove/replace stale entries to free room AND add new ones, even '
      "when an add alone would overflow. Use the bare action/content/old_text "
      'fields only for a single lone change.\n\n'
      'WHEN: save proactively when the user states a preference, correction, '
      'or personal detail, or you learn a stable fact about their environment, '
      'conventions, or workflow. Priority: user preferences & corrections > '
      'environment facts > procedures.',
  'parameters': {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['add', 'replace', 'remove'],
        'description': "Action to perform: 'add' appends, 'replace' edits, 'remove' deletes.",
      },
      'target': {
        'type': 'string',
        'enum': ['memory', 'user'],
        'description': "Store to operate on: 'memory' for personal notes, 'user' for user profile.",
        'default': 'memory',
      },
      'content': {
        'type': 'string',
        'description': 'Content to add or replacement text.',
      },
      'old_text': {
        'type': 'string',
        'description': "For 'replace'/'remove': substring of the entry to match.",
      },
      'operations': {
        'type': 'array',
        'description': 'Batch of {action, content?, old_text?} applied atomically.',
        'items': {
          'type': 'object',
          'properties': {
            'action': {'type': 'string', 'enum': ['add', 'replace', 'remove']},
            'content': {'type': 'string'},
            'old_text': {'type': 'string'},
          },
        },
      },
    },
  },
};

/// 注册 memory 工具。
void registerMemoryTool({String? baseDir, MemoryStore? existingStore}) {
  // 全局单例 store（agent 复用）。
  memoryStore = existingStore ??
      MemoryStore(baseDir: baseDir ?? (memoryStore?.baseDir ?? '.'));
  registry.register(
    name: 'memory',
    toolset: 'memory',
    schema: memorySchema,
    handler: (args, [kwargs]) async {
      final result = memoryTool(
        action: args['action'] as String?,
        target: args['target'] as String? ?? 'memory',
        content: args['content'] as String?,
        oldText: args['old_text'] as String?,
        operations: (args['operations'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(),
        store: memoryStore,
      );
      // P1：写入成功后异步索引（自动标签/知识点边），失败不影响原结果。
      final hook = memoryIndexHook;
      if (hook != null) {
        try {
          await hook(args, result);
        } catch (_) {}
      }
      return result;
    },
    checkFn: () => true,
    emoji: '🧠',
  );
}

/// 全局记忆 store（AIAgent / 主循环共享）。
MemoryStore? memoryStore;

/// P1 记忆索引钩子（v4 §5 确定性图建构）：memory 工具写入成功后异步触发
/// 自动标签/知识点边索引。由 main.dart 注入（关联 MemoryDB + StudyEngine）。
/// 可空、异常吞掉——不改变 Hermes memory 工具语义，纯附加行为。
Future<void> Function(Map<String, dynamic> args, String result)? memoryIndexHook;
