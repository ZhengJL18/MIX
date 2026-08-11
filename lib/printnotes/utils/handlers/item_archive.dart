import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';
import 'package:mix/printnotes/utils/storage_system.dart';
import 'package:mix/printnotes/ui/widgets/custom_snackbar.dart';

class ItemArchiveHandler {
  final BuildContext context;

  ItemArchiveHandler(this.context);

  Future<void> handleArchiveItem(FileSystemEntity item) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认归档'),
        content: Text(
            '确定要归档这个${item is Directory ? '文件夹' : '文件'}吗？它将从当前位置移除。'),
        actions: [
          TextButton(
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          TextButton(
            child: Text(
              '归档',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await StorageSystem.archiveItem(item.uri);
                if (context.mounted) {
                  final readSettProv = context.read<SettingsProvider>();
                  readSettProv.loadItems(context, readSettProv.currentPath);

                  customSnackBar(
                          '${item is Directory ? '文件夹' : '文件'}已归档',
                          type: 'success')
                      .show(context);
                }
              } catch (e) {
                if (context.mounted) {
                  customSnackBar('归档失败：$e', type: 'error')
                      .show(context);
                }
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> handleUnarchiveItem(FileSystemEntity item,
      {VoidCallback? onComplete}) async {
    try {
      await StorageSystem.unarchiveItem(item.path);
      if (context.mounted) {
        customSnackBar('已取消归档', type: 'success')
            .show(context);
      }
      onComplete?.call();
    } catch (e) {
      if (context.mounted) {
        customSnackBar('取消归档失败：$e', type: 'error')
            .show(context);
      }
    }
  }
}
