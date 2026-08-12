/// 终端工具（Linux 桌面专属）：让 agent 直接执行 shell 命令。
///
/// Linux 版不嵌 WebView，改用系统命令行能力替代：
/// - 网页抓取 → curl
/// - PDF 文本 → pdftotext
/// - 任意文件/系统操作 → shell 命令
/// 这是 Linux 版 agent 的"万能工具"，能力比 Android 更强。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'registry.dart';

/// 执行 shell 命令，返回 stdout/stderr/exit_code。
/// 超时自动 kill（防死循环）。
Future<Map<String, dynamic>> runTerminal(
  String command, {
  String? cwd,
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    final result = await Process.run(
      'bash',
      ['-c', command],
      workingDirectory: cwd,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);
    return {
      'stdout': (result.stdout as String?) ?? '',
      'stderr': (result.stderr as String?) ?? '',
      'exit_code': result.exitCode,
    };
  } on TimeoutException {
    return {
      'stdout': '',
      'stderr': '命令执行超时（>${timeout.inSeconds}s），已终止。',
      'exit_code': -1,
    };
  } catch (e) {
    return {
      'stdout': '',
      'stderr': '命令执行失败：$e',
      'exit_code': -1,
    };
  }
}

const Map<String, dynamic> _terminalSchema = {
  'name': 'run_terminal',
  'description':
      'Execute a shell command on the Linux desktop and return its output. '
      'Use this for file operations, running scripts, curl web requests, '
      'pdftotext PDF extraction, system commands, etc. '
      'The command runs via `bash -c`. Always prefer specific tools when '
      'they exist, but this gives you full terminal capability.',
  'parameters': {
    'type': 'object',
    'properties': {
      'command': {
        'type': 'string',
        'description': 'The shell command to execute',
      },
      'cwd': {
        'type': 'string',
        'description': 'Optional working directory (default: app directory)',
      },
    },
    'required': ['command'],
  },
};

Future<String> _handleTerminal(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  // 仅 Linux 注册（Android 上不暴露，避免滥用）。
  final command = args['command'] as String? ?? '';
  if (command.trim().isEmpty) {
    return toolError('run_terminal: command 不能为空');
  }
  final result = await runTerminal(
    command,
    cwd: args['cwd'] as String?,
  );
  return jsonEncode(result);
}

/// 注册终端工具（Linux 桌面专属）。
void registerTerminalTool() {
  registry.register(
    name: 'run_terminal',
    toolset: 'file',
    schema: _terminalSchema,
    handler: _handleTerminal,
    isAsync: true,
    emoji: '💻',
  );
}
