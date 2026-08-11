import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';

import 'package:mix/printnotes/utils/storage_system.dart';
import 'package:mix/printnotes/ui/widgets/custom_snackbar.dart';

class ItemDeletionHandler {
  final BuildContext context;

  ItemDeletionHandler(this.context);

  Future<void> showTrashConfirmation(FileSystemEntity item,
      {VoidCallback? onComplete}) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移到回收站？'),
        content: Text(
            '确定要把"${path.basename(item.path)}"${item is Directory ? "文件夹" : ""}移到回收站吗？'),
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
              '移到回收站',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
            onPressed: () {
              Navigator.of(context).pop();
              handleItemTrashing(item, onComplete: onComplete);
            },
          ),
        ],
      ),
    );
  }

  Future<void> handleItemTrashing(FileSystemEntity item,
      {VoidCallback? onComplete}) async {
    try {
      await StorageSystem.trashItem(item.path);

      if (context.mounted) {
        final readSettProv = context.read<SettingsProvider>();
        readSettProv.loadItems(context, readSettProv.currentPath);

        onComplete?.call();

        customSnackBar(
                '"${path.basename(item.path)}"${item is Directory ? "文件夹" : ""}已移到回收站',
                type: 'info')
            .show(context);
      }
    } catch (e) {
      if (context.mounted) {
        customSnackBar('删除"${path.basename(item.path)}"失败：$e',
                type: 'error')
            .show(context);
      }
    }
  }

  Future<void> showPermanentDeleteConfirmation(FileSystemEntity item,
      {VoidCallback? onComplete}) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text(
            '确定要彻底删除"${path.basename(item.path)}"${item is Directory ? "文件夹" : ""}吗？'),
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
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
            onPressed: () {
              Navigator.of(context).pop();
              handlePermanentItemDelete(item, onComplete: onComplete);
            },
          ),
        ],
      ),
    );
  }

  Future<void> handlePermanentItemDelete(FileSystemEntity item,
      {VoidCallback? onComplete}) async {
    try {
      await StorageSystem.permanentlyDeleteItem(item.path);

      if (context.mounted) {
        final readSettProv = context.read<SettingsProvider>();
        readSettProv.loadItems(context, readSettProv.currentPath);

        onComplete?.call();

        customSnackBar(
                '"${path.basename(item.path)}"${item is Directory ? "文件夹" : ""}已删除',
                type: 'info')
            .show(context);
      }
    } catch (e) {
      if (context.mounted) {
        customSnackBar(
                '彻底删除"${path.basename(item.path)}"${item is Directory ? "文件夹" : ""}失败：$e',
                type: 'error')
            .show(context);
      }
    }
  }

  Future<void> handleRestoringDeletedItem(FileSystemEntity item,
      {VoidCallback? onComplete}) async {
    try {
      await StorageSystem.restoreDeletedItem(item.path);
      if (context.mounted) {
        customSnackBar(
                '"${path.basename(item.path)}"${item is Directory ? "文件夹" : ""}已成功恢复',
                type: 'success')
            .show(context);

        onComplete?.call();

        final readSettProv = context.read<SettingsProvider>();
        readSettProv.loadItems(context, readSettProv.currentPath);
      }
    } catch (e) {
      if (context.mounted) {
        customSnackBar(
                '恢复"${path.basename(item.path)}"${item is Directory ? "文件夹" : ""}失败：$e',
                type: 'error')
            .show(context);
      }
    }
  }

  Future<void> showTrashManyConfirmation(List<FileSystemEntity> items,
      {VoidCallback? onComplete}) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('全部移到回收站？'),
        content: const Text(
            '确定要把选中的文件移到回收站吗？'),
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
              '全部移到回收站',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
            onPressed: () {
              Navigator.of(context).pop();
              handleManyItemTrashing(items, onComplete: onComplete);
            },
          ),
        ],
      ),
    );
  }

  Future<void> handleManyItemTrashing(List<FileSystemEntity> items,
      {VoidCallback? onComplete}) async {
    try {
      for (FileSystemEntity item in items) {
        await StorageSystem.trashItem(item.path);
      }

      if (context.mounted) {
        final readSettProv = context.read<SettingsProvider>();
        readSettProv.loadItems(context, readSettProv.currentPath);

        onComplete?.call();

        customSnackBar('所有项目已移到回收站', type: 'info')
            .show(context);
      }
    } catch (e) {
      if (context.mounted) {
        customSnackBar('删除选中项目失败：$e', type: 'error')
            .show(context);
      }
    }
  }
}
