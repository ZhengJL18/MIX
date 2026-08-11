/// 全局共享的无头 WebView 执行器。
///
/// 每次新建 HeadlessInAppWebView = Android 上一个独立 WebView 进程（吃
/// 100-200MB），连续抓取多个网页时反复创建/销毁是最大的内存峰值来源。
/// 这里复用单个 WebView：串行队列一次处理一个请求，空闲自动 dispose。
///
/// 模式照 mermaid_widget.dart 的 MermaidRenderer（同一份取舍：单 WebView +
/// 串行 + 空闲释放）。per-host 用户脚本用 removeAllUserScripts 清空重注入。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'userscripts.dart' as us;

/// 一次网页抓取请求。
class SharedWebviewRequest {
  const SharedWebviewRequest({
    required this.url,
    this.userScripts = const [],
    required this.extractJs,
    this.charLimit = 15000,
    this.timeout = const Duration(seconds: 25),
  });

  /// 目标 URL。
  final String url;

  /// per-host 用户脚本（加载前注入，load 前清空重注入）。
  final List<us.UserScript> userScripts;

  /// onLoadStop 里 evaluateJavascript 提取正文的 JS，应返回
  /// `{title, content}` 的 JSON 字符串或对象。
  final String extractJs;

  /// 正文截断上限。
  final int charLimit;

  /// 单请求超时。
  final Duration timeout;
}

/// 抓取结果。
class SharedWebviewResult {
  const SharedWebviewResult({
    this.content = '',
    this.title,
    this.truncated = false,
    this.error,
  });

  final String content;
  final String? title;
  final bool truncated;
  final String? error;

  bool get success => error == null;
}

/// 共享 WebView 执行器（全局单例）。
class SharedWebview {
  SharedWebview._();
  static final SharedWebview instance = SharedWebview._();

  static const _idleTtl = Duration(seconds: 60);

  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Future<void>? _initFuture;
  bool _disposed = false;

  // 串行队列：<request, completer>
  final Queue<(SharedWebviewRequest, Completer<SharedWebviewResult>)> _queue =
      Queue();
  bool _processing = false;

  // 当前正在用 WebView 加载的请求（onLoadStop 通过它回填结果）。
  SharedWebviewRequest? _currentReq;
  Completer<SharedWebviewResult>? _current;

  Timer? _idleTimer;

  /// 执行一次网页抓取（复用单例 WebView）。
  Future<SharedWebviewResult> execute(SharedWebviewRequest req) {
    final completer = Completer<SharedWebviewResult>();
    _queue.add((req, completer));
    _pump();
    return completer.future;
  }

  Future<void> _pump() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty) {
        final (req, completer) = _queue.removeFirst();
        try {
          final result = await _run(req);
          if (!completer.isCompleted) completer.complete(result);
        } catch (e) {
          if (!completer.isCompleted) {
            completer.complete(SharedWebviewResult(error: e.toString()));
          }
        }
      }
    } finally {
      _processing = false;
    }
  }

  Future<SharedWebviewResult> _run(SharedWebviewRequest req) async {
    _idleTimer?.cancel();
    await _ensureInit();
    final controller = _controller!;
    _currentReq = req;
    final completer = Completer<SharedWebviewResult>();
    _current = completer;

    // per-host 用户脚本：清空旧的，注入本次的。
    await controller.removeAllUserScripts();
    for (final s in req.userScripts) {
      await controller.addUserScript(
        userScript: UserScript(
          source: s.js,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      );
    }

    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(req.url)));

    try {
      return await completer.future.timeout(
        req.timeout,
        onTimeout: () => SharedWebviewResult(error: 'WebView 抓取超时'),
      );
    } finally {
      _current = null;
      _currentReq = null;
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
        userAgent:
            'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        javaScriptEnabled: true,
        domStorageEnabled: true,
        cacheEnabled: true,
        thirdPartyCookiesEnabled: true,
        isInspectable: false,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        if (!created.isCompleted) created.complete();
      },
      onLoadStop: (controller, url) async {
        final req = _currentReq;
        final current = _current;
        if (req == null || current == null || current.isCompleted) return;
        try {
          final jsResult =
              await controller.evaluateJavascript(source: req.extractJs);
          String? title;
          String? content;
          if (jsResult is Map<String, dynamic>) {
            title = jsResult['title'] as String?;
            content = jsResult['content'] as String?;
          } else if (jsResult is String) {
            try {
              final decoded = jsonDecode(jsResult);
              if (decoded is Map<String, dynamic>) {
                title = decoded['title'] as String?;
                content = decoded['content'] as String?;
              }
            } catch (_) {}
          }
          var text = content ?? '';
          // 空内容（登录墙/跳转页）不立即定稿，等后续 onLoadStop。
          if (text.trim().isEmpty) return;
          final truncated = text.length > req.charLimit;
          if (truncated) text = text.substring(0, req.charLimit);
          if (!current.isCompleted) {
            current.complete(SharedWebviewResult(
              content: text,
              title: title,
              truncated: truncated,
            ));
          }
        } catch (e) {
          if (!current.isCompleted) {
            current.complete(SharedWebviewResult(error: e.toString()));
          }
        }
      },
      onLoadError: (controller, url, codeNum, message) {
        final current = _current;
        if (current != null && !current.isCompleted) {
          current.complete(SharedWebviewResult(error: '加载失败: $message'));
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
    if (_queue.isNotEmpty || _processing) return; // 还有任务，暂不释放。
    _idleTimer?.cancel();
    _initFuture = null;
    _current = null;
    _currentReq = null;
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
}
