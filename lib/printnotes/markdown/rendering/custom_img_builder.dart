import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';
import 'package:mix/printnotes/providers/editor_config_provider.dart';
import 'package:mix/printnotes/utils/storage_system.dart';

class CustomImgBuilder extends StatelessWidget {
  final String url;
  final Uri fileUri;
  final Map<String, String> attributes;

  const CustomImgBuilder(this.url, this.fileUri, this.attributes, {super.key});

  @override
  Widget build(BuildContext context) {
    double editorFontSize = context.watch<EditorConfigProvider>().fontSize;

    // Get image stored locally, totally fine if fails or file doesn't exist
    // as Image.file error builder will catch it
    Future<File> getLocalImage() async {
      // Check if image (url) is relative to note (filePath)
      File relativeFile = File(join(
          dirname(fileUri.toFilePath()),
          url.startsWith('.$separator')
              ? url.replaceFirst('.$separator', '')
              : url));
      if (relativeFile.existsSync()) return relativeFile;

      // Otherwise, go through all files in mainDir to find by exact name
      final allFiles = await StorageSystem.listFolderContents(
        Uri.parse(context.read<SettingsProvider>().mainDir),
        recursive: true,
        showHidden: true,
      );
      for (FileSystemEntity item in allFiles) {
        if (item is File && basename(item.path) == url) {
          return File(item.path);
        }
      }

      // Catch for if full path was used instead
      return File(url);
      }

      /// 从 Jupyter notebook（.ipynb）提取第 [idx] 张输出图片。
      ///
      /// 用法：`![图](chapter12.ipynb#2)` —— 渲染时读 notebook JSON，
      /// 取第 2 个 `image/png` 输出 cell，base64 解码成图片显示。
      /// 解决"notebook 转 markdown 时图片丢失只剩画图代码"的问题，
      /// 无需额外图片文件，完全离线。
      Future<Uint8List> extractNotebookImage(String url) async {
      final hashIdx = url.indexOf('#');
      final filePart = hashIdx >= 0 ? url.substring(0, hashIdx) : url;
      final idx =
          hashIdx >= 0 ? (int.tryParse(url.substring(hashIdx + 1)) ?? 1) : 1;

      // 相对笔记目录解析 ipynb 文件
      File nbFile = File(join(dirname(fileUri.toFilePath()), filePart));
      if (!nbFile.existsSync()) {
        final allFiles = await StorageSystem.listFolderContents(
          Uri.parse(context.read<SettingsProvider>().mainDir),
          recursive: true,
          showHidden: true,
        );
        File? found;
        for (final item in allFiles) {
          if (item is File && basename(item.path) == filePart) {
            found = File(item.path);
            break;
          }
        }
        if (found == null) throw Exception('找不到 notebook 文件: $filePart');
        nbFile = found;
      }

      final raw = await nbFile.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final cells = (decoded['cells'] as List?) ?? [];
      var imgCount = 0;
      for (final cell in cells) {
        final outputs = (cell as Map<String, dynamic>)['outputs'];
        if (outputs is! List) continue;
        for (final out in outputs) {
          final data = (out as Map<String, dynamic>)['data'];
          if (data is Map && data['image/png'] is String) {
            imgCount++;
            if (imgCount == idx) {
              final b64 =
                  (data['image/png'] as String).replaceAll(RegExp(r'\s'), '');
              return base64Decode(b64);
            }
          }
        }
      }
      throw Exception('notebook 中没有第 $idx 张图片输出');
      }

    Widget errorMessage(String text) => Padding(
          padding: const EdgeInsets.all(8.0),
          child: RichText(
            softWrap: true,
            maxLines: 3,
            text:
                TextSpan(style: TextStyle(fontSize: editorFontSize), children: [
              WidgetSpan(
                child: Tooltip(
                  triggerMode: TooltipTriggerMode.tap,
                  showDuration: const Duration(seconds: 5),
                  enableTapToDismiss: true,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .error
                        .withValues(alpha: 0.5),
                  ),
                  message: text,
                  textStyle:
                      TextStyle(color: Theme.of(context).colorScheme.onSurface),
                  child: Icon(
                    Icons.broken_image,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
              TextSpan(
                text: ' ${attributes['alt'] ?? ''}',
                style:
                    TextStyle(color: Theme.of(context).colorScheme.onSurface),
              ),
            ]),
          ),
        );

    if (url.startsWith('http')) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded /
                      loadingProgress.expectedTotalBytes!
                  : null,
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) =>
            errorMessage('Image could not be loaded'),
      );
    } else {
      return FutureBuilder(
        future: getLocalImage(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return CircularProgressIndicator();
          }
          return Image.file(
            snapshot.data != null ? snapshot.data! : File(''),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => errorMessage(
                'Incorrect path or file type, check if url is correct'),
          );
        },
      );
    }
  }
}
