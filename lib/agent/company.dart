/// 公司模式：自定义部门 + 主 agent（CEO）调度多层代理。
///
/// 每个部门有一组角色（子代理）+ 工具集 + 人设。CEO 按任务性质选择部门，
/// 部门内子代理分工执行或讨论，结果汇总给 CEO。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 部门定义。
class AgentDepartment {
  final String id;
  final String name;
  final String description;
  final List<String> roles; // 部门内角色名（每个角色 = 一个子代理视角）。
  final List<String> toolsets; // 部门子代理可用工具。

  const AgentDepartment({
    required this.id,
    required this.name,
    required this.description,
    required this.roles,
    required this.toolsets,
  });
}

/// 预设部门（可按项目自定义，主 agent 根据任务性质选择）。
const List<AgentDepartment> presetDepartments = [
  AgentDepartment(
    id: 'code',
    name: '代码部',
    description: '写代码、重构、调试、代码审查',
    roles: ['架构师', '实现者', '审查者'],
    toolsets: ['file', 'web', 'delegate', 'moa'],
  ),
  AgentDepartment(
    id: 'research',
    name: '研究部',
    description: '调研、资料收集、分析、总结',
    roles: ['检索员', '分析师', '批评者'],
    toolsets: ['web', 'memory', 'delegate', 'moa'],
  ),
  AgentDepartment(
    id: 'office',
    name: '办公部',
    description: '写文档、整理资料、排版、校对',
    roles: ['文档员', '校对员', '排版员'],
    toolsets: ['file', 'web', 'delegate'],
  ),
];

/// 按 id 找部门。
AgentDepartment? findDepartment(String id) {
  for (final d in presetDepartments) {
    if (d.id == id) {
      return d;
    }
  }
  return null;
}

/// 生效的部门列表（预设 + 用户自定义，运行时可变）。
List<AgentDepartment> activeDepartments = [...presetDepartments];

/// 按 id 找生效部门。
AgentDepartment? findActiveDepartment(String id) {
  for (final d in activeDepartments) {
    if (d.id == id) {
      return d;
    }
  }
  return null;
}

/// 部门列表描述（给 CEO 系统提示，让它知道有哪些部门可用）。
String departmentsSummary() {
  return activeDepartments
      .map((d) => '  - ${d.id}（${d.name}）：${d.description}，'
          '角色：${d.roles.join('/')}')
      .join('\n');
}

/// 从 SharedPreferences 加载自定义部门，覆盖 activeDepartments。
Future<void> loadCustomDepartments() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('custom_departments');
    if (raw == null || raw.isEmpty) {
      activeDepartments = [...presetDepartments];
      return;
    }
    final decoded = jsonDecode(raw) as List;
    final custom = <AgentDepartment>[];
    for (final d in decoded) {
      if (d is! Map<String, dynamic>) continue;
      final id = d['id'] as String? ?? '';
      final roles = (d['roles'] as List?)?.whereType<String>().toList() ?? [];
      if (id.isEmpty || roles.isEmpty) continue;
      custom.add(AgentDepartment(
        id: id,
        name: d['name'] as String? ?? id,
        description: d['description'] as String? ?? '',
        roles: roles,
        toolsets: (d['toolsets'] as List?)?.whereType<String>().toList() ??
            const ['file', 'web'],
      ));
    }
    activeDepartments = custom.isNotEmpty ? custom : [...presetDepartments];
  } catch (_) {
    activeDepartments = [...presetDepartments];
  }
}

/// 保存自定义部门到 SharedPreferences（覆盖预设）。
Future<void> saveCustomDepartments(List<AgentDepartment> deps) async {
  final prefs = await SharedPreferences.getInstance();
  final encoded = jsonEncode([
    for (final d in deps)
      {
        'id': d.id,
        'name': d.name,
        'description': d.description,
        'roles': d.roles,
        'toolsets': d.toolsets,
      },
  ]);
  await prefs.setString('custom_departments', encoded);
  activeDepartments = [...deps];
}
