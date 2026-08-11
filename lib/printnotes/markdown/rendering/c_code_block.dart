// C 代码块执行：libtcc（TinyCC）原生 C 编译器嵌入。
// libtcc.so + 头文件（runtime/android/include，libtcc-cmake 自带 Android
// 标准头文件）由 CI 交叉编译后发布为 GitHub Release asset，App 首次使用时
// 按需下载到私有目录，Dart FFI 直调编译执行。
//
// 架构（与 Python 引擎同模式，但纯 FFI 无 HTTP）：
//   - 下载 libtcc-arm64-v8a.so → DynamicLibrary.open → FFI 封装官方 tcc API
//   - 下载 tcc-include-android.tar.gz → 解压到私有目录（编译时 -I 指向它）
//   - 执行流程：tcc_new → set_output_type(MEMORY) → set_options(-I include)
//     → 注入 freopen prologue（stdout/stderr 重定向到文件、stdin 指向 /dev/null）
//     → compile_string → relocate(AUTO) → tcc_run（执行 main）→ 读输出 → delete
//   - 纯 Dart FFI，不依赖 JNI/AssetManager（保持 MIX 纯 Dart 架构）
//
// 限制（第一版）：
//   - 同步执行：教学代码毫秒级完成；死循环会阻塞（后续可移到后台线程）
//   - scanf 输入暂不支持（stdin 重定向 /dev/null → 立即 EOF）
//   - main 无参数（tcc_run 传空 argv，argc/argv 用法受限）

import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'code_engine.dart';

/// C 代码执行结果。
class CRunResult {
  const CRunResult({this.stdout = '', this.stderr = '', this.exitCode, this.error});

  /// 程序 stdout 输出（printf 等）。
  final String stdout;

  /// 程序 stderr 输出。
  final String stderr;

  /// 退出码（执行成功时非 null）。
  final int? exitCode;

  /// 错误（编译失败 / 运行时错误提示）。
  final String? error;
}

/// libtcc 官方 C API（tcc.h）FFI 绑定。
//  typedef struct TCCState TCCState;
//  TCCState *tcc_new(void);
//  void tcc_delete(TCCState *s);
//  void tcc_set_error_func(TCCState *s, void *error_opaque,
//                          void (*error_func)(void *opaque, const char *msg));
//  void tcc_set_options(TCCState *s, const char *str);
//  int tcc_set_output_type(TCCState *s, int output_type); // TCC_OUTPUT_MEMORY=1
//  int tcc_compile_string(TCCState *s, const char *source);
//  int tcc_relocate(TCCState *s, void *ptr);             // TCC_RELOCATE_AUTO=(void*)1
//  void *tcc_get_symbol(TCCState *s, const char *name);
//  int tcc_run(TCCState *s, int argc, char **argv);
// dart:ffi 规范：lookupFunction 需要 native typedef（ffi 类型）与 dart typedef（dart 类型）成对。
typedef _TccNewNative = Pointer<Void> Function();
typedef _TccNewDart = Pointer<Void> Function();
typedef _TccDeleteNative = Void Function(Pointer<Void>);
typedef _TccDeleteDart = void Function(Pointer<Void>);
typedef _TccErrorCb = Void Function(Pointer<Void>, Pointer<Utf8>);
typedef _TccErrorFuncNative =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<NativeFunction<_TccErrorCb>>);
typedef _TccErrorFuncDart =
    void Function(Pointer<Void>, Pointer<Void>, Pointer<NativeFunction<_TccErrorCb>>);
typedef _TccSetOptionsNative = Void Function(Pointer<Void>, Pointer<Utf8>);
typedef _TccSetOptionsDart = void Function(Pointer<Void>, Pointer<Utf8>);
typedef _TccSetOutputTypeNative = Int32 Function(Pointer<Void>, Int32);
typedef _TccSetOutputTypeDart = int Function(Pointer<Void>, int);
typedef _TccCompileStringNative = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _TccCompileStringDart = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _TccRelocateNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _TccRelocateDart = int Function(Pointer<Void>, Pointer<Void>);
typedef _TccRunNative = Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Utf8>>);
typedef _TccRunDart = int Function(Pointer<Void>, int, Pointer<Pointer<Utf8>>);

/// TCC_OUTPUT_MEMORY（tcc.h）。
const _tccOutputMemory = 1;

/// TCC_RELOCATE_AUTO = (void*)1（tcc.h）。
final Pointer<Void> _tccRelocateAuto = Pointer<Void>.fromAddress(1);

/// 编译错误收集（NativeCallable 回调 → 静态 buffer）。
StringBuffer? _compileErrors;

void _tccErrorCallback(Pointer<Void> opaque, Pointer<Utf8> msg) {
  _compileErrors?.write(msg.toDartString());
  _compileErrors?.write('\n');
}

/// 全局唯一 C 执行引擎（libtcc）。
class CEngine {
  CEngine._();
  static final CEngine instance = CEngine._();

  /// 运行时目录（相对 appSupport）。
  static const _runtimeDir = 'c_tcc';

  /// release asset 稳定 URL（latest 永远指向最新发布）。
  static const _soUrl =
      'https://github.com/ZhengJL18/MIX/releases/latest/download/libtcc-arm64-v8a.so';
  static const _includeUrl =
      'https://github.com/ZhengJL18/MIX/releases/latest/download/tcc-include-android.tar.gz';

  /// 供 CodeEngine.requiredAssets 使用。
  static String get soUrl => _soUrl;
  static String get includeUrl => _includeUrl;

  static const _timeout = Duration(seconds: 60);

  DynamicLibrary? _lib;
  String? _includeDir;
  bool _loading = false;
  Future<void>? _ensureFuture;

  Future<Directory> get _appSupport async =>
      await getApplicationSupportDirectory();

  /// libtcc.so 是否已就绪（已下载 + 已 open）。
  Future<bool> isReady() async {
    if (_lib != null) return true;
    final support = await _appSupport;
    return File('${support.path}/$_runtimeDir/libtcc.so').existsSync();
  }

  /// 是否已下载 include 头文件。
  Future<bool> isIncludeReady() async {
    if (_includeDir != null) return true;
    final support = await _appSupport;
    return Directory('${support.path}/$_runtimeDir/include').existsSync();
  }

  /// 下载缺失的运行时（.so + include）。幂等。
  Future<void> ensureRuntime({
    void Function(String phase)? onProgress,
  }) async {
    if (_lib != null && _includeDir != null) return;
    if (_ensureFuture != null) return _ensureFuture;
    _ensureFuture = _download(onPhase: onProgress);
    return _ensureFuture;
  }

  Future<void> _download({void Function(String phase)? onPhase}) async {
    final support = await _appSupport;
    final dir = Directory('${support.path}/$_runtimeDir');
    if (!dir.existsSync()) await dir.create(recursive: true);

    // 1) libtcc.so
    final soFile = File('${dir.path}/libtcc.so');
    if (!soFile.existsSync() || soFile.lengthSync() == 0) {
      onPhase?.call('下载编译器');
      final resp = await http.get(Uri.parse(_soUrl)).timeout(_timeout);
      if (resp.statusCode != 200) {
        throw StateError('下载 libtcc 失败（HTTP ${resp.statusCode}）');
      }
      await soFile.writeAsBytes(resp.bodyBytes, flush: true);
    }

    // 2) include 头文件（tar.gz）
    final includeDir = Directory('${dir.path}/include');
    if (!includeDir.existsSync() || includeDir.listSync().isEmpty) {
      onPhase?.call('下载头文件');
      final resp = await http.get(Uri.parse(_includeUrl)).timeout(_timeout);
      if (resp.statusCode != 200) {
        throw StateError('下载 tcc 头文件失败（HTTP ${resp.statusCode}）');
      }
      if (includeDir.existsSync()) {
        await includeDir.delete(recursive: true);
      }
      await includeDir.create(recursive: true);
      final tar = TarDecoder().decodeBytes(
          GZipDecoder().decodeBytes(resp.bodyBytes));
      for (final f in tar.files) {
        if (f.isFile) {
          final rel = f.name.replaceAll('\\', '/');
          // 防御：跳过可疑路径（防 tar slip）
          if (rel.contains('..') || rel.startsWith('/')) continue;
          final out = File('${includeDir.path}/$rel');
          if (!out.parent.existsSync()) {
            await out.parent.create(recursive: true);
          }
          await out.writeAsBytes(f.content as List<int>, flush: true);
        }
      }
      _includeDir = includeDir.path;
    }

    // 3) 打开 .so
    _lib = DynamicLibrary.open(soFile.path);
  }

  /// 执行 C 代码（同步 FFI）。onPhase 回调阶段。
  Future<CRunResult> run(
    String code, {
    void Function(String phase)? onPhase,
  }) async {
    await ensureRuntime(onProgress: onPhase);
    final lib = _lib;
    final includeDir = _includeDir;
    if (lib == null) throw StateError('libtcc 未就绪');
    if (includeDir == null) throw StateError('头文件未就绪');

    // 绑定符号
    final tccNew = lib.lookupFunction<_TccNewNative, _TccNewDart>('tcc_new');
    final tccDelete = lib.lookupFunction<_TccDeleteNative, _TccDeleteDart>('tcc_delete');
    final tccSetErrorFunc =
        lib.lookupFunction<_TccErrorFuncNative, _TccErrorFuncDart>('tcc_set_error_func');
    final tccSetOptions =
        lib.lookupFunction<_TccSetOptionsNative, _TccSetOptionsDart>('tcc_set_options');
    final tccSetOutputType = lib.lookupFunction<_TccSetOutputTypeNative, _TccSetOutputTypeDart>(
        'tcc_set_output_type');
    final tccCompileString = lib.lookupFunction<_TccCompileStringNative, _TccCompileStringDart>(
        'tcc_compile_string');
    final tccRelocate =
        lib.lookupFunction<_TccRelocateNative, _TccRelocateDart>('tcc_relocate');
    final tccRun = lib.lookupFunction<_TccRunNative, _TccRunDart>('tcc_run');

    // 临时输出文件（freopen 重定向目标）
    final support = await _appSupport;
    final outFile = File('${support.path}/mix_c_out_${DateTime.now().microsecondsSinceEpoch}.txt');
    final errFile = File('${support.path}/mix_c_err_${DateTime.now().microsecondsSinceEpoch}.txt');

    onPhase?.call('编译');
    final state = tccNew();
    if (state == nullptr) {
      return const CRunResult(error: 'tcc_new 失败：无法创建编译器实例');
    }

    // 错误回调（编译错误收集）
    _compileErrors = StringBuffer();
    final errCb = NativeCallable<
            Void Function(Pointer<Void>, Pointer<Utf8>)>.isolateLocal(
        _tccErrorCallback);
    try {
      tccSetErrorFunc(state, nullptr, errCb.nativeFunction);
      tccSetOutputType(state, _tccOutputMemory);
      final optStr = '-I$includeDir'.toNativeUtf8();
      tccSetOptions(state, optStr);
      malloc.free(optStr);

      // prologue：重定向 stdin（防御 scanf 阻塞）→ /dev/null，stdout/stderr → 文件
      final prologue = '''
#include <stdio.h>
freopen("/dev/null", "r", stdin);
freopen("${_cStringLiteral(outFile.path)}", "w", stdout);
freopen("${_cStringLiteral(errFile.path)}", "w", stderr);
''';
      final src = (prologue + code).toNativeUtf8();
      final compileOk = tccCompileString(state, src);
      malloc.free(src);
      if (compileOk != 0) {
        final errText = _compileErrors?.toString().trim() ?? '编译失败（未知错误）';
        return CRunResult(error: errText);
      }

      onPhase?.call('链接');
      if (tccRelocate(state, _tccRelocateAuto) != 0) {
        final errText = _compileErrors?.toString().trim() ?? '链接失败（未知错误）';
        return CRunResult(error: errText);
      }

      onPhase?.call('运行');
      final argv = calloc<Pointer<Utf8>>(2);
      argv[0] = 'mix'.toNativeUtf8();
      argv[1] = nullptr;
      final exitCode = tccRun(state, 1, argv);
      malloc.free(argv[0]);
      calloc.free(argv);

      // 读输出
      final stdoutText = outFile.existsSync() ? await outFile.readAsString() : '';
      final stderrText = errFile.existsSync() ? await errFile.readAsString() : '';
      return CRunResult(
        stdout: stdoutText,
        stderr: stderrText,
        exitCode: exitCode,
      );
    } catch (e) {
      return CRunResult(error: e.toString());
    } finally {
      tccDelete(state);
      errCb.close();
      _compileErrors = null;
      // 清理临时文件
      try {
        if (outFile.existsSync()) await outFile.delete();
        if (errFile.existsSync()) await errFile.delete();
      } catch (_) {}
    }
  }

  /// 把 Dart 字符串转成 C 字符串字面量（转义引号/反斜杠）。
  static String _cStringLiteral(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}

/// C 引擎：libtcc 原生编译执行。
/// 运行时（libtcc.so + 头文件）按需从 GitHub Release 下载。
class CCodeEngine extends CodeEngine {
  const CCodeEngine();

  @override
  String get language => 'c';

  @override
  List<String> get aliases => const []; // 注意：libtcc 不支持 C++，cpp 代码块保持普通高亮

  @override
  String get displayName => 'C (libtcc)';

  @override
  List<EngineAsset> get requiredAssets => const [
        EngineAsset(
          name: 'libtcc 编译器',
          url:
              'https://github.com/ZhengJL18/MIX/releases/latest/download/libtcc-arm64-v8a.so',
          sizeMB: 1.5,
        ),
        EngineAsset(
          name: 'C 标准头文件',
          url:
              'https://github.com/ZhengJL18/MIX/releases/latest/download/tcc-include-android.tar.gz',
          sizeMB: 2.0,
        ),
      ];

  @override
  Widget buildWidget(String code) => CCodeBlockWidget(code: code);
}

/// C 代码块 UI：运行按钮 + 结果展示。
class CCodeBlockWidget extends StatefulWidget {
  const CCodeBlockWidget({super.key, required this.code});

  final String code;

  @override
  State<CCodeBlockWidget> createState() => _CCodeBlockWidgetState();
}

class _CCodeBlockWidgetState extends State<CCodeBlockWidget> {
  // idle → needRuntime（需下载运行时）→ downloading → running → done / error
  String _state = 'idle';
  String _phase = '';
  String? _error;
  CRunResult? _result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(theme),
        ..._buildResult(theme),
      ],
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('C',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSecondaryContainer)),
          ),
          const Spacer(),
          if (_state == 'idle' || _state == 'done' || _state == 'error')
            TextButton.icon(
              onPressed: _onRun,
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('运行', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildResult(ThemeData theme) {
    if (_state == 'needRuntime') {
      return [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('需要下载 C 运行时（libtcc 编译器 + 标准头文件，约 3.5MB）',
                  style: TextStyle(
                      fontSize: 13, color: theme.colorScheme.onSurface)),
              const SizedBox(height: 6),
              Text('首次运行会从 GitHub Release 下载并缓存（仅一次）。',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _onDownloadAndRun,
                icon: const Icon(Icons.download, size: 16),
                label: const Text('下载并运行', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ];
    }

    if (_state == 'downloading' || _state == 'running') {
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
              Text(
                  _state == 'downloading'
                      ? '下载运行时…'
                      : (_phase.isEmpty ? '执行中…' : '$_phase…'),
                  style: TextStyle(
                      fontSize: 13, color: theme.colorScheme.primary)),
            ],
          ),
        ),
      ];
    }

    final result = _result;
    final errText = result?.error ??
        (result != null && result.stderr.trim().isNotEmpty
            ? result.stderr.trim()
            : _error);
    if (result == null && errText == null) return const [];

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
            if (result != null &&
                result.exitCode != null &&
                result.exitCode != 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('退出码：${result.exitCode}',
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
    ];
  }

  Future<void> _onRun() async {
    final engine = CEngine.instance;
    if (!await engine.isReady() || !await engine.isIncludeReady()) {
      if (!mounted) return;
      setState(() => _state = 'needRuntime');
      return;
    }
    await _execute();
  }

  Future<void> _onDownloadAndRun() async {
    setState(() {
      _state = 'downloading';
      _error = null;
      _result = null;
    });
    try {
      await CEngine.instance.ensureRuntime(onProgress: (p) {
        if (!mounted) return;
        if (p != _phase) setState(() => _phase = p);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = 'error';
        _phase = '';
        _error = e.toString();
      });
      return;
    }
    if (!mounted) return;
    await _execute();
  }

  Future<void> _execute() async {
    setState(() {
      _state = 'running';
      _error = null;
      _result = null;
      _phase = '';
    });
    try {
      final r = await CEngine.instance.run(widget.code, onPhase: (p) {
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
