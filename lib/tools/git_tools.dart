/// Git 工具集 — 基于 libgit2（git2dart 绑定），agent 用 git 写代码。
///
/// 在 App 沙盒进程内 dlopen libgit2，不 exec 外部进程、不突破隔离墙。
/// 覆盖 agent 写代码核心操作 + GitHub 远程同步。
library;

import 'dart:io';

import 'package:git2dart/git2dart.dart';
import 'package:git2dart_binaries/git2dart_binaries.dart'
    show AndroidSSLHelper;

import '../services/github_service.dart';
import 'registry.dart';

bool _sslInitialized = false;

/// 默认 git 工作目录（工作区设置后，git 工具 path 可省略）。
String? _gitCwd;

/// 设置 git 默认工作目录（工作区切换时调用）。
void setGitCwd(String? path) {
  _gitCwd = path;
}

/// git 工具路径解析：path 为空时用默认工作目录。
String _resolvePath(String? path) {
  if (path != null && path.trim().isNotEmpty) return path.trim();
  if (_gitCwd != null && _gitCwd!.isNotEmpty) return _gitCwd!;
  return Directory.current.path;
}

/// 解析 git 认证 token：显式传入的 token 优先；否则自动读 SharedPreferences
/// 里配置的 GitHub PAT（flutter.github_pat_token），避免 git push 需要认证时
/// 还要用户单独把 token 告诉 agent。
///
/// **代码规范**：所有需要 GitHub 认证的工具一律走 [_resolveToken]，
/// 不要求 agent 在参数里手动填 token（配置里已有就直接用）。
Future<String?> _resolveToken(String? explicit) async {
  if (explicit != null && explicit.isNotEmpty) return explicit;
  try {
    final creds = await loadGitHubCredentials();
    return creds?.token;
  } catch (_) {
    return null;
  }
}

/// github_ci_logs：读取 GitHub Actions CI 运行状态与失败日志。
/// 用配置里的 PAT 自动认证（走 [_resolveToken]），不要求手动传 token。
Future<String> _handleCiLogs(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  final repo = (args['repo'] as String? ?? 'ZhengJL18/MIX').trim();
  final runId = (args['run_id'] as num?)?.toInt();
  final token = await _resolveToken(args['token'] as String?);
  if (token == null || token.isEmpty) {
    return toolError('github_ci_logs: 未配置 GitHub PAT（设置 → GitHub 里填）');
  }
  try {
    final runs = await fetchWorkflowRuns(token, repo);
    if (runs.isEmpty) return toolResult({'repo': repo, 'runs': [], 'hint': '没有 CI 运行记录'});

    // 选要看的运行：显式 run_id，否则最新一条失败/进行中的运行。
    var run = runs.first;
    if (runId != null) {
      final found = runs.where((r) => r['run_id'] == runId).toList();
      if (found.isNotEmpty) {
        run = found.first;
      } else {
        return toolError('github_ci_logs: 未找到 run_id=$runId（最近 ${runs.length} 条里）');
      }
    }
    final targetRunId = run['run_id'] as int;
    final conclusion = run['conclusion'] ?? run['status'];

    if (conclusion == 'success') {
      return toolResult({
        'repo': repo,
        'run_id': targetRunId,
        'name': run['name'],
        'conclusion': conclusion,
        'runs': runs,
        'hint': '该次 CI 成功，无报错日志。',
      });
    }

    // 找失败的 job → 第一个失败的 step → 拉日志。
    final jobs = await fetchRunJobs(token, repo, targetRunId);
    final failedJobs =
        jobs.where((j) => j['conclusion'] == 'failure').toList();
    if (failedJobs.isEmpty) {
      return toolResult({
        'repo': repo,
        'run_id': targetRunId,
        'conclusion': conclusion,
        'runs': runs,
        'jobs': jobs,
        'hint': '没有标记为 failure 的 job（可能在跑或 cancelled）',
      });
    }
    final job = failedJobs.first;
    final failedSteps = (job['steps'] as List)
        .where((s) => s['conclusion'] == 'failure')
        .toList();
    final stepName = failedSteps.isNotEmpty
        ? (failedSteps.first['name'] as String)
        : ((job['steps'] as List).isNotEmpty
            ? (job['steps'].last['name'] as String)
            : '');
    final log = stepName.isNotEmpty
        ? await fetchRunStepLog(
            token, repo, targetRunId, job['name'] as String, stepName)
        : '';

    // 截断日志，只保留尾部最有用的部分。
    const maxChars = 12000;
    final trimmed = log.length > maxChars
        ? '...[前 ${log.length - maxChars} 字符已省略]...\n${log.substring(log.length - maxChars)}'
        : log;

    return toolResult({
      'repo': repo,
      'run_id': targetRunId,
      'name': run['name'],
      'conclusion': conclusion,
      'failed_job': job['name'],
      'failed_step': stepName,
      'runs': runs,
      'jobs': jobs,
      'log': trimmed,
      'hint': '失败步骤日志已附上（尾部 ${maxChars} 字符）。',
    });
  } catch (e) {
    return toolError('github_ci_logs failed: $e');
  }
}

/// 初始化 libgit2 的 SSL 证书配置（Android 必需）。
///
/// Android 系统证书存储不在标准路径，libgit2 默认找不到 CA → HTTPS 报
/// "SSL certificate invalid"。git2dart_binaries 打包了 cacert.pem，需手动
/// 提取并设置。顺序：先触发 libgit2 init，再提取证书，再 setSSLCertLocations。
Future<void> ensureGitSsl() async {
  if (_sslInitialized) return;
  if (Platform.isAndroid) {
    // 1. 触发 libgit2 初始化（任何静态访问都会做）。
    Libgit2.version;
    // 2. 提取打包的 CA bundle 到 cache。
    final certPath = await AndroidSSLHelper.initialize();
    // 3. 配置 libgit2 使用它。
    Libgit2.setSSLCertLocations(file: certPath);
  }
  _sslInitialized = true;
}

/// libgit2 版本（验证加载）。
String gitVersion() {
  return 'libgit2 ${Libgit2.version}';
}

/// git init：在 [path] 初始化仓库。
String gitInit({required String path}) {
  try {
    Repository.initBasic(path: path, bare: false);
    return 'Initialized empty Git repository at $path';
  } catch (e) {
    return toolError('git init failed: $e');
  }
}

/// git status：工作区状态（改动文件 + 是否已暂存）。
String gitStatus({required String path}) {
  try {
    final repo = Repository.open(path);
    final lines = <String>[];
    // 暂存区（index）相对 HEAD 的差异。
    final head = _tryHeadOid(repo);
    if (head == null) {
      lines.add('* 新仓库，尚无提交');
    }
    lines.add('* 暂存区文件:');
    for (final e in repo.index) {
      lines.add('  - ${e.path}');
    }
    // 工作区改动：比较 index 与工作树。git2dart 的 status 需遍历 diff，
    // 简化：列出工作区所有文件与 index 的差异。
    final status = _statusEntries(repo);
    if (status.isEmpty) {
      lines.add('* 无未暂存改动');
    } else {
      lines.add('* 未暂存改动:');
      for (final s in status) {
        lines.add('  - ${s.path}');
      }
    }
    // 未跟踪文件（untracked）：工作区有、index 没有的新文件。
    final untracked = _untrackedFiles(repo);
    if (untracked.isNotEmpty) {
      lines.add('* 未跟踪文件:');
      for (final u in untracked) {
        lines.add('  - $u');
      }
    }
    return lines.join('\n');
  } catch (e) {
    return toolError('git status failed: $e');
  }
}

/// git add：暂存文件。[files] 为空时暂存全部。
String gitAdd({required String path, List<String> files = const []}) {
  try {
    final repo = Repository.open(path);
    repo.index.addAll(files.isEmpty ? const ['.'] : files);
    repo.index.write();
    return 'Staged ${files.isEmpty ? 'all files' : files.join(', ')}';
  } catch (e) {
    return toolError('git add failed: $e');
  }
}

/// git commit：提交暂存区。
String gitCommit({
  required String path,
  required String message,
  String? authorName,
  String? authorEmail,
}) {
  try {
    final repo = Repository.open(path);
    final index = repo.index;
    // 写 tree。
    final treeOid = index.writeTree(repo);
    final tree = Tree.lookup(repo: repo, oid: treeOid);
    // 父提交（HEAD 指向的 commit）。
    final parents = <Commit>[];
    final headOid = _tryHeadOid(repo);
    if (headOid != null) {
      parents.add(Commit.lookup(repo: repo, oid: headOid));
    }
    // 签名：优先自定义，否则仓库配置默认。
    final signature = _makeSignature(repo, authorName, authorEmail);
    final oid = Commit.create(
      repo: repo,
      updateRef: 'HEAD',
      author: signature,
      committer: signature,
      message: message,
      tree: tree,
      parents: parents,
    );
    return 'Committed ${oid.toString().substring(0, 7)}: $message';
  } catch (e) {
    return toolError('git commit failed: $e');
  }
}

/// git log：提交历史。
String gitLog({required String path, int limit = 20}) {
  try {
    final repo = Repository.open(path);
    final walker = RevWalk(repo);
    walker.pushHead();
    final commits = walker.walk(limit: limit);
    if (commits.isEmpty) {
      return 'No commits yet.';
    }
    final lines = <String>[];
    for (final c in commits) {
      final short = c.oid.toString().substring(0, 7);
      final msg = c.message.trim().split('\n').first;
      final when = DateTime.fromMillisecondsSinceEpoch(c.time * 1000)
          .toLocal()
          .toString()
          .substring(0, 16);
      lines.add('$short $when $msg');
    }
    return lines.join('\n');
  } catch (e) {
    return toolError('git log failed: $e');
  }
}

/// git branch：分支列表。
String gitBranch({required String path}) {
  try {
    final repo = Repository.open(path);
    final current = _tryHeadBranchName(repo);
    final branches = repo.branchesLocal;
    if (branches.isEmpty) {
      return 'No branches yet.';
    }
    final lines = <String>[];
    for (final b in branches) {
      final name = b.name;
      final mark = name == current ? '* ' : '  ';
      lines.add('$mark$name');
    }
    return lines.join('\n');
  } catch (e) {
    return toolError('git branch failed: $e');
  }
}

// ============================================================================
// helpers
// ============================================================================

Oid? _tryHeadOid(Repository repo) {
  try {
    return repo.head.target;
  } catch (_) {
    return null;
  }
}

String? _tryHeadBranchName(Repository repo) {
  try {
    return repo.head.name;
  } catch (_) {
    return null;
  }
}

/// 列出工作区里未被 index 跟踪的新文件（untracked）。
/// 手动栈遍历：先列顶层跳过 .git，再递归子目录，最多收集 50 个就停。
/// （`listSync(recursive)` 会把 .git 下几百个对象文件也全量列出来，
/// 4GB 设备上白白多建大量 FileSystemEntity。）
List<String> _untrackedFiles(Repository repo) {
  final root = repo.path; // 通常是 <repo>/.git/
  final workdir = root.endsWith('/.git/')
      ? root.substring(0, root.length - 5)
      : root.replaceAll(RegExp(r'/+$'), '');
  final indexed = <String>{for (final e in repo.index) e.path};
  final untracked = <String>[];
  try {
    final stack = <String>[workdir];
    while (stack.isNotEmpty && untracked.length < 50) {
      final dir = stack.removeLast();
      final entries = Directory(dir).listSync(followLinks: false);
      for (final entry in entries) {
        if (untracked.length >= 50) break;
        final rel =
            entry.path.substring(workdir.length + 1).replaceAll('\\', '/');
        if (entry is Directory) {
          if (rel == '.git' || rel.startsWith('.git/')) continue;
          stack.add(entry.path);
        } else if (entry is File) {
          if (!indexed.contains(rel)) {
            untracked.add(rel);
          }
        }
      }
    }
  } catch (_) {}
  return untracked;
}

Signature _makeSignature(Repository repo, String? name, String? email) {
  if (name != null && email != null) {
    return Signature.create(name: name, email: email);
  }
  try {
    return Signature.defaultSignature(repo);
  } catch (_) {
    return Signature.create(
      name: name ?? 'MIX',
      email: email ?? 'mix@localhost',
    );
  }
}

/// 简化 status：列出 index 里相对 HEAD 有差异的路径。
/// git2dart 没有直接的 status API，用 index 与 head tree 对比。
List<dynamic> _statusEntries(Repository repo) {
  final headOid = _tryHeadOid(repo);
  if (headOid == null) {
    // 无提交：index 全部是新文件。
    return repo.index.toList();
  }
  // headOid 是 HEAD 指向的 **commit** oid；Tree.lookup 需要 **tree** oid，
  // 直接传 commit oid 会让 libgit2 报 "requested type does not match the
  // type in the ODB"。用 Commit.lookup 取 commit 的 tree。
  final headTree = Commit.lookup(repo: repo, oid: headOid).tree;
  final idx = <String>{for (final e in repo.index) e.path};
  final headPaths = <String>[
    for (final e in headTree.entries) e.name,
  ];
  final changed = <dynamic>[];
  for (final hp in headPaths) {
    if (!idx.contains(hp)) {
      changed.add({'path': hp}); // 已从 index 删除
    }
  }
  // 简化：只报差异概览。
  final all = {...idx, ...headPaths};
  for (final f in all) {
    final inIdx = idx.contains(f);
    final inHead = headPaths.contains(f);
    if (inIdx && !inHead) changed.add({'path': '$f (new)'});
    if (inIdx && inHead) changed.add({'path': '$f (modified?)'});
  }
  return changed.toSet().toList();
}

/// git diff：工作区未暂存改动（indexToWorkdir）的 unified diff。
///
/// 内存保护：先遍历 `diff.deltas`（只有 stat 信息，不读文件内容），
/// 单侧超过 1MB 的文件**不生成 patch 文本**（避免 libgit2 把大文件
/// 整读进内存算 diff），只报文件名。
String gitDiff({required String path, String? target}) {
  try {
    final repo = Repository.open(path);
    final diff = Diff.indexToWorkdir(repo: repo, index: repo.index);
    final deltas = diff.deltas;
    if (deltas.isEmpty) {
      return 'No unstaged changes.';
    }
    const maxDiffFileBytes = 1 << 20; // 1MB
    final parts = <String>[];
    for (var i = 0; i < deltas.length; i++) {
      final d = deltas[i];
      final newFile = d.newFile;
      final oldFile = d.oldFile;
      final filePath =
          newFile.path.isNotEmpty ? newFile.path : oldFile.path;
      final maxSize =
          newFile.size > oldFile.size ? newFile.size : oldFile.size;
      if (maxSize > maxDiffFileBytes) {
        parts.add('(跳过 diff 内容: $filePath 约 ${maxSize ~/ 1024}KB '
            '> 1MB 上限，仅列出文件名)');
        continue;
      }
      // 只对安全的小文件生成 patch（Patch.fromDiff 按索引单个生成，
      // 大文件的 delta 完全不触发内容读取）。
      parts.add(Patch.fromDiff(diff: diff, index: i).text);
    }
    return parts.join('\n');
  } catch (e) {
    return toolError('git diff failed: $e');
  }
}

/// git clone：克隆远程仓库到本地（内存友好版）。
///
/// 不用 `Repository.clone`（它全量拉取所有分支 + 全部 tag + 完整历史，
/// 4GB 设备上易 OOM）。改为：
///   1. init 空仓库
///   2. 配 origin，fetch refspec 限定**单分支 master**
///   3. fetch（只下载 master 历史对象，不拉 136 个 tag 与其他分支的 refs）
///   4. 建本地 master + checkout 工作树
///
/// [token] 提供时用 HTTPS + PAT（UserPass username 用 'x-access-token'）。
/// 不支持认证时（无 token）尝试匿名 clone（公开仓库）。
String gitClone({
  required String url,
  required String localPath,
  String? token,
}) {
  try {
    final callbacks = (token != null && token.isNotEmpty)
        ? Callbacks(
            credentials:
                UserPass(username: 'x-access-token', password: token))
        : const Callbacks();
    // 1. 空仓库（比 Repository.clone 轻，且可控 fetch 范围）。
    final repo = Repository.initBasic(path: localPath, bare: false);
    // 2. origin 默认 fetch refspec 只跟 master 单分支。
    Remote.create(
      repo: repo,
      name: 'origin',
      url: url,
      fetch: '+refs/heads/master:refs/remotes/origin/master',
    );
    // 3. 显式单分支 fetch（不拉 tags / 其他分支的 refs）。
    final remote = Remote.lookup(repo: repo, name: 'origin');
    remote.fetch(
      refspecs: const ['+refs/heads/master:refs/remotes/origin/master'],
      callbacks: callbacks,
    );
    // 4. 本地 master → 远程 master，checkout 工作树。
    final remoteHead =
        Branch.lookup(repo: repo, name: 'origin/master', type: GitBranch.remote);
    final headCommit = Commit.lookup(repo: repo, oid: remoteHead.target);
    Branch.create(repo: repo, name: 'master', target: headCommit);
    repo.setHead('refs/heads/master');
    repo.reset(oid: remoteHead.target, resetType: GitReset.hard);
    return 'Cloned $url → $localPath（单分支 master，未拉 tags）';
  } catch (e) {
    return toolError('git clone failed: $e');
  }
}

/// git push：推送当前分支到 origin。
String gitPush({
  required String path,
  String? token,
  String branch = 'master',
}) {
  try {
    final repo = Repository.open(path);
    final creds = token != null && token.isNotEmpty
        ? UserPass(username: 'x-access-token', password: token) as Credentials
        : null;
    final callbacks = Callbacks(credentials: creds);
    final remote = Remote.lookup(repo: repo, name: 'origin');
    remote.push(
      refspecs: ['refs/heads/$branch:refs/heads/$branch'],
      callbacks: callbacks,
    );
    return 'Pushed $branch → origin';
  } catch (e) {
    return toolError('git push failed: $e');
  }
}

/// git pull：从 origin 拉取，但**不做硬 reset**（避免丢本地未 push 提交）。
///
/// libgit2 绑定无 merge 能力，这里 fetch 后报告本地与 origin 的领先/落后；
/// 需要真正合并时（Linux）用 run_terminal 跑 `git merge` / `git pull --rebase`。
String gitPull({
  required String path,
  String? token,
}) {
  try {
    final repo = Repository.open(path);
    final creds = token != null && token.isNotEmpty
        ? UserPass(username: 'x-access-token', password: token) as Credentials
        : null;
    final callbacks = Callbacks(credentials: creds);
    final remote = Remote.lookup(repo: repo, name: 'origin');
    // 只 fetch master 单分支（空 refspec 会按 origin 配置拉全部分支 + tag，
    // 4GB 设备上对象解压易 OOM）。
    remote.fetch(
      refspecs: const ['+refs/heads/master:refs/remotes/origin/master'],
      callbacks: callbacks,
    );
    final headName = repo.head.name;
    final shortName = headName.split('/').last;
    // 对比本地 head 与 origin/<branch>：一致则最新；不一致提示用终端合并。
    final localHead = repo.head.target;
    try {
      final remoteBranch = Branch.lookup(
          repo: repo, name: 'origin/$shortName', type: GitBranch.remote);
      if (localHead == remoteBranch.target) {
        return '已是最新（origin/$shortName 与本地一致）';
      }
    } catch (_) {
      // origin 分支不存在（首次 fetch）→ 只下载对象。
      return '已 fetch origin（首次，本地尚无对应分支）。可 push 到 origin。';
    }
    return '已 fetch origin/$shortName（本地与远程不同步）。\n'
        '未自动合并（避免硬 reset 丢提交）。如需合并，Linux 上用 '
        'run_terminal 执行：git merge origin/$shortName 或 git pull --rebase';
  } catch (e) {
    return toolError('git pull failed: $e');
  }
}


// ============================================================================
// Registry
// ============================================================================

const Map<String, dynamic> _gitVersionSchema = {
  'name': 'git_version',
  'description': 'Return the embedded libgit2 version (verify git support works).',
  'parameters': {'type': 'object', 'properties': {}, 'required': []},
};

const Map<String, dynamic> _gitInitSchema = {
  'name': 'git_init',
  'description':
      'Initialize a new Git repository at the given directory. '
      'Required before add/commit. Returns confirmation.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Directory to init the repo in'},
    },
    'required': [],
  },
};

const Map<String, dynamic> _gitStatusSchema = {
  'name': 'git_status',
  'description':
      'Show the working tree status: staged files and unstaged changes. '
      'Use before commit to see what changed.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Repository directory'},
    },
    'required': [],
  },
};

const Map<String, dynamic> _gitAddSchema = {
  'name': 'git_add',
  'description':
      'Stage file(s) for commit. If files is empty, stage all changes. '
      'Use after editing files, before git_commit.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Repository directory'},
      'files': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Files to stage. Omit or empty to stage all.',
      },
    },
    'required': [],
  },
};

const Map<String, dynamic> _gitCommitSchema = {
  'name': 'git_commit',
  'description':
      'Create a commit from the staged changes. Use after git_add. '
      'Provide a clear message describing the change.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Repository directory'},
      'message': {'type': 'string', 'description': 'Commit message'},
      'author_name': {'type': 'string', 'description': 'Optional author name'},
      'author_email': {'type': 'string', 'description': 'Optional author email'},
    },
    'required': ['message'],
  },
};

const Map<String, dynamic> _gitLogSchema = {
  'name': 'git_log',
  'description': 'Show recent commit history (short hash, time, message).',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Repository directory'},
      'limit': {'type': 'integer', 'description': 'Max commits (default 20)'},
    },
    'required': [],
  },
};

const Map<String, dynamic> _gitBranchSchema = {
  'name': 'git_branch',
  'description': 'List local branches, marking the current one.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Repository directory'},
    },
    'required': [],
  },
};

String _arg(Map<String, dynamic> args, String key, [String? def]) =>
    args[key] as String? ?? def ?? '';

/// 从 args 读 path；未提供时用默认工作目录（工作区设置后 path 可省略）。
String _pathArg(Map<String, dynamic> args) =>
    _resolvePath(_arg(args, 'path'));

void registerGitTools() {
  registry.register(
    name: 'git_version',
    toolset: 'git',
    schema: _gitVersionSchema,
    handler: (args, [kwargs]) => gitVersion(),
    emoji: '🐙',
  );
  registry.register(
    name: 'git_init',
    toolset: 'git',
    schema: _gitInitSchema,
    handler: (args, [kwargs]) => gitInit(path: _pathArg(args)),
    emoji: '🐙',
  );
  registry.register(
    name: 'git_status',
    toolset: 'git',
    schema: _gitStatusSchema,
    handler: (args, [kwargs]) => gitStatus(path: _pathArg(args)),
    emoji: '🐙',
  );
  registry.register(
    name: 'git_add',
    toolset: 'git',
    schema: _gitAddSchema,
    handler: (args, [kwargs]) => gitAdd(
          path: _pathArg(args),
          files: (args['files'] as List?)?.whereType<String>().toList() ?? const [],
        ),
    emoji: '🐙',
  );
  registry.register(
    name: 'git_commit',
    toolset: 'git',
    schema: _gitCommitSchema,
    handler: (args, [kwargs]) => gitCommit(
          path: _pathArg(args),
          message: _arg(args, 'message'),
          authorName: args['author_name'] as String?,
          authorEmail: args['author_email'] as String?,
        ),
    emoji: '🐙',
  );
  registry.register(
    name: 'git_log',
    toolset: 'git',
    schema: _gitLogSchema,
    handler: (args, [kwargs]) => gitLog(
          path: _pathArg(args),
          limit: args['limit'] as int? ?? 20,
        ),
    emoji: '🐙',
  );
  registry.register(
    name: 'git_branch',
    toolset: 'git',
    schema: _gitBranchSchema,
    handler: (args, [kwargs]) => gitBranch(path: _pathArg(args)),
    emoji: '🐙',
  );
  registry.register(
    name: 'git_diff',
    toolset: 'git',
    schema: _gitDiffSchema,
    handler: (args, [kwargs]) => gitDiff(path: _pathArg(args)),
    emoji: '🐙',
  );
  registry.register(
    name: 'git_clone',
    toolset: 'git',
    schema: _gitCloneSchema,
    handler: (args, [kwargs]) async {
      await ensureGitSsl();
      return gitClone(
        url: _arg(args, 'url'),
        localPath: _arg(args, 'local_path'),
        token: await _resolveToken(args['token'] as String?),
      );
    },
    emoji: '🐙',
  );
  registry.register(
    name: 'git_push',
    toolset: 'git',
    schema: _gitPushSchema,
    handler: (args, [kwargs]) async {
      await ensureGitSsl();
      return gitPush(
        path: _pathArg(args),
        token: await _resolveToken(args['token'] as String?),
        branch: _arg(args, 'branch', 'master'),
      );
    },
    emoji: '🐙',
  );
  registry.register(
    name: 'git_pull',
    toolset: 'git',
    schema: _gitPullSchema,
    handler: (args, [kwargs]) async {
      await ensureGitSsl();
      return gitPull(
        path: _pathArg(args),
        token: await _resolveToken(args['token'] as String?),
      );
    },
    emoji: '🐙',
  );
  registry.register(
    name: 'github_ci_logs',
    toolset: 'git',
    schema: _gitCiLogsSchema,
    handler: _handleCiLogs,
    emoji: '📋',
    maxResultSizeChars: 50000,
  );
}

const Map<String, dynamic> _gitDiffSchema = {
  'name': 'git_diff',
  'description':
      'Show the unified diff of unstaged working-tree changes. '
      'Use before commit to review what changed.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Repository directory'},
    },
    'required': [],
  },
};

const Map<String, dynamic> _gitCloneSchema = {
  'name': 'git_clone',
  'description':
      'Clone a remote Git repository to local. token optional (for private repos).',
  'parameters': {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': 'Repository URL (https or ssh)'},
      'local_path': {'type': 'string', 'description': 'Local directory to clone into'},
      'token': {'type': 'string', 'description': 'Optional GitHub PAT token for private repos'},
    },
    'required': ['url', 'local_path'],
  },
};

const Map<String, dynamic> _gitPushSchema = {
  'name': 'git_push',
  'description': 'Push current branch to remote origin. token optional.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Repository directory'},
      'token': {'type': 'string', 'description': 'Optional GitHub PAT token'},
      'branch': {'type': 'string', 'description': 'Branch to push (default master)'},
    },
    'required': [],
  },
};

const Map<String, dynamic> _gitPullSchema = {
  'name': 'git_pull',
  'description': 'Fetch and merge from remote origin. token optional.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Repository directory'},
      'token': {'type': 'string', 'description': 'Optional GitHub PAT token'},
    },
    'required': [],
  },
};

const Map<String, dynamic> _gitCiLogsSchema = {
  'name': 'github_ci_logs',
  'description':
      'Read GitHub Actions CI status and failure logs for a repo. Uses the '
      'configured GitHub PAT automatically (no token argument needed). Use after '
      'a push when the CI build failed — returns recent runs, the failed job/step, '
      'and the tail of the failing step log so you can diagnose the error.',
  'parameters': {
    'type': 'object',
    'properties': {
      'repo': {
        'type': 'string',
        'description': 'Full repo name like owner/name (default ZhengJL18/MIX)',
      },
      'run_id': {
        'type': 'integer',
        'description': 'Specific workflow run id; default = latest run',
      },
      'token': {
        'type': 'string',
        'description': 'Optional PAT override (usually not needed — auto-read)',
      },
    },
    'required': [],
  },
};
