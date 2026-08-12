/// Git 工具集 — 基于 libgit2（git2dart 绑定），agent 用 git 写代码。
///
/// 在 App 沙盒进程内 dlopen libgit2，不 exec 外部进程、不突破隔离墙。
/// 覆盖 agent 写代码核心操作 + GitHub 远程同步。
library;

import 'dart:io';

import 'package:git2dart/git2dart.dart';
import 'package:git2dart_binaries/git2dart_binaries.dart'
    show AndroidSSLHelper;

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
String gitDiff({required String path, String? target}) {
  try {
    final repo = Repository.open(path);
    final diff = Diff.indexToWorkdir(repo: repo, index: repo.index);
    final patches = diff.patches;
    if (patches.isEmpty) {
      return 'No unstaged changes.';
    }
    final parts = <String>[];
    for (final p in patches) {
      parts.add(p.text);
    }
    return parts.join('\n');
  } catch (e) {
    return toolError('git diff failed: $e');
  }
}

/// git clone：克隆远程仓库到本地。
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
        ? Callbacks(credentials: UserPass(username: 'x-access-token', password: token))
        : const Callbacks();
    Repository.clone(
      url: url,
      localPath: localPath,
      callbacks: callbacks,
    );
    return 'Cloned $url → $localPath';
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

/// git pull：从 origin 拉取并合并。
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
    remote.fetch(
      refspecs: const [],
      callbacks: callbacks,
    );
    // 拉取后 merge origin/当前分支（简化：直接 reset 到 origin）。
    final headName = repo.head.name;
    final shortName = headName.split('/').last;
    try {
      final branch =
          Branch.lookup(repo: repo, name: 'origin/$shortName', type: GitBranch.remote);
      repo.reset(oid: branch.target, resetType: GitReset.hard);
    } catch (_) {
      // origin 分支不存在（首次 fetch）→ 只下载对象，不 reset。
    }
    return 'Pulled origin/$shortName';
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
        token: args['token'] as String?,
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
        token: args['token'] as String?,
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
        token: args['token'] as String?,
      );
    },
    emoji: '🐙',
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
