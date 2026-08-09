// Mermaid 图表渲染：用本地打包的 mermaid.min.js（assets/mermaid/），
// HeadlessInAppWebView 执行渲染，提取 SVG 后交给 flutter_svg 显示。
// 全程离线，无需网络，与 Obsidian 的 mermaid 渲染一致。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
  bool _rendering = false;

  /// 本地 mermaid.min.js 的 asset 路径（Android: file:///android_asset/...）。
  static const _assetBase = 'file:///android_asset/flutter_assets/';

  @override
  void initState() {
    super.initState();
    _render();
  }

  @override
  void didUpdateWidget(MermaidWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code) {
      _svg = null;
      _error = null;
      _render();
    }
  }

  Future<void> _render() async {
    if (_rendering) return;
    _rendering = true;
    setState(() {});
    try {
      final svg = await _renderSvg(widget.code);
      if (!mounted) return;
      setState(() => _svg = svg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      _rendering = false;
    }
  }

  /// 用 Headless WebView 跑 mermaid.js，返回渲染好的 SVG 字符串。
  static Future<String> _renderSvg(String code) async {
    final html = _buildHtml(code);
    final completer = Completer<String>();
    var done = false;

    final headless = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: html,
        baseUrl: WebUri('$_assetBase/assets/mermaid/'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
      ),
      onLoadStop: (controller, url) async {
        if (done) return;
        try {
          // mermaid.run() 渲染完成后取 .mermaid 容器里的 SVG。
          final js = '''
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
          final result = await controller.evaluateJavascript(source: js);
          if (done) return;
          done = true;
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
            completer.complete(map['svg'] as String);
          } else {
            completer.completeError(
                StateError('mermaid: ${map['error'] ?? 'unknown error'}'));
          }
        } catch (e) {
          if (!done) {
            done = true;
            completer.completeError(e);
          }
        }
      },
      onLoadError: (controller, url, codeNum, message) {
        if (!done) {
          done = true;
          completer.completeError(StateError('mermaid load error: $message'));
        }
      },
    );

    await headless.run();
    try {
      return await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw StateError('mermaid render timeout'),
      );
    } finally {
      await headless.dispose();
    }
  }

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

  @override
  Widget build(BuildContext context) {
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
}
