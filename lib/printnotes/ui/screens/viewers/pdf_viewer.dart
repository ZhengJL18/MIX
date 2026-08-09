import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

import 'package:mix/services/remote_asset_manager.dart';

/// PDF 查看器：WebView + pdf.js（按需下载，与 mermaid 渲染同构）。
///
/// 设计要点：
/// - pdf.min.js / pdf.worker.min.js 走 RemoteAssetManager 按需下载（不进 APK）
/// - worker 代码以 base64 内联进 HTML，用 Blob URL 创建 —— 绕过 file:// 页面里
///   `new Worker('file://…')` 的跨域限制（Chromium 会拒绝 file worker）
/// - PDF 本体用 file:// 绝对 URL 流式加载（App 已具备"所有文件访问"权限）
/// - 顶部工具条：上一页/下一页/页码、缩放 ±、适应宽度；触摸上下滑翻页
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({super.key, required this.fileUri});

  final Uri fileUri;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  /// 就绪后的 HTML（含内联 worker）；null = 资源下载/构建中。
  String? _html;
  String? _baseUrl;

  /// 下载进度 0..1（资源未就绪时显示）。
  double _downloadProgress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      // 1. 按需下载 pdf.js 内核与 worker（首次下载，之后走缓存）。
      final jsPath = await RemoteAssetManager.instance.ensure('pdfjs',
          onProgress: _onProgress);
      final workerPath = await RemoteAssetManager.instance.ensure('pdfjs-worker',
          onProgress: _onProgress);
      if (!mounted) return;

      // 2. worker 代码 base64 内联进 HTML（Blob URL 方式，规避 file:// Worker 限制）。
      final workerB64 = base64Encode(await File(workerPath).readAsBytes());
      final pdfFileUrl = Uri.file(widget.fileUri.toFilePath()).toString();
      final jsDir = File(jsPath).parent.path;

      setState(() {
        _html = _buildHtml(workerB64, pdfFileUrl);
        _baseUrl = 'file://$jsDir/';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onProgress(int done, int total, String name) {
    if (!mounted) return;
    setState(() => _downloadProgress = total <= 0 ? 0 : done / total);
  }

  static String _buildHtml(String workerB64, String pdfUrl) {
    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
<style>
  html,body{margin:0;padding:0;background:#4a4f57;font-family:system-ui,-apple-system,sans-serif;}
  #toolbar{position:sticky;top:0;z-index:10;display:flex;align-items:center;gap:10px;
    background:#2f333a;color:#eee;padding:8px 12px;font-size:14px;box-shadow:0 1px 4px rgba(0,0,0,.4);}
  #toolbar button{background:#4a5058;color:#fff;border:none;border-radius:6px;padding:6px 12px;
    font-size:14px;min-width:36px;cursor:pointer;}
  #toolbar button:active{background:#666;}
  #pageInfo{min-width:72px;text-align:center;font-variant-numeric:tabular-nums;}
  #viewer{display:flex;flex-direction:column;align-items:center;gap:12px;padding:16px 8px;}
  .page-wrap{position:relative;margin:0 auto;}
  canvas{background:#fff;box-shadow:0 2px 10px rgba(0,0,0,.5);border-radius:2px;display:block;}
  #loading{color:#ccc;padding:48px 24px;text-align:center;font-size:15px;}
  #error{color:#ff8a80;padding:48px 24px;text-align:center;font-size:14px;word-break:break-all;}
</style>
</head>
<body>
<div id="toolbar">
  <button onclick="page(-1)">◀</button>
  <span id="pageInfo">- / -</span>
  <button onclick="page(1)">▶</button>
  <span style="flex:1"></span>
  <button onclick="zoom(-0.2)">−</button>
  <button onclick="zoom(0.2)">+</button>
  <button onclick="fitPage()">适应</button>
</div>
<div id="viewer">
  <div id="loading">正在加载 PDF…</div>
</div>
<script src="pdf.min.js"></script>
<script>
const PDF_PATH = '$pdfUrl';
const WORKER_B64 = '$workerB64';

// worker 用 Blob URL 创建：file:// 页面里 new Worker('file://…') 会被 Chromium 拒绝。
const workerBytes = Uint8Array.from(atob(WORKER_B64), c => c.charCodeAt(0));
pdfjsLib.GlobalWorkerOptions.workerSrc =
  URL.createObjectURL(new Blob([workerBytes], {type: 'application/javascript'}));

let pdfDoc = null;
let currentPage = 1;
let scale = 1.5;
const viewer = document.getElementById('viewer');

async function loadPdf() {
  try {
    pdfDoc = await pdfjsLib.getDocument({url: PDF_PATH}).promise;
    document.getElementById('loading').textContent = '';
    renderPage(currentPage);
  } catch (e) {
    document.getElementById('loading').innerHTML =
      '<div id="error">PDF 加载失败：' + e + '</div>';
  }
}

async function renderPage(n) {
  if (!pdfDoc) return;
  if (n < 1) n = 1;
  if (n > pdfDoc.numPages) n = pdfDoc.numPages;
  currentPage = n;
  document.getElementById('pageInfo').textContent = n + ' / ' + pdfDoc.numPages;

  const page = await pdfDoc.getPage(n);
  viewer.querySelectorAll('.page-wrap').forEach(el => el.remove());
  const wrap = document.createElement('div');
  wrap.className = 'page-wrap';
  const canvas = document.createElement('canvas');
  wrap.appendChild(canvas);
  viewer.appendChild(wrap);

  const ctx = canvas.getContext('2d');
  const vp = page.getViewport({scale: scale});
  canvas.width = vp.width;
  canvas.height = vp.height;
  await page.render({canvasContext: ctx, viewport: vp}).promise;
}

function page(delta) { renderPage(currentPage + delta); }
function zoom(d) {
  scale = Math.max(0.5, Math.min(4, scale + d));
  if (pdfDoc) renderPage(currentPage);
}
function fitPage() {
  if (!pdfDoc) return;
  pdfDoc.getPage(currentPage).then(page => {
    const w = Math.min(window.innerWidth - 40, 900);
    scale = w / page.getViewport({scale: 1}).width;
    renderPage(currentPage);
  });
}

// 触摸上下滑翻页（平滑图片上不触发）
let startY = 0, startX = 0, tracking = false;
document.addEventListener('touchstart', e => {
  tracking = true;
  startY = e.touches[0].clientY;
  startX = e.touches[0].clientX;
}, {passive: true});
document.addEventListener('touchend', e => {
  if (!tracking) return;
  tracking = false;
  const dy = e.changedTouches[0].clientY - startY;
  const dx = e.changedTouches[0].clientX - startX;
  if (Math.abs(dy) > 60 && Math.abs(dy) > Math.abs(dx)) page(dy < 0 ? 1 : -1);
}, {passive: true});

loadPdf();
</script>
</body>
</html>''';
  }

  @override
  Widget build(BuildContext context) {
    final fileName = p.basename(widget.fileUri.path);
    return Scaffold(
      appBar: AppBar(title: Text(fileName)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text('PDF 查看器初始化失败\n$_error',
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    if (_html == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('正在准备 PDF 渲染引擎… ${(_downloadProgress * 100).round()}%'),
          ],
        ),
      );
    }
    return InAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        allowFileAccess: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        supportMultipleWindows: false,
      ),
      onWebViewCreated: (controller) {
        controller.loadData(data: _html!, baseUrl: WebUri(_baseUrl!));
      },
    );
  }
}
