import 'package:flutter/material.dart';
import 'package:mix/printnotes/constants/toolbar_items_list.dart';
import 'package:mix/printnotes/utils/config_file/toolbar_config_handler.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/editor_config_provider.dart';

import 'package:mix/printnotes/ui/components/app_bar_drag_wrapper.dart';
import 'package:mix/printnotes/ui/components/centered_page_wrapper.dart';
import 'package:mix/printnotes/ui/widgets/list_section_title.dart';
import 'package:mix/printnotes/markdown/toolbar/markdown_toolbar.dart';

class EditorConfigPage extends StatelessWidget {
  const EditorConfigPage({super.key});

  @override
  Widget build(BuildContext context) {
    final watchProvider = context.watch<EditorConfigProvider>();

    double userFontSize = watchProvider.fontSize;
    bool isEditingToolbar = watchProvider.isEditing;
    bool autoEditMode = watchProvider.defaultEditorMode;

    return Scaffold(
      appBar: AppBarDragWrapper(
        child: AppBar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          centerTitle: true,
          title: const Text('编辑器设置'),
        ),
      ),
      body: CenteredPageWrapper(
        child: ListView(
          primary: true,
          children: [
            sectionTitle(
              '配置',
              Theme.of(context).colorScheme.secondary,
              padding: 10,
            ),
            ListTile(
              iconColor: Theme.of(context).colorScheme.secondary,
              leading: Icon(Icons.font_download, size: userFontSize),
              title: Text(
                '字号',
                style: TextStyle(fontSize: userFontSize),
              ),
              subtitle: const Text('更改笔记中所有文字的字号'),
              trailing: DropdownButton(
                  value: userFontSize,
                  items: const [
                    DropdownMenuItem(value: 12, child: Text('12px')),
                    DropdownMenuItem(value: 16, child: Text('16px（默认）')),
                    DropdownMenuItem(value: 20, child: Text('20px')),
                    DropdownMenuItem(value: 24, child: Text('24px')),
                    DropdownMenuItem(value: 28, child: Text('28px')),
                    DropdownMenuItem(value: 32, child: Text('32px')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      context
                          .read<EditorConfigProvider>()
                          .setFontSize(value.toDouble());
                    }
                  }),
            ),
            ListTile(
              iconColor: Theme.of(context).colorScheme.secondary,
              leading: const Icon(Icons.edit),
              title: const Text('默认进入编辑模式'),
              subtitle:
                  const Text('以编辑模式打开笔记而非预览'),
              trailing: Switch(
                  value: autoEditMode,
                  onChanged:
                      context.read<EditorConfigProvider>().setAutoEditMode),
            ),
            const Divider(),
            sectionTitle(
              '工具栏',
              Theme.of(context).colorScheme.secondary,
              padding: 10,
            ),
            ListTile(
              title: const Text('编辑工具栏？'),
              trailing: Switch(
                  value: isEditingToolbar,
                  onChanged: context.read<EditorConfigProvider>().setIsEditing),
            ),
            const Divider(),
            MarkdownToolbar(
              controller: TextEditingController(),
              onPreviewChanged: () {},
              undoController: UndoHistoryController(),
              toolbarBackground: Theme.of(context).colorScheme.surfaceContainer,
              expandableBackground: Theme.of(context).colorScheme.surface,
              userToolbarItemList:
                  context.watch<EditorConfigProvider>().toolbarItemList,
              absorbOnTap: true,
            ),
            if (isEditingToolbar)
              const Padding(
                padding: EdgeInsets.all(10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text('包含'), Text('排序')],
                ),
              ),
            AbsorbPointer(
              absorbing: !isEditingToolbar,
              child: ReorderableListView.builder(
                primary: false,
                shrinkWrap: true,
                physics: const ClampingScrollPhysics(),
                itemCount: context
                    .watch<EditorConfigProvider>()
                    .toolbarItemList
                    .length,
                itemBuilder: (context, index) {
                  List<ToolbarConfigItem> toolbarList =
                      context.watch<EditorConfigProvider>().toolbarItemList;
                  return ListTile(
                    key: ValueKey<String>(toolbarList[index].key),
                    leading: isEditingToolbar
                        ? Checkbox(
                            value: toolbarList[index].visible,
                            onChanged: (value) {
                              if (value != null) {
                                context
                                    .read<EditorConfigProvider>()
                                    .setToolbarItemVisibility(value, index);
                              }
                            },
                          )
                        : null,
                    title: Row(
                      children: [
                        toolbarReference[toolbarList[index].key]!['icon'],
                        const SizedBox(width: 15),
                        Text(toolbarReference[toolbarList[index].key]!['text']),
                      ],
                    ),
                    trailing:
                        isEditingToolbar ? const Icon(Icons.drag_handle) : null,
                  );
                },
                onReorder: context.read<EditorConfigProvider>().updateListOrder,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
