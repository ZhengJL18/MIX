/// 对应 `ref/hermes-agent/tools/skills_tool.py` + `skill_manager_tool.py`
/// （像素级复刻，核心）。
///
/// skills_list / skill_view / skill_manage 三个工具 + system prompt 索引注入。
///
/// skill 是 agent 的程序性记忆 —— 可复用方法，存为 SKILL.md。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../skills/skill_discovery.dart';
import '../services/services.dart';
import '../skills/skill_parser.dart';
import 'fuzzy_match.dart';
import 'registry.dart';

// =============================================================================
// System prompt 注入（渐进式披露：只注入 name+description 索引）
// =============================================================================

/// 构建 `## Skills (mandatory)` 块，按 category 分组。
String buildSkillsSystemPrompt() {
  final discovery = Services.instance.skillDiscovery;
  if (discovery == null) {
    return '';
  }
  final skills = discovery.findAllSkills();
  if (skills.isEmpty) {
    return '';
  }
  final byCategory = <String, List<SkillMeta>>{};
  for (final s in skills) {
    final cat = s.category.isEmpty ? 'general' : s.category;
    byCategory.putIfAbsent(cat, () => []).add(s);
  }
  final lines = <String>['## Skills (mandatory)', ''];
  byCategory.forEach((cat, list) {
    lines.add('### $cat');
    for (final s in list) {
      // 描述截断到 57 字符 + '...'（对齐 Hermes 系统提示索引）。
      final desc = s.description.length > 57
          ? '${s.description.substring(0, 57)}...'
          : s.description;
      lines.add('- ${s.name}: $desc');
    }
    lines.add('');
  });
  return lines.join('\n');
}

// =============================================================================
// 工具实现
// =============================================================================

/// skills_list：列出 skills（可按 category 过滤）。
String skillsListTool({String? category}) {
  final discovery = Services.instance.skillDiscovery;
  if (discovery == null) {
    return toolError('Skills not available');
  }
  final skills = discovery.findAllSkills();
  final filtered = category != null && category.isNotEmpty
      ? skills.where((s) => s.category == category).toList()
      : skills;
  final categories = skills.map((s) => s.category).where((c) => c.isNotEmpty).toSet().toList()
    ..sort();
  return jsonEncode({
    'skills': [for (final s in filtered) s.toJson()],
    'categories': categories,
    'count': filtered.length,
  });
}

/// skill_view：查看 skill 内容。
String skillViewTool({String? name, String? filePath}) {
  final discovery = Services.instance.skillDiscovery;
  if (discovery == null) {
    return toolError('Skills not available');
  }
  if (name == null && filePath == null) {
    return toolError("skill_view requires 'name' or 'file_path'");
  }
  final skill = discovery.findSkill(name ?? '', filePath: filePath);
  if (skill == null) {
    return toolError("Skill '$name' not found");
  }
  final content = discovery.readContent(skill.path);
  // linked_files：支持目录下的文件。
  final linked = <String, List<String>>{};
  for (final sub in skillSupportDirs) {
    final dir = p.join(skill.dir, sub);
    try {
      final d = Directory(dir);
      if (d.existsSync()) {
        linked[sub] = [
          for (final e in d.listSync(recursive: true, followLinks: false))
            if (e is File) p.relative(e.path, from: skill.dir),
        ];
      }
    } catch (_) {}
  }
  return jsonEncode({
    'name': skill.name,
    'category': skill.category,
    'content': content,
    'skill_dir': skill.dir,
    'linked_files': linked,
    'setup_needed': false,
  });
}

/// skill_manage：管理 skills（create/patch/edit/delete/write_file/remove_file）。
String skillManageTool({
  required String action,
  required String name,
  String? content,
  String? category,
  String? oldString,
  String? newString,
  bool replaceAll = false,
  String? filePath,
  String? fileContent,
}) {
  final discovery = Services.instance.skillDiscovery;
  if (discovery == null) {
    return toolError('Skills not available');
  }

  switch (action) {
    case 'create':
      return _createSkill(discovery, name, content ?? '', category);
    case 'patch':
      return _patchSkill(discovery, name, oldString ?? '', newString ?? '', replaceAll);
    case 'edit':
      return _editSkill(discovery, name, content ?? '');
    case 'delete':
      return _deleteSkill(discovery, name);
    case 'write_file':
      return _writeSkillFile(discovery, name, filePath ?? '', fileContent ?? '');
    case 'remove_file':
      return _removeSkillFile(discovery, name, filePath ?? '');
    default:
      return toolError("Unknown action '$action'");
  }
}

/// 公开创建 skill（refine 自进化与 skill_manage 工具共用同一逻辑）。
String createSkill(SkillDiscovery d, String name, String content, String? category) {
  final result = _createSkill(d, name, content, category);
  return result;
}

/// 公开 patch skill（refine 自进化用）。
String patchSkill(SkillDiscovery d, String name, String oldString, String newString,
    {bool replaceAll = false}) {
  return _patchSkill(d, name, oldString, newString, replaceAll);
}

String _createSkill(SkillDiscovery d, String name, String content, String? category) {
  // 校验 name。
  if (!isValidSkillName(name)) {
    return toolError("Invalid skill name '$name'");
  }
  // 校验 frontmatter。
  final (frontmatter, _) = parseFrontmatter(content);
  final validationError = validateFrontmatter(content, frontmatter, requireShortDesc: true);
  if (validationError != null) {
    return toolError('Validation failed: $validationError');
  }
  // 查重。
  if (d.findSkill(name) != null) {
    return toolError("Skill '$name' already exists");
  }
  // 目录。
  final skillDir = category != null && category.isNotEmpty
      ? p.join(d.skillsRoot, category, name)
      : p.join(d.skillsRoot, name);
  try {
    Directory(skillDir).createSync(recursive: true);
    final path = p.join(skillDir, 'SKILL.md');
    File(path).writeAsStringSync(content, flush: true);
  } catch (e) {
    return toolError('Failed to create skill: $e');
  }
  return toolResult({'success': true, 'name': name, 'action': 'create'});
}

String _patchSkill(SkillDiscovery d, String name, String oldString, String newString, bool replaceAll) {
  final skill = d.findSkill(name);
  if (skill == null) {
    return toolError("Skill '$name' not found");
  }
  final content = d.readContent(skill.path);
  final (newContent, count, _, error) = fuzzyFindAndReplace(
    content,
    oldString,
    newString,
    replaceAll: replaceAll,
  );
  if (error != null || count == 0) {
    return toolError(error ?? 'No match found');
  }
  try {
    File(skill.path).writeAsStringSync(newContent, flush: true);
  } catch (e) {
    return toolError('Failed to patch skill: $e');
  }
  return toolResult({'success': true, 'name': name, 'action': 'patch', 'matches': count});
}

String _editSkill(SkillDiscovery d, String name, String content) {
  final skill = d.findSkill(name);
  if (skill == null) {
    return toolError("Skill '$name' not found");
  }
  final (frontmatter, _) = parseFrontmatter(content);
  final validationError = validateFrontmatter(content, frontmatter);
  if (validationError != null) {
    return toolError('Validation failed: $validationError');
  }
  try {
    File(skill.path).writeAsStringSync(content, flush: true);
  } catch (e) {
    return toolError('Failed to edit skill: $e');
  }
  return toolResult({'success': true, 'name': name, 'action': 'edit'});
}

String _deleteSkill(SkillDiscovery d, String name) {
  final skill = d.findSkill(name);
  if (skill == null) {
    return toolError("Skill '$name' not found");
  }
  try {
    Directory(skill.dir).deleteSync(recursive: true);
  } catch (e) {
    return toolError('Failed to delete skill: $e');
  }
  return toolResult({'success': true, 'name': name, 'action': 'delete'});
}

String _writeSkillFile(SkillDiscovery d, String name, String filePath, String fileContent) {
  final skill = d.findSkill(name);
  if (skill == null) {
    return toolError("Skill '$name' not found");
  }
  if (_hasTraversal(filePath)) {
    return toolError('Path traversal not allowed');
  }
  final abs = p.join(skill.dir, filePath);
  try {
    Directory(p.dirname(abs)).createSync(recursive: true);
    File(abs).writeAsStringSync(fileContent, flush: true);
  } catch (e) {
    return toolError('Failed to write file: $e');
  }
  return toolResult({'success': true, 'name': name, 'file': filePath, 'action': 'write_file'});
}

String _removeSkillFile(SkillDiscovery d, String name, String filePath) {
  final skill = d.findSkill(name);
  if (skill == null) {
    return toolError("Skill '$name' not found");
  }
  if (_hasTraversal(filePath)) {
    return toolError('Path traversal not allowed');
  }
  final abs = p.join(skill.dir, filePath);
  try {
    if (File(abs).existsSync()) {
      File(abs).deleteSync();
    }
  } catch (e) {
    return toolError('Failed to remove file: $e');
  }
  return toolResult({'success': true, 'name': name, 'file': filePath, 'action': 'remove_file'});
}

bool _hasTraversal(String path) {
  return p.split(path).contains('..') || p.isAbsolute(path);
}

// =============================================================================
// Schemas + Registry
// =============================================================================

const Map<String, dynamic> skillsListSchema = {
  'name': 'skills_list',
  'description': 'List available skills with their names, descriptions, and categories.',
  'parameters': {
    'type': 'object',
    'properties': {
      'category': {
        'type': 'string',
        'description': 'Optional category filter',
      },
    },
  },
};

const Map<String, dynamic> skillViewSchema = {
  'name': 'skill_view',
  'description': 'View a skill\'s full content (SKILL.md) and linked support files.',
  'parameters': {
    'type': 'object',
    'properties': {
      'name': {
        'type': 'string',
        'description': 'Skill name or category/name',
      },
      'file_path': {
        'type': 'string',
        'description': 'Optional specific file path within a skill',
      },
    },
  },
};

const Map<String, dynamic> skillManageSchema = {
  'name': 'skill_manage',
  'description':
      'Manage skills (create, patch, edit, delete, write_file, remove_file). '
      'Skills are procedural memory — reusable approaches for recurring task types. '
      'create: full SKILL.md with YAML frontmatter (name, description ≤60 chars for new). '
      'patch: old_string/new_string fuzzy edit. edit: full rewrite. delete: remove. '
      'Confirm with user before creating/deleting.',
  'parameters': {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['create', 'patch', 'edit', 'delete', 'write_file', 'remove_file'],
        'description': 'The action to perform',
      },
      'name': {
        'type': 'string',
        'description': 'Skill name (lowercase, hyphens/underscores, max 64 chars)',
      },
      'content': {
        'type': 'string',
        'description': 'Full SKILL.md content (YAML frontmatter + markdown body)',
      },
      'category': {
        'type': 'string',
        'description': 'Optional category for new skills',
      },
      'old_string': {
        'type': 'string',
        'description': 'Text to find for patch action',
      },
      'new_string': {
        'type': 'string',
        'description': 'Replacement text for patch action',
      },
      'replace_all': {
        'type': 'boolean',
        'description': 'Replace all occurrences for patch (default false)',
        'default': false,
      },
      'file_path': {
        'type': 'string',
        'description': 'File path within skill for write_file/remove_file',
      },
      'file_content': {
        'type': 'string',
        'description': 'File content for write_file action',
      },
    },
    'required': ['action', 'name'],
  },
};

/// 注册三个 skill 工具。
void registerSkillTools({required String skillsRoot}) {
  Services.instance.skillDiscovery = SkillDiscovery(skillsRoot: skillsRoot);
  registry.register(
    name: 'skills_list',
    toolset: 'skills',
    schema: skillsListSchema,
    handler: (args, [kwargs]) {
      return skillsListTool(category: args['category'] as String?);
    },
    checkFn: () => Services.instance.skillDiscovery != null,
    emoji: '📚',
  );
  registry.register(
    name: 'skill_view',
    toolset: 'skills',
    schema: skillViewSchema,
    handler: (args, [kwargs]) {
      return skillViewTool(
        name: args['name'] as String?,
        filePath: args['file_path'] as String?,
      );
    },
    checkFn: () => Services.instance.skillDiscovery != null,
    emoji: '📖',
  );
  registry.register(
    name: 'skill_manage',
    toolset: 'skills',
    schema: skillManageSchema,
    handler: (args, [kwargs]) {
      return skillManageTool(
        action: args['action'] as String? ?? '',
        name: args['name'] as String? ?? '',
        content: args['content'] as String?,
        category: args['category'] as String?,
        oldString: args['old_string'] as String?,
        newString: args['new_string'] as String?,
        replaceAll: args['replace_all'] == true,
        filePath: args['file_path'] as String?,
        fileContent: args['file_content'] as String?,
      );
    },
    checkFn: () => Services.instance.skillDiscovery != null,
    emoji: '🛠️',
  );
}
