import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';

import 'package:mix/printnotes/providers/navigation_provider.dart';
import 'package:mix/printnotes/utils/handlers/item_create.dart';
import 'package:mix/printnotes/ui/components/dialogs/textbook_import_dialog.dart';

/// [onImported]：导入教材完成后回调（用于刷新列表）。
Widget speedDialFAB(BuildContext context, String currentFolder,
    {VoidCallback? onImported}) {
  return SpeedDial(
    icon: Icons.add,
    activeIcon: Icons.close,
    childPadding: const EdgeInsets.all(5),
    spaceBetweenChildren: 10,
    backgroundColor: Theme.of(context).colorScheme.secondary,
    foregroundColor: Theme.of(context).colorScheme.onSecondary,
    children: [
      SpeedDialChild(
        child: const Icon(Icons.create_new_folder_outlined),
        label: 'Create Folder',
        onTap: () async => await ItemCreationHandler(context)
            .handleCreateNewFolder(currentFolder),
      ),
      SpeedDialChild(
        child: const Icon(Icons.note_add_outlined),
        label: 'Create Note',
        onTap: () async => await ItemCreationHandler(context)
            .handleCreateNewNote(currentFolder),
      ),
      SpeedDialChild(
        child: const Icon(Icons.draw),
        label: 'Create Sketch',
        onTap: () async => await ItemCreationHandler(context)
            .handleCreateNewSketch(currentFolder),
      ),
      SpeedDialChild(
        child: const Icon(Icons.folder_copy),
        label: 'Open External File',
        onTap: () async =>
            await context.read<NavigationProvider>().openExternalFile(context),
      ),
      SpeedDialChild(
        child: const Icon(Icons.library_books_outlined),
        label: '导入教材',
        onTap: () async {
          await showTextbookImportDialog(context);
          onImported?.call();
        },
      ),
    ],
  );
}
