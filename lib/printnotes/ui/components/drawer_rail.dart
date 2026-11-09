import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/navigation_provider.dart';
import 'package:mix/printnotes/providers/settings_provider.dart';

import 'package:mix/printnotes/ui/screens/trash_archive_screens.dart';

class DrawerRailView extends StatelessWidget {
  const DrawerRailView({super.key, required this.reload});

  final VoidCallback reload;

  void _navigateToScreen(BuildContext context, {Widget? screen, String? path}) {
    if (path != null) {
      context.read<NavigationProvider>().addToRouteHistory(path);
    }
    if (screen != null) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (context) => screen,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButtonTheme(
      data: IconButtonThemeData(
          style: ButtonStyle(
              iconColor: WidgetStatePropertyAll(
                  Theme.of(context).colorScheme.onSurfaceVariant))),
      child: Container(
        alignment: Alignment.center,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: ListView(
          children: [
            IconButton(
              icon: const Icon(Icons.article_outlined),
              tooltip: '全部笔记',
              onPressed: () {
                _navigateToScreen(context,
                    path: context.read<SettingsProvider>().mainDir);
                reload();
              },
            ),
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: '最近打开',
              onPressed: () {
                _navigateToScreen(context, path: '⏱');
                reload();
              },
            ),
            const Opacity(opacity: 0.2, child: Divider()),
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: '归档',
              onPressed: () => _navigateToScreen(context,
                  path: context.read<SettingsProvider>().archivePath,
                  screen: const TrashArchiveScreen(
                    screenName: 'Archive',
                  )),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outlined),
              tooltip: '回收站',
              onPressed: () => _navigateToScreen(context,
                  path: context.read<SettingsProvider>().trashPath,
                  screen: const TrashArchiveScreen(
                    screenName: 'Trash',
                  )),
            ),
            const Opacity(opacity: 0.2, child: Divider()),
            IconButton(
              icon: const Icon(Icons.menu_book),
              tooltip: '返回聊天',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
