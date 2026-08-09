/// 对应 `ref/hermes-agent/tools/file_operations.py`（像素级复刻）。
///
/// 文件操作模块：提供跨后端工作的读、写、patch、搜索能力。
///
/// Python 版的核心洞见是"所有文件操作都可表达为 shell 命令，因此包装 terminal
/// 后端的 execute() 接口提供统一文件 API"。
///
/// ## Dart 适配（传输层）
/// Android App 沙盒无 shell（SELinux 限制），`ShellFileOperations` 的 `_exec`
/// shell 命令（sed/cat/wc/head/mv/mktemp/chmod/rg/grep/find）映射为 `dart:io`
/// 直接操作。**接口（FileOperations 抽象 + 所有 dataclass 与 to_dict）、错误
/// 消息、行尾/BOM 处理、分页、lint delta、搜索结果的形状全部逐函数保留。**
/// 实现类命名为 `LocalFileOperations` 反映传输层替换。
///
/// 已知跳过（手机无对应能力，已在源码注释标注）：
/// - shell linter（python/node/tsc/go/rustfmt 子进程）→ skipped
/// - YAML/TOML/Python 进程内 linter → "__SKIP__"（PyYAML yaml.parse 的宽容
///   多文档语义 package:yaml 不匹配；Dart 无 Python/TOML 解析器）
/// - LSP 语义诊断（agent/lsp）→ 恒返回 "" / 不捕获 baseline
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// 部分顶层声明是对 Python 模块的忠实移植，但在 Android 原生文件路径不可达
// （rg/grep 输出解析器、shell linter 基础设施、shell 转义辅助）。它们保留供
// 未来 shell/SSH 后端或 file_tools.dart 使用，故文件级抑制 unused 警告。
// ignore_for_file: unused_element, unused_element_parameter, unused_local_variable, prefer_interpolation_to_compose_strings, unnecessary_brace_in_string_interps, prefer_iterable_wheretype

import 'binary_extensions.dart';
import 'file_safety.dart';
import 'fuzzy_match.dart';
import 'patch_parser.dart';
import 'sequence_matcher.dart';
import 'tool_output_limits.dart';

// ---------------------------------------------------------------------------
// 写路径黑名单 —— 阻塞写敏感系统/凭据文件
// ---------------------------------------------------------------------------

final String _home = homePath();

final Set<String> writeDeniedPaths = buildWriteDeniedPaths(_home);

final List<String> writeDeniedPrefixes = buildWriteDeniedPrefixes(_home);

final RegExp _oscSequenceRe = RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)');
final RegExp _fenceMarkerRe = RegExp(r"'?\x07?__HERMES_FENCE_[A-Za-z0-9]+__\x07?'?");

/// 剥离文件读取输出中泄漏的 terminal fence 包装。
String _stripTerminalFenceLeaks(String text) {
  if (text.isEmpty) {
    return text;
  }
  // 逐行保留行尾（对应 Python splitlines(keepends=True)）。
  final out = <String>[];
  var start = 0;
  while (true) {
    final nl = text.indexOf('\n', start);
    final end = nl == -1 ? text.length : nl + 1;
    final line = text.substring(start, end);
    final hadTerminalWrapper =
        line.contains('__HERMES_FENCE_') || line.contains('\x1b]');
    var cleaned = line.replaceAll(_oscSequenceRe, '');
    cleaned = cleaned.replaceAll(_fenceMarkerRe, '');
    cleaned = cleaned.replaceAll('\x07', '');
    if (!(hadTerminalWrapper && cleaned.trim() == '')) {
      out.add(cleaned);
    }
    if (nl == -1) {
      break;
    }
    start = end;
  }
  return out.join();
}

/// 返回 ``sample`` 中占主导的行尾，无法判定返回 null。
///
/// 看前几个换行，有 ``\r\n`` 则选 ``\r\n``（Windows/DOS），否则 ``\n``（Unix）。
/// 空/单行内容（无法判定）返回 null。用于跨 write_file 和 patch 操作保留文件
/// 原始行尾 —— 没有它，agent 的 bare-LF 工具参数会静默规范化 Windows 行尾文件，
/// 且 patch 只在替换区域变化时产生混合行尾。
String? _detectLineEnding(String sample) {
  if (sample.isEmpty) {
    return null;
  }
  // 看第一个块 —— 足够判定，廉价扫描。
  final head = sample.length > 4096 ? sample.substring(0, 4096) : sample;
  if (head.contains('\r\n')) {
    return '\r\n';
  }
  if (head.contains('\n')) {
    return '\n';
  }
  return null;
}

/// 把 ``text`` 中所有行尾转成 ``target``（``\n`` 或 ``\r\n``）。
///
/// 幂等：连续两次归一化相同。单遍把混合行尾内容均质化。
String _normalizeLineEndings(String text, String target) {
  // 先折叠为 LF（处理 CRLF 和 lone CR），target 为 CRLF 时再展开。
  // 顺序重要：分别替换会双重转换 CRLF -> LFLF。
  final lfNormalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (target == '\n') {
    return lfNormalized;
  }
  if (target == '\r\n') {
    return lfNormalized.replaceAll('\n', '\r\n');
  }
  return text;
}

/// UTF-8 字节序标记。部分 Windows 编辑器（记事本、旧 VS、部分 PowerShell
/// 重定向）在 UTF-8 文本文件前加此不可见 3 字节标记（EF BB BF == U+FEFF）。
/// 读时剥离使模型看到干净内容，写时原文件有则恢复 —— 与行尾保留对称
/// （磁盘检测，跨编辑保留）。
const String _utf8Bom = '﻿';

/// 返回 `(text-without-leading-BOM, had_bom)`。
///
/// 只剥离单个前导 BOM；内容中间出现的 BOM 保留（那里是合法数据，不是文件标记）。
(String, bool) _stripBom(String text) {
  if (text.isNotEmpty && text.startsWith(_utf8Bom)) {
    return (text.substring(_utf8Bom.length), true);
  }
  return (text, false);
}

/// 若 ``text`` 以 UTF-8 BOM 开头则 True。
bool _hasBom(String? text) => text != null && text.startsWith(_utf8Bom);

/// 若路径在写黑名单上则 True。
bool _isWriteDenied(String path) => isWriteDenied(path);

// =============================================================================
// Result Data Classes
// =============================================================================

/// 读文件结果。
class ReadResult {
  String content;
  int totalLines;
  int fileSize;
  bool truncated;
  String? hint;
  bool isBinary;
  bool isImage;
  String? base64Content;
  String? mimeType;
  String? dimensions; // 图像："WIDTHxHEIGHT"
  String? error;
  List<String> similarFiles;

  ReadResult({
    this.content = '',
    this.totalLines = 0,
    this.fileSize = 0,
    this.truncated = false,
    this.hint,
    this.isBinary = false,
    this.isImage = false,
    this.base64Content,
    this.mimeType,
    this.dimensions,
    this.error,
    this.similarFiles = const [],
  });

  Map<String, dynamic> toDict() {
    final result = <String, dynamic>{};
    void add(String k, Object? v) {
      if (v != null && v != <Object>[]) {
        result[k] = v;
      }
    }

    add('content', content);
    add('total_lines', totalLines);
    add('file_size', fileSize);
    add('truncated', truncated);
    add('hint', hint);
    add('is_binary', isBinary);
    add('is_image', isImage);
    add('base64_content', base64Content);
    add('mime_type', mimeType);
    add('dimensions', dimensions);
    add('error', error);
    add('similar_files', similarFiles);
    return result;
  }
}

/// 写文件结果。
class WriteResult {
  int bytesWritten;
  bool dirsCreated;
  // 落盘内容校验：写后读回字节与预期一致为 true；无法校验（读回失败）为
  // null。不匹配永不落到该字段 —— 它是硬错误（见 writeFile）。
  bool? verified;
  Map<String, dynamic>? lint;
  // 来自 LSP 层的语义诊断（当适用时）。单独字段（不并入 ``lint``）使模型和
  // 下游解析器把语法错误和语义错误读作独立信号。LSP 禁用、文件不在 git
  // 工作区、或本次编辑未引入诊断时为 null。
  String? lspDiagnostics;
  String? error;
  String? warning;

  WriteResult({
    this.bytesWritten = 0,
    this.dirsCreated = false,
    this.verified,
    this.lint,
    this.lspDiagnostics,
    this.error,
    this.warning,
  });

  Map<String, dynamic> toDict() {
    final result = <String, dynamic>{};
    if (bytesWritten != 0) {
      result['bytes_written'] = bytesWritten;
    }
    if (dirsCreated) {
      result['dirs_created'] = dirsCreated;
    }
    if (verified != null) {
      result['verified'] = verified;
    }
    if (lint != null) {
      result['lint'] = lint;
    }
    if (lspDiagnostics != null) {
      result['lsp_diagnostics'] = lspDiagnostics;
    }
    if (error != null) {
      result['error'] = error;
    }
    if (warning != null) {
      result['warning'] = warning;
    }
    return result;
  }
}

/// 打补丁结果。
class PatchResult {
  bool success;
  String diff;
  List<String> filesModified;
  List<String> filesCreated;
  List<String> filesDeleted;
  Map<String, dynamic>? lint;
  String? lspDiagnostics;
  String? error;
  // 成功形状的 no-op：请求的编辑已存在于文件，未做任何写入。携带 note 向
  // 模型解释为何无 diff（对齐 upstream PatchResult.no_change）。
  bool noChange;
  String? note;

  PatchResult({
    this.success = false,
    this.diff = '',
    this.filesModified = const [],
    this.filesCreated = const [],
    this.filesDeleted = const [],
    this.lint,
    this.lspDiagnostics,
    this.error,
    this.noChange = false,
    this.note,
  });

  Map<String, dynamic> toDict() {
    final result = <String, dynamic>{'success': success};
    if (noChange) {
      result['no_change'] = true;
    }
    if (note != null) {
      result['note'] = note;
    }
    if (diff.isNotEmpty) {
      result['diff'] = diff;
    }
    if (filesModified.isNotEmpty) {
      result['files_modified'] = filesModified;
    }
    if (filesCreated.isNotEmpty) {
      result['files_created'] = filesCreated;
    }
    if (filesDeleted.isNotEmpty) {
      result['files_deleted'] = filesDeleted;
    }
    if (lint != null) {
      result['lint'] = lint;
    }
    if (lspDiagnostics != null) {
      result['lsp_diagnostics'] = lspDiagnostics;
    }
    if (error != null) {
      result['error'] = error;
    }
    return result;
  }
}

/// 单个搜索匹配。
class SearchMatch {
  String path;
  int lineNumber;
  String content;
  double mtime; // 排序用修改时间

  SearchMatch({
    required this.path,
    required this.lineNumber,
    required this.content,
    this.mtime = 0.0,
  });
}

/// 搜索结果。
class SearchResult {
  List<SearchMatch> matches;
  List<String> files;
  Map<String, int> counts;
  int totalCount;
  bool truncated;
  String? limitReason;
  String? warning;
  String? error;

  // 超过此数量把 content 模式匹配密集化为按路径分组文本块。
  static const int _densifyMinMatches = 5;

  SearchResult({
    this.matches = const [],
    this.files = const [],
    this.counts = const {},
    this.totalCount = 0,
    this.truncated = false,
    this.limitReason,
    this.warning,
    this.error,
  });

  /// 把 content 模式匹配渲染为紧凑、按路径分组的文本块。
  ///
  /// 详细形式对每个匹配重复 ``{"path","line","content"}`` 键和完整路径串。
  /// 此方法把连续匹配按路径分组（路径打印一次，然后 ``  <line>: <content>`` 行），
  /// 无损 —— 每个路径、行号、内容字节都保留 —— 模型无需解码步骤即可读。
  ///
  /// 匹配太少不值得密集化时返回 null，调用者回退详细数组。
  String? _densifyMatches() {
    if (matches.length < _densifyMinMatches) {
      return null;
    }
    // ripgrep 输出路径排序（一个文件内所有命中连续），因此按路径变化分组把
    // 每个文件折叠为单个头而不重排结果。
    final lines = <String>[];
    String? currentPath;
    for (final m in matches) {
      if (m.path != currentPath) {
        lines.add(m.path);
        currentPath = m.path;
      }
      // 只 rstrip 尾随空白；代码前导缩进有意义，在 "<line>: " 前缀后原样保留。
      lines.add('  ${m.lineNumber}: ${m.content.trimRight()}');
    }
    return lines.join('\n');
  }

  Map<String, dynamic> toDict({bool densify = false}) {
    final result = <String, dynamic>{'total_count': totalCount};
    if (matches.isNotEmpty) {
      final dense = densify ? _densifyMatches() : null;
      if (dense != null) {
        // 自描述：格式键告诉模型如何读块，使它永不需猜测形状。
        result['matches_format'] =
            'path-grouped: each file path on its own line, followed by '
            "indented '<line>: <content>' rows for matches in that file";
        result['matches_text'] = dense;
      } else {
        result['matches'] = [
          for (final m in matches)
            {'path': m.path, 'line': m.lineNumber, 'content': m.content},
        ];
      }
    }
    if (files.isNotEmpty) {
      result['files'] = files;
    }
    if (counts.isNotEmpty) {
      result['counts'] = counts;
    }
    if (truncated) {
      result['truncated'] = true;
    }
    if (limitReason != null) {
      result['limit_reason'] = limitReason;
    }
    if (warning != null) {
      result['warning'] = warning;
    }
    if (error != null) {
      result['error'] = error;
    }
    return result;
  }
}

/// 检查文件结果。
class LintResult {
  bool success;
  bool skipped;
  String output;
  String message;

  LintResult({
    this.success = true,
    this.skipped = false,
    this.output = '',
    this.message = '',
  });

  Map<String, dynamic> toDict() {
    if (skipped) {
      return {'status': 'skipped', 'message': message};
    }
    final result = <String, dynamic>{
      'status': success ? 'ok' : 'error',
      'output': output,
    };
    if (message.isNotEmpty) {
      result['message'] = message;
    }
    return result;
  }
}

/// 执行 shell 命令结果（保留形状；Dart 传输层直接 io）。
class ExecuteResult {
  String stdout;
  int exitCode;

  ExecuteResult({this.stdout = '', this.exitCode = 0});
}

final RegExp _searchTimeoutMarkerRe =
    RegExp(r'\n?\[Command timed out after \d+s\]\s*$');

/// 返回清理用于解析的 stdout 和搜索超时的 limit reason。
(String, String?) _searchStdoutAndLimit(ExecuteResult result) {
  if (result.exitCode == 124) {
    return (result.stdout.replaceAll(_searchTimeoutMarkerRe, ''), 'search_timeout');
  }
  return (result.stdout, null);
}

/// 把 rg/grep 诊断行与真实匹配输出分开。
///
/// `_exec` 以 stderr=STDOUT 运行命令，因此 rg/grep 的错误和警告文本与匹配行交错
/// 在单流中。诊断绝不能解析为匹配；硬失败时它们是表面错误消息。
///
/// 返回 `(diagnostics, payload)`，payload 只含像真实搜索输出的行 —— 匹配行
/// （``file:line:content``）、files-only 路径、count 行、或 context 行/分隔符。
/// 其他一切（工具前缀错误、rg 多行 ``regex parse error`` 块带缩进尖号、空行）
/// 折叠进 diagnostics。
///
/// 按*形状*而非错误前缀分类，使 exit-2 守卫区分纯失败（无可用 payload → 表面
/// 错误）与部分失败（部分文件匹配、一个不可读 → 保留匹配）。
List<String> _splitToolDiagnostics(String output) {
  final diagnostics = <String>[];
  final payload = <String>[];
  for (final line in output.split('\n')) {
    if (line.trim().isEmpty) {
      continue;
    }
    // 工具诊断总是带 "<tool>: " 前缀。先检查：真实匹配路径可合法含 "-<digit>"
    // （如 tmp 目录 ".../pytest-686/..."），形状正则否则会当匹配行。
    final stripped = line.trimLeft();
    if (stripped.startsWith('rg: ') || stripped.startsWith('grep: ')) {
      diagnostics.add(line);
      continue;
    }
    if (line == '--' || _searchOutputRe.hasMatch(line)) {
      payload.add(line);
    } else {
      diagnostics.add(line);
    }
  }
  return diagnostics;
}

// 真实 rg/grep 输出行以路径 token 开始，后跟 ``:``（匹配/count）、``-``（context）
// 或什么都没有（files_only）。工具诊断（"rg: ..."、"grep: ..."、"error: ..."、
// 缩进尖号）永不匹配，因路径 token 禁止空白且前导工具前缀如 "rg" 后跟 ": "
// （空格），被否定类拒绝。
final RegExp _searchOutputRe = RegExp(
  r'^([A-Za-z]:)?[^\s:][^\n]*?[:\-]\d|^[^\s:][^\s]*$',
);

/// 解析 grep/rg context 输出 ``path-line-content`` 格式。
///
/// context 行有歧义，因为文件名可合法含 ``-<digits>-`` 段。偏好最右数字分隔符，
/// 使 ``dir/file-12-name.py-8-context`` 解析为 ``dir/file-12-name.py`` 第 ``8``
/// 行，而非在 ``file`` 处截断。
(String, int, String)? _parseSearchContextLine(String line) {
  if (line.isEmpty || line == '--') {
    return null;
  }

  Match? match;
  for (final m in RegExp(r'-(\d+)-').allMatches(line)) {
    match = m;
  }

  if (match == null) {
    return null;
  }

  final path = line.substring(0, match.start);
  if (path.isEmpty) {
    return null;
  }

  return (path, int.parse(match.group(1)!), line.substring(match.end));
}

// =============================================================================
// 抽象接口
// =============================================================================

/// 跨文件操作后端的抽象接口。
abstract class FileOperations {
  /// 读文件并支持分页。
  ReadResult readFile(String path, {int offset = 1, int limit = 2000});

  /// 以纯字符串读完整文件内容。
  ///
  /// 无分页、无行号前缀、无逐行截断。返回 ReadResult，.content = 完整文件文本，
  /// 失败时 .error 已设置。无论文件大小始终读至 EOF。
  ReadResult readFileRaw(String path);

  /// 写内容到文件，按需创建目录。
  WriteResult writeFile(String path, String content);

  /// 用模糊匹配替换文件中的文本。
  PatchResult patchReplace(
    String path,
    String oldString,
    String newString, {
    bool replaceAll = false,
  });

  /// 应用 V4A 格式补丁。
  PatchResult patchV4a(String patchContent);

  /// 删除文件。返回 WriteResult，失败时 .error 已设置。
  WriteResult deleteFile(String path);

  /// 跨平台删除，处理文件和（recursive=True 时）目录树。
  WriteResult deletePath(String path, {bool recursive = false});

  /// 把文件从 src 移到 dst。返回 WriteResult，失败时 .error 已设置。
  WriteResult moveFile(String src, String dst);

  /// 把文件或目录树从 src 复制到 dst（目录递归复制，系统级字节复制）。
  /// 返回 WriteResult，失败时 .error 已设置。
  WriteResult copyFile(String src, String dst);

  /// 搜索内容或文件。
  SearchResult search(
    String pattern, {
    String path = '.',
    String target = 'content',
    String? fileGlob,
    int limit = 50,
    int offset = 0,
    String outputMode = 'content',
    int context = 0,
  });
}

// =============================================================================
// 本地实现（Android App 沙盒传输层 = dart:io）
// =============================================================================

/// 图像扩展名（返回 base64 的二进制子集）。
const Set<String> imageExtensions = {
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico',
};

// 检查文件 lint 的语言扩展表。Python 版用外部工具链子进程；Android 无 → 全跳过。
const Map<String, String> _linters = {};

// 扩展名集合（保留 Python 常量形状；_SHELL_LINTER_LSP_REDUNDANT 在本实现跳过）。
const Set<String> _shellLinterLspRedundant = {'.ts', '.go', '.rs'};

const Map<String, List<String>> _linterUnusablePatterns = {};

bool _looksLikeLinterUnusable(String baseCmd, String output) {
  final patterns = _linterUnusablePatterns[baseCmd];
  if (patterns == null) {
    return false;
  }
  final lower = output.toLowerCase();
  return patterns.any(lower.contains);
}

/// 进程内 JSON 语法检查。返回 (ok, error_message)。
(bool, String) _lintJsonInproc(String content) {
  try {
    jsonDecode(content);
    return (true, '');
  } catch (e) {
    return (false, 'JSONDecodeError: $e');
  }
}

/// 进程内 YAML 语法检查。返回 (ok, error_message)。
///
/// Dart 适配：PyYAML 的 ``yaml.parse`` 宽容多文档/自定义标签语义 package:yaml
/// 不匹配（loadYaml 拒绝多文档）。为避免假拒绝结构化写入，返回 "__SKIP__"。
(bool, String) _lintYamlInproc(String content) {
  return (true, '__SKIP__');
}

/// 进程内 TOML 语法检查。Dart 无 TOML 解析器 → "__SKIP__"。
(bool, String) _lintTomlInproc(String content) {
  return (true, '__SKIP__');
}

/// 进程内 Python 语法检查。Dart 无 Python 解析器 → "__SKIP__"。
(bool, String) _lintPythonInproc(String content) {
  return (true, '__SKIP__');
}

/// 进程内 linters 按扩展名。优先于 shell linters。
/// 每个 callable 取文件内容 (str) 返回 (ok: bool, error: str)。
/// 错误串 ``"__SKIP__"`` 表示 linter 不可用（缺依赖），应视为"无 linter"。
final Map<String, (bool, String) Function(String)> _lintersInproc = {
  '.py': _lintPythonInproc,
  '.json': _lintJsonInproc,
  '.yaml': _lintYamlInproc,
  '.yml': _lintYamlInproc,
  '.toml': _lintTomlInproc,
};

/// LINTERS_INPROC 中 write_file 的 pre-write fail-closed 门拒绝（而非仅报告）
/// 的子集。刻意排除 ``.py``：JSON/YAML/TOML（原子结构化数据块，"不解析"总意味着
/// "损坏"）与 .py（代码库测试 fixture 用 .py 作为任意非 Python 文本的通用替代
/// 扩展名）行为不同。Python 源码保留既有（不变）post-write lint-delta *报告*。
final Set<String> _failClosedInprocExts = {'.json', '.yaml', '.yml', '.toml'};

// 读操作的最大限制。
const int maxLines = 2000;
const int maxLineLength = 2000;
const int maxFileSize = 50 * 1024; // 50KB
const int defaultReadOffset = 1;
const int defaultReadLimit = 2000;
const int defaultSearchOffset = 0;
const int defaultSearchLimit = 50;

/// 搜索遍历的文件数上限。同步 listSync(recursive) 遍历大目录会卡 UI 主 isolate，
/// 达到上限即截断并标记 truncated。
const int maxSearchFiles = 10000;

int _coerceInt(Object? value, int default_) {
  // Python int(x) 语义：int(3.7)→3（截断）、int(True)→1、int("3")→3。
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.toInt();
  }
  if (value is bool) {
    return value ? 1 : 0;
  }
  final v = int.tryParse(value.toString());
  return v ?? default_;
}

/// 返回安全的 read_file 分页边界。
///
/// 工具 schema 声明最小/最大值，但并非每个调用者或 provider 在 dispatch 前强制
/// schema。在这里钳制，使无效值不能漏进 sed 范围如 ``0,-1p``。
///
/// ``limit`` 上限来自 config.yaml 的 ``tool_output.max_lines``
/// （默认模块级 ``MAX_LINES`` 常量）。
(int, int) normalizeReadPagination([Object? offset = defaultReadOffset, Object? limit = defaultReadLimit]) {
  final maxLines_ = getMaxLines();
  final o = _coerceInt(offset, defaultReadOffset);
  final normalizedOffset = o < 1 ? 1 : o; // max(1, _coerce_int(...))
  var normalizedLimit = _coerceInt(limit, defaultReadLimit);
  normalizedLimit = normalizedLimit < 1
      ? 1
      : (normalizedLimit > maxLines_ ? maxLines_ : normalizedLimit);
  return (normalizedOffset, normalizedLimit);
}

/// 返回 shell head/tail 管道安全的搜索分页边界。
(int, int) normalizeSearchPagination([Object? offset = defaultSearchOffset, Object? limit = defaultSearchLimit]) {
  final normalizedOffset = _coerceInt(offset, defaultSearchOffset) < 0
      ? 0
      : _coerceInt(offset, defaultSearchOffset);
  final normalizedLimit = _coerceInt(limit, defaultSearchLimit) < 1
      ? 1
      : _coerceInt(limit, defaultSearchLimit);
  return (normalizedOffset, normalizedLimit);
}

final RegExp _regexNewlineEscapeRe = RegExp(r'(?<!\\)(?:\\\\)*\\n');

/// 当 content-search 正则尝试匹配换行时 True。
///
/// ``search_files`` 以行导向模式运行 rg/grep，非 rg ``-U``/``--multiline`` 模式，
/// 因此换行正则不能跨行匹配。检测已解码进工具参数的 literal newline 和正则
/// ``\n`` 转义（``n`` 前奇数反斜杠）。偶数反斜杠如 ``\\n`` 表示 literal
/// backslash+n 搜索，不应警告。
bool _patternHasRegexNewline(String pattern) {
  return pattern.contains('\n') || _regexNewlineEscapeRe.hasMatch(pattern);
}

/// rg 需要 multiline 模式时的硬错误返回 True。
bool _isLineOrientedNewlineError(String? error) {
  if (error == null) {
    return false;
  }
  return error.contains('literal "\\n" is not allowed') &&
      error.contains('--multiline');
}

/// 仅当搜索无可用结果时附加 newline-regex 警告。
SearchResult _maybeWarnLineOrientedNewlinePattern(SearchResult result, String pattern) {
  if (result.totalCount != 0 || !_patternHasRegexNewline(pattern)) {
    return result;
  }
  if (result.error != null && !_isLineOrientedNewlineError(result.error)) {
    return result;
  }
  result.error = null;
  result.warning =
      '0 results found. Note: search_files content search is line-oriented '
      'and does not run ripgrep with -U/--multiline, so `\\n` in the regex '
      'does not match line breaks. Use context=N to inspect neighboring '
      'lines, or escape as `\\\\n` when searching for a literal backslash+n.';
  return result;
}

// ---------------------------------------------------------------------------
// Negative-result cache —— 对已知不存在的路径跳过昂贵的 parent-dir 相似文件
// walk（对齐 upstream file_tools.py not_found 缓存：TTL + 存在性守卫 + 写失效）。
// ---------------------------------------------------------------------------

final Map<(String, String), ({double at, Object payload})> _notFoundCache = {};
const double _notFoundTtlSeconds = 60.0;
const int _notFoundCap = 500;

/// 返回缓存的 not-found 结果（仍新鲜且路径确实不存在时）。
Object? _checkNotFoundCache(String op, String resolved) {
  final key = (op, resolved);
  final entry = _notFoundCache[key];
  if (entry == null) {
    return null;
  }
  if (DateTime.now().millisecondsSinceEpoch / 1000.0 - entry.at >
      _notFoundTtlSeconds) {
    _notFoundCache.remove(key);
    return null;
  }
  // 存在性守卫：路径可能已被外部进程创建（write/patch 显式失效，但不是唯一
  // 写者）。模型常见模式"先查不存在 → 创建 → 再读"不能被过期 miss 破坏。
  if (File(resolved).existsSync() || Directory(resolved).existsSync()) {
    _notFoundCache.remove(key);
    return null;
  }
  return entry.payload;
}

/// 记录一次 not-found（op 区分 read/search，两者错误形状不同）。
void _recordNotFound(String op, String resolved, Object payload) {
  if (_notFoundCache.length >= _notFoundCap) {
    _notFoundCache.remove(_notFoundCache.keys.first);
  }
  _notFoundCache[(op, resolved)] =
      (at: DateTime.now().millisecondsSinceEpoch / 1000.0, payload: payload);
}

/// write/patch 创建路径后清除负缓存 —— 后续读/搜必须落盘。
void _invalidateNotFound(String resolved) {
  _notFoundCache.remove(('read', resolved));
  _notFoundCache.remove(('search', resolved));
}

/// 字节级相等比较（write 落盘校验用）。
bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// 通过 dart:io 直接操作的文件操作实现（对应 ShellFileOperations，传输层替换）。
class LocalFileOperations implements FileOperations {
  LocalFileOperations({this.cwd, this.allowExternalAccess = false});

  /// 工作目录；null 时用当前目录。
  String? cwd;

  /// 是否允许访问 App 沙盒之外的路径（对应 Android「所有文件访问」权限）。
  /// 为 true 时 search 不再限制在 cwd 内，可搜索公共目录。
  bool allowExternalAccess;

  /// 公开的路径解析入口（file_tools.dart 报告实际写入路径用）。
  String resolveForTool(String path) => _abs(path);

  /// 返回绝对化后的路径（相对 cwd 解析）。
  String _abs(String path) {
    final expanded = _expandPath(path);
    if (p.isAbsolute(expanded)) {
      return expanded;
    }
    final base = cwd ?? Directory.current.path;
    return p.normalize(p.join(base, expanded));
  }

  /// 展开 ~ 路径为绝对路径。Android 沙盒无 shell 展开，直接基于 home。
  String _expandPath(String path) {
    if (path.isEmpty) {
      return path;
    }
    if (path == '~') {
      return homePath();
    }
    if (path.startsWith('~/')) {
      return p.join(homePath(), path.substring(2));
    }
    return path;
  }

  String _escapeShellArg(String arg) => arg;

  /// 检查文件是否可能为二进制。
  ///
  /// 用扩展名检查（快）+ 内容分析（兜底）。
  bool _isLikelyBinary(String path, {String? contentSample}) {
    final ext = p.extension(path).toLowerCase();
    if (binaryExtensions.contains(ext)) {
      return true;
    }
    if (contentSample != null) {
      // 不可解码字节：Python 版 terminal env 以 errors="replace" 解码 stdout，
      // 因此任何非 UTF-8 字节到达时已成 U+FFFD。该字符"可打印"（ord 65533），
      // 非打印比例永不捕获它 —— 且返回有损文本会让读→编辑→写往返静默覆盖原始
      // 字节为 mojibake。样本带替换字符的文件视为二进制（只读），防止 agent
      // 损坏它。合法 UTF-8 文本几乎不含 U+FFFD。
      final sample = contentSample.length > 1000
          ? contentSample.substring(0, 1000)
          : contentSample;
      if (sample.contains('�')) {
        return true;
      }
      var nonPrintable = 0;
      for (final c in sample.codeUnits) {
        if (c < 32 && c != 10 && c != 13 && c != 9) {
          nonPrintable++;
        }
      }
      final denom = sample.length < 1000 ? sample.length : 1000;
      return nonPrintable / denom > 0.30;
    }
    return false;
  }

  bool _isImage(String path) {
    return imageExtensions.contains(p.extension(path).toLowerCase());
  }

  /// 读取用于二进制检测的样本（前 1000 字节）。
  ///
  /// 修复「读不了含中文的 dart 文件」：原实现在 1000 字节处硬截断，而
  /// [RandomAccessFile.readSync] 可能把多字节 UTF-8 字符（中文等）拦腰截断，
  /// `allowMalformed` 解码会在样本末尾产生孤立的 U+FFFD，被 [_isLikelyBinary]
  /// 误判为二进制，导致含中文注释的合法文本文件被当作损坏文件拒绝读取
  /// （ripgrep/git 均正常，仅 read_file 拒读 —— 典型如 lib/agent/agent.dart）。
  /// 此处修正：若样本中唯一的 U+FFFD 恰在末尾、且文件比样本长（采样被截断），
  /// 视为采样截断假象剥掉；内容中部的 U+FFFD 仍按二进制处理。
  String _readBinarySample(File f, int fileSize) {
    String sample;
    var bytesLen = 0;
    try {
      final raf = f.openSync();
      final bytes = raf.readSync(1000);
      bytesLen = bytes.length;
      raf.closeSync();
      sample = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
    sample = _stripTerminalFenceLeaks(sample);
    final firstFf = sample.indexOf('�');
    if (firstFf >= 0 &&
        firstFf == sample.lastIndexOf('�') &&
        firstFf == sample.length - 1 &&
        bytesLen < fileSize) {
      sample = sample.substring(0, firstFf);
    }
    return sample;
  }

  /// 按 ``LINE_NUM|CONTENT`` 格式给内容加行号。
  ///
  /// 沟槽用紧凑 ``<n>|`` 前缀而非定宽零/空格填充（``    34|foo``）。填充是纯
  /// token 开销：密集源上填充沟槽比裸内容贵约 48% token、比紧凑形式贵约 16%。
  /// A/B（Sonnet 4.6，2 遍）显示紧凑沟槽在行引用/patch/值查找/结构任务上与
  /// 填充沟槽持平（4/4 双），而完全去掉行号则行引用回退（模型手数且 off-by-one，
  /// 3/4）—— 因此保留数字，只是不填充。
  String _addLineNumbers(String content, {int startLine = 1}) {
    final maxLineLength_ = getMaxLineLength();
    final lines = content.split('\n');
    final numbered = <String>[];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line.length > maxLineLength_) {
        line = line.substring(0, maxLineLength_) + '... [truncated]';
      }
      numbered.add('${startLine + i}|$line');
    }
    return numbered.join('\n');
  }

  /// 原子写：写临时文件 + rename。
  ///
  /// 与 Python 版同语义：临时文件在目标同目录（rename 同一文件系统），保留现有
  /// 文件模式，成功后换入。失败移除临时文件，原始文件不动。
  ExecuteResult _atomicWrite(String path, String content) {
    final absPath = _abs(path);
    final dir = p.dirname(absPath);
    try {
      Directory(dir).createSync(recursive: true);
    } catch (_) {
      return ExecuteResult(stdout: 'Failed to create directory: $dir', exitCode: 1);
    }
    final tmp = p.join(dir, '.hermes-tmp.${pid}.${DateTime.now().microsecondsSinceEpoch}');
    try {
      File(tmp).writeAsStringSync(content, flush: true);
      File(tmp).renameSync(absPath);
      return ExecuteResult();
    } catch (e) {
      try {
        if (File(tmp).existsSync()) {
          File(tmp).deleteSync();
        }
      } catch (_) {}
      return ExecuteResult(stdout: 'Atomic write failed: $e', exitCode: 1);
    }
  }

  String? _detectFileLineEnding(String path, {String? preContent}) {
    if (preContent != null) {
      return _detectLineEnding(preContent);
    }
    final absPath = _abs(path);
    try {
      final f = File(absPath);
      if (!f.existsSync()) {
        return null;
      }
      final raf = f.openSync();
      final bytes = raf.readSync(4096);
      raf.closeSync();
      return _detectLineEnding(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }

  bool _fileHasBom(String path, {String? preContent}) {
    if (preContent != null) {
      return _hasBom(preContent);
    }
    final absPath = _abs(path);
    try {
      final f = File(absPath);
      if (!f.existsSync()) {
        return false;
      }
      final raf = f.openSync();
      final bytes = raf.readSync(3);
      raf.closeSync();
      return _hasBom(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return false;
    }
  }

  String _unifiedDiff(String oldContent, String newContent, String filename) {
    final oldKeep = _splitKeepEnds(oldContent);
    final newKeep = _splitKeepEnds(newContent);
    final diff = unifiedDiff(
      oldKeep,
      newKeep,
      fromfile: 'a/$filename',
      tofile: 'b/$filename',
    );
    return diff.join();
  }

  List<String> _splitKeepEnds(String s) {
    final lines = <String>[];
    var start = 0;
    while (true) {
      final nl = s.indexOf('\n', start);
      if (nl == -1) {
        if (start < s.length) {
          lines.add(s.substring(start));
        }
        break;
      }
      lines.add(s.substring(start, nl + 1));
      start = nl + 1;
    }
    return lines;
  }

  // =========================================================================
  // READ
  // =========================================================================

  @override
  ReadResult readFile(String path, {int offset = 1, int limit = 2000}) {
    // 展开 ~。
    final absPath = _abs(path);

    final (offsetN, limitN) = normalizeReadPagination(offset, limit);

    // 检查文件存在并取大小。
    final f = File(absPath);
    if (!f.existsSync()) {
      // 负缓存：已知不存在的路径直接返回缓存错误，跳过 parent-dir 相似文件 walk
      // （模型重复重试同一 typo 路径时，每次重试都省一次目录遍历）。
      final cached = _checkNotFoundCache('read', absPath);
      if (cached is ReadResult) {
        return cached;
      }
      final suggest = _suggestSimilarFiles(path);
      if ((suggest.error ?? '').startsWith('File not found:')) {
        _recordNotFound('read', absPath, suggest);
      }
      return suggest;
    }
    int fileSize;
    try {
      fileSize = f.lengthSync();
    } catch (_) {
      fileSize = 0;
    }

    // 图像永不内联 —— 重定向到 vision 工具。
    if (_isImage(absPath)) {
      return ReadResult(
        isImage: true,
        isBinary: true,
        fileSize: fileSize,
        hint: 'Image file detected. Automatically redirected to vision_analyze tool. '
            'Use vision_analyze with this file path to inspect the image contents.',
      );
    }

    // 读样本检查二进制内容（_readBinarySample 剥掉 1000 字节截断的 U+FFFD 假象）。
    final sampleOutput = _readBinarySample(f, fileSize);

    if (_isLikelyBinary(absPath, contentSample: sampleOutput)) {
      return ReadResult(
        isBinary: true,
        fileSize: fileSize,
        error: 'Binary file - cannot display as text. Use appropriate tools to handle this file type.',
      );
    }

    // 分页读。
    final endLine = offsetN + limitN - 1;
    String fullContent;
    try {
      fullContent = f.readAsStringSync();
    } on FormatException {
      // 严格 UTF-8 解码失败：内容确实含非法字节（真二进制/损坏），拒绝展示。
      return ReadResult(
        isBinary: true,
        fileSize: fileSize,
        error: 'Binary file - cannot display as text. Use appropriate tools to handle this file type.',
      );
    } catch (e) {
      return ReadResult(error: 'Failed to read file: $e');
    }
    fullContent = _stripTerminalFenceLeaks(fullContent);
    if (offsetN == 1) {
      final (s, _) = _stripBom(fullContent);
      fullContent = s;
    }

    final lines = fullContent.split('\n');
    // Python 用 wc -l（按 \n 计数）：尾随换行不产生额外空行。split 在尾随
    // \n 时产生一个空串元素，去掉它使 total_lines 与 Python 一致。
    final totalLines = (fullContent.endsWith('\n') && lines.isNotEmpty)
        ? lines.length - 1
        : lines.length;
    final page = lines.skip(offsetN - 1).take(limitN).join('\n');

    final truncated = totalLines > endLine;
    String? hint;
    if (truncated) {
      hint = 'Use offset=${endLine + 1} to continue reading (showing $offsetN-$endLine of $totalLines lines)';
    }

    return ReadResult(
      content: _addLineNumbers(page, startLine: offsetN),
      totalLines: totalLines,
      fileSize: fileSize,
      truncated: truncated,
      hint: hint,
    );
  }

  /// 文件未找到时建议相似文件。
  ReadResult _suggestSimilarFiles(String path) {
    final absPath = _abs(path);
    final dirPath = p.dirname(absPath);
    final filename = p.basename(absPath);
    final basenameNoExt = p.basenameWithoutExtension(filename);
    final ext = p.extension(filename).toLowerCase();
    final lowerName = filename.toLowerCase();

    // 列出目标目录条目（Python ls -1 含文件与目录）。
    List<String> dirEntries;
    try {
      dirEntries = Directory(dirPath)
          .listSync()
          .map((e) => p.basename(e.path))
          .toList()
        ..sort();
    } catch (_) {
      dirEntries = const [];
    }

    final scored = <(int, String)>[]; // (score, filepath)，高者优先。
    for (final f in dirEntries) {
      if (f.isEmpty) {
        continue;
      }
      final lf = f.toLowerCase();
      var score = 0;

      if (lf == lowerName) {
        score = 100;
      } else if (p.basenameWithoutExtension(f).toLowerCase() ==
          basenameNoExt.toLowerCase()) {
        score = 90;
      } else if (lf.startsWith(lowerName) || lowerName.startsWith(lf)) {
        score = 70;
      } else if (lowerName.contains(lf)) {
        score = 60;
      } else if (lf.contains(lowerName) && lf.length > 2) {
        score = 40;
      } else if (ext.isNotEmpty &&
          p.extension(f).toLowerCase() == ext) {
        final common = lowerName.split('').toSet().intersection(lf.split('').toSet());
        if (common.length >= (lowerName.length > lf.length ? lowerName.length : lf.length) * 0.4) {
          score = 30;
        }
      }

      if (score > 0) {
        scored.add((score, p.join(dirPath, f)));
      }
    }

    scored.sort((x, y) => y.$1.compareTo(x.$1));
    final similar = scored.take(5).map((x) => x.$2).toList();

    return ReadResult(
      error: 'File not found: $path',
      similarFiles: similar,
    );
  }

  @override
  ReadResult readFileRaw(String path) {
    final absPath = _abs(path);
    final f = File(absPath);
    if (!f.existsSync()) {
      return _suggestSimilarFiles(path);
    }
    int fileSize;
    try {
      fileSize = f.lengthSync();
    } catch (_) {
      fileSize = 0;
    }
    if (_isImage(absPath)) {
      return ReadResult(isImage: true, isBinary: true, fileSize: fileSize);
    }
    // 读样本检查二进制内容（_readBinarySample 剥掉 1000 字节截断的 U+FFFD 假象）。
    final sampleOutput = _readBinarySample(f, fileSize);
    if (_isLikelyBinary(absPath, contentSample: sampleOutput)) {
      return ReadResult(
        isBinary: true,
        fileSize: fileSize,
        error: 'Binary file — cannot display as text.',
      );
    }
    String raw;
    try {
      raw = f.readAsStringSync();
    } on FormatException {
      // 严格 UTF-8 解码失败：内容确实含非法字节（真二进制/损坏），拒绝展示。
      return ReadResult(
        isBinary: true,
        fileSize: fileSize,
        error: 'Binary file — cannot display as text.',
      );
    } catch (e) {
      return ReadResult(error: 'Failed to read file: $e');
    }
    final (s, _) = _stripBom(_stripTerminalFenceLeaks(raw));
    return ReadResult(
      content: s,
      fileSize: fileSize,
    );
  }

  @override
  WriteResult deleteFile(String path) => _delete(path, recursive: false);

  @override
  WriteResult deletePath(String path, {bool recursive = false}) =>
      _delete(path, recursive: recursive);

  WriteResult _delete(String path, {required bool recursive}) {
    final absPath = _abs(path);
    final denied = getWriteDeniedError(absPath, verb: 'Delete');
    if (denied != null) {
      return WriteResult(error: denied);
    }
    try {
      final f = File(absPath);
      if (f.existsSync()) {
        f.deleteSync();
        return WriteResult();
      }
      final d = Directory(absPath);
      if (d.existsSync()) {
        if (recursive) {
          d.deleteSync(recursive: true);
          return WriteResult();
        }
        return WriteResult(error: 'is a directory: $path');
      }
      return WriteResult(); // 不存在等同成功（Python FileNotFoundError→pass）
    } catch (e) {
      return WriteResult(error: 'Failed to delete $path: $e');
    }
  }

  @override
  WriteResult moveFile(String src, String dst) {
    final absSrc = _abs(src);
    final absDst = _abs(dst);
    for (final p in [absSrc, absDst]) {
      final denied = getWriteDeniedError(p, verb: 'Move');
      if (denied != null) {
        return WriteResult(error: denied);
      }
    }
    try {
      File(absSrc).renameSync(absDst);
      return WriteResult();
    } catch (e) {
      return WriteResult(error: 'Failed to move $src -> $dst: $e');
    }
  }

  @override
  WriteResult copyFile(String src, String dst) {
    final absSrc = _abs(src);
    final absDst = _abs(dst);
    // dst 走写黑名单（src 是读取，由工具层守卫设备路径）。
    final denied = getWriteDeniedError(absDst, verb: 'Copy');
    if (denied != null) {
      return WriteResult(error: denied);
    }
    try {
      final srcFile = File(absSrc);
      if (srcFile.existsSync()) {
        File(absDst).parent.createSync(recursive: true);
        srcFile.copySync(absDst);
        return WriteResult(bytesWritten: srcFile.lengthSync());
      }
      final srcDir = Directory(absSrc);
      if (srcDir.existsSync()) {
        final (bytes, err) = _copyDirRec(srcDir, Directory(absDst));
        if (err != null) {
          return WriteResult(error: err);
        }
        return WriteResult(bytesWritten: bytes);
      }
      return WriteResult(error: 'Failed to copy $src -> $dst: source does not exist');
    } catch (e) {
      return WriteResult(error: 'Failed to copy $src -> $dst: $e');
    }
  }

  /// 递归复制目录树，返回 (复制的字节数, 错误或 null)。
  (int, String?) _copyDirRec(Directory srcDir, Directory dstDir) {
    try {
      dstDir.createSync(recursive: true);
    } catch (e) {
      return (0, 'Failed to create $dstDir: $e');
    }
    var bytes = 0;
    try {
      for (final entity in srcDir.listSync(followLinks: false)) {
        final dstPath = p.join(dstDir.path, p.basename(entity.path));
        if (entity is File) {
          entity.copySync(dstPath);
          bytes += entity.lengthSync();
        } else if (entity is Directory) {
          final (sub, err) = _copyDirRec(entity, Directory(dstPath));
          if (err != null) {
            return (bytes, err);
          }
          bytes += sub;
        }
      }
    } catch (e) {
      return (bytes, 'Failed to copy directory $srcDir -> $dstDir: $e');
    }
    return (bytes, null);
  }

  // =========================================================================
  // WRITE
  // =========================================================================

  @override
  WriteResult writeFile(String path, String content) {
    // 展开 ~。
    final absPath = _abs(path);

    // 阻塞写敏感路径。
    final denied = getWriteDeniedError(absPath);
    if (denied != null) {
      return WriteResult(error: denied);
    }

    // ── Fail-closed pre-write syntax gate ───────────────────────────
    // 在磁盘碰任何字节前验证候选内容。范围：_FAIL_CLOSED_INPROC_EXTS 内扩展名
    // （JSON/YAML/TOML）。.py 刻意保留既有非阻塞 lint-delta 报告。
    final ext = p.extension(absPath).toLowerCase();
    (bool, String) Function(String)? inprocLinter;
    if (_failClosedInprocExts.contains(ext)) {
      inprocLinter = _lintersInproc[ext];
    }
    if (inprocLinter != null) {
      final (ok, lintErr) = inprocLinter(content);
      if (!ok && lintErr != '__SKIP__') {
        return WriteResult(
          error: "Refusing to write '$path': candidate content fails "
              '$ext syntax validation ($lintErr). The file was '
              'NOT created or modified. Fix the content and retry.',
        );
      }
    }

    // 捕获 pre-write 内容（lint-delta 用）。
    String? preContent;
    final wantPre = _lintersInproc.containsKey(ext);
    if (wantPre) {
      try {
        final f = File(absPath);
        if (f.existsSync()) {
          preContent = f.readAsStringSync();
        }
      } catch (_) {
        preContent = null;
      }
    }

    // ── 行尾保留 ─────────────────────────────────────────────
    final originalEnding = _detectFileLineEnding(absPath, preContent: preContent);
    if (originalEnding == '\r\n') {
      content = _normalizeLineEndings(content, '\r\n');
    }

    // ── BOM 保留 ──────────────────────────────────────────────
    if (_fileHasBom(absPath, preContent: preContent) && !_hasBom(content)) {
      content = _utf8Bom + content;
    }

    // 创建父目录。
    final parent = p.dirname(absPath);
    var dirsCreated = false;
    if (parent.isNotEmpty) {
      try {
        Directory(parent).createSync(recursive: true);
        dirsCreated = true;
      } catch (_) {}
    }

    // 原子写。
    final writeResult = _atomicWrite(absPath, content);
    if (writeResult.exitCode != 0) {
      return WriteResult(error: 'Failed to write file: ${writeResult.stdout}');
    }

    // 取写入字节数。
    int bytesWritten;
    try {
      bytesWritten = File(absPath).lengthSync();
    } catch (_) {
      bytesWritten = utf8.encode(content).length;
    }

    // Post-write content verification —— 读回对比磁盘字节与预期内容。
    // 对齐上游 WriteResult.verified：写已落盘且哈希一致才 true，模型看到
    // verified:true 就不必再读回确认（生产里模型常写后立刻重读确认落盘）。
    // Dart 原生写盘总能校验；不一致是硬错误（镜像 patchReplace 的验证）。
    bool? verified;
    try {
      final diskBytes = File(absPath).readAsBytesSync();
      verified = _bytesEqual(diskBytes, utf8.encode(content));
      if (!verified) {
        return WriteResult(
          error: 'Post-write verification failed for $path: on-disk content '
              'hash differs from the intended write. The write did not '
              'persist correctly — re-read the file and retry.',
        );
      }
    } catch (_) {
      verified = null; // 读回失败 → 无法校验，不阻断。
    }

    // 写成功 → 该路径不再是"不存在"，清除负缓存。
    _invalidateNotFound(absPath);

    // Post-write lint with delta refinement。
    final lintResult = _checkLintDelta(absPath, preContent: preContent, postContent: content);

    return WriteResult(
      bytesWritten: bytesWritten,
      dirsCreated: dirsCreated,
      verified: verified,
      lint: lintResult.toDict(),
    );
  }

  // =========================================================================
  // PATCH（Replace Mode）
  // =========================================================================

  @override
  PatchResult patchReplace(
    String path,
    String oldString,
    String newString, {
    bool replaceAll = false,
  }) {
    final absPath = _abs(path);

    final denied = getWriteDeniedError(absPath);
    if (denied != null) {
      return PatchResult(error: denied);
    }

    String content;
    try {
      content = File(absPath).readAsStringSync();
    } catch (e) {
      return PatchResult(error: 'Failed to read file: $path');
    }
    final (contentBomless, _) = _stripBom(content);
    content = contentBomless;

    final (newContent, matchCount, strategy, error) = fuzzyFindAndReplace(
      content,
      oldString,
      newString,
      replaceAll: replaceAll,
    );

    if (error != null || matchCount == 0) {
      // 已应用检测：最常见的 patch 失败是重发一个已落地的编辑。转成显式成功
      // 形状的 no-op，让模型继续而非重读重打（对齐 upstream）。
      if (isAlreadyApplied(content, oldString, newString)) {
        return PatchResult(
          success: true,
          noChange: true,
          note: 'File already contains the target text — the edit appears to '
              'be already applied to $path. No write performed; do not re-send '
              'this patch.',
        );
      }
      var errMsg = error ?? 'Could not find match for old_string in $path';
      // Python 包 try/except: pass —— hint 计算失败不顶掉主错误。
      try {
        errMsg += formatNoMatchHint(error, matchCount, oldString, content);
      } catch (_) {}
      return PatchResult(error: errMsg);
    }

    // ── 行尾保留 ─────────────────────────────────────────────
    final fileEnding = _detectLineEnding(content);
    var effectiveNew = newContent;
    if (fileEnding != null) {
      effectiveNew = _normalizeLineEndings(effectiveNew, fileEnding);
    }

    // 写回。
    final writeResult = writeFile(path, effectiveNew);
    if (writeResult.error != null) {
      return PatchResult(error: 'Failed to write changes: ${writeResult.error}');
    }

    // Post-write verification —— 重读并确认期望字节确实落盘。
    String verifyContent;
    try {
      verifyContent = File(absPath).readAsStringSync();
    } catch (_) {
      return PatchResult(
          error: 'Post-write verification failed: could not re-read $path');
    }
    final (verifyBomless, _) = _stripBom(verifyContent);
    final verifyNormalized = verifyBomless.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final newNormalized = effectiveNew.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (verifyNormalized != newNormalized) {
      return PatchResult(
        error: 'Post-write verification failed for $path: on-disk content '
            'differs from intended write '
            '(wrote ${newNormalized.length} chars, read back '
            '${verifyNormalized.length} chars after normalizing line endings). '
            'The patch did not persist. Re-read the file and try again.',
      );
    }

    final diff = _unifiedDiff(content, effectiveNew, path);

    final lintResult = _checkLintDelta(absPath, preContent: content, postContent: effectiveNew);

    return PatchResult(
      success: true,
      diff: diff,
      filesModified: [path],
      lint: lintResult.toDict(),
      lspDiagnostics: writeResult.lspDiagnostics,
    );
  }

  @override
  PatchResult patchV4a(String patchContent) {
    // 对应 Python 的 patch_v4a：解析 + 应用。
    final (operations, parseError) = parseV4aPatch(patchContent);
    if (parseError != null) {
      return PatchResult(error: 'Failed to parse patch: $parseError');
    }
    return applyV4aOperations(operations, this);
  }

  /// 公开 lint 入口，对应 Python `_check_lint`（V4A apply 阶段 hasattr 检查用）。
  LintResult checkLintFile(String path) => _checkLint(path);

  // =========================================================================
  // LINT
  // =========================================================================

  LintResult _checkLint(String path, {String? content}) {
    final ext = p.extension(path).toLowerCase();

    final inproc = _lintersInproc[ext];
    if (inproc != null) {
      String? text = content;
      if (text == null) {
        try {
          final f = File(_abs(path));
          if (!f.existsSync()) {
            return LintResult(skipped: true, message: 'Failed to read $path for lint');
          }
          text = f.readAsStringSync();
        } catch (_) {
          return LintResult(skipped: true, message: 'Failed to read $path for lint');
        }
      }
      final (ok, err) = inproc(text);
      if (err == '__SKIP__') {
        return LintResult(skipped: true, message: 'No linter available for $ext (missing dependency)');
      }
      return LintResult(success: ok, output: ok ? '' : err);
    }

    // shell linter 在 Android 不可用 —— 全跳过。
    return LintResult(skipped: true, message: 'No linter for $ext files');
  }

  /// 带 pre-write baseline 对比的 post-write lint。
  ///
  /// 两层策略：
  /// 1. **语法检查**（进程内，微秒）。捕获本层动机的 bug 类：损坏写入、乱引号、
  ///    截断输出。
  /// 2. **相对 pre-write 内容的 delta 细化**，当语法层报告错误时。过滤编辑前
  ///    已存在的错误，使 agent 不被继承状态分心。
  LintResult _checkLintDelta(
    String path, {
    String? preContent,
    String? postContent,
  }) {
    final post = _checkLint(path, content: postContent);

    // Hot path：post-write 语法干净。
    if (post.success || post.skipped) {
      return post;
    }

    // Post-write 有语法错误。有 pre-content 则跑 delta 细化过滤已存在错误。
    if (preContent == null) {
      return post;
    }

    final pre = _checkLint(path, content: preContent);
    if (pre.success || pre.skipped || pre.output.isEmpty) {
      // Pre-write 干净（或无法 lint）—— post 错误全为新。
      return post;
    }

    // Pre- 和 post-write 都有错误。对非空 stripped 行做集合差。
    // 若 post 每条错误也出现在 pre，文件仍 broken 但此编辑未引入新的。
    final preLines = pre.output.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toSet();
    final postLines = post.output
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !preLines.contains(l))
        .toList();

    if (postLines.isEmpty) {
      return LintResult(
        success: false,
        output: post.output,
        message: "Pre-existing lint errors — this edit didn't introduce new ones but the file is still broken.",
      );
    }

    return LintResult(
      success: false,
      output: 'New lint errors introduced by this edit '
          '(pre-existing errors filtered out):\n' +
          postLines.join('\n'),
    );
  }

  // =========================================================================
  // SEARCH（Dart 原生实现，替换 rg/grep 子进程）
  // =========================================================================

  @override
  SearchResult search(
    String pattern, {
    String path = '.',
    String target = 'content',
    String? fileGlob,
    int limit = 50,
    int offset = 0,
    String outputMode = 'content',
    int context = 0,
  }) {
    final (offsetN, limitN) = normalizeSearchPagination(offset, limit);
    final absPath = _abs(path);

    // 隔离墙保护：默认搜索限制在 cwd（App documents 目录）内，防遍历整个
    // 文件系统卡死。授予「所有文件访问」权限后（allowExternalAccess），
    // 允许搜索公共目录；但 cwd 为空时仍拒绝（防 Directory.current = `/` 递归）。
    final baseCwd = cwd;
    if (baseCwd == null || baseCwd.isEmpty) {
      return SearchResult(
        error: '搜索范围未配置（cwd 为空）。请先初始化 App 文件目录。',
        totalCount: 0,
      );
    }
    if (!allowExternalAccess) {
      final absCwd = p.isAbsolute(baseCwd)
          ? p.normalize(baseCwd)
          : p.normalize(p.join(Directory.current.path, baseCwd));
      if (absPath != absCwd && !p.isWithin(absCwd, absPath)) {
        return SearchResult(
          error: "搜索路径 '$path' 超出沙盒范围（$absCwd）。"
              'MIX 默认只搜索 App 自己的文件空间。'
              '如需访问公共目录，请在设置中授予「所有文件访问」权限。',
          totalCount: 0,
        );
      }
    }

    // 验证路径存在。
    if (!Directory(absPath).existsSync() && !File(absPath).existsSync()) {
      // 负缓存：已知不存在的搜索根直接返回缓存错误（跳过重复 shell/目录遍历）。
      final cached = _checkNotFoundCache('search', absPath);
      if (cached is SearchResult) {
        return cached;
      }
      // 多路径恢复：模型常把 "dir1 dir2 dir3"（或逗号分隔列表）一次塞进 path。
      // 拆开搜索所有存在的路径并合并结果，报告被跳过的部分。
      final multi = _tryMultiPathSearch(
        pattern,
        path,
        target,
        fileGlob,
        limitN,
        offsetN,
        outputMode,
        context,
      );
      if (multi != null) {
        return multi;
      }
      final notFound =
          SearchResult(error: 'Path not found: $path', totalCount: 0);
      _recordNotFound('search', absPath, notFound);
      return notFound;
    }

    if (target == 'files') {
      return _searchFiles(pattern, absPath, limitN, offsetN);
    }
    return _searchContent(pattern, absPath, fileGlob, limitN, offsetN, outputMode, context);
  }

  /// 多路径恢复：把 not-found 的 ``path`` 拆成多个候选（空格/逗号分隔）。
  ///
  /// 生产轨迹显示模型把 "dir1 dir2 dir3" 或逗号分隔列表整体塞进 path。当
  /// 至少给出两个候选且至少一个存在时，搜索每个存在的路径并合并结果，note
  /// 报告跳过的部分。返回 null 表示这不像是多路径字符串（对齐 upstream
  /// ``_try_multi_path_search``）。
  SearchResult? _tryMultiPathSearch(
    String pattern,
    String path,
    String target,
    String? fileGlob,
    int limit,
    int offset,
    String outputMode,
    int context,
  ) {
    final parts = path
        .split(RegExp(r'[,\s]+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
    if (parts.length < 2) {
      return null;
    }
    final existing = <String>[];
    final missing = <String>[];
    for (final part in parts) {
      final expanded = _abs(part);
      // 沙盒边界：未授全盘访问时，超范围的部分按缺失处理（不越界搜索）。
      if (!allowExternalAccess) {
        final baseCwd = cwd;
        final absCwd = baseCwd == null
            ? Directory.current.path
            : (p.isAbsolute(baseCwd)
                ? p.normalize(baseCwd)
                : p.normalize(p.join(Directory.current.path, baseCwd)));
        if (expanded != absCwd && !p.isWithin(absCwd, expanded)) {
          missing.add(part);
          continue;
        }
      }
      if (Directory(expanded).existsSync() || File(expanded).existsSync()) {
        existing.add(expanded);
      } else {
        missing.add(part);
      }
    }
    if (existing.isEmpty) {
      return null;
    }

    final merged = SearchResult(
      matches: <SearchMatch>[],
      files: <String>[],
      counts: <String, int>{},
    );
    for (final p in existing) {
      final sub = target == 'files'
          ? _searchFiles(pattern, p, limit, offset)
          : _searchContent(pattern, p, fileGlob, limit, offset, outputMode, context);
      if (sub.error != null) {
        continue;
      }
      merged.matches.addAll(sub.matches);
      merged.files.addAll(sub.files);
      merged.counts.addAll(sub.counts);
      merged.totalCount += sub.totalCount;
      merged.truncated = merged.truncated || sub.truncated;
    }
    merged.matches = merged.matches.take(limit).toList();
    merged.files = merged.files.take(limit).toList();
    var note = 'path contained ${parts.length} entries; searched '
        '${existing.length} that exist';
    if (missing.isNotEmpty) {
      note += '; skipped missing: ${missing.take(3).join(', ')}';
      if (missing.length > 3) {
        note += ' (+${missing.length - 3} more)';
      }
    }
    merged.warning = note;
    return merged;
  }

  SearchResult _searchFiles(String pattern, String path, int limit, int offset) {
    final baseName = pattern.split('/').last;
    final files = <String>[];
    // 受控遍历：最多访问 maxSearchFiles 个条目就截断。
    // 用迭代 DFS 而非 listSync(recursive) —— 后者是 eager 的，会先把整棵
    // 目录树物化成 List 才返回；授予「所有文件访问」后从 /sdcard 全盘搜索
    // 时，同步物化几十万条目会卡死 UI 主 isolate。
    final (walked, visited) = _walkLimited(path, maxSearchFiles);
    for (final e in walked) {
      if (e is! File) {
        continue;
      }
      final name = p.basename(e.path);
      if (_globMatch(baseName, name)) {
        files.add(e.path);
      }
    }
    files.sort();
    final page = files.skip(offset).take(limit).toList();
    return SearchResult(
      files: page,
      totalCount: files.length,
      truncated: visited,
    );
  }

  SearchResult _searchContent(
    String pattern,
    String path,
    String? fileGlob,
    int limit,
    int offset,
    String outputMode,
    int context, {
    bool probeMode = false,
    bool caseSensitive = true,
  }) {
    RegExp re;
    try {
      re = RegExp(pattern, caseSensitive: caseSensitive);
    } catch (e) {
      return SearchResult(error: 'Search failed: invalid regex $e', totalCount: 0);
    }

    final matches = <SearchMatch>[];
    final counts = <String, int>{};
    final matchedFiles = <String>[];
    var truncated = false;

    try {
      final files = _collectFiles(path, fileGlob);
      for (final file in files) {
        if (truncated) {
          break;
        }
        String content;
        try {
          content = File(file).readAsStringSync();
        } catch (_) {
          continue; // 不可读文件：与 rg 部分失败行为一致（保留其他匹配）。
        }
        final lines = content.split('\n');
        var fileCount = 0;
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (re.hasMatch(line)) {
            fileCount++;
            if (outputMode == 'content') {
              // 超长行截断到 500 字符（Python rg 匹配行 [:500]）。
              final clipped = line.length > 500 ? line.substring(0, 500) : line;
              matches.add(SearchMatch(
                path: file,
                lineNumber: i + 1,
                content: clipped,
              ));
              // context=N：把相邻行也纳入（Python rg -C）。
              if (context > 0) {
                for (var c = 1; c <= context; c++) {
                  final before = i - c;
                  if (before >= 0) {
                    final bLine = lines[before];
                    matches.add(SearchMatch(
                      path: file,
                      lineNumber: before + 1,
                      content: bLine.length > 500
                          ? bLine.substring(0, 500)
                          : bLine,
                    ));
                  }
                  final after = i + c;
                  if (after < lines.length) {
                    final aLine = lines[after];
                    matches.add(SearchMatch(
                      path: file,
                      lineNumber: after + 1,
                      content: aLine.length > 500
                          ? aLine.substring(0, 500)
                          : aLine,
                    ));
                  }
                }
              }
            } else if (outputMode == 'files_only') {
              if (!matchedFiles.contains(file)) {
                matchedFiles.add(file);
              }
            }
          }
        }
        // count 模式：只有命中的文件才进 counts（Python rg -c）。
        if (outputMode == 'count' && fileCount > 0) {
          counts[file] = fileCount;
        }
        if (matches.length >= offset + limit + (context > 0 ? 200 : 0)) {
          truncated = true;
          break;
        }
      }
    } catch (_) {}

    if (outputMode == 'files_only') {
      return SearchResult(
        files: matchedFiles.skip(offset).take(limit).toList(),
        totalCount: matchedFiles.length,
        truncated: truncated,
      );
    }
    if (outputMode == 'count') {
      return SearchResult(
        counts: counts,
        totalCount: counts.values.fold(0, (a, b) => a + b),
        truncated: truncated,
      );
    }
    final total = matches.length;
    final page = matches.skip(offset).take(limit).toList();
    final result = SearchResult(
      matches: page,
      totalCount: total,
      truncated: total > offset + limit || truncated,
    );
    // 零命中探测：0 匹配的结果对模型没有可抓的抓手，是死轮。廉价探测近邻
    // （大小写错误、正则元字符需转义）并附 warning（对齐 upstream
    // ``_zero_match_probe``）。probeMode 防止探测自身再触发探测。
    if (!probeMode && total == 0 && outputMode == 'content') {
      final hint = _zeroMatchProbe(pattern, path, fileGlob);
      if (hint != null) {
        result.warning =
            result.warning == null ? hint : '${result.warning} $hint';
      }
    }
    return _maybeWarnLineOrientedNewlinePattern(result, pattern);
  }

  /// 零命中内容搜索的近邻探测。返回提示或 null。
  ///
  /// 上游 13.9% 的 content 搜索零命中且不给模型任何可转向信息。跑至多两次
  /// 廉价 count-only 扫描：大小写不敏感探测 + （正则含元字符时）字面量探测。
  /// hidden/gitignored 探测跳过 —— Dart 原生搜索不排除点目录（无 gitignore），
  /// 隐藏文件本就被覆盖。
  String? _zeroMatchProbe(String pattern, String path, String? fileGlob) {
    // 1. 大小写不敏感探测。
    final ci = _searchContent(
      pattern,
      path,
      fileGlob,
      50,
      0,
      'count',
      0,
      probeMode: true,
      caseSensitive: false,
    );
    if (ci.totalCount > 0) {
      return '0 exact matches, but ${ci.totalCount} case-insensitive '
          "match(es) in ${ci.counts.length} file(s) — the pattern's casing "
          'may be wrong.';
    }
    // 2. 正则元字符 → 字面量探测。
    if (RegExp(r'[.\[\](){}?*+^$\\|]').hasMatch(pattern)) {
      final fixed = _searchContent(
        RegExp.escape(pattern),
        path,
        fileGlob,
        50,
        0,
        'count',
        0,
        probeMode: true,
      );
      if (fixed.totalCount > 0) {
        return '0 regex matches, but ${fixed.totalCount} literal match(es) — '
            'the pattern contains regex metacharacters that likely need '
            'escaping (or pass a simpler substring).';
      }
    }
    return null;
  }

  /// 递归收集要搜索的文件（尊重 fileGlob 通配）。
  List<String> _collectFiles(String path, String? fileGlob) {
    final files = <String>[];
    try {
      final f = File(path);
      if (f.existsSync()) {
        if (_fileGlobMatch(fileGlob, p.basename(path))) {
          files.add(path);
        }
        return files;
      }
    } catch (_) {}
    try {
      final d = Directory(path);
      if (!d.existsSync()) {
        return files;
      }
      final (walked, _) = _walkLimited(path, maxSearchFiles);
      for (final e in walked) {
        if (e is File) {
          if (_fileGlobMatch(fileGlob, p.basename(e.path))) {
            files.add(e.path);
          }
        }
      }
    } catch (_) {}
    return files;
  }

  /// 受控递归遍历：迭代 DFS + 访问条目计数。
  ///
  /// 返回 (访问到的条目, 是否因达到上限提前截断)。
  /// 用显式栈逐目录 listSync（非递归、单层），每访问一个条目就计数；
  /// 超过 [maxEntries] 立即停止 —— 同步接口下既不阻塞 UI 太久，又能保证
  /// 全盘大目录（/sdcard）下有限时间内返回。权限拒绝的目录跳过（continue）。
  (List<FileSystemEntity>, bool) _walkLimited(String path, int maxEntries) {
    final result = <FileSystemEntity>[];
    final stack = <Directory>[Directory(path)];
    while (stack.isNotEmpty && result.length < maxEntries) {
      final dir = stack.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        continue; // 无权限/损坏目录 → 跳过，继续其他分支。
      }
      for (final e in entries) {
        if (result.length >= maxEntries) {
          break;
        }
        result.add(e);
        if (e is Directory) {
          stack.add(e);
        }
      }
    }
    return (result, result.length >= maxEntries);
  }

  bool _fileGlobMatch(String? glob, String name) {
    if (glob == null || glob.isEmpty) {
      return true;
    }
    return _globMatch(glob, name);
  }

  /// 极简 glob 匹配（`*`/`?`/`**`），等价 rg --glob 的常用子集。
  bool _globMatch(String pattern, String name) {
    if (!pattern.contains('*') && !pattern.contains('?')) {
      return pattern == name;
    }
    // 先转义字面正则特殊字符，再替换通配符 —— 顺序不能反，否则会破坏插入的
    // 字符类（`[^/]`）。
    var re = pattern.replaceAllMapped(
      RegExp(r'([.+^${}()|\[\]\\])'),
      (m) => '\\${m[1]}',
    );
    re = re
        .replaceAllMapped(RegExp(r'\*\*+'), (_) => '.*')
        .replaceAll('*', '[^/]*')
        .replaceAll('?', '.');
    return RegExp('^$re\$').hasMatch(name);
  }

  // LSP 语义诊断：Android 无 LSP，恒返回 ""。
  String _maybeLspDiagnostics(String path, {String? preContent, String? postContent}) =>
      '';
}
