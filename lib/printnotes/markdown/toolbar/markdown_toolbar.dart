// Toolbar taken and expanded upon from [simple_markdown_editor](https://github.com/zahniar88/simple_markdown_editor)
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:mix/printnotes/utils/config_file/toolbar_config_handler.dart';

import 'toolbar.dart';
import 'modal_input_url.dart';
import 'modal_insert_table.dart';
import 'toolbar_item.dart';

class MarkdownToolbar extends StatelessWidget {
  MarkdownToolbar({
    super.key,
    required this.onPreviewChanged,
    required this.controller,
    required this.undoController,
    this.onValueChange,
    this.toolbarBackground,
    this.expandableBackground,
    this.userToolbarItemList,
    this.absorbOnTap = false,
  }) : toolbar = Toolbar(controller: controller, onValueChange: onValueChange);

  final VoidCallback onPreviewChanged;
  final TextEditingController controller;
  final UndoHistoryController undoController;
  final Toolbar toolbar;
  final ValueChanged<bool>? onValueChange;
  final Color? toolbarBackground;
  final Color? expandableBackground;
  final List<ToolbarConfigItem>? userToolbarItemList;
  final bool absorbOnTap;

  @override
  Widget build(BuildContext context) {
    final Map<String, Widget> allToolbarItems = <String, Widget>{
      // preview
      'toolbar_view_item': ToolbarItem(
        key: const ValueKey<String>("toolbar_view_item"),
        icon: FaIcon(FontAwesomeIcons.eye),
        tooltip: '显示/隐藏 Markdown 预览',
        onPressedButton: () {
          onPreviewChanged.call();
        },
      ),
      'toolbar_undo_redo_actions': ValueListenableBuilder(
        key: const ValueKey<String>("toolbar_undo_redo_actions"),
        valueListenable: undoController,
        builder: (context, value, child) {
          return Row(
            children: [
              // undo
              ToolbarItem(
                key: const ValueKey<String>("toolbar_undo_action"),
                icon: FaIcon(FontAwesomeIcons.arrowRotateLeft),
                tooltip: '撤销上一步',
                onPressedButton:
                    value.canUndo ? () => undoController.undo() : null,
              ),
              // redo
              ToolbarItem(
                key: const ValueKey<String>("toolbar_redo_action"),
                icon: FaIcon(FontAwesomeIcons.arrowRotateRight),
                tooltip: '重做上一步',
                onPressedButton:
                    value.canRedo ? () => undoController.redo() : null,
              ),
            ],
          );
        },
      ),
      // select single line
      'toolbar_selection_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_selection_action"),
        icon: FaIcon(FontAwesomeIcons.textWidth),
        tooltip: '选择单行',
        onPressedButton: () {
          toolbar.selectSingleLine();
        },
      ),
      // bold
      'toolbar_bold_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_bold_action"),
        icon: FaIcon(FontAwesomeIcons.bold),
        tooltip: '加粗文字',
        onPressedButton: () {
          toolbar.action("**", "**");
        },
      ),
      // italic
      'toolbar_italic_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_italic_action"),
        icon: FaIcon(FontAwesomeIcons.italic),
        tooltip: '斜体文字',
        onPressedButton: () {
          toolbar.action("_", "_");
        },
      ),
      // highlighter
      'toolbar_highlight_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_highlight_action"),
        icon: FaIcon(FontAwesomeIcons.highlighter),
        tooltip: '高亮文字',
        onPressedButton: () {
          toolbar.action("==", "==");
        },
      ),
      // strikethrough
      'toolbar_strikethrough_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_strikethrough_action"),
        icon: FaIcon(FontAwesomeIcons.strikethrough),
        tooltip: '删除线',
        onPressedButton: () {
          toolbar.action("~~", "~~");
        },
      ),
      // heading
      'toolbar_heading_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_heading_action"),
        icon: FaIcon(FontAwesomeIcons.heading),
        isExpandable: true,
        tooltip: '插入标题',
        expandableBackground: expandableBackground,
        items: [
          ToolbarItem(
            key: const ValueKey<String>("h1"),
            icon: "H1",
            tooltip: '插入标题 1',
            onPressedButton: () => toolbar.action("# ", ""),
          ),
          ToolbarItem(
            key: const ValueKey<String>("h2"),
            icon: "H2",
            tooltip: '插入标题 2',
            onPressedButton: () => toolbar.action("## ", ""),
          ),
          ToolbarItem(
            key: const ValueKey<String>("h3"),
            icon: "H3",
            tooltip: '插入标题 3',
            onPressedButton: () => toolbar.action("### ", ""),
          ),
        ],
      ),
      // indent
      'toolbar_indent_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_indent_action"),
        icon: Icons.format_indent_increase,
        tooltip: '增加缩进',
        onPressedButton: () {
          toolbar.action("  ", "");
        },
      ),
      // unindent
      'toolbar_unindent_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_unindent_action"),
        icon: Icons.format_indent_decrease,
        tooltip: '减少缩进',
        onPressedButton: () {
          toolbar.action("", "  ");
        },
      ),
      // unordered list
      'toolbar_unordered_list_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_unordered_list_action"),
        icon: FaIcon(FontAwesomeIcons.listUl),
        tooltip: '无序列表',
        onPressedButton: () {
          toolbar.action("- ", "");
        },
      ),
      // checkbox list
      'toolbar_checkbox_list_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_checkbox_list_action"),
        icon: FaIcon(FontAwesomeIcons.listCheck),
        isExpandable: true,
        expandableBackground: expandableBackground,
        items: [
          ToolbarItem(
            key: const ValueKey<String>("checkbox"),
            icon: FaIcon(FontAwesomeIcons.solidSquareCheck),
            tooltip: '勾选复选框',
            onPressedButton: () {
              toolbar.action("- [x] ", "");
            },
          ),
          ToolbarItem(
            key: const ValueKey<String>("uncheckbox"),
            icon: FaIcon(FontAwesomeIcons.square),
            tooltip: '取消勾选',
            onPressedButton: () {
              toolbar.action("- [ ] ", "");
            },
          )
        ],
      ),
      // underline
      'toolbar_underline_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_underline_action"),
        icon: FaIcon(FontAwesomeIcons.underline),
        tooltip: '下划线',
        onPressedButton: () {
          toolbar.action("__", "__");
        },
      ),

      'toolbar_insert_table': ToolbarItem(
        key: const ValueKey<String>('toolbar_insert_table'),
        icon: FaIcon(FontAwesomeIcons.table),
        tooltip: '插入表格',
        onPressedButton: () async {
          if (toolbar.hasSelection) {
            toolbar.action("| ", " |");
          } else {
            await _showModalInsertTable(context, controller.selection);
          }
        },
      ),
      // link
      'toolbar_link_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_link_action"),
        icon: FaIcon(FontAwesomeIcons.link),
        tooltip: '添加链接',
        onPressedButton: () async {
          if (toolbar.hasSelection) {
            toolbar.action("[enter link description here](", ")");
          } else {
            await _showModalInputUrl(context, "[enter link description here](",
                controller.selection);
          }
        },
      ),
      // image
      'toolbar_image_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_image_action"),
        icon: FaIcon(FontAwesomeIcons.image),
        tooltip: '添加图片',
        onPressedButton: () async {
          if (toolbar.hasSelection) {
            toolbar.action("![enter image description here](", ")");
          } else {
            await _showModalInputUrl(
              context,
              "![enter image description here](",
              controller.selection,
            );
          }
        },
      ),
      // blockquote
      'toolbar_blockquote_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_blockquote_action"),
        icon: FaIcon(FontAwesomeIcons.quoteLeft),
        tooltip: '引用块',
        onPressedButton: () {
          toolbar.action("> ", "");
        },
      ),
      // code
      'toolbar_code_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_code_action"),
        icon: FaIcon(FontAwesomeIcons.code),
        tooltip: '代码语法/字体',
        onPressedButton: () {
          toolbar.action("`", "`");
        },
      ),
      // line
      'toolbar_line_action': ToolbarItem(
        key: const ValueKey<String>("toolbar_line_action"),
        icon: FaIcon(FontAwesomeIcons.rulerHorizontal),
        tooltip: '插入行',
        onPressedButton: () {
          toolbar.action("___", "");
        },
      ),
    };
    List<Widget> returnedToolList = [];
    if (userToolbarItemList != null && userToolbarItemList != []) {
      for (ToolbarConfigItem item in userToolbarItemList!) {
        if (item.visible) returnedToolList.add(allToolbarItems[item.key]!);
      }
    } else {
      returnedToolList =
          allToolbarItems.entries.map((entry) => entry.value).toList();
    }
    return Container(
      color: toolbarBackground ?? Colors.grey[200],
      width: double.infinity,
      height: 45,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: AbsorbPointer(
          absorbing: absorbOnTap,
          child: Row(
            children: returnedToolList,
          ),
        ),
      ),
    );
  }

  // show modal for url input
  Future<dynamic> _showModalInputUrl(
    BuildContext context,
    String leftText,
    TextSelection selection,
  ) {
    return showModalBottomSheet(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(30),
        ),
      ),
      isScrollControlled: true,
      context: context,
      builder: (context) {
        return ModalInputUrl(
          toolbar: toolbar,
          leftText: leftText,
          selection: selection,
        );
      },
    );
  }

  // show modal to build a table
  Future<dynamic> _showModalInsertTable(
    BuildContext context,
    TextSelection selection,
  ) {
    return showModalBottomSheet(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(30),
        ),
      ),
      isScrollControlled: true,
      context: context,
      builder: (context) {
        return ModalInsertTable(
          toolbar: toolbar,
          selection: selection,
        );
      },
    );
  }
}
