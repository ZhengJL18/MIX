import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';
import 'package:mix/printnotes/utils/storage_system.dart';
import 'package:mix/printnotes/ui/widgets/custom_snackbar.dart';

class ItemRenameHandler {
  static Future<void> showRenameDialog(
      BuildContext context, FileSystemEntity item) async {
    final TextEditingController controller = TextEditingController(
      text: item.path.split('/').last,
    );
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('重命名${item is Directory ? '文件夹' : '文件'}'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '输入新名称'),
        ),
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
              '重命名',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
            onPressed: () {
              Navigator.of(context).pop();
              handleItemRename(context, item, controller.text);
            },
          ),
        ],
      ),
    );
  }

  static Future<void> handleItemRename(
      BuildContext context, FileSystemEntity item, String newName,
      {bool? showMessage = true}) async {
    try {
      await StorageSystem.renameItem(item.uri, newName);
      if (context.mounted) {
        final readSettProv = context.read<SettingsProvider>();
        readSettProv.loadItems(context, readSettProv.currentPath);

        if (showMessage == true) {
          customSnackBar(
                  '"${path.basename(item.path)}"${item is Directory ? "文件夹" : ""}已重命名',
                  type: 'success')
              .show(context);
        }
      }
    } catch (e) {
      if (context.mounted) {
        customSnackBar(
                '重命名"${path.basename(item.path)}"${item is Directory ? "文件夹" : ""}失败：$e',
                type: 'error')
            .show(context);
      }
    }
  }
}
