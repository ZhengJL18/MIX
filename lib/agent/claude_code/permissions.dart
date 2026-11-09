/// Claude Code 权限模型（Dart 移植）。
///
/// 逆向 2.1.319 得到的六种模式（字符串出现频次：default 1061 / auto 515 /
/// plan 260 / bypassPermissions 127 / dontAsk 69 / acceptEdits 60），
/// 以及「权限决策是独立可拦截点」的设计（PermissionRequest hook）。
///
/// 本模块只做纯判定，不读文件、不发通知：调用方（registry dispatch / agent loop）
/// 拿到 [PermissionDecision] 后决定是执行、询问用户还是拒绝。
library;

/// 权限模式。
enum PermissionMode {
  /// 默认：读自由，写与执行需确认。
  def('default', '默认', '读操作自由；写文件与执行命令需要确认'),

  /// 自动：除高危命令外一律放行（Claude Code 里已升到第二常用）。
  auto('auto', '自动', '写与执行自动放行，仅高危命令拦截'),

  /// 计划：只读探索，产出计划，禁止任何写/执行。
  plan('plan', '计划', '只读；禁止写文件、git 写操作与命令执行'),

  /// 接受编辑：写文件放行，命令仍需确认。
  acceptEdits('acceptEdits', '接受编辑', '文件编辑自动放行；命令执行仍需确认'),

  /// 跳过权限：全部放行。
  bypassPermissions('bypassPermissions', '跳过权限', '全部放行（含高危命令），仅记录'),

  /// 不问：全部放行且不再打扰用户（无人值守场景）。
  dontAsk('dontAsk', '不问', '全部放行，不弹确认；用于定时/后台任务');

  const PermissionMode(this.wire, this.label, this.hint);

  /// wire 名（与 Claude Code 的 JSON 值一致，便于持久化）。
  final String wire;

  /// 中文显示名。
  final String label;

  /// 一句话说明（拼进系统提示词）。
  final String hint;

  static PermissionMode fromWire(String? v) {
    for (final m in PermissionMode.values) {
      if (m.wire == v) return m;
    }
    return PermissionMode.def;
  }
}

/// 工具风险类别。
enum ToolClass {
  /// 只读：读文件、搜索、git 查询、状态查询。
  read,

  /// 写：创建/编辑/删除文件、git 写操作。
  write,

  /// 执行：shell / 命令 / 子进程。
  exec,

  /// 网络：抓取、搜索、上传。
  network,

  /// 其它（记忆、待办、MCP 等按只读处理）。
  other,
}

/// 判定结果。
enum PermissionVerdict {
  /// 直接允许。
  allow,

  /// 需询问用户（UI 弹确认）。
  ask,

  /// 直接拒绝（含原因）。
  deny,
}

/// 一次权限判定的结果。
class PermissionDecision {
  final PermissionVerdict verdict;
  final String reason;

  const PermissionDecision(this.verdict, this.reason);

  bool get isAllowed => verdict == PermissionVerdict.allow;
  bool get isDenied => verdict == PermissionVerdict.deny;
  bool get needsAsk => verdict == PermissionVerdict.ask;

  @override
  String toString() => '${verdict.name}: $reason';
}

/// 按工具名推断风险类别。
///
/// 命名是 MIX / Hermes 约定（`read_file`、`search_files`、`write_file`、
/// `git_commit`、`bash`、`web_fetch`…），用前缀匹配而不是精确表，
/// 新增工具不必改本文件。
ToolClass toolClassOf(String name) {
  final n = name.toLowerCase();

  // 执行类优先判断（bash 也可能带 file 关键词）
  if (n == 'bash' ||
      n == 'shell' ||
      n == 'terminal' ||
      n.startsWith('run_') ||
      n.contains('execute') ||
      n.endsWith('_exec')) {
    return ToolClass.exec;
  }

  // 网络
  if (n.startsWith('web_') ||
      n.contains('fetch') ||
      n.contains('search_web') ||
      n.contains('http') ||
      n.contains('download') ||
      n.contains('upload')) {
    return ToolClass.network;
  }

  // 写类
  if (n.startsWith('write') ||
      n.startsWith('edit') ||
      n.startsWith('create') ||
      n.startsWith('delete') ||
      n.startsWith('move') ||
      n.startsWith('copy') ||
      n.contains('patch') ||
      n.contains('_write') ||
      n.contains('_edit') ||
      n.contains('mkdir') ||
      n.contains('rename')) {
    return ToolClass.write;
  }

  // git：读/写要分开
  if (n.startsWith('git_')) {
    const mutating = {
      'git_add',
      'git_commit',
      'git_push',
      'git_reset',
      'git_checkout',
      'git_merge',
      'git_rebase',
      'git_stash',
      'git_clean',
      'git_apply',
    };
    return mutating.contains(n) ? ToolClass.write : ToolClass.read;
  }

  // 只读
  if (n.startsWith('read') ||
      n.startsWith('list') ||
      n.startsWith('search') ||
      n.startsWith('grep') ||
      n.startsWith('glob') ||
      n.startsWith('find') ||
      n.contains('_status') ||
      n.contains('_diff') ||
      n.contains('_log') ||
      n == 'todo_read' ||
      n.contains('memory_search') ||
      n.contains('session_search')) {
    return ToolClass.read;
  }

  return ToolClass.other;
}

/// 高危命令片段：即使 auto / dontAsk 也拦（删除、强推、格式化磁盘、关机）。
const List<String> _dangerousPatterns = [
  r'rm -rf /',
  r':(){',
  'mkfs',
  'dd if=',
  'shutdown',
  'reboot',
  '> /dev/sd',
  'git push --force',
  'git push -f',
  'git reset --hard',
  'chmod -R 777 /',
];

/// 命令是否命中高危模式。
bool isDangerousCommand(String command) {
  final c = command.toLowerCase();
  for (final p in _dangerousPatterns) {
    if (c.contains(p.toLowerCase())) return true;
  }
  return false;
}

/// 核心判定。
///
/// [mode] 当前权限模式；[toolName] 工具名；[input] 已解析的入参（用于检查
/// 命令内容），可为空。
PermissionDecision evaluatePermission({
  required PermissionMode mode,
  required String toolName,
  Map<String, dynamic>? input,
}) {
  final cls = toolClassOf(toolName);

  // 只读与网络在任何模式下都放行（plan 模式也允许探索）。
  if (cls == ToolClass.read || cls == ToolClass.network) {
    return PermissionDecision(PermissionVerdict.allow, '${cls.name} 操作，$toolName 放行');
  }

  if (cls == ToolClass.other) {
    return PermissionDecision(PermissionVerdict.allow, '非文件/命令类工具，默认放行');
  }

  switch (mode) {
    case PermissionMode.plan:
      return PermissionDecision(
        PermissionVerdict.deny,
        '计划模式只读：$toolName 属于 ${cls.name}，本轮禁止',
      );

    case PermissionMode.bypassPermissions:
    case PermissionMode.dontAsk:
      return PermissionDecision(
        PermissionVerdict.allow,
        '${mode.label}模式：$toolName 直接放行',
      );

    case PermissionMode.auto:
      if (cls == ToolClass.exec) {
        final cmd = (input?['command'] ?? input?['cmd'] ?? '').toString();
        if (isDangerousCommand(cmd)) {
          return const PermissionDecision(
            PermissionVerdict.deny,
            '高危命令，自动模式下强制拦截',
          );
        }
      }
      return PermissionDecision(
        PermissionVerdict.allow,
        '自动模式：$toolName 放行',
      );

    case PermissionMode.acceptEdits:
      if (cls == ToolClass.write) {
        return PermissionDecision(
          PermissionVerdict.allow,
          '接受编辑模式：$toolName 放行',
        );
      }
      return PermissionDecision(
        PermissionVerdict.ask,
        '命令执行需确认：$toolName',
      );

    case PermissionMode.def:
      if (cls == ToolClass.exec) {
        final cmd = (input?['command'] ?? input?['cmd'] ?? '').toString();
        if (isDangerousCommand(cmd)) {
          return const PermissionDecision(
            PermissionVerdict.deny,
            '高危命令，默认模式拦截',
          );
        }
      }
      return PermissionDecision(
        PermissionVerdict.ask,
        '${cls.name} 操作需确认：$toolName',
      );
  }
}
