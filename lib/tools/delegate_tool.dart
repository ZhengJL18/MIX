/// delegate_task 工具：agent 派子任务给子 agent 并行处理。
///
/// 子 agent 用独立 LLM 调用 + 工具执行，返回结果给主 agent。
/// 通过全局 [delegateHandler] 由 ChatScreen 提供（复用 MIXAgent）。
///
/// ## P3 异步委派（DSH 启示 2，v4 §7.2）
/// - `delegate_task_async`：派发后立即返回 delegation id，后台执行，
///   完成写入 `async_delegations` 表（Hermes 预留表补全）。
/// - `delegation_status`：查询委派状态（running/done/failed + result）。
/// 手机场景：后台出题/教材分析不阻塞聊天，完成后查询取结果。
library;

import 'dart:async';

import '../services/memory_db.dart';
import '../services/services.dart';
import 'registry.dart';

/// 最大代理层数（4 层代理 = 3 层子代理）。
const int maxAgentDepth = 3;

/// 当前正在执行的代理层数（串行模型下由子代理运行前设置）。
/// 不靠 LLM 传参（LLM 不会传内部字段），由 _runSubAgent/_runDepartment 维护。
int currentAgentDepth = 0;

/// delegate_task 工具 handler。
Future<String> _handleDelegate(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final handler = Services.instance.delegateHandler;
  if (handler == null) {
    return toolError('delegate_task: 子 agent 执行器未注册');
  }
  final task = args['task'] as String? ?? '';
  if (task.isEmpty) {
    return toolError('delegate_task: missing task');
  }
  final toolsets = (args['toolsets'] as List?)?.whereType<String>().toList();
  final depth = currentAgentDepth;
  // 层数上限：达到 maxAgentDepth 的子代理不能再委派。
  if (depth >= maxAgentDepth) {
    return toolError('delegate_task: 已达最大代理层数（3 层子代理），'
        '请直接在子任务内完成，不要继续委派。');
  }
  try {
    return await handler(task, toolsets, depth);
  } catch (e) {
    return toolError('delegate_task failed: $e');
  }
}

/// delegate_task_async handler：派发后立即返回 delegation id。
Future<String> _handleDelegateAsync(
    Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final handler = Services.instance.delegateHandler;
  final db = Services.instance.delegateDb;
  if (handler == null) {
    return toolError('delegate_task_async: 子 agent 执行器未注册');
  }
  if (db == null) {
    return toolError('delegate_task_async: 记忆库不可用');
  }
  final task = args['task'] as String? ?? '';
  if (task.isEmpty) {
    return toolError('delegate_task_async: missing task');
  }
  final toolsets = (args['toolsets'] as List?)?.whereType<String>().toList();
  final depth = currentAgentDepth;
  if (depth >= maxAgentDepth) {
    return toolError('delegate_task_async: 已达最大代理层数（3 层子代理）');
  }
  try {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    db.db.execute(
      'INSERT INTO async_delegations(task, status, created_at) '
      'VALUES (?, ?, ?)',
      [task, 'running', now],
    );
    final id = db.db.lastInsertRowId;
    // 后台执行（fire-and-forget，不阻塞主 agent）。
    unawaited(_runDelegation(id, task, toolsets, depth, handler, db));
    return toolResult({
      'success': true,
      'delegation_id': id,
      'message': 'Delegated in background. Poll delegation_status with '
          'delegation_id=$id.',
    });
  } catch (e) {
    return toolError('delegate_task_async failed: $e');
  }
}

/// 后台执行委派并写回结果（db 写入失败静默——后台任务容错，不抛未捕获异常）。
Future<void> _runDelegation(
  int id,
  String task,
  List<String>? toolsets,
  int depth,
  Future<String> Function(String task, List<String>? toolsets, int depth)
      handler,
  MemoryDB db,
) async {
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  var status = 'done';
  String? resultStr;
  try {
    resultStr = await handler(task, toolsets, depth);
  } catch (e) {
    status = 'failed';
    resultStr = 'delegation error: $e';
  }
  try {
    db.db.execute(
      'UPDATE async_delegations SET status = ?, result = ?, finished_at = ? '
      'WHERE id = ?',
      [status, resultStr, now, id],
    );
  } catch (_) {
    // 库已关闭等：静默丢弃结果（fire-and-forget 语义）。
  }
}

/// delegation_status handler：查询委派状态。
Future<String> _handleDelegationStatus(
    Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final db = Services.instance.delegateDb;
  if (db == null) {
    return toolError('delegation_status: 记忆库不可用');
  }
  final id = args['delegation_id'] as int?;
  if (id == null) {
    return toolError('delegation_status: delegation_id required');
  }
  try {
    final result = db.db.select(
      'SELECT * FROM async_delegations WHERE id = ? LIMIT 1',
      [id],
    );
    final rows = result.toList();
    if (rows.isEmpty) {
      return toolError('delegation_status: delegation $id not found');
    }
    final r = rows.first;
    return toolResult({
      'delegation_id': id,
      'status': r['status'],
      'task': r['task'],
      'result': r['result'],
      'created_at': r['created_at'],
      'finished_at': r['finished_at'],
    });
  } catch (e) {
    return toolError('delegation_status failed: $e');
  }
}

const Map<String, dynamic> _delegateSchema = {
  'name': 'delegate_task',
  'description':
      'Delegate a sub-task to a sub-agent that runs independently with its own '
      'LLM turns and tool access, then returns a summary. Use for tasks that '
      'can run in parallel with your main work, or that benefit from a fresh '
      'context (research, refactoring a separate file, drafting code). '
      'The sub-agent result is returned as text.',
  'parameters': {
    'type': 'object',
    'properties': {
      'task': {
        'type': 'string',
        'description': 'A self-contained task description for the sub-agent',
      },
      'toolsets': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Optional toolsets the sub-agent may use (file, web, git)',
      },
    },
    'required': ['task'],
  },
};

/// 注册 delegate 工具。
void registerDelegateTool() {
  registry.register(
    name: 'delegate_task',
    toolset: 'delegate',
    schema: _delegateSchema,
    handler: _handleDelegate,
    isAsync: true,
    emoji: '🤖',
  );
  registry.register(
    name: 'delegate_task_async',
    toolset: 'delegate',
    schema: _delegateAsyncSchema,
    handler: _handleDelegateAsync,
    isAsync: true,
    emoji: '🚀',
  );
  registry.register(
    name: 'delegation_status',
    toolset: 'delegate',
    schema: _delegationStatusSchema,
    handler: _handleDelegationStatus,
    isAsync: true,
    emoji: '📋',
  );
}

const Map<String, dynamic> _delegateAsyncSchema = {
  'name': 'delegate_task_async',
  'description':
      'Delegate a sub-task to a background sub-agent and return immediately '
      'with a delegation_id (non-blocking). Poll delegation_status to get the '
      'result when done. Use for long tasks (research, drafting, analysis) '
      'that should not block your current turn.',
  'parameters': {
    'type': 'object',
    'properties': {
      'task': {
        'type': 'string',
        'description': 'A self-contained task description for the sub-agent',
      },
      'toolsets': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Optional toolsets the sub-agent may use',
      },
    },
    'required': ['task'],
  },
};

const Map<String, dynamic> _delegationStatusSchema = {
  'name': 'delegation_status',
  'description':
      'Query the status of a background delegation by delegation_id. '
      'Returns status (running/done/failed) and result when finished.',
  'parameters': {
    'type': 'object',
    'properties': {
      'delegation_id': {
        'type': 'integer',
        'description': 'Delegation id from delegate_task_async',
      },
    },
    'required': ['delegation_id'],
  },
};
