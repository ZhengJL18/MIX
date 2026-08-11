/// web_login 工具：agent 遇到登录墙内容时，主动打开内嵌登录页让用户登录。
///
/// 用户登录后 cookie 存进平台级全局 WebView jar，之后 web_extract 对同一
/// 域名走无头 WebView 抓取会自动带登录态，拿到真实内容（而非登录引导页）。
library;

import 'dart:async';

import 'registry.dart';

/// UI 注册的登录回调：给定目标 URL/域名，打开内嵌登录页，返回结果描述。
/// 由 ChatScreen 注册（Navigator.push 到 WebViewLoginScreen）。
Future<String> Function(String url, String domain)? webLoginHandler;

/// web_login 工具 handler：打开登录页等待用户完成登录。
Future<String> _handleWebLogin(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final handler = webLoginHandler;
  if (handler == null) {
    return toolError('web_login: 界面未提供登录回调');
  }
  final url = args['url'] as String? ?? '';
  final domain = args['domain'] as String? ?? '';
  if (url.isEmpty && domain.isEmpty) {
    return toolError('web_login: 需要 url 或 domain');
  }
  try {
    return await handler(url, domain);
  } catch (e) {
    return toolError('web_login: $e');
  }
}

const Map<String, dynamic> _webLoginSchema = {
  'name': 'web_login',
  'description':
      'Open the in-app login page for a website so the user can log in. '
      'Use this when web_extract returns a login wall / sign-in prompt for '
      'a site that requires authentication (e.g. Zhihu, Xiaohongshu, Weibo). '
      'After the user logs in, the session cookie is saved and subsequent '
      'web_extract calls for that domain will return real content.',
  'parameters': {
    'type': 'object',
    'properties': {
      'url': {
        'type': 'string',
        'description': 'The login page URL or the target page URL of the site to log into',
      },
      'domain': {
        'type': 'string',
        'description': 'Optional domain (e.g. zhihu.com) — used when only the domain is known',
      },
    },
    'required': ['url'],
  },
};

/// 注册 web_login 工具。
void registerWebLoginTool() {
  registry.register(
    name: 'web_login',
    toolset: 'web',
    schema: _webLoginSchema,
    handler: _handleWebLogin,
    isAsync: true,
    emoji: '🌐',
  );
}
