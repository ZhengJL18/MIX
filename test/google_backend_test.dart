import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mix/tools/web_tools.dart';

/// UTF-8 编码的响应（MockClient 默认 Latin-1，中文会乱码）。
http.Response utf8Resp(String body, [int status = 200]) =>
    http.Response.bytes(
      utf8.encode(body),
      status,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );

/// 模拟 gbv=1 无 JS 版 Google 搜索结果页（含 /url?q= 包装与 VwiC3b 摘要）。
const String _sampleGoogleHtml = '''
<!doctype html><html><head><title>测试 - Google Search</title></head><body>
<div class="g">
  <h3 class="r"><a href="/url?q=https%3A%2F%2Fdart.dev%2Fdocs&amp;sa=U&amp;ved=2ahUKEwiXxLq3hJqGAxVWkq8BHYd0C9EQFnoECAUQAg" onmousedown="return rwt(this)">Dart 编程语言入门</a></h3>
  <div class="s">
    <div class="VwiC3b yXK7x lVm3ye">Dart 是 Google 开发的编程语言，用于构建 Web、服务器和移动应用。</div>
  </div>
</div>
<div class="g">
  <h3 class="r"><a href="https://flutter.dev/docs" onmousedown="return rwt(this)">Flutter 官方文档</a></h3>
  <div class="s">
    <div class="VwiC3b yXK7x lVm3ye">Flutter 是跨平台 UI 框架，一套代码构建多端应用。</div>
  </div>
</div>
</body></html>
''';

/// 模拟 Google News RSS。
const String _sampleNewsRss = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel><title>测试 - Google News</title>
<item>
<title>AI 最新进展</title>
<link>https://news.google.com/rss/articles/CBMi</link>
<description>人工智能领域的重大突破。</description>
</item>
<item>
<title>低空经济动态</title>
<link>https://news.google.com/rss/articles/CBMj</link>
<description>华南地区低空经济试点进展。</description>
</item>
</channel>
</rss>
''';

/// 空结果页（无 h3 结果块，模拟被反爬/验证页）。
const String _emptyGoogleHtml =
    '<html><head><title>Google Search</title></head><body><p>unusual traffic</p></body></html>';

void main() {
  group('GoogleBackend', () {
    test('解析 gbv=1 HTML：标题/URL 解码/摘要', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'www.google.com');
        expect(request.url.queryParameters['q'], '测试');
        expect(request.url.queryParameters['gbv'], '1');
        expect(request.url.queryParameters['hl'], 'zh-CN');
        return utf8Resp(_sampleGoogleHtml);
      });
      webHttpClient = client;
      final backend = GoogleBackend();
      final results = await backend.search('测试', 5);
      expect(results.length, 2);
      expect(results[0]['title'], 'Dart 编程语言入门');
      expect(results[0]['url'], 'https://dart.dev/docs');
      expect(results[0]['description'], contains('Dart 是'));
      expect(results[0]['position'], 1);
      // 直链（非 /url?q=）直接取。
      expect(results[1]['url'], 'https://flutter.dev/docs');
      expect(results[1]['description'], contains('跨平台'));
    });

    test('limit 截断', () async {
      webHttpClient = MockClient((request) async {
        return utf8Resp(_sampleGoogleHtml);
      });
      final backend = GoogleBackend();
      final results = await backend.search('x', 1);
      expect(results.length, 1);
    });

    test('网页无结果 → 回退 Google News RSS', () async {
      var webCalled = false;
      var newsCalled = false;
      final client = MockClient((request) async {
        if (request.url.host == 'www.google.com') {
          webCalled = true;
          return utf8Resp(_emptyGoogleHtml);
        }
        expect(request.url.host, 'news.google.com');
        expect(request.url.path, '/rss/search');
        newsCalled = true;
        return utf8Resp(_sampleNewsRss,
            // 复用 utf8Resp 但改 content-type 无妨（解析只看 body）。
            );
      });
      webHttpClient = client;
      final backend = GoogleBackend();
      final results = await backend.search('AI', 5);
      expect(webCalled, isTrue);
      expect(newsCalled, isTrue);
      expect(results.length, 2);
      expect(results[0]['title'], 'AI 最新进展');
      expect(results[0]['url'], contains('news.google.com'));
    });

    test('非 200 返回空', () async {
      webHttpClient = MockClient((request) async {
        return http.Response('error', 429);
      });
      final backend = GoogleBackend();
      final results = await backend.search('x', 5);
      expect(results, isEmpty);
    });
  });
}
