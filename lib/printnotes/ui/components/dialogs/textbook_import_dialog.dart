/// 教材导入对话框：列出可导入的开源教材（md/ipynb + LaTeX），
/// 点击一键下载、转换、导入到笔记库 subject_library/。
library;

import 'package:flutter/material.dart';

import 'package:mix/printnotes/utils/textbook_importer.dart';
import 'package:mix/printnotes/ui/widgets/menu_tile.dart';

/// 打开教材导入对话框。
Future<void> showTextbookImportDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('导入教材'),
      icon: const Icon(Icons.library_books_outlined, size: 40),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: kTextbookSources.length,
          itemBuilder: (ctx, i) {
            final src = kTextbookSources[i];
            return MenuTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: src.name,
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(src.description,
                      style: const TextStyle(fontSize: 12)),
                  Text(src.license,
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(ctx).colorScheme.onSurface.withAlpha(150))),
                ],
              ),
              trailing: const Icon(Icons.download),
              isFirst: i == 0,
              isLast: i + 1 == kTextbookSources.length,
              onTap: () {
                Navigator.of(ctx).pop();
                _doImport(context, src);
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          child: const Text('关闭'),
          onPressed: () => Navigator.of(ctx).pop(),
        ),
      ],
    ),
  );
}

/// 执行导入：进度弹窗 → 完成提示。
Future<void> _doImport(BuildContext context, TextbookSource src) async {
  final messenger = ScaffoldMessenger.of(context);
  final progress = ValueNotifier<double>(0);
  // 进度弹窗。
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => ValueListenableBuilder<double>(
      valueListenable: progress,
      builder: (ctx, value, _) => AlertDialog(
        title: Text('正在导入 ${src.name}…'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('下载并解压开源教材到笔记库（仅一次，之后可离线阅读）'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: value),
            const SizedBox(height: 8),
            Text('${(value * 100).round()}%',
                style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    ),
  );

  try {
    final result = await importTextbook(
      src,
      onProgress: (p) => progress.value = p,
    );
    if (context.mounted) {
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(result)));
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context).pop();
      messenger.showSnackBar(
          SnackBar(content: Text('导入失败：$e'), backgroundColor: Colors.red));
    }
  } finally {
    progress.dispose();
  }
}
