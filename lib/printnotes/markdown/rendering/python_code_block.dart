// Python 代码块执行：内置 Pyodide core 运行时（WebAssembly Python），
// 在 HeadlessInAppWebView 中跑真实 CPython，支持 numpy/matplotlib/networkx
// 画图并渲染成图片。科学计算 wheels 按需从用户 GitHub 仓库下载并缓存。
//
// 架构（与 mermaid_widget 一致）：
//   - 全局单例 PythonEngine：全 App 只维护一个 WebView，串行执行所有代码块
//   - 首次运行解压 pyodide core（assets 内 6.7MB）→ loadPyodide → 常驻复用
//   - import 分析 → 依赖闭包 → 缺失 wheel 提示下载 → 执行 → 返回 stdout + 图片

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'code_engine.dart';

/// 单个 wheel 的描述（名称 = import 顶层名）。
class PyWheel {
  const PyWheel(this.name, this.wheel, this.sizeMB, this.deps);
  final String name;
  final String wheel;
  final double sizeMB;
  final List<String> deps;
}

/// 全部已准备的 wheels（存放在 GitHub 仓库 assets/python/wheels/）。
/// key = import 顶层包名（含 from X import 的 X）。
const Map<String, PyWheel> _wheels = {
  'numpy': PyWheel(
      'numpy', 'numpy-2.4.3-cp314-cp314-pyemscripten_2026_0_wasm32.whl', 15.0,
      []),
  'matplotlib': PyWheel(
      'matplotlib',
      'matplotlib-3.10.8-cp314-cp314-pyemscripten_2026_0_wasm32.whl',
      10.8,
      ['numpy', 'contourpy', 'cycler', 'fonttools', 'kiwisolver', 'packaging',
       'pyparsing', 'dateutil', 'pytz', 'six', 'PIL']),
  'networkx': PyWheel(
      'networkx', 'networkx-3.6.1-py3-none-any.whl', 2.2, []),
  'PIL': PyWheel(
      'PIL', 'pillow-12.2.0-cp314-cp314-pyemscripten_2026_0_wasm32.whl', 4.5,
      []),
  'contourpy': PyWheel(
      'contourpy',
      'contourpy-1.3.3-cp314-cp314-pyemscripten_2026_0_wasm32.whl', 3.1, []),
  'cycler': PyWheel('cycler', 'cycler-0.12.1-py3-none-any.whl', 0.1, []),
  'fonttools': PyWheel(
      'fonttools', 'fonttools-4.62.1-py3-none-any.whl', 3.6, []),
  'kiwisolver': PyWheel(
      'kiwisolver', 'kiwisolver-1.5.0-cp314-cp314-pyemscripten_2026_0_wasm32.whl',
      1.4, []),
  'packaging': PyWheel('packaging', 'packaging-26.1-py3-none-any.whl', 0.1, []),
  'pyparsing': PyWheel('pyparsing', 'pyparsing-3.3.2-py3-none-any.whl', 0.2, []),
  'dateutil': PyWheel(
      'dateutil', 'python_dateutil-2.9.0.post0-py2.py3-none-any.whl', 0.4, []),
  'pytz': PyWheel('pytz', 'pytz-2026.1.post1-py2.py3-none-any.whl', 0.3, []),
  'six': PyWheel('six', 'six-1.17.0-py2.py3-none-any.whl', 0.1, []),
};

/// 代码块运行结果。
class PythonRunResult {
  const PythonRunResult({
    this.stdout = '',
    this.stderr = '',
    this.images = const [],
    this.error,
  });
  final String stdout;
  final String stderr;
  final List<String> images; // base64 PNG
  final String? error;
}

/// 解析 Python 源码的顶层 import 名（去重、仅映射表内感兴趣的）。
Set<String> analyzeImports(String code) {
  final re = RegExp(
    r'^\s*(?:import\s+([A-Za-z_]\w*)|from\s+([A-Za-z_]\w*)\s+import)\b',
    multiLine: true,
  );
  final result = <String>{};
  for (final m in re.allMatches(code)) {
    final name = (m.group(1) ?? m.group(2))!;
    if (_wheels.containsKey(name)) result.add(name);
  }
  return result;
}

/// 顶层包 → 依赖闭包（返回全部需要 wheel 的包名）。
Set<String> wheelClosure(Set<String> tops) {
  final result = <String>{};
  void visit(String name) {
    final w = _wheels[name];
    if (w == null || !result.add(name)) return;
    for (final d in w.deps) {
      visit(d);
    }
  }

  for (final t in tops) {
    visit(t);
  }
  return result;
}

/// Python 代码块 → 运行按钮 + 下载提示 + 执行结果（文本 + matplotlib 图片）。
class PythonCodeBlockWidget extends StatefulWidget {
  const PythonCodeBlockWidget({super.key, required this.code});

  /// Python 源码（不含 ```python 围栏）。
  final String code;

  @override
  State<PythonCodeBlockWidget> createState() => _PythonCodeBlockWidgetState();
}

class _PythonCodeBlockWidgetState extends State<PythonCodeBlockWidget> {
  // idle → running → needPackages → downloading → executing → done / error
  String _state = 'idle';
  String? _error;
  PythonRunResult? _result;
  Set<String> _pendingWheels = {};
  int _dlDone = 0;
  int _dlTotal = 0;
  String _dlName = '';

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
          Icon(Icons.terminal, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text('python',
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
    if (_state == 'running' || _state == 'executing') {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_state == 'needPackages') {
      return FilledButton(
        onPressed: _onDownloadAndRun,
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [Icon(Icons.download, size: 16), Text('下载并运行')],
        ),
      );
    }
    if (_state == 'downloading') {
      return Text('${_dlDone}/${_dlTotal}',
          style: TextStyle(fontSize: 12, color: theme.colorScheme.primary));
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
                Text('初始化 Python 环境…',
                    style: TextStyle(
                        fontSize: 13, color: theme.colorScheme.primary)),
              ],
            ),
          ),
      ];
    }

    if (_state == 'needPackages') {
      final names = _pendingWheels
          .map((n) =>
              '${_wheels[n]!.name}(${_wheels[n]!.sizeMB.toStringAsFixed(1)}MB)')
          .join('、');
      return [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('这段代码需要以下 Python 库：',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface)),
              const SizedBox(height: 6),
              Text(names,
                  style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace')),
              const SizedBox(height: 6),
              Text('首次运行会从 GitHub 仓库下载并缓存（仅一次）。',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ];
    }

    if (_state == 'downloading') {
      return [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Expanded(
                child: Text('正在下载 $_dlName（$_dlDone/$_dlTotal）…',
                    style: TextStyle(
                        fontSize: 13, color: theme.colorScheme.primary)),
              ),
            ],
          ),
        ),
      ];
    }

    if (_state == 'executing') {
      return [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('执行中…',
                  style: TextStyle(
                      fontSize: 13, color: theme.colorScheme.primary)),
            ],
          ),
        ),
      ];
    }

    // done / error
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
            if (result != null && result.stdout.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText(result.stdout.trim(),
                    style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    ];
  }

  Future<void> _onRun() async {
    final engine = PythonEngine.instance;
    setState(() {
      _state = 'running';
      _error = null;
      _result = null;
    });

    // 分析 import → 依赖闭包 → 检查缺失
    final tops = analyzeImports(widget.code);
    final closure = wheelClosure(tops);
    final missing = await engine.missingWheels(closure);

    if (!mounted) return;
    if (missing.isNotEmpty) {
      setState(() {
        _pendingWheels = missing;
        _state = 'needPackages';
      });
      return;
    }

    await _execute(closure);
  }

  Future<void> _onDownloadAndRun() async {
    final engine = PythonEngine.instance;
    final wheels = _pendingWheels;
    setState(() {
      _dlDone = 0;
      _dlTotal = wheels.length;
      _dlName = '';
      _state = 'downloading';
    });
    try {
      await engine.downloadWheels(
        wheels.toList(),
        onProgress: (done, total, name) {
          if (!mounted) return;
          setState(() {
            _dlDone = done;
            _dlTotal = total;
            _dlName = name;
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = 'idle';
        _error = e.toString();
      });
      return;
    }
    if (!mounted) return;
    await _execute(wheels);
  }

  Future<void> _execute(Set<String> wheels) async {
    setState(() {
      _state = 'executing';
      _error = null;
    });
    try {
      final r = await PythonEngine.instance.run(widget.code, wheels);
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

/// 全局唯一 Python 执行引擎（Pyodide）。
///
/// - 首次使用：解压 pyodide core（assets）→ 创建 WebView → loadPyodide
/// - 串行执行所有代码块（同一时刻只有一个 WebView 任务）
/// - wheels 下载到应用私有目录缓存
class PythonEngine {
  PythonEngine._();
  static final PythonEngine instance = PythonEngine._();

  /// 解压后 pyodide 运行时目录（相对 appSupport）。
  static const _pyodideDir = 'pyodide';
  static const _packagesDir = 'python_packages';

  /// 从用户 GitHub 仓库下载 wheels。
  static const _githubBase =
      'https://raw.githubusercontent.com/ZhengJL18/MIX/master/assets/python/wheels/';

  /// wheels 下载地址（公开，供 PythonCodeEngine.requiredAssets 使用）。
  static String get wheelsBaseUrl => _githubBase;

  static const _initTimeout = Duration(seconds: 60);
  static const _runTimeout = Duration(seconds: 90);

  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Future<void>? _initFuture;
  bool _disposed = false;
  Set<String> _loadedWheels = {};
  // JS async 操作结果回传（callHandler → Completer）
  Completer<String>? _resultCompleter;

  // 串行执行队列
  Future<void> _tail = Future.value();

  Future<Directory> get _appSupport async =>
      await getApplicationSupportDirectory();

  /// 已下载缓存的 wheel 是否就绪。
  Future<Set<String>> missingWheels(Set<String> closure) async {
    final dir = Directory('${(await _appSupport).path}/$_packagesDir');
    final missing = <String>{};
    for (final name in closure) {
      final w = _wheels[name]!;
      final f = File('${dir.path}/${w.wheel}');
      if (!f.existsSync()) missing.add(name);
    }
    return missing;
  }

  /// 下载缺失的 wheels（带进度回调）。
  Future<void> downloadWheels(
    List<String> names, {
    void Function(int done, int total, String name)? onProgress,
  }) async {
    final dir = Directory('${(await _appSupport).path}/$_packagesDir');
    if (!dir.existsSync()) await dir.create(recursive: true);

    var done = 0;
    final total = names.length;
    for (final name in names) {
      final w = _wheels[name]!;
      final f = File('${dir.path}/${w.wheel}');
      if (f.existsSync() && f.lengthSync() > 0) {
        done++;
        onProgress?.call(done, total, name);
        continue;
      }
      onProgress?.call(done, total, name);
      final resp = await http.get(Uri.parse('$_githubBase${w.wheel}'));
      if (resp.statusCode != 200) {
        throw StateError(
            '下载 ${w.name} 失败（HTTP ${resp.statusCode}）\n'
            '$_githubBase${w.wheel}');
      }
      await f.writeAsBytes(resp.bodyBytes);
      done++;
      onProgress?.call(done, total, name);
    }
  }

  /// 执行 Python 代码（串行）。wheels = 需要加载的包闭包。
  Future<PythonRunResult> run(String code, Set<String> wheels) {
    final completer = Completer<PythonRunResult>();
    _tail = _tail.then((_) async {
      try {
        final r = await _runInternal(code, wheels);
        if (!completer.isCompleted) completer.complete(r);
      } catch (e) {
        if (!completer.isCompleted) {
          completer.complete(PythonRunResult(error: e.toString()));
        }
      }
    });
    return completer.future;
  }

  Future<PythonRunResult> _runInternal(
      String code, Set<String> wheels) async {
    await _ensureInit();
    final controller = _controller!;

    // 1) 加载 wheels（按拓扑序，先依赖后本体；幂等跳过已加载的）
    final toLoad = _topoOrder(wheels.difference(_loadedWheels));
    if (toLoad.isNotEmpty) {
      final dir = await _appSupport;
      final paths = toLoad.map((n) {
        final w = _wheels[n]!;
        return 'file://${dir.path}/$_packagesDir/${w.wheel}';
      }).toList();
      final res = await _evalWithResult(
          'mixLoadWheels(${jsonEncode(paths)})');
      final map = _decodeMap(res);
      if (map['ok'] != true) {
        throw StateError('加载 Python 库失败: ${map['error'] ?? 'unknown'}');
      }
      _loadedWheels.addAll(toLoad);
    }

    // 2) 执行
    final res = await _evalWithResult('mixRun(${jsonEncode(code)})')
        .timeout(_runTimeout);
    final map = _decodeMap(res);
    if (map['ok'] != true) {
      return PythonRunResult(
          error: (map['error'] ?? 'unknown error').toString(),
          stdout: (map['stdout'] ?? '').toString());
    }
    final images = <String>[];
    if (map['images'] is List) {
      for (final img in map['images'] as List) {
        if (img is String) images.add(img);
      }
    }
    return PythonRunResult(
      stdout: (map['stdout'] ?? '').toString(),
      stderr: (map['stderr'] ?? '').toString(),
      images: images,
    );
  }

  /// 按依赖拓扑排序（先依赖后本体），供 loadPackageFromFile 顺序加载。
  List<String> _topoOrder(Set<String> names) {
    final result = <String>[];
    final visited = <String>{};
    void visit(String n) {
      if (visited.contains(n)) return;
      visited.add(n);
      final w = _wheels[n];
      if (w == null) return;
      for (final d in w.deps) {
        if (_wheels.containsKey(d)) visit(d);
      }
      result.add(n);
    }

    for (final n in names) {
      visit(n);
    }
    return result;
  }

  /// 执行 JS（async 函数）：结果由 JS 侧 callHandler 主动回传。
  Future<String> _evalWithResult(String source) async {
    final c = Completer<String>();
    _resultCompleter = c;
    try {
      await _controller!.evaluateJavascript(source: source);
    } catch (e) {
      _resultCompleter = null;
      if (!c.isCompleted) c.completeError(e);
    }
    return c.future;
  }

  Map<String, dynamic> _decodeMap(dynamic res) {
    if (res is Map) return Map<String, dynamic>.from(res);
    if (res is String) {
      try {
        final d = jsonDecode(res);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return {};
  }

  Future<void> _ensureInit() async {
    if (_webView != null && !_disposed) return;
    if (_initFuture != null) return _initFuture;
    _initFuture = _create();
    return _initFuture;
  }

  Future<void> _create() async {
    _disposed = false;

    // 解压 pyodide core（幂等）
    final appSupport = await _appSupport;
    final runtimeDir = Directory('${appSupport.path}/$_pyodideDir');
    if (!File('${runtimeDir.path}/pyodide.js').existsSync()) {
      final bytes = await rootBundle
          .load('assets/python/pyodide-core-314.0.4.tar.bz2')
          .then((b) => b.buffer.asUint8List());
      if (!runtimeDir.existsSync()) await runtimeDir.create(recursive: true);
      final archive = BZip2Decoder().decodeBytes(bytes);
      final tar = TarDecoder().decodeBytes(archive);
      for (final f in tar.files) {
        if (f.isFile) {
          final out = File('${runtimeDir.path}/${f.name}');
          if (!out.parent.existsSync()) {
            await out.parent.create(recursive: true);
          }
          await out.writeAsBytes(f.content as List<int>, flush: true);
        }
      }
    }

    final created = Completer<void>();
    final headless = HeadlessInAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        allowFileAccess: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        // JS → Dart 主动回传：async 操作（加载 wheels / 执行代码）完成后
        // 由 JS 调用 callHandler 把结果推给 Dart（evaluateJavascript 无法等待 Promise）。
        controller.addJavaScriptHandler(
          handlerName: 'mixAsyncResult',
          callback: (args) {
            if (args.isNotEmpty && args.first is String) {
              final c = _resultCompleter;
              _resultCompleter = null;
              if (c != null && !c.isCompleted) {
                c.complete(args.first as String);
              }
            }
            return null;
          },
        );
        if (!created.isCompleted) created.complete();
      },
      onLoadStop: (controller, url) async {
        // 加载完成后调用 mixInit（幂等）初始化 Pyodide
        if (_initFuture == null) return;
        try {
          await controller.evaluateJavascript(source: 'mixInit()');
        } catch (_) {}
      },
      onLoadError: (controller, url, code, message) {
        // 忽略（onReceivedError 已处理）
      },
    );
    _webView = headless;
    await headless.run();
    await created.future.timeout(const Duration(seconds: 15));

    // 加载 HTML（baseUrl 指向解压后的 pyodide 运行时目录）
    final runtimeUrl =
        WebUri('file://${runtimeDir.path}/');
    await _controller!.loadData(
      data: _buildHtml(),
      baseUrl: runtimeUrl,
    );

    // 等待 mixInit 完成（轮询标记）
    final ready = await _waitForPyodideReady();
    if (!ready) {
      throw StateError('Pyodide 初始化失败或超时');
    }
  }

  Future<bool> _waitForPyodideReady() async {
    final deadline = DateTime.now().add(_initTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final res = await _controller!.evaluateJavascript(
            source: 'mixReady()');
        if (res == true || res == 'true' || res == 1) return true;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  String _buildHtml() {
    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<script src="pyodide.js"></script>
</head>
<body>
<script>
var mix_pyodide = null;
var mix_ready = false;

function mixReady() {
  return mix_ready;
}

async function mixInit() {
  if (mix_ready) return JSON.stringify({ok: true});
  try {
    mix_pyodide = await loadPyodide({indexURL: document.baseURI});
    mix_ready = true;
    return JSON.stringify({ok: true});
  } catch (e) {
    return JSON.stringify({ok: false, error: String(e)});
  }
}

async function mixLoadWheels(paths) {
  try {
    if (!mix_ready) { window.flutter_inappwebview.callHandler('mixAsyncResult', JSON.stringify({ok: false, error: 'pyodide not ready'})); return; }
    for (var i = 0; i < paths.length; i++) {
      await mix_pyodide.loadPackageFromFile(paths[i]);
    }
    window.flutter_inappwebview.callHandler('mixAsyncResult', JSON.stringify({ok: true}));
  } catch (e) {
    window.flutter_inappwebview.callHandler('mixAsyncResult', JSON.stringify({ok: false, error: String(e)}));
  }
}

async function mixRun(code) {
  try {
    if (!mix_ready) { window.flutter_inappwebview.callHandler('mixAsyncResult', JSON.stringify({ok: false, error: 'pyodide not ready'})); return; }
    var pre = [
      "import sys, io, base64",
      "import matplotlib",
      "matplotlib.use('Agg')",
      "import matplotlib.pyplot as plt",
      "_MIX_IMGS = []",
      "def _mix_show(*a, **k):",
      "    _mix_save_figs()",
      "def _mix_save_figs():",
      "    import io as _io, base64 as _b64",
      "    for _f in plt.get_fignums():",
      "        _fig = plt.figure(_f)",
      "        _buf = _io.BytesIO()",
      "        _fig.savefig(_buf, format='png', dpi=110, bbox_inches='tight')",
      "        _MIX_IMGS.append(_b64.b64encode(_buf.getvalue()).decode())",
      "        plt.close(_fig)",
      "plt.show = _mix_show",
      "_MIX_OUT = io.StringIO()",
      "_MIX_ERR = io.StringIO()",
      "_mix_orig_stdout, _mix_orig_stderr = sys.stdout, sys.stderr",
      "sys.stdout, sys.stderr = _MIX_OUT, _MIX_ERR",
      ""
    ].join('\\n');
    mix_pyodide.runPython(pre);
    mix_pyodide.runPython(code);
    var post = [
      "_mix_save_figs()",
      "sys.stdout, sys.stderr = _mix_orig_stdout, _mix_orig_stderr",
      "import json",
      "result = json.dumps({'ok': True, 'stdout': _MIX_OUT.getvalue(), 'stderr': _MIX_ERR.getvalue(), 'images': _MIX_IMGS})"
    ].join('\\n');
    mix_pyodide.runPython(post);
    window.flutter_inappwebview.callHandler('mixAsyncResult', mix_pyodide.globals.get('result'));
  } catch (e) {
    var stderr = '';
    try {
      stderr = mix_pyodide.runPython('_MIX_ERR.getvalue()') || '';
    } catch (_) {}
    window.flutter_inappwebview.callHandler('mixAsyncResult', JSON.stringify({ok: false, error: String(e), stdout: '', stderr: stderr}));
  }
}
</script>
</body>
</html>
''';
  }
}

/// python 引擎：内置 Pyodide 执行，matplotlib 画图渲染成图片。
/// 运行时 pyodide core 打包进 APK；科学计算 wheels 按需从 GitHub 仓库下载。
class PythonCodeEngine extends CodeEngine {
  const PythonCodeEngine();

  @override
  String get language => 'python';

  @override
  List<String> get aliases => const ['py'];

  @override
  String get displayName => 'Python (Pyodide)';

  @override
  List<EngineAsset> get requiredAssets => _wheels.entries.map((e) {
        final w = e.value;
        return EngineAsset(
          name: e.key,
          url: '${PythonEngine.wheelsBaseUrl}${w.wheel}',
          sizeMB: w.sizeMB,
        );
      }).toList();

  @override
  Widget buildWidget(String code) => PythonCodeBlockWidget(code: code);
}
