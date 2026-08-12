/// WebView 抓取服务（第二层：后台纯文本管道）。
///
/// 用 flutter_inappwebview 的 `HeadlessInAppWebView`（真无头，不挂 UI）加载 URL，
/// 真实 Chromium 内核执行 JS + 过反爬，注入用户脚本，提取正文纯文本给 agent。
///
/// **防刷保证**：WebView 是无头后台运行，用户永远看不到网页界面 —— 只看到
/// agent 返回的纯文本。抖音/快手是视频，纯文本无意义，天然刷不起来。
///
/// **内存**：WebView 复用 [SharedWebview] 单例（单个无头 WebView + 串行 +
/// 空闲释放），避免连续抓取时反复创建 WebView 进程（Android 每个 100-200MB）。
/// **登录态**：共享平台级全局 cookie jar（「网页登录」页已移除，cookie 由
/// WebView 自身会话积累）。
library;

import 'dart:convert';

import 'shared_webview.dart';
import 'userscripts.dart' as us;

/// 抓取结果。
class WebviewExtractResult {
  final String content;
  final bool success;
  final String? error;
  final String? title;

  /// 内容是否被 charLimit 截断（agent 可据此加大 char_limit 重抓）。
  final bool truncated;

  WebviewExtractResult({
    this.content = '',
    this.success = false,
    this.error,
    this.title,
    this.truncated = false,
  });
}

/// 用共享 WebView 抓取 URL 正文（纯文本）。
///
/// [url] 需通过 [isAllowedUrl] 白名单校验（由调用方决定）。
/// [charLimit] 正文截断上限。
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
    final result = await SharedWebview.instance.execute(
      SharedWebviewRequest(
        url: url,
        userScripts: scripts,
        extractJs: extractJs,
        charLimit: charLimit,
      ),
    );
    if (result.error != null) {
      return WebviewExtractResult(error: result.error);
    }
    return WebviewExtractResult(
      content: result.content,
      success: result.content.isNotEmpty,
      title: result.title,
      truncated: result.truncated,
    );
  } catch (e) {
    return WebviewExtractResult(error: 'WebView extract failed: $e');
  }
}
