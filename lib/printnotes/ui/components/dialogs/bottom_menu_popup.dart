import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';
import 'package:mix/printnotes/providers/selecting_provider.dart';

import 'package:mix/printnotes/utils/handlers/item_move.dart';
import 'package:mix/printnotes/utils/handlers/item_rename.dart';
import 'package:mix/printnotes/utils/handlers/item_duplication.dart';
import 'package:mix/printnotes/utils/handlers/item_archive.dart';
import 'package:mix/printnotes/utils/handlers/item_delete.dart';

void showBottomMenu(
  BuildContext context,
  FileSystemEntity item,
  Function loadItems,
) {
  showModalBottomSheet(
    context: context,
    builder: (BuildContext sheetContext) {
      bool isTreeView = sheetContext.read<SettingsProvider>().layout == 'tree';
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (item is! Directory)
              ListTile(
                textColor:
                    isTreeView ? Theme.of(sheetContext).disabledColor : null,
                iconColor: isTreeView
                    ? Theme.of(sheetContext).disabledColor
                    : Theme.of(sheetContext).colorScheme.secondary,
                leading: const Icon(Icons.check),
                title: const Text('选择'),
                onTap: isTreeView
                    ? null
                    : () {
                        Navigator.pop(sheetContext);
                        sheetContext
                            .read<SelectingProvider>()
                            .setSelectingMode(mode: true);
                        sheetContext
                            .read<SelectingProvider>()
                            .updateSelectedList(item);
                      },
              ),
            ListTile(
              leading: Icon(
                Icons.drive_file_move_outline,
                color: Theme.of(sheetContext).colorScheme.secondary,
              ),
              title: const Text('移动'),
              onTap: () {
                Navigator.pop(sheetContext);
                ItemMoveHandler.showMoveDialog(context, [item.uri]);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.edit,
                color: Theme.of(sheetContext).colorScheme.secondary,
              ),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(sheetContext);
                ItemRenameHandler.showRenameDialog(context, item);
              },
            ),
            if (item is! Directory)
              ListTile(
                leading: Icon(
                  Icons.copy,
                  color: Theme.of(sheetContext).colorScheme.secondary,
                ),
                title: const Text('复制'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  ItemDuplicationHandler(context).handleDuplicateItem(item);
                },
              ),
            ListTile(
              leading: Icon(
                Icons.archive_outlined,
                color: Theme.of(sheetContext).colorScheme.secondary,
              ),
              title: const Text('归档'),
              onTap: () {
                Navigator.pop(sheetContext);
                ItemArchiveHandler(context).handleArchiveItem(item);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_sweep,
                color: Theme.of(sheetContext).colorScheme.secondary,
              ),
              title: const Text('移到回收站'),
              onTap: () {
                Navigator.pop(sheetContext);
                ItemDeletionHandler(context).showTrashConfirmation(item);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_forever,
                color: Colors.red,
              ),
              title: const Text('彻底删除'),
              onTap: () {
                Navigator.pop(sheetContext);
                ItemDeletionHandler(context)
                    .showPermanentDeleteConfirmation(item);
              },
            ),
          ],
        ),
      );
    },
  );
}
