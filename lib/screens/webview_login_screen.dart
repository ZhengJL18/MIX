/// 内嵌网页登录页：让用户在 App 里直接登录目标网站（不跳出去），
/// 登录态 cookie 存进平台级全局 WebView jar —— 之后无头 WebView 抓取
/// 同一域名自动带登录态，爬登录墙内容就能拿到真实内容。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 网页登录页。可选 [initialUrl]（agent web_login 工具调用时带目标页）。
class WebViewLoginScreen extends StatefulWidget {
  const WebViewLoginScreen({super.key, this.initialUrl});

  /// 初始加载地址；为空默认展示域名输入。
  final String? initialUrl;

  @override
  State<WebViewLoginScreen> createState() => _WebViewLoginScreenState();
}

class _WebViewLoginScreenState extends State<WebViewLoginScreen> {
  final TextEditingController _urlCtrl = TextEditingController();
  InAppWebViewController? _controller;
  String _currentUrl = '';
  bool _loading = false;
  bool _loginDetected = false;

  static const _defaultStart = 'https://www.zhihu.com/';

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = widget.initialUrl ?? _defaultStart;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  void _go(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    setState(() => _loading = true);
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  /// 粗略判断"已登录"：页面 URL 从登录框跳回正常内容页。
  void _checkLogin(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final host = uri.host;
    // 登录页常见路径片段；跳到这些之外基本算登录完成。
    final loginPaths = ['login', 'passport', 'signin', 'sign_in', 'account/login'];
    final path = uri.path;
    final isLoginPath = loginPaths.any(path.contains);
    if (!isLoginPath && host.isNotEmpty && !_loginDetected) {
      _loginDetected = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存 $host 的登录态，爬虫可抓取该站内容')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentUrl.isEmpty ? '网页登录' : _currentUrl),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => _go(_urlCtrl.text),
          ),
        ],
      ),
      body: Column(
        children: [
          // 地址栏 + 提示。
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      hintText: '输入网站地址，如 https://www.zhihu.com/',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: () => _go(_urlCtrl.text),
                      ),
                    ),
                    onSubmitted: _go,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text(
              '在此登录目标网站，登录态自动保存，之后 MIX 爬虫可抓取该站内容。',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          // WebView 主体。
          Expanded(
            child: InAppWebView(
                    initialUrlRequest:
                        URLRequest(url: WebUri(_urlCtrl.text)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: true,
                      cacheEnabled: true,
                      thirdPartyCookiesEnabled: true,
                      supportMultipleWindows: false,
                    ),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                    },
                    onProgressChanged: (controller, progress) {
                      if (mounted) setState(() => _loading = progress < 100);
                    },
                    onLoadStop: (controller, url) async {
                      final urlStr = url?.toString() ?? '';
                      if (mounted) {
                        setState(() {
                          _currentUrl = urlStr;
                          if (urlStr.isNotEmpty) _urlCtrl.text = urlStr;
                        });
                      }
                      _checkLogin(urlStr);
                    },
                  ),
          ),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}
