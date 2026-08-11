import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mix/printnotes/markdown/rendering/strikethrough.dart';
import 'package:mix/printnotes/markdown/rendering/subscript.dart';
import 'package:mix/printnotes/markdown/rendering/superscript.dart';
import 'package:provider/provider.dart';
import './markdown_widget/markdown_widget.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:mix/printnotes/providers/theme_provider.dart';
import 'package:mix/printnotes/providers/settings_provider.dart';
import 'package:mix/printnotes/providers/editor_config_provider.dart';

import 'package:flutter_highlight/theme_map.dart';
import 'package:flutter_highlight/themes/a11y-light.dart';
import 'package:flutter_highlight/themes/a11y-dark.dart';

import 'package:mix/printnotes/markdown/rendering/code_wrapper.dart';
import 'package:mix/printnotes/markdown/rendering/mermaid_widget.dart';
import 'package:mix/printnotes/markdown/rendering/custom_img_builder.dart';
import 'package:mix/printnotes/markdown/rendering/custom_node.dart';
import 'package:mix/printnotes/markdown/rendering/latex.dart';
import 'package:mix/printnotes/markdown/rendering/latex_protector.dart';
import 'package:mix/printnotes/markdown/rendering/wiki_link.dart';
import 'package:mix/printnotes/markdown/rendering/highlighter.dart';
import 'package:mix/printnotes/markdown/rendering/underline.dart';
import 'package:mix/printnotes/markdown/rendering/note_tags.dart';

import 'package:mix/printnotes/markdown/link_handler.dart';
import 'package:mix/printnotes/markdown/rendering/c_code_block.dart';
import 'package:mix/printnotes/markdown/rendering/python_code_block.dart';
import 'package:mix/printnotes/markdown/rendering/remote_code_block.dart';
import 'package:mix/printnotes/markdown/rendering/code_engine.dart';

MarkdownConfig theMarkdownConfigs(
  BuildContext context, {
  required Uri fileUri,
  bool? hideCodeButtons,
  bool inEditor = false,
  Color? textColor,
  TextEditingController? editingController,
  Future<void> Function()? onCheckboxToggle,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final config =
      isDark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig;

  final userCodeHighlight = context.watch<ThemeProvider>().codeHighlight;

  codeWrapper(child, text, language) {
    // 注册内置引擎（幂等：重复注册同名会覆盖，但无害）。
    // 新增语言 = 新建 CodeEngine 实现 + 在这里注册一行（或引擎内部自注册）。
    CodeEngineRegistry.register(const MermaidCodeEngine());
    CodeEngineRegistry.register(const PythonCodeEngine());
    CodeEngineRegistry.register(const CCodeEngine());
    // 云端执行引擎：覆盖 python/c（本地引擎退役），并解锁 js/bash/java/sql。
    CodeEngineRegistry.register(
        const RemoteCodeEngine('python', 'Python (云端)', aliases: ['py']));
    CodeEngineRegistry.register(const RemoteCodeEngine('c', 'C (云端)'));
    CodeEngineRegistry.register(
        const RemoteCodeEngine('js', 'JavaScript (云端)', aliases: ['javascript']));
    CodeEngineRegistry.register(
        const RemoteCodeEngine('bash', 'Bash (云端)', aliases: ['sh', 'shell']));
    CodeEngineRegistry.register(const RemoteCodeEngine('java', 'Java (云端)'));
    CodeEngineRegistry.register(const RemoteCodeEngine('sql', 'SQL (云端)'));
    // 命中已注册引擎（mermaid → 图，python → 原生 CPython 执行，c → libtcc 编译执行）
    // → 交给引擎。
    final engine = CodeEngineRegistry.engineFor(language);
    if (engine != null) {
      return engine.buildWidget(text);
    }
    // 其他语言 → 普通代码块（语法高亮 + 复制按钮）。
    return CodeWrapperWidget(child, text, language,
        hideCodeButtons: hideCodeButtons);
  }

  double editorFontSize = context.watch<EditorConfigProvider>().fontSize;

  return config.copy(configs: [
    PConfig(
      textStyle: TextStyle(
        fontSize: inEditor ? editorFontSize : 16,
        color: textColor,
      ),
    ),
    H1Config(
      style: TextStyle(
        fontSize: inEditor ? editorFontSize + 16 : 32,
        color: textColor,
      ),
    ),
    H2Config(
      style: TextStyle(
        fontSize: inEditor ? editorFontSize + 8 : 24,
        color: textColor,
      ),
    ),
    H3Config(
      style: TextStyle(
        fontSize: inEditor ? editorFontSize + 4 : 20,
        color: textColor,
      ),
    ),
    H4Config(
      style: TextStyle(
        fontSize: inEditor ? editorFontSize : 16,
        color: textColor,
      ),
    ),
    H5Config(
      style: TextStyle(
        fontSize: inEditor ? editorFontSize : 16,
        color: textColor,
      ),
    ),
    H6Config(
      style: TextStyle(
        fontSize: inEditor ? editorFontSize : 16,
        color: textColor,
      ),
    ),
    ListConfig(marginLeft: editorFontSize * 1.5),
    CheckBoxConfig(
      size: inEditor ? editorFontSize * 1.25 : null,
      onToggle: (event) {
        final lineIdx = event.line;
        if (editingController == null || lineIdx == null) return;
        final lines = editingController.text.split('\n');
        if (lineIdx < 0 || lineIdx >= lines.length) return;
        final line = lines[lineIdx];
        final taskRegex = RegExp(r'^(\s*[-\*\+]\s*)\[[ xX]\]\s*(.*)');
        final m = taskRegex.firstMatch(line);
        if (m != null) {
          final prefix = m.group(1) ?? '';
          final rest = m.group(2) ?? '';
          final newMark = event.checked ? '[x]' : '[ ]';
          lines[lineIdx] = '$prefix$newMark $rest';
          editingController.text = lines.join('\n');

          // call save callback if provided
          if (onCheckboxToggle != null) {
            unawaited(onCheckboxToggle());
          }
        }
      },
    ),
    TableConfig(
      wrapper: (table) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: table,
      ),
    ),
    HrConfig(
      height: 2,
      color: textColor ??
          Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2),
    ),
    BlockquoteConfig(
      textColor: textColor ??
          Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
      sideColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
    ),
    ImgConfig(
      builder: (url, attributes) => CustomImgBuilder(url, fileUri, attributes),
    ),
    LinkConfig(onTap: (url) => linkHandler(context, url)),
    WikiLinkConfig(onTap: (url) => linkHandler(context, url)),
    const PreConfig().copy(
      theme: _codeThemeNoBg(themeMap[userCodeHighlight] ??
          (isDark ? a11yDarkTheme : a11yLightTheme)),
      decoration: BoxDecoration(
          // 与聊天气泡同源：surfaceContainerHighest（主题色阶），
          // 不再是接近纯白的 surface —— 修复"涂改带"观感。
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.65),
          borderRadius: BorderRadius.all(Radius.circular(12)),
          border: Border.all(
              width: 1,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.15))),
      wrapper: codeWrapper,
      textStyle: TextStyle(
          fontSize: inEditor ? editorFontSize : null,
          color: Theme.of(context).colorScheme.onSurface),
      styleNotMatched: TextStyle(
          fontSize: inEditor ? editorFontSize : null,
          color: Theme.of(context).colorScheme.onSurface),
    ),
    // 行内代码 `xxx` 背景同样跟随主题（原写死白底 0xCCeff1f3）。
    CodeConfig(
      style: TextStyle(
          backgroundColor: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.65),
          color: Theme.of(context).colorScheme.onSurface),
    ),
  ]);
}

/// 剥掉高亮主题里的 backgroundColor（如 a11yLight root 的纯白底），
/// 让代码块背景完全由容器统一控制（跟随主题），避免"白底黑字"。
/// 注意：不能用 copyWith(backgroundColor: null) —— copyWith 对 null 是
/// "保持原值"，必须重建一个不设背景的 TextStyle。
Map<String, TextStyle> _codeThemeNoBg(Map<String, TextStyle> theme) {
  final copy = Map<String, TextStyle>.from(theme);
  for (final entry in copy.entries.toList()) {
    final s = entry.value;
    if (s.backgroundColor != null) {
      copy[entry.key] = TextStyle(
        inherit: s.inherit,
        color: s.color,
        fontSize: s.fontSize,
        fontWeight: s.fontWeight,
        fontStyle: s.fontStyle,
        letterSpacing: s.letterSpacing,
        wordSpacing: s.wordSpacing,
        height: s.height,
        decoration: s.decoration,
        decorationColor: s.decorationColor,
        decorationStyle: s.decorationStyle,
        shadows: s.shadows,
        fontFamily: s.fontFamily,
        fontFamilyFallback: s.fontFamilyFallback,
        fontFeatures: s.fontFeatures,
        fontVariations: s.fontVariations,
        // 故意不传 backgroundColor / background —— 彻底去掉背景。
      );
    }
  }
  return copy;
}

MarkdownGenerator theMarkdownGenerators(BuildContext context,
    {double? textScale}) {
  // Not an elegant way to customize, but it works
  final isDark = Theme.of(context).brightness == Brightness.dark;
  SpanNodeGeneratorWithTag noteTagGenerator = SpanNodeGeneratorWithTag(
      tag: 'noteTag',
      generator: (e, config, visitor) => NoteTagNode(
            e.attributes,
            config,
            tagBackgroundColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            tagTextColor: isDark
                ? Theme.of(context).colorScheme.secondary
                : Theme.of(context).colorScheme.primary,
          ));

  return MarkdownGenerator(
    generators: [
      if (context.watch<SettingsProvider>().useLatex) latexGenerator,
      noteTagGenerator,
      highlighterGeneratorWithTag,
      underlineGeneratorWithTag,
      strikethroughGeneratorWithTag,
      superscriptGeneratorWithTag,
      subscriptGeneratorWithTag,
    ],
    inlineSyntaxList: [
      if (context.watch<SettingsProvider>().useLatex) LatexSyntax(),
      NoteTagSyntax(),
      WikiLinkSyntax(),
      HighlighterSyntax(),
      UnderlineSyntax(),
      StrikethroughSyntax(),
      SuperscriptSyntax(),
      SubscriptSyntax(),
    ],
    textGenerator: (node, config, visitor) =>
        CustomTextNode(node.textContent, config, visitor),
    richTextBuilder: (span) => Text.rich(
      span,
      textScaler: TextScaler.linear(textScale ?? 1),
    ),
  );
}

Widget buildMarkdownWidget(
  BuildContext context, {
  required String data,
  required Uri fileUri,
  AutoScrollController? controller,
  TocController? tocController,
  ScrollPhysics? physics,
  bool shrinkWrap = false,
  bool? selectable,
  TextEditingController? editingController,
  Future<void> Function()? onCheckboxToggle,
}) {
  // LaTeX 开启时，把公式提取成占位符再交给 markdown 解析，
  // 渲染层再还原成公式节点（见 custom_node.dart / latex_protector.dart）。
  final renderData =
      context.watch<SettingsProvider>().useLatex ? protectLatex(data) : data;
  return MarkdownWidget(
    data: renderData,
    controller: controller,
    tocController: tocController,
    physics: physics,
    shrinkWrap: shrinkWrap,
    selectable: selectable ?? true,
    config: theMarkdownConfigs(
      context,
      fileUri: fileUri,
      inEditor: true,
      editingController: editingController,
      onCheckboxToggle: onCheckboxToggle,
    ),
    markdownGenerator: theMarkdownGenerators(context),
  );
}
