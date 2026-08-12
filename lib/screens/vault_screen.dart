/// 云端保险柜：注册/登录 + 加密上传/下载备份。
///
/// 不登录不影响软件其他功能，保险柜是独立的功能。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/vault_service.dart';
import '../theme/theme_ext.dart';

class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final _serverController = TextEditingController();
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _secretController = TextEditingController();
  VaultConfig? _config; // 已登录的配置（null = 未登录）。
  bool _loading = true;
  bool _busy = false;
  bool _isRegister = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _serverController.dispose();
    _nameController.dispose();
    _passwordController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await loadVaultConfig();
    if (!mounted) return;
    setState(() {
      _config = cfg;
      if (cfg == null) {
        _serverController.text = officialVaultUrl;
      } else {
        _serverController.text = cfg.serverUrl;
        _nameController.text = cfg.accountName;
      }
      _loading = false;
    });
  }

  void _setMsg(String m) {
    if (!mounted) return;
    setState(() => _msg = m);
  }

  /// 注册或登录。
  Future<void> _authenticate() async {
    final url = _serverController.text.trim().replaceAll(RegExp(r'/+$'), '');
    final name = _nameController.text.trim();
    final password = _passwordController.text;
    if (url.isEmpty || name.isEmpty || password.isEmpty) {
      _setMsg('请填写服务器地址、保险柜名和密码');
      return;
    }
    setState(() {
      _busy = true;
      _msg = _isRegister ? '注册中…' : '登录中…';
    });
    try {
      final token = _isRegister
          ? await registerVaultAccount(
              serverUrl: url, name: name, password: password)
          : await loginVaultAccount(
              serverUrl: url, name: name, password: password);
      final cfg = VaultConfig(
        serverUrl: url,
        accountName: name.toLowerCase(),
        sessionToken: token,
      );
      await saveVaultConfig(cfg);
      if (!mounted) return;
      setState(() {
        _config = cfg;
        _busy = false;
        _msg = _isRegister ? '✓ 注册成功，已登录' : '✓ 登录成功';
      });
    } on VaultAuthException catch (e) {
      _setMsg('✗ $e');
      setState(() => _busy = false);
    } catch (e) {
      _setMsg('✗ $e');
      setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    await clearVaultConfig();
    if (!mounted) return;
    setState(() {
      _config = null;
      _passwordController.clear();
      _secretController.clear();
      _msg = '已退出登录';
    });
  }

  /// 列出 documents 顶层可备份目录（跳过隐藏/缓存/仓库根），供用户勾选。
  List<String> _listBackupCandidates(String basePath) {
    const skipNames = {'.git', '.dart_tool', 'build', 'third_party', 'site',
      'cache', 'remote_assets', 'refine', 'skills'};
    final out = <String>[];
    try {
      for (final e in Directory(basePath).listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = e.path.split('/').last;
        if (name.startsWith('.') || skipNames.contains(name)) continue;
        if (Directory('${e.path}/.git').existsSync()) continue; // 仓库根
        out.add(name);
      }
    } catch (_) {}
    return out;
  }

  Future<void> _upload() async {
    final cfg = _config;
    if (cfg == null) return;
    final secret = _secretController.text.trim();
    if (secret.isEmpty) {
      _setMsg('请设置保险柜加密密钥（用于加密备份数据）');
      return;
    }
    // 让用户选要备份的文件夹；取消则不上传。
    final selected = await _selectBackupFolders();
    if (selected == null) return;
    setState(() {
      _busy = true;
      _msg = '打包并加密中…';
    });
    try {
      final payload = await buildBackupPayload(includePaths: selected);
      final encrypted = encryptPayload(payload, secret);
      setState(() => _msg = '上传中…');
      await uploadBackup(cfg, encrypted);
      _setMsg('✓ 备份已上传（${encrypted.length} 字节，已加密）');
    } catch (e) {
      _setMsg('✗ 上传失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 备份文件夹选择对话框（默认全选可取消勾选）。
  Future<List<String>?> _selectBackupFolders() async {
    final base = (await getApplicationDocumentsDirectory()).path;
    if (!mounted) return null;
    final candidates = _listBackupCandidates(base);
    if (candidates.isEmpty) {
      return const <String>[];
    }
    final selected = <String>{...candidates};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('选择要备份的文件夹'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final d in candidates)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(d),
                      value: selected.contains(d),
                      onChanged: (v) => setDialogState(() {
                        if (v == true) {
                          selected.add(d);
                        } else {
                          selected.remove(d);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return null;
    return selected.toList();
  }

  Future<void> _download() async {
    final cfg = _config;
    if (cfg == null) return;
    final secret = _secretController.text.trim();
    if (secret.isEmpty) {
      _setMsg('请输入保险柜加密密钥');
      return;
    }
    setState(() {
      _busy = true;
      _msg = '下载中…';
    });
    try {
      final encrypted = await downloadBackup(cfg);
      setState(() => _msg = '解密中…');
      final payload = decryptPayload(encrypted, secret);
      await _restorePayload(payload);
      _setMsg('✓ 已恢复备份');
    } on FormatException {
      _setMsg('✗ 解密失败：密钥错误或数据损坏');
    } on HttpException catch (e) {
      _setMsg('✗ $e');
    } catch (e) {
      _setMsg('✗ 下载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restorePayload(Map<String, dynamic> payload) async {
    final dir = await _getDocsDir();
    final dbB64 = payload['state_db'];
    if (dbB64 is String) {
      final bytes = base64Decode(dbB64);
      await File('${dir.path}/state.db').writeAsBytes(bytes);
    }
    final files = payload['files'];
    if (files is Map<String, dynamic>) {
      for (final entry in files.entries) {
        final relPath = entry.key;
        final content = entry.value;
        if (content is! String) continue;
        final target = File('${dir.path}/$relPath');
        if (!target.path.startsWith(dir.path)) continue;
        await target.create(recursive: true);
        await target.writeAsString(content);
      }
    }
  }

  Future<Directory> _getDocsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(docs.path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('云端保险柜')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _config == null
                        ? _buildLogin()
                        : _buildVault(),
                  ),
                ),
              ],
            ),
    );
  }

  /// 未登录：注册/登录表单。
  Widget _buildLogin() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '云端保险柜需要注册/登录使用（不影响其他功能）。'
          '保险柜名唯一，注册时若被占用会提示。',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _serverController,
          decoration: const InputDecoration(
            labelText: '服务器地址',
            hintText: 'https://...',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: '保险柜名',
            hintText: '2-32 位字母/数字/_-',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _passwordController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '密码',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (_msg != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_msg!, style: const TextStyle(fontSize: 12)),
          ),
        if (_busy) const LinearProgressIndicator(),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _authenticate,
          icon: Icon(_isRegister ? Icons.person_add : Icons.login),
          label: Text(_isRegister ? '注册' : '登录'),
        ),
        TextButton(
          onPressed: _busy ? null : () => setState(() {
            _isRegister = !_isRegister;
            _msg = null;
          }),
          child: Text(_isRegister
              ? '已有保险柜？去登录'
              : '还没有保险柜？去注册'),
        ),
      ],
    );
  }

  /// 已登录：保险柜操作。
  Widget _buildVault() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.vpn_key, size: 18),
            const SizedBox(width: 6),
            Text('已登录：${_config!.accountName}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton(
              onPressed: _busy ? null : _logout,
              child: const Text('退出登录'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _secretController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '保险柜加密密钥',
            hintText: '自设密钥，用于加密备份数据，务必记住',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (_msg != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_msg!, style: const TextStyle(fontSize: 12)),
          ),
        if (_busy) const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _upload,
                icon: const Icon(Icons.upload),
                label: const Text('上传备份'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _download,
                style: FilledButton.styleFrom(
                  backgroundColor: context.appPalette.primary,
                ),
                icon: const Icon(Icons.download),
                label: const Text('下载恢复'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
