// 富 HTML 直出渲染。
//
// 为什么需要它：现有 markdown 引擎里 HTML 只按「零散行内标签 + 表格」处理
// （custom_node.dart → HtmlWidget），CSS 能力基本为零。而模型输出 HTML 时
// 常用的是 <div style>、flex 布局、<details>、<svg>、彩色卡片这类东西，
// 只有真正的浏览器排版能还原。
//
// 设计约束（全部来自本项目既有踩坑经验）：
//   1. 资源离线：KaTeX 打包在 APK 内（assets/katex），走
//      file:///android_asset/flutter_assets/ —— 与 convert_tools.dart 的
//      md→PDF 完全同一条路径，不依赖 CDN。
//   2. 高度自适应：WebView 在长列表里必须有确定高度，否则塌陷成 0。
//      页面用 ResizeObserver + load 双保险把 body 高度回报给 Flutter。
//   3. 滚动交给父级：disableVerticalScroll + body overflow hidden，
//      否则手指在代码块上滑动会被 WebView 吃掉。
//   4. 流式更新节流：模型 token 是逐个来的，每次全量 setInnerHTML 会
//      反复重排 KaTeX。250ms 合并一次，结束后再补一次最终渲染。
//   5. 链接外开：内容里的链接不应把聊天页导航走。
//
// 判定「这段是不是 HTML」的策略见 isHtmlBlock / htmlFromMarkdown。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../printnotes/markdown/rendering/code_engine.dart';

/// 把一段 HTML 用 WebView 原生排版出来。
///
/// [html] 是 HTML **片段**（不需要 <html>/<body>），可以直接含 <style>。
/// 公式用 `$...$` / `$$...$$` / `\(...\)` / `\[...\]`，由 KaTeX 自动渲染。
class HtmlRichView extends StatefulWidget {
  const HtmlRichView({
    super.key,
    required this.html,
    this.fontSize = 15,
    this.maxHeight = 4000,
  });

  final String html;
  final double fontSize;

  /// 高度上限：超过后内部滚动，避免一条消息撑出几屏。
  final double maxHeight;

  @override
  State<HtmlRichView> createState() => _HtmlRichViewState();
}

class _HtmlRichViewState extends State<HtmlRichView> {
  InAppWebViewController? _controller;
  double _height = 72; // 首帧占位，等到 JS 回报再收敛
  bool _loaded = false;
  String _loadedHtml = '';
  Timer? _throttle;

  @override
  void didUpdateWidget(covariant HtmlRichView old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html && _loaded) _scheduleUpdate();
  }

  @override
  void dispose() {
    _throttle?.cancel();
    super.dispose();
  }

  /// 流式输出：合并 250ms 内的多次变更，只推一次 DOM。
  void _scheduleUpdate() {
    if (_throttle?.isActive ?? false) return;
    _throttle = Timer(const Duration(milliseconds: 250), () {
      final c = _controller;
      if (c == null || widget.html == _loadedHtml) return;
      _loadedHtml = widget.html;
      c.evaluateJavascript(source: 'window.mxSet(${jsonEncode(widget.html)});');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final html = _buildDocument(
      widget.html,
      dark: dark,
      fontSize: widget.fontSize,
      accent: _cssColor(scheme.primary),
      fg: _cssColor(scheme.onSurface),
      muted: _cssColor(scheme.onSurface.withValues(alpha: 0.62)),
      border: _cssColor(scheme.onSurface.withValues(alpha: 0.16)),
      codeBg: _cssColor(scheme.onSurface.withValues(alpha: dark ? 0.10 : 0.06)),
    );

    final screenH = MediaQuery.of(context).size.height;
    final cap = widget.maxHeight < screenH * 6 ? widget.maxHeight : screenH * 6;
    final effective = _height.clamp(24.0, cap).toDouble();

    return SizedBox(
      width: double.infinity,
      height: effective,
      child: AnimatedOpacity(
        // 首帧高度是猜的，等真实高度回来再淡入，避免内容被裁一刀。
        opacity: _loaded ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: InAppWebView(
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            transparentBackground: true,
            disableVerticalScroll: _height > cap,
            disableHorizontalScroll: false,
            verticalScrollBarEnabled: _height > cap,
            horizontalScrollBarEnabled: false,
            supportZoom: false,
            builtInZoomControls: false,
            allowFileAccess: true,
            allowFileAccessFromFileURLs: true,
            allowUniversalAccessFromFileURLs: true,
          ),
          onWebViewCreated: (controller) async {
            _controller = controller;
            controller.addJavaScriptHandler(
              handlerName: 'mxHeight',
              callback: (args) {
                if (!mounted) return true;
                final raw = args.isNotEmpty ? args.first : null;
                final h = raw is num ? raw.toDouble() : double.tryParse('$raw');
                if (h == null || h <= 0) return true;
                final next = h + 4; // 留 4px 呼吸位，防最后一像素被截
                if ((next - _height).abs() > 1) {
                  setState(() {
                    _height = next;
                    if (!_loaded) _loaded = true;
                  });
                } else if (!_loaded) {
                  setState(() => _loaded = true);
                }
                return true;
              },
            );
            _loadedHtml = widget.html;
            await controller.loadData(data: html, baseUrl: _assetBase);
          },
          onLoadStop: (controller, url) async {
            // 双保险：ResizeObserver 在个别老 WebView 上不触发，这里主动补一次；
            // 再兜一层定时器，保证即使高度回调全挂，内容也不会一直透明。
            await controller.evaluateJavascript(
              source: 'window.mxPostHeight && window.mxPostHeight();',
            );
            if (!mounted || _loaded) return;
            Timer(const Duration(milliseconds: 400), () {
              if (mounted && !_loaded) setState(() => _loaded = true);
            });
          },
          shouldOverrideUrlLoading: (controller, action) async {
            final uri = action.request.url;
            if (uri == null) return NavigationActionPolicy.ALLOW;
            final s = uri.scheme;
            if (s == 'http' || s == 'https' || s == 'mailto' || s == 'tel') {
              // 聊天里的链接一律外部打开，别把会话导航没了。
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              return NavigationActionPolicy.CANCEL;
            }
            return NavigationActionPolicy.ALLOW;
          },
        ),
      ),
    );
  }

  /// APK 内 flutter_assets 的虚拟路径（KaTeX 就在这里）。
  /// 非 Android 平台没有这个协议，返回 null 让 WebView 用默认 base。
  WebUri? get _assetBase {
    if (kIsWeb) return null;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return WebUri('file:///android_asset/flutter_assets/');
    }
    return null;
  }
}

/// Color → CSS rgba()。用 rgba 而不是 hex，这样半透明色也能正确表达。
String _cssColor(Color c) {
  final r = (c.r * 255).round();
  final g = (c.g * 255).round();
  final b = (c.b * 255).round();
  final a = c.a;
  return a >= 1 ? 'rgb($r,$g,$b)' : 'rgba($r,$g,$b,${a.toStringAsFixed(3)})';
}

/// 组装完整页面：排版 CSS 全部内联，不依赖网络。
String _buildDocument(
  String bodyHtml, {
  required bool dark,
  required double fontSize,
  required String accent,
  required String fg,
  required String muted,
  required String border,
  required String codeBg,
}) {
  final inlineCodeBg = dark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.055)';
  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<link rel="stylesheet" href="katex/katex.min.css">
<script src="katex/katex.min.js"></script>
<script src="katex/auto-render.min.js"></script>
<style>
  :root {
    --fg: $fg;
    --muted: $muted;
    --border: $border;
    --code-bg: $codeBg;
    --inline-code-bg: $inlineCodeBg;
    --accent: $accent;
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0; padding: 0;
    background: transparent;
    overflow-x: hidden;
    -webkit-text-size-adjust: 100%;
    text-size-adjust: 100%;
  }
  body {
    font-family: -apple-system, "Noto Sans CJK SC", "Source Han Sans SC",
                 "PingFang SC", "HarmonyOS Sans SC", "Microsoft YaHei",
                 system-ui, sans-serif;
    color: var(--fg);
  }
  #root {
    font-size: ${fontSize}px;
    line-height: 1.68;
    word-wrap: break-word;
    overflow-wrap: anywhere;
    padding-bottom: 1px;
  }
  #root > :first-child { margin-top: 0 !important; }
  #root > :last-child { margin-bottom: 0 !important; }
  p { margin: 0 0 0.72em; }
  h1, h2, h3, h4, h5, h6 {
    margin: 1.05em 0 0.45em;
    line-height: 1.32;
    font-weight: 600;
    letter-spacing: -0.005em;
  }
  h1 { font-size: 1.42em; }
  h2 { font-size: 1.24em; }
  h3 { font-size: 1.1em; }
  h4, h5, h6 { font-size: 1em; }
  h1, h2 { padding-bottom: 0.22em; border-bottom: 1px solid var(--border); }
  ul, ol { margin: 0 0 0.72em; padding-left: 1.35em; }
  li { margin: 0.16em 0; }
  li > p { margin: 0 0 0.3em; }
  a { color: var(--accent); text-decoration: none; }
  a:active { opacity: 0.6; }
  strong { font-weight: 650; }
  hr { border: none; border-top: 1px solid var(--border); margin: 1.1em 0; }
  blockquote {
    margin: 0.7em 0;
    padding: 0.15em 0 0.15em 0.85em;
    border-left: 3px solid var(--accent);
    color: var(--muted);
  }
  blockquote > :last-child { margin-bottom: 0; }
  code {
    font-family: ui-monospace, "SF Mono", "Roboto Mono", Menlo, Consolas, monospace;
    font-size: 0.88em;
  }
  :not(pre) > code {
    background: var(--inline-code-bg);
    border: 1px solid var(--border);
    border-radius: 5px;
    padding: 0.1em 0.35em;
  }
  pre {
    margin: 0.7em 0;
    padding: 0.7em 0.8em;
    background: var(--code-bg);
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
  }
  pre code { background: none; border: none; padding: 0; font-size: 0.86em; line-height: 1.55; }
  table {
    width: 100%;
    margin: 0.7em 0;
    border-collapse: collapse;
    font-size: 0.95em;
  }
  th, td {
    border: 1px solid var(--border);
    padding: 0.4em 0.6em;
    text-align: left;
    vertical-align: top;
  }
  th { font-weight: 600; background: var(--inline-code-bg); }
  img { max-width: 100%; height: auto; border-radius: 8px; }
  svg { max-width: 100%; height: auto; }
  details {
    margin: 0.7em 0;
    padding: 0.5em 0.75em;
    border: 1px solid var(--border);
    border-radius: 10px;
  }
  summary { cursor: pointer; font-weight: 550; }
  .katex { font-size: 1.04em; }
  .katex-display {
    margin: 0.6em 0;
    padding: 0.15em 0;
    overflow-x: auto;
    overflow-y: hidden;
  }
  /* 模型偶尔会写 <style> 覆盖全局，这里把根节点字色按住不让它跑偏 */
  #root { color: var(--fg); }
</style>
</head>
<body>
<div id="root">$bodyHtml</div>
<script>
(function () {
  var root = document.getElementById('root');
  var lastH = -1;

  function postHeight() {
    var h = Math.ceil(root.getBoundingClientRect().height);
    if (h > 0 && h !== lastH) {
      lastH = h;
      try { window.flutter_inappwebview.callHandler('mxHeight', h); } catch (e) {}
    }
  }
  window.mxPostHeight = postHeight;

  function typeset() {
    if (!window.renderMathInElement) return;
    try {
      renderMathInElement(root, {
        delimiters: [
          { left: '\$\$', right: '\$\$', display: true },
          { left: '\\\\[', right: '\\\\]', display: true },
          { left: '\$', right: '\$', display: false },
          { left: '\\\\(', right: '\\\\)', display: false }
        ],
        throwOnError: false,
        strict: false
      });
    } catch (e) {}
  }

  // 流式更新入口：只换内容，不重载页面（重载会闪白 + 丢滚动位置）。
  window.mxSet = function (html) {
    root.innerHTML = html;
    typeset();
    lastH = -1;
    requestAnimationFrame(postHeight);
  };

  window.addEventListener('load', function () {
    typeset();
    postHeight();
    // KaTeX 字体加载完成后高度可能变，补两次。
    setTimeout(postHeight, 160);
    setTimeout(postHeight, 640);
  });

  if (window.ResizeObserver) {
    new ResizeObserver(postHeight).observe(root);
  }
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(postHeight).catch(function () {});
  }
})();
</script>
</body>
</html>''';
}

// ============================================================================
// 判定与转换
// ============================================================================

/// 块级标签：出现这些标签基本可以认定「这是一段 HTML 而不是数学/文本」。
const _blockTags = [
  'div',
  'section',
  'article',
  'aside',
  'header',
  'footer',
  'main',
  'nav',
  'table',
  'thead',
  'tbody',
  'tr',
  'td',
  'th',
  'style',
  'script',
  'svg',
  'details',
  'summary',
  'figure',
  'figcaption',
  'canvas',
  'iframe',
  'html',
  'body',
  'dl',
  'dt',
  'dd',
  'form',
  'fieldset',
];

final RegExp _fencedHtml = RegExp(
  r'^\s*```(?:html|htm|HTML|HTM)\s*\n([\s\S]*?)\n?\s*```\s*$',
);
final RegExp _fencedAny = RegExp(r'^\s*```');
final RegExp _bareOpen = RegExp(
  '<(${_blockTags.join('|')})(?:\\s|>|/)',
  caseSensitive: false,
);
final RegExp _bareClose = RegExp(
  '</(${_blockTags.join('|')})\\s*>',
  caseSensitive: false,
);
// markdown 结构特征：有这些说明是 markdown（可能夹 HTML），需要先转换。
final RegExp _mdHints = RegExp(
  r'^(\s{0,3}#{1,6}\s|\s*[-*+]\s+\S|\s*\d+\.\s+\S|\s*>\s|```)',
  multiLine: true,
);

/// 整段是否就是一段 HTML（```html 围栏，或裸块级标签且成对闭合）。
///
/// 刻意排除了 `<(https?://…)` 自动链接和 `<T>` 泛型写法 —— 只看白名单
/// 里的块级标签，且要求有闭合标签，避免把正常回答误判成 HTML。
bool isHtmlBlock(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (_fencedHtml.hasMatch(t)) return true;
  if (_fencedAny.hasMatch(t)) return false; // 是别的语言代码块，别抢
  if (!_bareOpen.hasMatch(t)) return false;
  return _bareClose.hasMatch(t);
}

/// 开头看起来就在写 HTML（流式输出时闭合标签还没到，先用这个锁方向）。
final RegExp _htmlStart = RegExp(
  r'^\s*(```(?:html|htm)|<\s*(?:div|section|article|table|style|html|body|svg|details|figure|main|header|footer|canvas|iframe|form)\b)',
  caseSensitive: false,
);

/// 文本以 HTML 块开头 —— 用于流式阶段的「提前判定」。
bool startsWithHtmlBlock(String text) => _htmlStart.hasMatch(text);

/// 拿到可直接渲染的 HTML。
///
/// - ```html 围栏：剥掉围栏，内容原样用（模型已经写成 HTML 了，别再转一次）
/// - 裸 HTML 里同时有 markdown 结构：走 md→html，块级 HTML 由 markdown
///   解析器原样透传，段落/列表/标题正常转换
/// - 纯 HTML：原样用
String htmlFromMarkdown(String text) {
  final t = text.trim();
  final fenced = _fencedHtml.firstMatch(t);
  if (fenced != null) return fenced.group(1)!.trim();

  // 没有 markdown 结构特征 → 已经是 HTML，原样用，别多转一层。
  if (!_mdHints.hasMatch(t)) return t;

  // LaTeX 必须先摘出来再转换：markdown 会把公式里的 _ * \ 当标记吃掉，
  // 转换完再原样放回去，交给 KaTeX 处理。
  final math = <String>[];
  final protected = t.replaceAllMapped(_mathReg, (m) {
    math.add(m.group(0)!);
    return '\u0001MXMATH${math.length - 1}MX\u0001';
  });

  var html = _mdToHtml(protected);
  html = html.replaceAllMapped(RegExp('\u0001MXMATH(\\d+)MX\u0001'), (m) {
    final i = int.tryParse(m.group(1)!) ?? -1;
    return (i >= 0 && i < math.length) ? math[i] : m.group(0)!;
  });
  return html;
}

// 公式边界：块级 $$..$$ / \[..\]，行内 \(..\) / $..$（排除 \$ 转义）。
// 与 printnotes/latex_protector.dart 同一套约定，保证两边识别一致。
final RegExp _mathReg = RegExp(
  r'\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\\\([\s\S]+?\\\)|(?<!\\)\$[^$\n]+\$',
);

/// markdown → HTML。用 package:markdown 的 GFM 扩展：
/// 块级 HTML 原样透传，表格/删除线/任务列表都有。
String _mdToHtml(String markdownText) => md.markdownToHtml(
  markdownText,
  extensionSet: md.ExtensionSet.gitHubFlavored,
);

// ============================================================================
// 代码块引擎：```html 直接出预览
// ============================================================================

/// 让 ```html 围栏变成「可预览的 HTML 卡片」，而不是一坨源码。
///
/// 仍然保留源码视图 —— 模型偶尔会输出想让你复制走的 HTML 模板，
/// 直接吃掉源码会让人没法拿走。
class HtmlCodeEngine extends CodeEngine {
  const HtmlCodeEngine();

  @override
  String get language => 'html';

  @override
  List<String> get aliases => const ['htm', 'xhtml'];

  @override
  String get displayName => 'HTML 预览';

  @override
  List<EngineAsset> get requiredAssets => const [];

  @override
  Widget buildWidget(String code) => HtmlBlockCard(html: code);
}

/// HTML 预览卡片：工具条（预览/源码切换、复制）+ 内容区。
class HtmlBlockCard extends StatefulWidget {
  const HtmlBlockCard({super.key, required this.html});

  final String html;

  @override
  State<HtmlBlockCard> createState() => _HtmlBlockCardState();
}

class _HtmlBlockCardState extends State<HtmlBlockCard> {
  bool _showSource = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.14)),
        borderRadius: BorderRadius.circular(12),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.32),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(scheme),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
            child: _showSource
                ? SelectableText(
                    widget.html,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      height: 1.5,
                      color: scheme.onSurface.withValues(alpha: 0.86),
                    ),
                  )
                : HtmlRichView(html: widget.html, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 0),
      child: Row(
        children: [
          Icon(Icons.web_rounded, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            'HTML',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
              color: scheme.outline,
            ),
          ),
          const Spacer(),
          _iconBtn(
            icon: _showSource ? Icons.visibility_outlined : Icons.code,
            tooltip: _showSource ? '看预览' : '看源码',
            onTap: () => setState(() => _showSource = !_showSource),
          ),
          _iconBtn(
            icon: Icons.copy_rounded,
            tooltip: '复制 HTML',
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: widget.html));
              if (!mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text('HTML 已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _iconBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}
