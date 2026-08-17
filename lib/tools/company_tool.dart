/// delegate_to_department 工具：主 agent（CEO）把任务派给部门。
///
/// 部门内各角色（子代理）并行执行任务，结果汇总返回给 CEO。
/// 通过全局 [departmentHandler] 由 ChatScreen 提供执行器。
library;

import '../agent/company.dart';
import '../services/services.dart';
import 'delegate_tool.dart' show currentAgentDepth;
import 'registry.dart';

/// delegate_to_department 工具 handler。
Future<String> _handleDepartment(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final handler = Services.instance.departmentHandler;
  if (handler == null) {
    return toolError('delegate_to_department: 部门执行器未注册');
  }
  final department = args['department'] as String? ?? '';
  final task = args['task'] as String? ?? '';
  if (department.isEmpty) {
    return toolError('delegate_to_department: missing department');
  }
  if (task.isEmpty) {
    return toolError('delegate_to_department: missing task');
  }
  if (findActiveDepartment(department) == null) {
    return toolError('delegate_to_department: 未知部门 "$department"。'
        '可用：${activeDepartments.map((d) => d.id).join(', ')}');
  }
  final depth = currentAgentDepth;
  try {
    return await handler(department, task, depth);
  } catch (e) {
    return toolError('delegate_to_department failed: $e');
  }
}

const Map<String, dynamic> _departmentSchema = {
  'name': 'delegate_to_department',
  'description':
      'Delegate a task to a department (a team of sub-agents with specific '
      'roles). The department roles work in parallel on the task, then '
      'results are summarized and returned. Use for complex work that benefits '
      'from a specialized team: coding (code), research (research), or '
      'document work (office). Returns the summarized output.',
  'parameters': {
    'type': 'object',
    'properties': {
      'department': {
        'type': 'string',
        'enum': ['code', 'research', 'office'],
        'description': 'Which department to delegate to: code, research, office',
      },
      'task': {
        'type': 'string',
        'description': 'A self-contained task for the department to complete',
      },
    },
    'required': ['department', 'task'],
  },
};

/// 注册 delegate_to_department 工具。
void registerCompanyTool() {
  registry.register(
    name: 'delegate_to_department',
    toolset: 'company',
    schema: _departmentSchema,
    handler: _handleDepartment,
    isAsync: true,
    emoji: '🏢',
  );
}
