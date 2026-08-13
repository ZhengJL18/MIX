import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';
import 'package:mix/printnotes/providers/selecting_provider.dart';

import 'package:mix/printnotes/utils/configs/data_path.dart';

import 'package:mix/printnotes/ui/components/app_bar_drag_wrapper.dart';
import 'package:mix/printnotes/ui/components/centered_page_wrapper.dart';
import 'package:mix/printnotes/ui/components/dialogs/basic_popup.dart';

import 'package:mix/printnotes/ui/widgets/menu_tile.dart';
import 'package:mix/printnotes/ui/widgets/list_section_title.dart';
import 'package:mix/printnotes/ui/widgets/custom_snackbar.dart';

import 'package:mix/printnotes/ui/screens/settings/more_design_options_page.dart';
import 'package:mix/printnotes/ui/screens/settings/codeblock_theme_page.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget? getSortOrderSubtitle() {
      String sortOrder = context.watch<SettingsProvider>().sortOrder;
      String? text;
      switch (sortOrder) {
        case 'default':
          text = 'Varies on system';
          break;
        case 'titleAsc':
          text = 'Sorted a,b,c...';
          break;
        case 'titleDsc':
          text = 'Sorted z,y,x...';
          break;
        case 'lastModAsc':
          text = 'Newer towards bottom';
          break;
        case 'lastModDsc':
          text = 'Newer towards top';
          break;
        default:
          text = null;
      }
      return text != null ? MenuTile.subtitleText(context, text: text) : null;
    }

    return Scaffold(
      appBar: AppBarDragWrapper(
        child: AppBar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          leading: IconButton(
            icon: const Icon(
              Icons.arrow_back,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          centerTitle: true,
          title: const Text('笔记设置'),
        ),
      ),
      body: SingleChildScrollView(
        child: CenteredPageWrapper(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            children: [
              sectionTitle(
                '排序',
                Theme.of(context).colorScheme.secondary,
                padding: 10,
              ),
              MenuTile(
                leading: const Icon(Icons.sort),
                title: '排序方式',
                subtitle: getSortOrderSubtitle(),
                trailing: DropdownButton(
                    value: context.watch<SettingsProvider>().sortOrder,
                    items: const [
                      DropdownMenuItem(
                          value: 'default', child: Text('默认排序')),
                      DropdownMenuItem(
                          value: 'titleAsc', child: Text('标题（升序）')),
                      DropdownMenuItem(
                          value: 'titleDsc', child: Text('标题（降序）')),
                      DropdownMenuItem(
                          value: 'lastModAsc', child: Text('最近修改（升序）')),
                      DropdownMenuItem(
                          value: 'lastModDsc', child: Text('最近修改（降序）')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        context.read<SettingsProvider>().setSortOrder(value);
                      }
                    }),
                isFirst: true,
              ),
              MenuTile(
                leading: const Icon(Icons.folder_copy_outlined),
                title: '文件夹置顶',
                subtitle: MenuTile.subtitleText(context,
                    text: '文件夹显示在文件上方或下方'),
                trailing: DropdownButton(
                    value: context.watch<SettingsProvider>().folderPriority,
                    items: const [
                      DropdownMenuItem(value: 'above', child: Text('上方')),
                      DropdownMenuItem(value: 'none', child: Text('无')),
                      DropdownMenuItem(value: 'below', child: Text('下方')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        context
                            .read<SettingsProvider>()
                            .setFolderPriority(value);
                      }
                    }),
                isLast: true,
              ),
              sectionTitle(
                '外观',
                Theme.of(context).colorScheme.secondary,
                padding: 10,
              ),
              MenuTile(
                leading: const Icon(Icons.view_module),
                title: '布局模式',
                trailing: DropdownButton(
                    value: context.watch<SettingsProvider>().layout,
                    items: const [
                      DropdownMenuItem(value: 'grid', child: Text('网格视图')),
                      DropdownMenuItem(value: 'list', child: Text('列表视图')),
                      DropdownMenuItem(value: 'tree', child: Text('树形视图')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        context.read<SettingsProvider>().setLayout(value);
                        context
                            .read<SelectingProvider>()
                            .setSelectingMode(mode: false);
                      }
                    }),
                isFirst: true,
              ),
              MenuTile(
                leading: const Icon(Icons.dashboard_customize),
                title: '更多设计选项',
                trailing: const Icon(Icons.arrow_forward_ios_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (context) => const MoreDesignOptionsPage(),
                )),
                isLast: true,
              ),
              sectionTitle(
                '高级',
                Theme.of(context).colorScheme.secondary,
                padding: 10,
              ),
              if (Platform.isAndroid)
                MenuTile(
                    leading: const Icon(Icons.gesture),
                    title: '常显底部导航',
                    subtitle: MenuTile.subtitleText(context,
                        text:
                            'Only applies to bottom button navigation mode.\nReload app to see changes'),
                    trailing: Switch(
                        value: context
                            .watch<SettingsProvider>()
                            .bottomBarPersistence,
                        onChanged: (value) {
                          context
                              .read<SettingsProvider>()
                              .setBottomBarPersistence(value);
                        }),
                    isFirst: true),
              MenuTile(
                leading: const Icon(Icons.code),
                title: '代码块主题',
                subtitle: MenuTile.subtitleText(context,
                    text: 'Change theme for codeblocks'),
                trailing: const Icon(Icons.arrow_forward_ios_rounded),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const CodeblockThemePage())),
                isFirst: true,
              ),
              MenuTile(
                leading: const Icon(Icons.functions),
                title: 'LaTeX 支持',
                subtitle: MenuTile.subtitleText(context,
                    text: 'Markup for mathematical symbols'),
                trailing: Switch(
                    value: context.watch<SettingsProvider>().useLatex,
                    onChanged: (value) {
                      context.read<SettingsProvider>().setLatexUse(value);
                    }),
              ),
              MenuTile(
                leading: const Icon(Icons.label_important),
                title: 'Frontmatter 支持',
                subtitle: MenuTile.subtitleText(context,
                    text: 'Used to read certain syntax as metadata'),
                trailing: Switch(
                    value: context.watch<SettingsProvider>().useFrontmatter,
                    onChanged: (value) {
                      context.read<SettingsProvider>().setFrontMatterUse(value);
                    }),
              ),
              const SizedBox(height: 12),
              MenuTile(
                leading: const Icon(Icons.data_array),
                title: '重置笔记配置',
                subtitle: MenuTile.subtitleText(context,
                    text: 'Resets certain configurations'),
                trailing: IconButton(
                    onPressed: () async {
                      final bool response = await showBasicPopup(
                          context,
                          'Delete Config File?',
                          'Are you sure you want to delete?\nThis will get rid of all custom themes and markdown toolbar modifications and restore defaults!');
                      if (response) {
                        DataPath.deleteJsonConfigFile(DataPath.mainConfigFile);
                        if (context.mounted) {
                          customSnackBar('Generated new config file',
                                  type: 'success')
                              .show(context);
                        }
                      }
                    },
                    icon: Icon(Icons.delete,
                        color: Theme.of(context).colorScheme.error)),
                isFirst: true,
                isLast: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
