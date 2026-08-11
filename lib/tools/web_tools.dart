/// 对应 `ref/hermes-agent/tools/web_tools.py`（像素级复刻，接口对齐）。
///
/// web_search / web_extract 工具。Hermes 用插件后端（Firecrawl/Tavily/Exa/
/// ddgs）；手机版 App 内置**无 key 的 DuckDuckGo 后端**，用户无需配搜索 key。
///
/// ## 返回格式（对齐 Hermes）
/// - webSearchTool → `{success, data: {web: [{title, url, description, position}]}}`
/// - webExtractTool → `{results: [{url, title, content, error}]}`
///
/// ## 安全
/// - SSRF 防护（url_safety）：拦截私网/云元数据 URL。
/// - 敏感查询参数拦截（防 URL 泄露凭据）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'registry.dart';
import 'url_safety.dart';
import 'userscripts.dart' as us;
import 'web_login_tool.dart';
import 'webview_extract.dart';

/// 搜索后端接口（可替换：未来接 Firecrawl/Tavily 时实现 provider）。
abstract class WebSearchBackend {
  Future<List<Map<String, dynamic>>> search(String query, int limit);
  bool get requiresKey => false;
}

/// DuckDuckGo Instant Answer API 后端（免费无 key）。
class DuckDuckGoBackend implements WebSearchBackend {
  @override
  bool get requiresKey => false;

  @override
  Future<List<Map<String, dynamic>>> search(String query, int limit) async {
    try {
      final uri = Uri.parse('https://api.duckduckgo.com/')
          .replace(queryParameters: {'q': query, 'format': 'json', 'no_html': '1', 'skip_disambig': '1'});
      final resp = await webHttpClient.get(uri).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        return const [];
      }
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final results = <Map<String, dynamic>>[];
      // Abstract（答案）+ RelatedTopics。
      final abstractText = data['AbstractText'] as String?;
      if (abstractText != null && abstractText.isNotEmpty) {
        results.add({
          'title': data['Heading'] as String? ?? query,
          'url': data['AbstractURL'] as String? ?? '',
          'description': abstractText,
          'position': results.length + 1,
        });
      }
      final related = data['RelatedTopics'];
      if (related is List) {
        for (final topic in related) {
          if (results.length >= limit) break;
          if (topic is! Map<String, dynamic>) continue;
          // 嵌套的 Topics（分组）。
          final nested = topic['Topics'];
          if (nested is List) {
            for (final sub in nested) {
              if (results.length >= limit) break;
              if (sub is! Map<String, dynamic>) continue;
              final text = sub['Text'] as String? ?? '';
              final url = sub['FirstURL'] as String? ?? '';
              if (text.isNotEmpty && url.isNotEmpty) {
                results.add({
                  'title': text.split(' - ').first,
                  'url': url,
                  'description': text,
                  'position': results.length + 1,
                });
              }
            }
          } else {
            final text = topic['Text'] as String? ?? '';
            final url = topic['FirstURL'] as String? ?? '';
            if (text.isNotEmpty && url.isNotEmpty) {
              results.add({
                'title': text.split(' - ').first,
                'url': url,
                'description': text,
                'position': results.length + 1,
              });
            }
          }
        }
      }
      return results;
    } catch (_) {
      return const [];
    }
  }
}

/// 必应 RSS 后端（免费无 key，中文搜索质量高）。
///
/// `cn.bing.com/search?q=<query>&format=rss&mkt=zh-CN` 返回标准 RSS 2.0 XML，
/// `<item>` 的 title/link/description 直接可解析，link 是原始 URL（无 /ck/a 包装）。
class BingBackend implements WebSearchBackend {
  @override
  bool get requiresKey => false;

  @override
  Future<List<Map<String, dynamic>>> search(String query, int limit) async {
    try {
      final uri = Uri.https('cn.bing.com', '/search', {
        'q': query,
        'format': 'rss',
        'mkt': 'zh-CN',
      });
      final resp = await webHttpClient.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        return const [];
      }
      final xmlText = utf8.decode(resp.bodyBytes);
      return _parseRss(xmlText, limit);
    } catch (_) {
      return const [];
    }
  }

  /// 解析 RSS XML → 搜索结果列表。
  List<Map<String, dynamic>> _parseRss(String xmlText, int limit) {
    final results = <Map<String, dynamic>>[];
    try {
      final doc = XmlDocument.parse(xmlText);
      final items = doc.findAllElements('item').take(limit);
      for (final item in items) {
        final title = item.findElements('title').isEmpty
            ? ''
            : item.findElements('title').first.innerText;
        final link = item.findElements('link').isEmpty
            ? ''
            : item.findElements('link').first.innerText;
        final desc = item.findElements('description').isEmpty
            ? ''
            : item.findElements('description').first.innerText;
        if (title.isNotEmpty && link.isNotEmpty) {
          results.add({
            'title': title,
            'url': link,
            'description': desc,
            'position': results.length + 1,
          });
        }
      }
    } catch (_) {}
    return results;
  }
}

/// 活动搜索后端（默认必应；失败 fallback DDG）。
WebSearchBackend webSearchBackend = BingBackend();
WebSearchBackend webSearchFallbackBackend = DuckDuckGoBackend();

/// web_search 工具：返回搜索元数据（URL/标题/描述）。
///
/// 对应 Hermes web_search_tool。默认必应（中文质量高），失败 fallback DDG。
Future<String> webSearchTool(String query, {int limit = 5}) async {
  if (limit < 1 || limit > 100) {
    limit = 5;
  }
  try {
    var results = await webSearchBackend.search(query, limit);
    // 必应无结果 → fallback DDG。
    if (results.isEmpty) {
      results = await webSearchFallbackBackend.search(query, limit);
    }
    return jsonEncode({
      'success': true,
      'data': {'web': results},
    });
  } catch (e) {
    return toolError('Web search failed: $e', extra: {'success': false});
  }
}

/// 可注入的 http client（测试用；默认全局）。
http.Client webHttpClient = http.Client();

/// web_download 工具：下载 URL 的二进制文件到本地。
///
/// [url] 远程文件 URL；[path] 目标保存路径（绝对或相对 cwd）。
/// 返回保存后的绝对路径和字节数。
Future<String> webDownloadTool({
  required String url,
  required String path,
  http.Client? client,
}) async {
  final httpClient = client ?? webHttpClient;
  try {
    final uri = Uri.parse(url);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return toolError("web_download: unsupported scheme '${uri.scheme}'");
    }
    // 下载（流式写文件，避免大文件占内存）。
    final request = http.Request('GET', uri);
    final resp = await httpClient.send(request).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      return toolError('web_download: HTTP ${resp.statusCode}');
    }
    final file = File(path);
    file.parent.createSync(recursive: true);
    final sink = file.openWrite();
    var total = 0;
    await for (final chunk in resp.stream) {
      sink.add(chunk);
      total += chunk.length;
    }
    await sink.flush();
    await sink.close();
    return 'Downloaded ${file.absolute.path} ($total bytes)';
  } catch (e) {
    return toolError('web_download: $e');
  }
}

const Map<String, dynamic> webDownloadSchema = {
  'name': 'web_download',
  'description':
      'Download a file (including binary) from a URL to local disk. '
      'Use for packages, binaries, images, archives. Returns the saved path '
      'and byte size. The path may be absolute or relative to the working dir.',
  'parameters': {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': 'URL to download'},
      'path': {'type': 'string', 'description': 'Local save path'},
    },
    'required': ['url', 'path'],
  },
};

/// 走 WebView 无头抓取的域名（预置 + 用户自定义合并）。
///
/// 预置登录墙/需渲染平台；用户可在登录页之外手动添加自定义域名，
/// 存 SharedPreferences（key `mix_webview_hosts`）。
const Set<String> _builtinWebviewHosts = {
  'zhihu.com',
  'xiaohongshu.com',
  'tieba.baidu.com',
  'weibo.com',
  'bilibili.com',
  'juejin.cn',
  'csdn.net',
  'douban.com',
};

/// 用户自定义的 WebView 域名（缓存，避免每次读 prefs）。
Set<String> _customWebviewHosts = {};

/// 加载用户自定义 WebView 域名（App 启动时调用一次）。
Future<void> loadWebviewHosts() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    _customWebviewHosts =
        (prefs.getStringList('mix_webview_hosts') ?? const []).toSet();
  } catch (_) {}
}

/// 手动添加一个自定义 WebView 域名（如 "example.com"）。
Future<void> addWebviewHost(String domain) async {
  final d = domain.trim().toLowerCase().replaceAll(RegExp(r'^https?://'), '');
  if (d.isEmpty) return;
  _customWebviewHosts.add(d);
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('mix_webview_hosts', _customWebviewHosts.toList());
  } catch (_) {}
}

/// 当前全部 WebView 域名（预置 + 自定义）。
Set<String> get webviewHosts => {..._builtinWebviewHosts, ..._customWebviewHosts};

/// 是否需 WebView 抓取。
bool _needsWebview(String url) {
  try {
    final host = Uri.parse(url).host.toLowerCase();
    for (final h in webviewHosts) {
      if (host == h || host.endsWith('.$h')) {
        return true;
      }
    }
  } catch (_) {}
  return false;
}

/// 极简 HTML → 文本提取（去标签/去脚本/去样式）。公开供测试。
String htmlToText(String html) {
  var text = html;
  // 去 script/style。
  text = text.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '');
  text = text.replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '');
  // 去注释。
  text = text.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  // 标题。
  text = text.replaceAllMapped(
    RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false),
    (m) => '## ${m.group(1)?.trim() ?? ''}\n\n',
  );
  // 块级标签 → 换行。
  text = text.replaceAll(
      RegExp(r'</?(?:p|div|br|li|h[1-6]|tr|section|article|blockquote)[^>]*>',
          caseSensitive: false),
      '\n');
  // 链接保留文本（replaceAllMapped 才能用捕获组）。
  // 用非 raw 双引号字符串 + 双反斜杠转义，避免引号界定冲突。
  text = text.replaceAllMapped(
    RegExp("<a[^>]*href=['\"]([^'\"]+)['\"][^>]*>([\\s\\S]*?)</a>",
        caseSensitive: false),
    (m) => '[${m.group(2)}](${m.group(1)})',
  );
  // 去剩余标签。
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');
  // HTML 实体。
  text = text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');
  // 压缩空白。
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

/// web_extract 工具：抓取 URL 内容转文本。
///
/// 对应 Hermes web_extract_tool。手机版内置 HTTP 抓取 + HTML→text（无 key）。
/// SSRF 防护 + 敏感参数拦截。char_limit 默认 15000，超长 head+tail 截断。
Future<String> webExtractTool(
  List<dynamic> urls, {
  String? format,
  int? charLimit,
  http.Client? client,
}) async {
  final httpClient = client ?? webHttpClient;
  final charCap = charLimit ?? 15000;
  final results = <Map<String, dynamic>>[];
  for (var i = 0; i < urls.length; i++) {
    final item = urls[i];
    String? url;
    if (item is String) {
      url = item;
    } else if (item is Map<String, dynamic>) {
      final u = item['url'] ?? item['href'];
      if (u is String) {
        url = u;
      }
    }
    if (url == null) {
      results.add({
        'url': '',
        'title': '',
        'content': '',
        'error': 'Invalid URL item at index $i: expected a URL string or an object with a string url/href field',
      });
      continue;
    }
    // 敏感查询参数拦截。
    final sensitiveKey = sensitiveQueryParamName(url);
    if (sensitiveKey != null) {
      results.add({
        'url': url,
        'title': '',
        'content': '',
        'error': "Blocked: URL contains a credential-like query parameter ($sensitiveKey).",
      });
      continue;
    }
    // SSRF 防护。
    if (!await isSafeUrl(url)) {
      results.add({
        'url': url,
        'title': '',
        'content': '',
        'error': 'Blocked: URL targets a private or internal network address',
      });
      continue;
    }
    // 白名单检查（防刷核心）：非白名单域名拒绝。
    if (!us.isAllowedUrl(url)) {
      results.add({
        'url': url,
        'title': '',
        'content': '',
        'error': 'Blocked: domain not in allowlist. Hermes only extracts from approved sites.',
      });
      continue;
    }
    // 私域/需渲染平台（知乎/小红书/贴吧）→ WebView 抓取（无头后台）。
    if (_needsWebview(url)) {
      final wv = await webviewExtract(url, charLimit: charCap);
      if (wv.success) {
        results.add({
          'url': url,
          'title': wv.title,
          'content': wv.content,
        });
      } else {
        results.add({
          'url': url,
          'title': '',
          'content': '',
          'error': wv.error ?? 'WebView extract failed',
        });
      }
      continue;
    }
    try {
      final uri = Uri.parse(url);
      final resp = await httpClient.get(uri).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        results.add({
          'url': url,
          'title': '',
          'content': '',
          'error': 'HTTP ${resp.statusCode}',
        });
        continue;
      }
      final contentType = resp.headers['content-type'] ?? '';
      String text;
      if (contentType.contains('html') || url.contains('.html')) {
        text = htmlToText(utf8.decode(resp.bodyBytes, allowMalformed: true));
      } else {
        text = utf8.decode(resp.bodyBytes, allowMalformed: true).trim();
      }
      // char_limit head+tail 截断。
      var content = text;
      var truncated = false;
      if (content.length > charCap) {
        final head = content.substring(0, charCap ~/ 2);
        final tail = content.substring(content.length - charCap ~/ 2);
        content = '$head\n\n... [truncated] ...\n\n$tail';
        truncated = true;
      }
      results.add({
        'url': url,
        'title': '',
        'content': content,
        if (truncated) 'truncated': true,
      });
    } catch (e) {
      results.add({
        'url': url,
        'title': '',
        'content': '',
        'error': '$e',
      });
    }
  }
  return jsonEncode({'results': results});
}

// =============================================================================
// Schemas + Registry
// =============================================================================

const Map<String, dynamic> webSearchSchema = {
  'name': 'web_search',
  'description':
      'Search the web for current information. Returns search result metadata '
      '(URLs, titles, descriptions). Use web_extract to get full content from '
      'a specific URL.',
  'parameters': {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'The search query',
      },
      'limit': {
        'type': 'integer',
        'description': 'Maximum number of results (default 5, max 100)',
        'default': 5,
      },
    },
    'required': ['query'],
  },
};

const Map<String, dynamic> webExtractSchema = {
  'name': 'web_extract',
  'description':
      'Extract readable text content from a specific web page URL. '
      'Use after web_search to get full page content. Blocked for private '
      'or internal network addresses.',
  'parameters': {
    'type': 'object',
    'properties': {
      'urls': {
        'type': 'array',
        'description': 'URLs to extract content from',
        'items': {'type': 'string'},
      },
      'format': {
        'type': 'string',
        'enum': ['markdown', 'html'],
        'description': 'Desired output format (optional)',
      },
      'char_limit': {
        'type': 'integer',
        'description': 'Per-page char budget (default 15000)',
      },
    },
    'required': ['urls'],
  },
};

/// 注册 web 工具。
void registerWebTools() {
  registerWebLoginTool();
  registry.register(
    name: 'web_search',
    toolset: 'web',
    schema: webSearchSchema,
    handler: (args, [kwargs]) async {
      return await webSearchTool(
        args['query'] as String? ?? '',
        limit: args['limit'] as int? ?? 5,
      );
    },
    checkFn: () => true,
    emoji: '🌐',
  );
  registry.register(
    name: 'web_extract',
    toolset: 'web',
    schema: webExtractSchema,
    handler: (args, [kwargs]) async {
      final rawUrls = args['urls'];
      final urls = rawUrls is List ? rawUrls : const <dynamic>[];
      return await webExtractTool(
        urls,
        format: args['format'] as String?,
        charLimit: args['char_limit'] as int?,
      );
    },
    checkFn: () => true,
    emoji: '📄',
  );
  registry.register(
    name: 'web_download',
    toolset: 'web',
    schema: webDownloadSchema,
    handler: (args, [kwargs]) async {
      return await webDownloadTool(
        url: args['url'] as String? ?? '',
        path: args['path'] as String? ?? '',
      );
    },
    checkFn: () => true,
    emoji: '⬇️',
  );
}
