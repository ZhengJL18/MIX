// 云端代码块执行：把代码 POST 到用户自己的服务器执行（HTTP/JSON），
// 返回 stdout / stderr / matplotlib 图片。替代本地 serious_python / libtcc，
// 同时解锁 js / bash / java / sql 等之前只能静态展示的语言。
//
// 配置（SharedPreferences，键 remote_exec_url / remote_exec_token）：
//   未配置时点「运行」弹对话框填写，存好后复用。
//
// 协议：
//   POST {url}/run  {"token":..., "language":..., "code":...}
//   → {"stdout","stderr","images":[base64 PNG...],"exit_code","duration_ms","error"}
//
// 服务器端见 assets/remote-runner/server.py（单文件，部署到用户云服务器）。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'code_engine.dart';

/// 云端运行结果。
class RemoteRunResult {
  const RemoteRunResult({
    this.stdout = '',
    this.stderr = '',
    this.images = const [],
    this.error,
    this.durationMs,
  });
  final String stdout;
  final String stderr;
  final List<String> images; // base64 PNG
  final String? error;
  final int? durationMs;
}

/// 云端引擎（一个实例对应一种语言，注册时覆盖本地 python/c 引擎）。
class RemoteCodeEngine extends CodeEngine {
  const RemoteCodeEngine(this.lang, this.display, {this.aliases = const []});

  final String lang;
  final String display;
  final List<String> aliases;

  @override
  String get language => lang;

  @override
  String get displayName => display;

  @override
  List<EngineAsset> get requiredAssets => const [];

  @override
  Widget buildWidget(String code) =>
      RemoteCodeBlockWidget(code: code, language: lang, displayName: display);
}

/// 代码块 UI：运行按钮 + 结果（文本 + 图片）。
class RemoteCodeBlockWidget extends StatefulWidget {
  const RemoteCodeBlockWidget({
    super.key,
    required this.code,
    required this.language,
    required this.displayName,
  });

  final String code;
  final String language;
  final String displayName;

  @override
  State<RemoteCodeBlockWidget> createState() => _RemoteCodeBlockWidgetState();
}

class _RemoteCodeBlockWidgetState extends State<RemoteCodeBlockWidget> {
  // idle → running → done / error
  String _state = 'idle';
  RemoteRunResult? _result;
  String? _error;

  static const _urlKey = 'remote_exec_url';
  static const _tokenKey = 'remote_exec_token';

  Future<void> _onRun() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_urlKey)?.trim() ?? '';
    if (url.isEmpty) {
      _showConfigDialog(prefs);
      return;
    }
    final token = prefs.getString(_tokenKey)?.trim() ?? '';
    setState(() {
      _state = 'running';
      _result = null;
      _error = null;
    });
    try {
      final r = await _run(url, token);
      if (!mounted) return;
      setState(() {
        _result = r;
        _state = (r.error == null) ? 'done' : 'error';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = 'error';
        _error = e.toString();
      });
    }
  }

  Future<RemoteRunResult> _run(String url, String token) async {
    final base = url.replaceAll(RegExp(r'/+$'), '');
    final resp = await http
        .post(
          Uri.parse('$base/run'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'token': token,
            'language': widget.language,
            'code': widget.code,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode == 401) {
      return const RemoteRunResult(error: 'token 错误，请重新配置服务器');
    }
    if (resp.statusCode != 200) {
      return RemoteRunResult(error: '服务器返回 ${resp.statusCode}：${resp.body}');
    }
    final m = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return RemoteRunResult(
      stdout: (m['stdout'] as String?) ?? '',
      stderr: (m['stderr'] as String?) ?? '',
      images: ((m['images'] as List?) ?? const []).cast<String>(),
      error: m['error'] as String?,
      durationMs: m['duration_ms'] as int?,
    );
  }

  /// 未配置服务器时弹出的配置对话框。
  Future<void> _showConfigDialog(SharedPreferences prefs) async {
    final urlCtrl =
        TextEditingController(text: prefs.getString(_urlKey) ?? '');
    final tokenCtrl =
        TextEditingController(text: prefs.getString(_tokenKey) ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('配置云端执行服务器'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'http://43.139.179.58:8123',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: tokenCtrl,
              decoration: const InputDecoration(
                labelText: 'Token',
                hintText: '部署 server.py 时设置的 MIX_RUN_TOKEN',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '服务器端部署见仓库 assets/remote-runner/',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await prefs.setString(_urlKey, urlCtrl.text.trim());
      await prefs.setString(_tokenKey, tokenCtrl.text.trim());
      if (urlCtrl.text.trim().isNotEmpty) _onRun();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4);
    final border = theme.colorScheme.onSurface.withValues(alpha: 0.15);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(theme),
          const Divider(height: 1),
          ..._buildBody(theme),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.cloud_outlined,
              size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(widget.language,
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace')),
          const Spacer(),
          _buildAction(theme),
        ],
      ),
    );
  }

  Widget _buildAction(ThemeData theme) {
    if (_state == 'idle') {
      return FilledButton.tonal(
        onPressed: _onRun,
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [Icon(Icons.play_arrow, size: 16), Text('运行')],
        ),
      );
    }
    if (_state == 'running') {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    // done / error
    return IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      tooltip: '重新运行',
      icon: const Icon(Icons.refresh),
      onPressed: _onRun,
    );
  }

  List<Widget> _buildBody(ThemeData theme) {
    final codeStyle = TextStyle(
        fontSize: 13,
        fontFamily: 'monospace',
        color: theme.colorScheme.onSurface);

    if (_state == 'idle' || _state == 'running') {
      return [
        _CodeView(code: widget.code, style: codeStyle),
        if (_state == 'running')
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text('发送到服务器执行…',
                    style: TextStyle(
                        fontSize: 13, color: theme.colorScheme.primary)),
              ],
            ),
          ),
      ];
    }

    final result = _result;
    if (result != null && result.error == null && result.images.isNotEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final b64 in result.images)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Image.memory(
                    base64Decode(b64),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
            ],
          ),
        ),
        if (result.stdout.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: SelectableText(
              result.stdout.trim(),
              style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ];
    }

    final errText = result?.error ??
        (result != null && result.stderr.trim().isNotEmpty
            ? result.stderr.trim()
            : _error);
    final hasStdout = result != null && result.stdout.trim().isNotEmpty;
    return [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('运行结果：',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface)),
            const SizedBox(height: 6),
            if (errText != null && errText.isNotEmpty)
              SelectableText(errText,
                  style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: theme.colorScheme.error)),
            if (hasStdout)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText(result!.stdout.trim(),
                    style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            if (result?.durationMs != null && errText == null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('耗时 ${result!.durationMs}ms',
                    style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    ];
  }
}

/// 代码块只读视图（等宽字体 + 底色）。
class _CodeView extends StatelessWidget {
  const _CodeView({required this.code, required this.style});
  final String code;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      child: SelectableText(code, style: style),
    );
  }
}
