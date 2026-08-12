/// 工作区选择页（Linux 桌面）：让用户选一个项目目录作为 agent 的工作目录。
///
/// 选中后调 [onWorkspaceSelected] 把 cwd 切到该目录（configureFileTools），
/// agent 的相对路径就解析到项目里了。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 工作区路径存储 key。
const String kWorkspacePathKey = 'mix_workspace_path';

/// 读取已保存的工作区路径。
Future<String?> loadWorkspacePath() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(kWorkspacePathKey);
}

/// 保存工作区路径。
Future<void> saveWorkspacePath(String path) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(kWorkspacePathKey, path);
}

/// 工作区选择页。
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, this.onWorkspaceSelected});

  /// 选中新工作区后的回调（返回新目录路径）。
  final Future<void> Function(String path)? onWorkspaceSelected;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  String? _current;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final path = await loadWorkspacePath();
    if (mounted) setState(() => _current = path);
  }

  Future<void> _pick() async {
    // 桌面端目录选择器；非桌面（Android）走手输。
    String? picked;
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      final dir = await getDirectoryPath(
        initialDirectory: _current,
        confirmButtonText: '选择此目录',
      );
      picked = dir;
    } else {
      final controller = TextEditingController(text: _current ?? '');
      picked = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('输入工作区路径'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '/path/to/project'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, controller.text),
                child: const Text('确定')),
          ],
        ),
      );
    }
    if (picked == null || picked.isEmpty || !mounted) return;

    // 校验目录存在。
    if (!Directory(picked).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('目录不存在：$picked')),
      );
      return;
    }
    setState(() => _current = picked);
    await saveWorkspacePath(picked);
    await widget.onWorkspaceSelected?.call(picked);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('工作区已切换到：$picked')),
      );
    }
  }

  Future<void> _clear() async {
    await saveWorkspacePath('');
    if (mounted) setState(() => _current = null);
    await widget.onWorkspaceSelected?.call('');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清除工作区，恢复默认目录')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('工作区')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '选择一个项目目录作为 agent 的工作目录。'
            '之后 agent 的相对路径、git 操作、文件读写都以它为根。',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('当前工作区'),
              subtitle: Text(_current ?? '（默认：应用文档目录）'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pick,
            ),
          ),
          const SizedBox(height: 8),
          if (_current != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.close),
                title: const Text('清除工作区'),
                onTap: _clear,
              ),
            ),
        ],
      ),
    );
  }
}
