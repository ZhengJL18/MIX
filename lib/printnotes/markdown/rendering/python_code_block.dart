// Python 代码块执行：serious_python 原生 CPython（非 WASM）在后台线程运行，
// 通过 HTTP 与本 App 通信（runner = assets/python/runner/main.py，纯 stdlib）。
// 支持 numpy/matplotlib/networkx 画图并渲染成图片。科学计算 wheels 按需从
// 用户 GitHub 仓库下载、解压到私有目录、运行时注入 sys.path（不进 APK）。
//
// 架构（与旧 WebView+Pyodide 方案的区别）：
//   - 旧：WASM CPython 跑在 HeadlessInAppWebView，单线程 + JS 桥接，matplotlib
//     大图渲染超时画不出来（性能瓶颈是结构性的）。
//   - 新：原生 CPython 3.14 后台线程（serious_python），HTTP/JSON 通信，
//     matplotlib Agg 渲染为原生速度，图秒出。
//   - 全局单例 PythonEngine：全 App 只维护一个 runner，串行执行所有代码块
//   - import 分析 → 依赖闭包 → 缺失 wheel 提示下载 → 解压注入 → 执行 → 返回 stdout + 图片

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:serious_python/serious_python.dart';

import 'code_engine.dart';

/// 单个 wheel 的描述（名称 = import 顶层名）。
class PyWheel {
  const PyWheel(this.name, this.wheel, this.sizeMB, this.deps);
  final String name;
  final String wheel;
  final double sizeMB;
  final List<String> deps;
}

/// 全部已准备的 wheels（存放在 GitHub 仓库 assets/python/wheels-android/）。
/// 平台：CPython 3.14 + Android arm64（android_24_arm64_v8a）。
/// key = import 顶层包名（含 from X import 的 X）。
const Map<String, PyWheel> _wheels = {
  'numpy': PyWheel(
      'numpy', 'numpy-2.4.6-1-cp314-cp314-android_24_arm64_v8a.whl', 6.8,
      []),
  'matplotlib': PyWheel(
      'matplotlib',
      'matplotlib-3.10.9-2-cp314-cp314-android_24_arm64_v8a.whl',
      8.2,
      ['numpy', 'contourpy', 'cycler', 'fonttools', 'kiwisolver', 'packaging',
       'pyparsing', 'dateutil', 'pytz', 'six', 'PIL']),
  'networkx': PyWheel(
      'networkx', 'networkx-3.6.1-py3-none-any.whl', 2.2, []),
  'PIL': PyWheel(
      'PIL', 'pillow-12.2.0-1-cp314-cp314-android_24_arm64_v8a.whl', 0.6,
      []),
  'contourpy': PyWheel(
      'contourpy',
      'contourpy-1.3.3-1-cp314-cp314-android_24_arm64_v8a.whl', 0.3, []),
  'cycler': PyWheel('cycler', 'cycler-0.12.1-py3-none-any.whl', 0.1, []),
  'fonttools': PyWheel(
      'fonttools', 'fonttools-4.62.1-py3-none-any.whl', 3.6, []),
  'kiwisolver': PyWheel(
      'kiwisolver', 'kiwisolver-1.5.0-1-cp314-cp314-android_24_arm64_v8a.whl',
      0.1, []),
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

/// 剥离 Jupyter/IPython 魔法命令与 shell 命令，让 notebook 代码能直接在
/// Pyodide 里跑（普通 Python 解释器没有这些语法，遇到会 SyntaxError）：
///   - `%matplotlib inline`、`%time` 等 `%` 开头的行
///   - `!pip install ...` 等 `!` 开头的 shell 行
///   - `%%time` 等单元魔法块（%% 开头到下一个空行/结尾）
/// 逐行过滤保留其余代码；魔法命令不影响程序逻辑（notebook 里它们只是指令）。
String sanitizePythonCode(String code) {
  final lines = code.split('\n');
  final out = <String>[];
  var inCellMagic = false;
  for (final raw in lines) {
    final line = raw.trimRight();
    final t = line.trimLeft();
    if (t.startsWith('%%')) {
      // 单元魔法：跳过该行及其后直到空行的内容
      inCellMagic = true;
      continue;
    }
    if (inCellMagic) {
      if (t.isEmpty) inCellMagic = false;
      continue;
    }
    if (t.startsWith('%') || t.startsWith('!')) continue; // 行魔法 / shell
    out.add(line);
  }
  return out.join('\n');
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
  String _phase = ''; // executing 阶段的细分进度文案

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
              Text(_phase.isEmpty ? '执行中…' : '$_phase…',
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
      _phase = '';
    });
    try {
      final r = await PythonEngine.instance.run(widget.code, wheels,
          onPhase: (p) {
        if (!mounted) return;
        if (p != _phase) setState(() => _phase = p);
      });
      if (!mounted) return;
      setState(() {
        _result = r;
        _phase = '';
        _state = (r.error == null) ? 'done' : 'error';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = 'error';
        _phase = '';
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

/// 全局唯一 Python 执行引擎（serious_python 原生 CPython）。
///
/// - 首次使用：启动 runner（assets/python/runner/main.py 打包进 APK 的
///   stdlib-only HTTP server）→ 后台线程跑 CPython 3.14 → 轮询端口文件
/// - 串行执行所有代码块（同一时刻只有一个 runner 任务）
/// - wheels 下载到应用私有目录，解压后通过 HTTP /add_path 注入 sys.path
class PythonEngine {
  PythonEngine._();
  static final PythonEngine instance = PythonEngine._();

  /// wheel 下载缓存目录（相对 appSupport）。
  static const _packagesDir = 'python_packages';

  /// wheel 解压注入目录（相对 appSupport）。
  static const _wheelsDir = 'python_wheels';

  /// 从用户 GitHub 仓库下载 wheels（android arm64 平台）。
  static const _githubBase =
      'https://raw.githubusercontent.com/ZhengJL18/MIX/master/assets/python/wheels-android/';

  /// wheels 下载地址（公开，供 PythonCodeEngine.requiredAssets 使用）。
  static String get wheelsBaseUrl => _githubBase;

  static const _startTimeout = Duration(seconds: 60);
  static const _runTimeout = Duration(seconds: 120);

  // runner 状态
  bool _started = false;
  Future<void>? _startFuture;
  int? _port;
  Set<String> _loadedWheels = {};

  // 串行执行队列
  Future<void> _tail = Future.value();

  Future<Directory> get _appSupport async =>
      await getApplicationSupportDirectory();

  /// 已下载缓存的 wheel 是否就绪（检查 .whl 文件存在）。
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
  /// onPhase 每进入一个阶段回调一次（初始化引擎 / 加载库 / 执行代码），
  /// 供 UI 显示当前进度。
  Future<PythonRunResult> run(
    String code,
    Set<String> wheels, {
    void Function(String phase)? onPhase,
  }) {
    final completer = Completer<PythonRunResult>();
    _tail = _tail.then((_) async {
      try {
        final r = await _runInternal(sanitizePythonCode(code), wheels,
            onPhase: onPhase);
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
    String code,
    Set<String> wheels, {
    void Function(String phase)? onPhase,
  }) async {
    await _ensureStarted();

    // 1) 解压缺失的 wheel → HTTP add_path 注入 sys.path（按拓扑序）
    final toLoad = _topoOrder(wheels.difference(_loadedWheels));
    if (toLoad.isNotEmpty) {
      onPhase?.call('加载库');
      for (final name in toLoad) {
        final dir = await _extractWheel(name);
        await _post('/add_path', {'path': dir});
      }
      _loadedWheels.addAll(toLoad);
    }

    // 2) 执行
    onPhase?.call('执行代码');
    final map = await _post('/run', {'code': code}).timeout(_runTimeout);
    if (map['ok'] != true) {
      return PythonRunResult(
          error: (map['error'] ?? 'unknown error').toString(),
          stdout: (map['stdout'] ?? '').toString(),
          stderr: (map['stderr'] ?? '').toString());
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

  /// 解压 .whl（zip 格式）到私有目录 python_wheels/<name>/，返回该目录。
  /// 幂等：已解压直接返回。
  Future<String> _extractWheel(String name) async {
    final w = _wheels[name]!;
    final appSupport = await _appSupport;
    final wheelFile = File('${appSupport.path}/$_packagesDir/${w.wheel}');
    final outDir = Directory('${appSupport.path}/$_wheelsDir/$name');
    if (outDir.existsSync() && outDir.listSync().isNotEmpty) {
      return outDir.path;
    }

    if (!wheelFile.existsSync()) {
      throw StateError('wheel 未下载: ${w.wheel}');
    }
    final bytes = await wheelFile.readAsBytes();
    if (outDir.existsSync()) await outDir.delete(recursive: true);
    await outDir.create(recursive: true);

    // .whl 是 zip：解压出包目录 + dist-info（PyPI 标准布局）
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final f in archive) {
      if (f.isFile) {
        final rel = f.name;
        // 防御：跳过可疑路径（防止 zip slip）
        if (rel.contains('..') || rel.startsWith('/')) continue;
        final out = File('${outDir.path}/$rel');
        if (!out.parent.existsSync()) {
          await out.parent.create(recursive: true);
        }
        await out.writeAsBytes(f.content as List<int>, flush: true);
      }
    }
    return outDir.path;
  }

  /// 按依赖拓扑排序（先依赖后本体），供 sys.path 注入顺序使用。
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

  /// 启动 runner（幂等）：SeriousPython.run() 后台线程跑 main.py，
  /// 轮询 <support>/data/mix_runner_port.json 拿 HTTP 端口。
  Future<void> _ensureStarted() async {
    if (_started) return;
    if (_startFuture != null) return _startFuture;
    _startFuture = _start();
    return _startFuture;
  }

  Future<void> _start() async {
    // serious_python：启动打包的 main.py（runner HTTP server），后台线程
    await SeriousPython.run();

    // 轮询端口文件（runner 启动后写入 <support>/data/mix_runner_port.json）
    final appSupport = await _appSupport;
    final portFile = File('${appSupport.path}/data/mix_runner_port.json');
    final deadline = DateTime.now().add(_startTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        if (await portFile.exists()) {
          final text = await portFile.readAsString();
          final map = jsonDecode(text);
          if (map is Map && map['port'] is int) {
            _port = map['port'] as int;
            // 确认 runner 存活
            final ping = await _post('/ping', {}).timeout(const Duration(seconds: 5));
            if (ping['ok'] == true) {
              _started = true;
              return;
            }
          }
        }
      } catch (_) {
        // 端口文件可能还没写完 / runner 未就绪，重试
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('Python runner 启动超时（60s）');
  }

  /// 向 runner 发 HTTP POST JSON 请求。
  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final port = _port;
    if (port == null) throw StateError('Python runner 未就绪');
    final resp = await http
        .post(
          Uri.parse('http://127.0.0.1:$port$path'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw StateError('runner HTTP ${resp.statusCode}: $path');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return {'ok': false, 'error': 'runner 返回异常: $decoded'};
  }
}

/// python 引擎：serious_python 原生 CPython 执行，matplotlib 画图渲染成图片。
/// 运行时 CPython 打包进 APK；科学计算 wheels 按需从 GitHub 仓库下载。
class PythonCodeEngine extends CodeEngine {
  const PythonCodeEngine();

  @override
  String get language => 'python';

  @override
  List<String> get aliases => const ['py'];

  @override
  String get displayName => 'Python (Native)';

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
