import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mix/tools/web_tools.dart';

/// UTF-8 编码的 XML 响应（MockClient 默认 Latin-1，中文会乱码）。
http.Response xmlResp(String body, [int status = 200]) => http.Response.bytes(
      utf8.encode(body),
      status,
      headers: {'content-type': 'application/xml; charset=utf-8'},
    );

/// 构造必应 RSS 响应。
const String _sampleRss = '''<?xml version="1.0"?>
<rss version="2.0">
<channel>
<title>必应：测试</title>
<item>
<title>Dart 编程语言入门</title>
<link>https://dart.dev/docs</link>
<description>Dart 是 Google 开发的编程语言。</description>
</item>
<item>
<title>Flutter 官方文档</title>
<link>https://flutter.dev/docs</link>
<description>Flutter 是跨平台 UI 框架。</description>
</item>
</channel>
</rss>''';

void main() {
  group('BingBackend', () {
    test('解析 RSS 返回搜索结果', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'cn.bing.com');
        expect(request.url.queryParameters['format'], 'rss');
        expect(request.url.queryParameters['mkt'], 'zh-CN');
        expect(request.url.queryParameters['q'], '测试');
        expect(request.headers['Accept-Language'], contains('zh-CN'));
        return xmlResp(_sampleRss);
      });
      webHttpClient = client;
      final backend = BingBackend();
      final results = await backend.search('测试', 5);
      expect(results.length, 2);
      expect(results[0]['title'], 'Dart 编程语言入门');
      expect(results[0]['url'], 'https://dart.dev/docs');
      expect(results[0]['description'], contains('Dart 是'));
      expect(results[0]['position'], 1);
      expect(results[1]['title'], 'Flutter 官方文档');
    });

    test('limit 截断', () async {
      webHttpClient = MockClient((request) async {
        return xmlResp(_sampleRss);
      });
      final backend = BingBackend();
      final results = await backend.search('x', 1);
      expect(results.length, 1);
    });

    test('非 200 返回空', () async {
      webHttpClient = MockClient((request) async {
        return http.Response('error', 403);
      });
      final backend = BingBackend();
      final results = await backend.search('x', 5);
      expect(results, isEmpty);
    });

    test('畸形 XML 返回空', () async {
      webHttpClient = MockClient((request) async {
        return xmlResp('not xml at all');
      });
      final backend = BingBackend();
      final results = await backend.search('x', 5);
      expect(results, isEmpty);
    });
  });

  group('webSearchTool', () {
    test('必应成功返回结果', () async {
      webHttpClient = MockClient((request) async {
        return xmlResp(_sampleRss);
      });
      final orig = webSearchBackend;
      webSearchBackend = BingBackend();
      try {
        final result = await webSearchTool('测试');
        final map = jsonDecode(result) as Map;
        expect(map['success'], true);
        final web = (map['data'] as Map)['web'] as List;
        expect(web, isNotEmpty);
      } finally {
        webSearchBackend = orig;
      }
    });

    test('主后端空结果 → 必应返回', () async {
      final orig = webSearchBackend;
      final origFallback = webSearchFallbackBackend;
      final origFallback2 = webSearchFallbackBackend2;
      webSearchBackend = _EmptyBackend();
      webSearchFallbackBackend = _FixedBackend([
        {'title': 'Bing 结果', 'url': 'http://bing.example', 'description': 'bing', 'position': 1},
      ]);
      webSearchFallbackBackend2 = _FixedBackend([
        {'title': '不应走到 DDG', 'url': 'http://ddg.example', 'description': 'ddg', 'position': 1},
      ]);
      try {
        final result = await webSearchTool('x');
        final map = jsonDecode(result) as Map;
        final web = (map['data'] as Map)['web'] as List;
        expect(web.first['title'], 'Bing 结果');
      } finally {
        webSearchBackend = orig;
        webSearchFallbackBackend = origFallback;
        webSearchFallbackBackend2 = origFallback2;
      }
    });

    test('主+必应都空结果 → DDG 兜底', () async {
      final orig = webSearchBackend;
      final origFallback = webSearchFallbackBackend;
      final origFallback2 = webSearchFallbackBackend2;
      webSearchBackend = _EmptyBackend();
      webSearchFallbackBackend = _EmptyBackend();
      webSearchFallbackBackend2 = _FixedBackend([
        {'title': 'DDG 结果', 'url': 'http://ddg.example', 'description': 'ddg', 'position': 1},
      ]);
      try {
        final result = await webSearchTool('x');
        final map = jsonDecode(result) as Map;
        final web = (map['data'] as Map)['web'] as List;
        expect(web.first['title'], 'DDG 结果');
      } finally {
        webSearchBackend = orig;
        webSearchFallbackBackend = origFallback;
        webSearchFallbackBackend2 = origFallback2;
      }
    });
  });
}

/// 恒返回空的后端（模拟必应失败）。
class _EmptyBackend implements WebSearchBackend {
  @override
  bool get requiresKey => false;
  @override
  Future<List<Map<String, dynamic>>> search(String query, int limit) async =>
      const [];
}

/// 返回固定结果的后端。
class _FixedBackend implements WebSearchBackend {
  final List<Map<String, dynamic>> results;
  _FixedBackend(this.results);
  @override
  bool get requiresKey => false;
  @override
  Future<List<Map<String, dynamic>>> search(String query, int limit) async =>
      results;
}
