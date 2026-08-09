// Mermaid 图表渲染：用本地打包的 mermaid.min.js（assets/mermaid/），
// HeadlessInAppWebView 执行渲染，提取 SVG 后交给 flutter_svg 显示。
// 全程离线，无需网络，与 Obsidian 的 mermaid 渲染一致。
//
// 内存优化（2026-08）：全 App 只维护【一个】HeadlessInAppWebView 实例，
// 所有 mermaid 块通过全局串行队列复用它，渲染结果按代码哈希缓存；
// 块滚动进视口才触发渲染（懒加载），空闲 60s 自动释放 WebView 进程。
// 避免"一篇笔记 N 个 mermaid 块 = N 个 WebView 进程"导致的 OOM。

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'code_engine.dart';

/// mermaid 代码块 → 渲染后的 SVG 图。
class MermaidWidget extends StatefulWidget {
  const MermaidWidget({super.key, required this.code});

  /// mermaid 源码（不含 ```mermaid 围栏）。
  final String code;

  @override
  State<MermaidWidget> createState() => _MermaidWidgetState();
}

class _MermaidWidgetState extends State<MermaidWidget> {
  String? _svg;
  String? _error;
  bool _started = false; // 是否已触发渲染（懒加载）

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: ValueKey('mermaid_${widget.code.hashCode}_$_started'),
      onVisibilityChanged: (info) {
        if (!_started && info.visibleFraction > 0) {
          _started = true;
          _render();
        }
      },
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_svg != null) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.15)),
        ),
        child: SvgPicture.string(
          _svg!,
          fit: BoxFit.contain,
          placeholderBuilder: (context) => const SizedBox(
            width: double.infinity,
            height: 120,
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .errorContainer
              .withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('mermaid 渲染失败：$_error',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12)),
            const SizedBox(height: 8),
            SelectableText(widget.code,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
      );
    }
    return const SizedBox(
      width: double.infinity,
      height: 120,
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }

  Future<void> _render() async {
    try {
      final svg = await MermaidRenderer.instance.render(widget.code);
      if (!mounted) return;
      setState(() => _svg = svg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }
}

/// 全局唯一 mermaid 渲染器。
///
/// - 复用单个 HeadlessInAppWebView，串行处理所有请求
/// - 按代码哈希缓存 SVG（上限 [maxCache] 条，LRU 淘汰）
/// - 空闲 [idleTtl] 后自动 dispose WebView，释放内存
class MermaidRenderer {
  MermaidRenderer._();
  static final MermaidRenderer instance = MermaidRenderer._();

  /// 本地 mermaid.min.js 的 asset 路径（Android: file:///android_asset/...）。
  static const _assetBase = 'file:///android_asset/flutter_assets/';

  static const _idleTtl = Duration(seconds: 60);
  static const _renderTimeout = Duration(seconds: 20);
  static const _maxCache = 30;

  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Future<void>? _initFuture;
  bool _disposed = false;

  // 串行队列：<code, completer>
  final Queue<(String, Completer<String>)> _queue = Queue();
  bool _processing = false;

  // 缓存
  final LinkedHashMap<String, String> _cache = LinkedHashMap();
  // 进行中的请求（code -> future），去重
  final Map<String, Future<String>> _inflight = {};

  // 当前正在用 WebView 渲染的任务（onLoadStop 通过它回填结果）
  Completer<String>? _current;

  Timer? _idleTimer;

  /// 渲染 mermaid 代码为 SVG 字符串（带缓存与去重）。
  Future<String> render(String code) {
    final cached = _cache[code];
    if (cached != null) return Future.value(cached);

    final inFlight = _inflight[code];
    if (inFlight != null) return inFlight;

    final completer = Completer<String>();
    _inflight[code] = completer.future;
    _queue.add((code, completer));
    _pump();
    return completer.future;
  }

  Future<void> _pump() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty) {
        final (code, completer) = _queue.removeFirst();
        try {
          final svg = await _renderWithWebView(code);
          _putCache(code, svg);
          if (!completer.isCompleted) completer.complete(svg);
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        } finally {
          _inflight.remove(code);
        }
      }
    } finally {
      _processing = false;
    }
  }

  void _putCache(String code, String svg) {
    _cache.remove(code);
    _cache[code] = svg;
    while (_cache.length > _maxCache) {
      _cache.remove(_cache.keys.first); // LRU：淘汰最久未用的
    }
  }

  /// 用全局唯一 WebView 渲染单个 mermaid 代码。
  Future<String> _renderWithWebView(String code) async {
    _idleTimer?.cancel();
    await _ensureInit();
    final controller = _controller!;
    final completer = Completer<String>();
    _current = completer;

    await controller.loadData(
      data: _buildHtml(code),
      baseUrl: WebUri('$_assetBase/assets/mermaid/'),
    );

    try {
      return await completer.future.timeout(_renderTimeout,
          onTimeout: () => throw StateError('mermaid render timeout'));
    } finally {
      _current = null;
      _scheduleIdleDispose();
    }
  }

  Future<void> _ensureInit() async {
    if (_webView != null && !_disposed) return;
    if (_initFuture != null) return _initFuture;
    _initFuture = _create();
    return _initFuture;
  }

  Future<void> _create() async {
    _disposed = false;
    final created = Completer<void>();
    final headless = HeadlessInAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        if (!created.isCompleted) created.complete();
      },
      onLoadStop: (controller, url) async {
        final current = _current;
        if (current == null || current.isCompleted) return;
        try {
          final result = await controller.evaluateJavascript(source: _js);
          var map = <String, dynamic>{};
          if (result is Map) {
            map = result.cast<String, dynamic>();
          } else if (result is String) {
            try {
              final decoded = jsonDecode(result);
              if (decoded is Map) map = decoded.cast<String, dynamic>();
            } catch (_) {}
          }
          if (map['ok'] == true && map['svg'] != null) {
            current.complete(map['svg'] as String);
          } else {
            current.completeError(
                StateError('mermaid: ${map['error'] ?? 'unknown error'}'));
          }
        } catch (e) {
          if (!current.isCompleted) current.completeError(e);
        }
      },
      onLoadError: (controller, url, codeNum, message) {
        final current = _current;
        if (current != null && !current.isCompleted) {
          current.completeError(StateError('mermaid load error: $message'));
        }
      },
    );
    _webView = headless;
    await headless.run();
    await created.future.timeout(const Duration(seconds: 10));
  }

  void _scheduleIdleDispose() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTtl, _disposeWebView);
  }

  Future<void> _disposeWebView() async {
    if (_queue.isNotEmpty || _processing) return; // 还有任务，暂不释放
    _idleTimer?.cancel();
    _initFuture = null;
    _current = null;
    final wv = _webView;
    _webView = null;
    _controller = null;
    _disposed = true;
    if (wv != null) {
      try {
        await wv.dispose();
      } catch (_) {}
    }
  }

  /// 取 mermaid 渲染结果 JS（含容错与超时兜底）。
  static const _js = '''
(function() {
  const el = document.getElementById('graph');
  if (!el) return JSON.stringify({ok: false, error: 'no container'});
  return mermaid.render('graphSvg', el.textContent)
    .then(function(res) {
      return JSON.stringify({ok: true, svg: res.svg});
    })
    .catch(function(err) {
      return JSON.stringify({ok: false, error: String(err)});
    });
})();
''';

  /// 生成 HTML：引本地 mermaid.min.js + 把源码放进 #graph。
  static String _buildHtml(String code) {
    final escaped = _escapeHtml(code);
    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<script src="$_assetBase/assets/mermaid/mermaid.min.js"></script>
<style>
  body { margin: 0; background: transparent; }
  #graph { display: none; }
</style>
</head>
<body>
<div id="graph">$escaped</div>
</body>
</html>
''';
  }

  static String _escapeHtml(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }
}

/// mermaid 引擎：渲染成 SVG 图。
/// 资源 mermaid.min.js 已打包进 APK（assets/mermaid/），无需按需下载。
class MermaidCodeEngine extends CodeEngine {
  const MermaidCodeEngine();

  @override
  String get language => 'mermaid';

  @override
  List<String> get aliases => const [];

  @override
  String get displayName => 'Mermaid 图表';

  @override
  List<EngineAsset> get requiredAssets => const [];

  @override
  Widget buildWidget(String code) => MermaidWidget(code: code);
}
