/// GitHub 功能区：凭据配置 + 远程仓库浏览/克隆 + 本地仓库管理（进度/提交/推送）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/github_service.dart';
import '../tools/git_tools.dart';
import '../theme/theme_ext.dart';

class GitHubScreen extends StatefulWidget {
  const GitHubScreen({super.key});

  @override
  State<GitHubScreen> createState() => _GitHubScreenState();
}

class _GitHubScreenState extends State<GitHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  // 凭据
  GitHubCredentials? _creds;
  bool _loadingCreds = true;

  // 远程仓库
  List<GitHubRepo> _repos = [];
  bool _loadingRepos = false;
  String? _reposError;

  // 本地仓库
  List<String> _localRepos = [];
  bool _loadingLocal = false;

  final _tokenController = TextEditingController();
  final _usernameController = TextEditingController();
  bool _savingToken = false;
  String? _tokenMsg;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _loadCreds();
  }

  @override
  void dispose() {
    _tab.dispose();
    _tokenController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _loadCreds() async {
    final creds = await loadGitHubCredentials();
    if (!mounted) return;
    setState(() {
      _creds = creds;
      _loadingCreds = false;
      if (creds != null) {
        _tokenController.text = creds.token;
        _usernameController.text = creds.username;
      }
    });
  }

  Future<void> _saveToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _tokenMsg = '请输入 GitHub PAT token');
      return;
    }
    setState(() {
      _savingToken = true;
      _tokenMsg = null;
    });
    try {
      final username = await fetchGitHubUsername(token);
      await saveGitHubCredentials(token: token, username: username);
      if (!mounted) return;
      setState(() {
        _creds = GitHubCredentials(token: token, username: username);
        _usernameController.text = username;
        _savingToken = false;
        _tokenMsg = '✓ 已保存，登录为 $username';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savingToken = false;
        _tokenMsg = '✗ $e';
      });
    }
  }

  Future<void> _clearToken() async {
    await clearGitHubCredentials();
    if (!mounted) return;
    setState(() {
      _creds = null;
      _tokenController.clear();
      _usernameController.clear();
      _tokenMsg = '已清除凭据';
    });
  }

  Future<void> _fetchRepos() async {
    final creds = _creds;
    if (creds == null) {
      setState(() => _reposError = '请先在「凭据」标签配置 GitHub token');
      return;
    }
    setState(() {
      _loadingRepos = true;
      _reposError = null;
    });
    try {
      final repos = await fetchUserRepos(creds.token);
      if (!mounted) return;
      setState(() {
        _repos = repos;
        _loadingRepos = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingRepos = false;
        _reposError = '$e';
      });
    }
  }

  Future<void> _loadLocal() async {
    setState(() => _loadingLocal = true);
    final dir = await _githubRootDir();
    final local = <String>[];
    if (dir.existsSync()) {
      for (final d in dir.listSync(followLinks: false)) {
        if (d is Directory && d.path.endsWith('.git')) continue;
        if (d is Directory && Directory('${d.path}/.git').existsSync()) {
          local.add(d.path);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _localRepos = local;
      _loadingLocal = false;
    });
  }

  Future<Directory> _githubRootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/github');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _cloneRepo(GitHubRepo repo) async {
    final creds = _creds;
    final root = await _githubRootDir();
    final destDir = '${root.path}/${repo.name}';
    if (Directory(destDir).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${repo.name} 已存在')));
      return;
    }
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(),
      ),
    );
    await ensureGitSsl();
    final result = await gitClone(
      url: repo.cloneUrl ?? 'https://github.com/${repo.fullName}.git',
      localPath: destDir,
      token: creds?.token,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result)),
    );
    await _loadLocal();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('GitHub'),
          bottom: TabBar(
            controller: _tab,
            tabs: const [
              Tab(text: '凭据', icon: Icon(Icons.key)),
              Tab(text: '远程', icon: Icon(Icons.cloud_outlined)),
              Tab(text: '本地', icon: Icon(Icons.folder_outlined)),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tab,
          children: [
            _buildCredentials(),
            _buildRemote(),
            _buildLocal(),
          ],
        ),
      ),
    );
  }

  Widget _buildCredentials() {
    if (_loadingCreds) {
      return const Center(child: CircularProgressIndicator());
    }
    final configured = _creds != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.person, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      configured ? '已登录：${_creds!.username}' : '未配置凭据',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _tokenController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'GitHub PAT token',
                    hintText: 'ghp_... 或 github_pat_...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: '用户名（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                if (_tokenMsg != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_tokenMsg!, style: const TextStyle(fontSize: 12)),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _savingToken ? null : _saveToken,
                        icon: const Icon(Icons.save),
                        label: const Text('保存并验证'),
                      ),
                    ),
                    if (configured) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _clearToken,
                        icon: Icon(Icons.logout, color: context.appPalette.danger),
                        tooltip: '清除凭据',
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            'Token 只保存在本机（SharedPreferences），用于 GitHub API 和 HTTPS git 推送。',
            style: TextStyle(fontSize: 12, color: context.appPalette.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _buildRemote() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _loadingRepos ? null : _fetchRepos,
                  icon: const Icon(Icons.refresh),
                  label: const Text('加载我的仓库'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loadingRepos
              ? const Center(child: CircularProgressIndicator())
              : _reposError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline, color: context.appPalette.danger, size: 40),
                            const SizedBox(height: 8),
                            Text(_reposError!, textAlign: TextAlign.center),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: _fetchRepos,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _repos.isEmpty
                      ? const Center(child: Text('点「加载我的仓库」开始'))
                      : ListView.builder(
                          itemCount: _repos.length,
                          itemBuilder: (context, i) {
                            final r = _repos[i];
                            return ListTile(
                              leading: const Icon(Icons.code),
                              title: Text(r.fullName),
                              subtitle: Text(
                                (r.description.isEmpty ? '无描述' : r.description),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(Icons.download, color: context.appPalette.primary),
                                    tooltip: '克隆到本地',
                                    onPressed: () => _cloneRepo(r),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }

  Widget _buildLocal() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _loadingLocal ? null : _loadLocal,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新本地仓库'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loadingLocal
              ? const Center(child: CircularProgressIndicator())
              : _localRepos.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.folder_open, size: 48, color: context.appPalette.textSecondary),
                          SizedBox(height: 8),
                          Text('暂无本地仓库，去「远程」克隆一个'),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _localRepos.length,
                      itemBuilder: (context, i) {
                        final path = _localRepos[i];
                        final name = path.split(Platform.pathSeparator).last;
                        return ListTile(
                          leading: Icon(Icons.folder, color: context.appPalette.accent),
                          title: Text(name),
                          subtitle: Text(path),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => LocalRepoScreen(path: path),
                              ),
                            );
                          },
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

/// 本地仓库详情：状态 / 提交 / 推送。
class LocalRepoScreen extends StatefulWidget {
  final String path;
  const LocalRepoScreen({super.key, required this.path});

  @override
  State<LocalRepoScreen> createState() => _LocalRepoScreenState();
}

class _LocalRepoScreenState extends State<LocalRepoScreen> {
  String _status = '';
  String _log = '';
  bool _loading = true;
  bool _busy = false;
  String _result = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
    });
    final status = await gitStatus(path: widget.path);
    final log = await gitLog(path: widget.path, limit: 15);
    if (!mounted) return;
    setState(() {
      _status = status;
      _log = log;
      _loading = false;
    });
  }

  Future<void> _doAction(String action) async {
    final creds = await loadGitHubCredentials();
    setState(() {
      _busy = true;
      _result = '';
    });
    String result;
    switch (action) {
      case 'commit':
        result = await gitAdd(path: widget.path, files: const ['.']);
        result += '\n${await gitCommit(path: widget.path, message: 'MIX: auto commit')}';
        break;
      case 'push':
        result = await gitPush(path: widget.path, token: creds?.token);
        break;
      case 'pull':
        result = await gitPull(path: widget.path, token: creds?.token);
        break;
      default:
        result = '';
    }
    if (!mounted) return;
    final status = await gitStatus(path: widget.path);
    final log = await gitLog(path: widget.path, limit: 15);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
      _status = status;
      _log = log;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('仓库：${widget.path.split(Platform.pathSeparator).last}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _doAction('commit'),
                        icon: const Icon(Icons.commit),
                        label: const Text('提交'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _doAction('push'),
                        icon: const Icon(Icons.upload),
                        label: const Text('推送'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _doAction('pull'),
                        icon: const Icon(Icons.download),
                        label: const Text('拉取'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_busy) const LinearProgressIndicator(),
                if (_result.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(_result, style: const TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                const Text('状态', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(_status, style: const TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('最近提交', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(_log, style: const TextStyle(fontSize: 13)),
                  ),
                ),
              ],
            ),
    );
  }
}
