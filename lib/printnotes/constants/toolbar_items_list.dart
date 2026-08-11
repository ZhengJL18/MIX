import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:mix/printnotes/utils/config_file/toolbar_config_handler.dart';

List<ToolbarConfigItem> defaultToolbarList = [
  ToolbarConfigItem(key: 'toolbar_view_item', visible: true),
  ToolbarConfigItem(key: 'toolbar_undo_redo_actions', visible: true),
  ToolbarConfigItem(key: 'toolbar_selection_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_bold_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_italic_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_highlight_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_strikethrough_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_heading_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_indent_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_unindent_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_unordered_list_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_checkbox_list_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_underline_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_insert_table', visible: true),
  ToolbarConfigItem(key: 'toolbar_link_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_image_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_blockquote_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_code_action', visible: true),
  ToolbarConfigItem(key: 'toolbar_line_action', visible: true),
];

final Map<String, Map<String, dynamic>> toolbarReference = {
  'toolbar_view_item': {
    'icon': FaIcon(FontAwesomeIcons.eye),
    'text': '预览',
  },
  'toolbar_undo_redo_actions': {
    'icon': FaIcon(FontAwesomeIcons.arrowRotateLeft),
    'text': '撤销/重做',
  },
  'toolbar_selection_action': {
    'icon': FaIcon(FontAwesomeIcons.textWidth),
    'text': '选择当前行',
  },
  'toolbar_bold_action': {
    'icon': FaIcon(FontAwesomeIcons.bold),
    'text': '加粗文字',
  },
  'toolbar_italic_action': {
    'icon': FaIcon(FontAwesomeIcons.italic),
    'text': '斜体文字',
  },
  'toolbar_highlight_action': {
    'icon': FaIcon(FontAwesomeIcons.highlighter),
    'text': '高亮文字',
  },
  'toolbar_strikethrough_action': {
    'icon': FaIcon(FontAwesomeIcons.strikethrough),
    'text': '删除线',
  },
  'toolbar_heading_action': {
    'icon': FaIcon(FontAwesomeIcons.heading),
    'text': '插入标题',
  },
  'toolbar_indent_action': {
    'icon': Icon(Icons.format_indent_increase),
    'text': '增加缩进',
  },
  'toolbar_unindent_action': {
    'icon': Icon(Icons.format_indent_decrease),
    'text': '减少缩进',
  },
  'toolbar_unordered_list_action': {
    'icon': FaIcon(FontAwesomeIcons.listUl),
    'text': '无序列表',
  },
  'toolbar_checkbox_list_action': {
    'icon': FaIcon(FontAwesomeIcons.listCheck),
    'text': '复选框',
  },
  'toolbar_underline_action': {
    'icon': FaIcon(FontAwesomeIcons.underline),
    'text': '下划线',
  },
  'toolbar_insert_table': {
    'icon': FaIcon(FontAwesomeIcons.table),
    'text': '插入表格',
  },
  'toolbar_link_action': {
    'icon': FaIcon(FontAwesomeIcons.link),
    'text': '插入链接',
  },
  'toolbar_image_action': {
    'icon': FaIcon(FontAwesomeIcons.image),
    'text': '插入图片',
  },
  'toolbar_blockquote_action': {
    'icon': FaIcon(FontAwesomeIcons.quoteLeft),
    'text': '引用块',
  },
  'toolbar_code_action': {
    'icon': FaIcon(FontAwesomeIcons.code),
    'text': '代码语法/字体',
  },
  'toolbar_line_action': {
    'icon': FaIcon(FontAwesomeIcons.rulerHorizontal),
    'text': '插入分隔线',
  },
};
