/// 设置页：provider/vendor 下拉 + 模型 + API key + 自定义 baseUrl。
///
/// UI 是新设计（Hermes 无移动端配置页），但 vendor/模型映射来自
/// [providers.dart] 复刻的解析链。
library;

import 'package:flutter/material.dart';

import '../config/mix_config.dart';
import '../services/storage_permission.dart';
import 'department_screen.dart';
import 'fast_model_screen.dart';
import 'github_screen.dart';
import 'history_screen.dart';
import 'memory_screen.dart';
import 'skills_screen.dart';
import 'theme_screen.dart';
import 'vault_screen.dart';
import 'vision_settings_screen.dart';
import 'webview_login_screen.dart';
import '../main.dart' show checkUpdateHandler;
import '../printnotes/constants/constants.dart' as pn;
import '../printnotes/ui/screens/settings/settings_screen.dart' as printnotes;
import '../theme/theme_ext.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _modelController = TextEditingController();
  String _vendor = '';
  String _model = '';
  String _apiKey = '';
  String _baseUrl = '';
  bool _loading = true;
  // 从 /models 拉取的动态模型列表；null = 未拉取/失败。
  List<String>? _fetchedModels;
  bool _fetchingModels = false;
  String? _modelFetchError;
  // 所有文件访问权限状态。
  bool _externalGranted = false;
  bool _checkingExternal = true;
  // 各流程思考强度滑块值（flowId → 0-100）。
  final Map<String, int> _efforts = {};

  @override
  void initState() {
    super.initState();
    _load();
    _loadEfforts();
  }

  /// 加载各流程思考强度档位。
  Future<void> _loadEfforts() async {
    final values = <String, int>{};
    for (final f in MIXConfig.effortFlows) {
      values[f.id] = await MIXConfig.loadEffort(f.id);
    }
    if (mounted) setState(() => _efforts.addAll(values));
  }

  @override
  void dispose() {
    _modelController.dispose();
    super.dispose();
  }

  /// 设置模型并同步输入框显示。
  void _setModel(String v) {
    setState(() => _model = v);
    if (_modelController.text != v) {
      _modelController.text = v;
    }
  }

  /// 从 provider 的 /models 端点刷新模型列表。
  Future<void> _refreshModels() async {
    if (_fetchingModels) return;
    final config = MIXConfig(
      vendorId: _vendor,
      model: _model,
      apiKey: _apiKey.trim(),
      baseUrl: _baseUrl.trim(),
    );
    setState(() {
      _fetchingModels = true;
      _modelFetchError = null;
    });
    final models = await config.fetchModels();
    if (!mounted) return;
    setState(() {
      _fetchingModels = false;
      if (models != null && models.isNotEmpty) {
        _fetchedModels = models;
        // 若当前模型不在新列表且预设列表也没有，自动选第一个。
        if (!models.contains(_model) &&
            !(vendorModels[_vendor]?.contains(_model) ?? false)) {
          _setModel(models.first);
        }
      } else {
        _modelFetchError = '拉取失败（检查 API Key 或网络）';
      }
    });
  }

  Future<void> _load() async {
    final config = await MIXConfig.load();
    setState(() {
      if (config != null) {
        _vendor = config.vendorId;
        _model = config.model;
        _apiKey = config.apiKey;
        _baseUrl = config.baseUrl;
      } else {
        _vendor = 'deepseek';
        _model = 'deepseek-chat';
      }
      _modelController.text = _model;
      _loading = false;
    });
    _checkExternalPermission();
  }

  /// 检测「所有文件访问」权限并同步开关。
  Future<void> _checkExternalPermission() async {
    final granted = await isExternalStorageGranted();
    if (!mounted) return;
    setState(() {
      _externalGranted = granted;
      _checkingExternal = false;
    });
  }

  /// 打开系统设置页授予「所有文件访问」，返回后重新检测。
  Future<void> _requestExternalPermission() async {
    await openManageExternalStorageSettings();
    await _checkExternalPermission();
    // 同步 file_tools 外部访问开关。
    await syncExternalAccessPermission();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final config = MIXConfig(
      vendorId: _vendor,
      model: _model,
      apiKey: _apiKey.trim(),
      baseUrl: _baseUrl.trim(),
    );
    await config.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存配置')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final models = vendorModels[_vendor] ?? const <String>[];
    final labels = vendorLabels;

    return Scaffold(
      appBar: AppBar(title: const Text('MIX 设置')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // vendor 下拉。
            DropdownButtonFormField<String>(
              initialValue: _vendor,
              decoration: const InputDecoration(
                labelText: 'AI 厂商',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final entry in labels.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _vendor = v;
                  // 切换厂商时自动选默认模型，清空已拉取的模型列表。
                  _fetchedModels = null;
                  _modelFetchError = null;
                  final m = vendorModels[v];
                  if (m != null && m.isNotEmpty) {
                    _setModel(m.first);
                  } else {
                    _setModel('');
                  }
                });
              },
            ),
            const SizedBox(height: 12),
            // 模型（可编辑文本，onChanged 同步 _model）。
            TextFormField(
              controller: _modelController,
              decoration: const InputDecoration(
                labelText: '模型',
                border: OutlineInputBorder(),
                helperText: '可用模型（预设）',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入模型' : null,
              onChanged: (v) => _model = v.trim(),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _fetchedModels != null
                        ? '已刷新 ${_fetchedModels!.length} 个模型'
                        : (_modelFetchError ?? ''),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton.icon(
                  icon: _fetchingModels
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: Text(_fetchingModels ? '刷新中…' : '刷新模型'),
                  onPressed: _fetchingModels ? null : _refreshModels,
                ),
              ],
            ),
            // 显示模型 chips：刷新后的动态列表优先，否则预设列表。
            if ((_fetchedModels ?? models).isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: [
                  for (final m in (_fetchedModels ?? models))
                    ChoiceChip(
                      label: Text(m),
                      selected: _model == m,
                      onSelected: (_) => _setModel(m),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            // API key。
            TextFormField(
              initialValue: _apiKey,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入 API Key' : null,
              onChanged: (v) => _apiKey = v,
            ),
            const SizedBox(height: 12),
            // 自定义 baseUrl（可选）。
            TextFormField(
              initialValue: _baseUrl,
              decoration: const InputDecoration(
                labelText: '自定义 Base URL（可选）',
                border: OutlineInputBorder(),
                hintText: '留空用厂商默认',
              ),
              onChanged: (v) => _baseUrl = v,
            ),
            const SizedBox(height: 24),
            // ── 权限与账户 ──
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('权限与账户',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: _checkingExternal
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _externalGranted
                                ? Icons.verified_user
                                : Icons.folder_open,
                            color: _externalGranted
                                ? context.appPalette.success
                                : Theme.of(context).colorScheme.primary,
                          ),
                    title: const Text('所有文件访问权限'),
                    subtitle: Text(
                      _checkingExternal
                          ? '检查中…'
                          : _externalGranted
                              ? '已授予 —— agent 可读写公共目录（Download/Documents）'
                              : '未授予 —— agent 只能访问 App 自己的文件空间',
                    ),
                    trailing: _checkingExternal
                        ? null
                        : _externalGranted
                            ? Icon(Icons.check,
                                color: context.appPalette.success)
                            : TextButton(
                                onPressed: _requestExternalPermission,
                                child: const Text('去授权'),
                              ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.login),
                    title: const Text('网页登录'),
                    subtitle: const Text('登录后爬虫自动带登录态'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const WebViewLoginScreen()),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // ── 模型与智能 ──
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('模型与智能',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.visibility),
                    title: const Text('视觉模型'),
                    subtitle: const Text('配置 vision_analyze 的图像分析模型'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const VisionSettingsScreen()),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.bolt),
                    title: const Text('快速模型'),
                    subtitle: const Text('配置 delegate 子任务用的快/便宜模型'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const FastModelScreen()),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.apartment),
                    title: const Text('部门管理'),
                    subtitle: const Text('配置公司模式的部门（角色/工具）'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const DepartmentScreen()),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.sticky_note_2_outlined),
                    title: const Text('记忆管理'),
                    subtitle: const Text('查看/编辑 agent 的长期记忆'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const MemoryScreen()),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // ── 内容与数据 ──
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('内容与数据',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.notes),
                    title: const Text('笔记设置'),
                    subtitle: const Text('排序 / 布局 / LaTeX / 代码块主题'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const printnotes.SettingsScreen()),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: const Text('对话历史'),
                    subtitle: const Text('浏览 / 查看 / 删除历史会话'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const HistoryScreen()),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.menu_book),
                    title: const Text('技能管理'),
                    subtitle: const Text('查看 / 创建 / 删除技能'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SkillsScreen()),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.shield_outlined),
                    title: const Text('云端保险柜'),
                    subtitle: const Text('加密备份到你的云服务器（存档式）'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const VaultScreen()),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 思考强度：各流程独立滑块（0-100，左右拖动）。
            Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      '思考强度',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      '各流程的推理深度，向左更省时省 token，向右更深入',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  for (final flow in MIXConfig.effortFlows)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 110,
                            child: Text(flow.label,
                                style:
                                    const TextStyle(fontSize: 13)),
                          ),
                          Expanded(
                            child: Slider(
                              value:
                                  (_efforts[flow.id] ?? flow.defaultValue)
                                      .toDouble(),
                              min: 0,
                              max: 100,
                              divisions: 4,
                              label: MIXConfig.effortValueLabel(
                                  _efforts[flow.id] ?? flow.defaultValue),
                              onChanged: (v) {
                                final rounded = v.round();
                                setState(() => _efforts[flow.id] = rounded);
                                MIXConfig.saveEffort(flow.id, rounded);
                              },
                            ),
                          ),
                          SizedBox(
                            width: 36,
                            child: Text(
                              MIXConfig.effortValueLabel(
                                  _efforts[flow.id] ?? flow.defaultValue),
                              textAlign: TextAlign.end,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // ── 外观与系统 ──
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('外观与系统',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            // 系统：主题 / 检查更新 / GitHub / 版本。
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('主题'),
                    subtitle: const Text('配色方案 + 明暗模式'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ThemeScreen()),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.system_update_alt),
                    title: const Text('检查更新'),
                    subtitle: const Text('检查 MIX 是否有新版本'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => checkUpdateHandler?.call(),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.code),
                    title: const Text('GitHub'),
                    subtitle: const Text('项目仓库'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const GitHubScreen()),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('版本'),
                    subtitle: Text('v${pn.appVersion}'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
            const SizedBox(height: 8),
            Text(
              '所有配置仅存本机（SharedPreferences）。'
              '厂商/模型映射来自 Hermes providers 解析链复刻。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
