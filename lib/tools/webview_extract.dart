/// WebView 抓取服务（第二层：后台纯文本管道）。
///
/// 用 flutter_inappwebview 的 `HeadlessInAppWebView`（真无头，不挂 UI）加载 URL，
/// 真实 Chromium 内核执行 JS + 过反爬，注入用户脚本，提取正文纯文本给 agent。
///
/// **防刷保证**：WebView 是无头后台运行，用户永远看不到网页界面 —— 只看到
/// agent 返回的纯文本。抖音/快手是视频，纯文本无意义，天然刷不起来。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'userscripts.dart' as us;

/// 抓取结果。
class WebviewExtractResult {
  final String content;
  final bool success;
  final String? error;
  final String? title;

  WebviewExtractResult({
    this.content = '',
    this.success = false,
    this.error,
    this.title,
  });
}

/// 用 Headless WebView 抓取 URL 正文（纯文本）。
///
/// [url] 需通过 [isAllowedUrl] 白名单校验（由调用方决定）。
/// [charLimit] 正文截断上限。
///
/// 登录态：Android 上 Headless 与有 UI 的 WebView 共享平台级全局 cookie jar，
/// 用户在「网页登录」页登录某站点后，这里抓取该域名自动带登录态。
Future<WebviewExtractResult> webviewExtract(
  String url, {
  int charLimit = 15000,
}) async {
  final host = Uri.parse(url).host;
  final scripts = us.userScriptsForHost(host);

  // 提取正文的 JS。
  final extractJs = '''
(function(){
  var title = document.title || '';
  var content = document.body ? document.body.innerText : '';
  return JSON.stringify({title: title, content: content});
})();
''';

  try {
    final result = await _runHeadless(url, scripts, extractJs, charLimit);
    return result;
  } catch (e) {
    return WebviewExtractResult(error: 'WebView extract failed: $e');
  }
}

/// 运行无头 WebView。
Future<WebviewExtractResult> _runHeadless(
  String url,
  List<us.UserScript> scripts,
  String extractJs,
  int charLimit,
) async {
  final completer = Completer<WebviewExtractResult>();
  // 防二次 complete（重定向/多次 onLoadStop）。
  var completed = false;

  final headless = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(url)),
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
    onWebViewCreated: (controller) async {
      // 注入用户脚本（类油猴）。
      for (final s in scripts) {
        await controller.addUserScript(
          userScript: UserScript(
            source: s.js,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        );
      }
    },
    onLoadStop: (controller, url) async {
      // 只取第一次「有意义」内容（非空）；空内容（登录墙/跳转页）不立即定稿，
      // 等后续 onLoadStop（真实页面加载完）再取。
      final jsResult = await controller.evaluateJavascript(source: extractJs);
      String? title;
      String? content;
      if (jsResult is Map<String, dynamic>) {
        title = jsResult['title'] as String?;
        content = jsResult['content'] as String?;
      } else if (jsResult is String) {
        // JSON 字符串。
        try {
          final parsed = jsonDecode(jsResult);
          if (parsed is Map<String, dynamic>) {
            title = parsed['title'] as String?;
            content = parsed['content'] as String?;
          }
        } catch (_) {}
      }
      var text = content ?? '';
      if (text.trim().isEmpty && !completed) {
        return; // 空内容，等待后续加载。
      }
      if (text.length > charLimit) {
        text = text.substring(0, charLimit);
      }
      if (!completed) {
        completed = true;
        completer.complete(WebviewExtractResult(
          content: text,
          success: text.isNotEmpty,
          title: title,
        ));
      }
    },
  );

  await headless.run();
  try {
    final result = await completer.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => WebviewExtractResult(
        error: 'WebView extract timed out',
      ),
    );
    return result;
  } finally {
    await headless.dispose();
  }
}
