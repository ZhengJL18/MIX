import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/navigation_provider.dart';
import 'package:mix/printnotes/providers/settings_provider.dart';

import 'package:mix/printnotes/ui/screens/trash_archive_screens.dart';

import 'package:mix/printnotes/constants/constants.dart';

class DrawerView extends StatelessWidget {
  const DrawerView({super.key, required this.reload});

  final VoidCallback reload;

  void _navigateToScreen(BuildContext context, {Widget? screen, String? path}) {
    Navigator.pop(context);

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
    return Column(
      children: [
        Expanded(
          child: ListTileTheme(
            iconColor: Theme.of(context).colorScheme.secondary,
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                // DrawerHeader without bottom border
                Container(
                  height: MediaQuery.paddingOf(context).top + 160.0,
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow),
                  child: AnimatedContainer(
                    alignment: Alignment.centerLeft,
                    margin: const EdgeInsets.only(bottom: 8.0),
                    padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0)
                        .add(EdgeInsets.only(
                            top: MediaQuery.paddingOf(context).top)),
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.fastOutSlowIn,
                    child: Image.asset(
                      'assets/brand/mix_mark.png',
                      width: 48,
                      height: 48,
                    ),
                  ),
                ),
                ListTile(
                    leading: const Icon(Icons.article_outlined),
                    title: const Text('全部笔记'),
                    onTap: () {
                      _navigateToScreen(context,
                          path: context.read<SettingsProvider>().mainDir);
                      reload();
                    }),
                ListTile(
                    leading: const Icon(Icons.history),
                    title: Text('最近打开'),
                    onTap: () {
                      _navigateToScreen(context, path: '⏱');
                      reload();
                    }),
                ExpansionTile(
                  leading: Icon(Icons.tag),
                  title: Text('标签'),
                  collapsedIconColor: Theme.of(context).colorScheme.secondary,
                  children: context.watch<SettingsProvider>().tagList.isNotEmpty
                      ? context
                          .watch<SettingsProvider>()
                          .tagList
                          .map(
                            (tag) => ListTile(
                                title: Text(tag),
                                onTap: () {
                                  _navigateToScreen(context, path: '※$tag');
                                  reload();
                                }),
                          )
                          .toList()
                      : [
                          ListTile(
                            title: Text('还没有标签'),
                          ),
                        ],
                  onExpansionChanged: (expanded) {
                    if (expanded) context.read<SettingsProvider>().getTagList();
                  },
                ),
                const Opacity(opacity: 0.2, child: Divider()),
                ListTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: const Text('归档'),
                  onTap: () => _navigateToScreen(context,
                      path: context.read<SettingsProvider>().archivePath,
                      screen: const TrashArchiveScreen(
                        screenName: 'Archive',
                      )),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outlined),
                  title: const Text('回收站'),
                  onTap: () => _navigateToScreen(context,
                      path: context.read<SettingsProvider>().trashPath,
                      screen: const TrashArchiveScreen(
                        screenName: 'Trash',
                      )),
                ),
                const Opacity(opacity: 0.2, child: Divider()),
                ListTile(
                    leading: const Icon(Icons.menu_book),
                    title: const Text('返回聊天'),
                    onTap: () {
                      // 抽屉开启态：第一次 pop 关抽屉（local history），
                      // 第二次 pop 离开笔记页回聊天页。
                      final nav = Navigator.of(context);
                      nav.pop();
                      nav.pop();
                    }),
              ],
            ),
          ),
        ),
        ListTile(
          title: Opacity(
            opacity: 0.5,
            child: Text(
              'Version: $appVersion',
              textAlign: TextAlign.center,
            ),
          ),
        )
      ],
    );
  }
}
