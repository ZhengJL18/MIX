/// skill 管理页：查看/创建/删除技能。
///
/// 复用 SkillDiscovery + skills_tool.dart 的工具函数。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/services.dart';
import '../skills/skill_discovery.dart';
import '../tools/skills_tool.dart';
import '../theme/theme_ext.dart';

class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  List<SkillMeta> _skills = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final discovery = Services.instance.skillDiscovery;
    if (discovery == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _skills = discovery.findAllSkills();
      _loading = false;
    });
  }

  Future<void> _createSkill() async {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final contentController = TextEditingController();
    final categoryController = TextEditingController(text: 'general');
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创建技能'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameController, decoration: const InputDecoration(labelText: '名称（小写连字符）')),
                TextField(controller: descController, decoration: const InputDecoration(labelText: '描述（≤60 字符）')),
                TextField(controller: categoryController, decoration: const InputDecoration(labelText: '分类')),
                TextField(
                  controller: contentController,
                  maxLines: 8,
                  decoration: const InputDecoration(labelText: 'SKILL.md 内容（含 --- frontmatter ---）'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
        ],
      ),
    );
    if (created != true) return;
    final content = contentController.text.trim();
    if (content.isEmpty) {
      // 用户没填全文，用 name/desc 拼一个。
      contentController.text =
          '---\nname: ${nameController.text.trim()}\ndescription: ${descController.text.trim()}\n---\n\n# ${nameController.text.trim()}\n';
    }
    final result = skillManageTool(
      action: 'create',
      name: nameController.text.trim(),
      content: content.isEmpty
          ? '---\nname: ${nameController.text.trim()}\ndescription: ${descController.text.trim()}\n---\n'
          : content,
      category: categoryController.text.trim(),
    );
    _showResult(result);
    await _load();
  }

  Future<void> _viewSkill(SkillMeta skill) async {
    final result = skillViewTool(name: skill.name);
    final map = jsonDecode(result) as Map;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SkillViewScreen(
          name: skill.name,
          content: map['content'] as String? ?? '',
        ),
      ),
    );
  }

  Future<void> _deleteSkill(SkillMeta skill) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除技能'),
        content: Text('确定删除技能 ${skill.name} 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = skillManageTool(action: 'delete', name: skill.name);
    _showResult(result);
    await _load();
  }

  void _showResult(String result) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.length > 100 ? result.substring(0, 100) : result)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('技能管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '创建技能',
            onPressed: _createSkill,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _skills.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.menu_book, size: 56, color: context.appPalette.textSecondary),
                      SizedBox(height: 12),
                      Text('暂无技能，点右上角 + 创建'),
                    ],
                  ),
                )
              : _buildGroupedList(),
    );
  }

  /// 按分类分组的技能列表。
  Widget _buildGroupedList() {
    final groups = <String, List<SkillMeta>>{};
    for (final s in _skills) {
      final cat = s.category.isEmpty ? 'general' : s.category;
      groups.putIfAbsent(cat, () => []).add(s);
    }
    final sortedCats = groups.keys.toList()..sort();

    return ListView(
      children: [
        for (final cat in sortedCats) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Icon(
                  cat == 'general' ? Icons.category : Icons.folder,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  cat,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${groups[cat]!.length}',
                  style: TextStyle(fontSize: 12, color: context.appPalette.textSecondary),
                ),
              ],
            ),
          ),
          for (final s in groups[cat]!)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: const Icon(Icons.menu_book, size: 18),
              ),
              title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w500)),
              subtitle: Text(
                s.description.isEmpty ? '无描述' : s.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteSkill(s),
              ),
              onTap: () => _viewSkill(s),
            ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}

/// 单个 skill 详情查看。
class _SkillViewScreen extends StatelessWidget {
  final String name;
  final String content;

  const _SkillViewScreen({required this.name, required this.content});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: SelectableText(
            content,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
    );
  }
}
