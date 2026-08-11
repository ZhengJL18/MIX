import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:mix/printnotes/markdown/markdown_widget/config/toc.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';
import 'package:mix/printnotes/providers/customization_provider.dart';
import 'package:mix/printnotes/providers/editor_config_provider.dart';

import 'package:mix/printnotes/utils/open_explorer.dart';
import 'package:mix/printnotes/utils/parsers/frontmatter_parser.dart';
import 'package:mix/printnotes/utils/parsers/csv_parser.dart';

import 'package:mix/printnotes/markdown/build_markdown.dart';
import 'package:mix/printnotes/markdown/editor_field.dart';
import 'package:mix/printnotes/markdown/toolbar/markdown_toolbar.dart';

import 'package:mix/printnotes/ui/screens/editors/notes/editor_config_page.dart';

import 'package:mix/printnotes/ui/components/app_bar_drag_wrapper.dart';
import 'package:mix/printnotes/ui/components/centered_page_wrapper.dart';
import 'package:mix/printnotes/ui/widgets/file_info_bottom_sheet.dart';
import 'package:mix/printnotes/ui/widgets/custom_snackbar.dart';

class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen(
      {super.key, required this.fileUri, this.newNote, this.jumpToHeader});

  final Uri fileUri;
  final bool? newNote;
  final String? jumpToHeader;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

// For switching between preview and edit with ctrl-shift-v
class SwitchModeIntent extends Intent {
  const SwitchModeIntent();
}

bool isScreenLarge(BuildContext context) {
  return MediaQuery.sizeOf(context).width >= 1000;
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final TextEditingController _notesController;
  late final AutoScrollController _autoScrollController;
  late final TocController _tocController;
  late final FocusNode _noteFocusNode;
  late final UndoHistoryController _undoHistoryController;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _readOnlyMode = false;
  bool _isEditingFile = false;
  bool _isLoading = true;
  bool _isError = false;

  DateTime? _lastModifiedTime;
  Timer? _fileCheckTimer;
  Timer? _autoSaveTimer;
  Timer? _scrollToHeader;
  bool _hasUnsavedChanges = false;

  final Duration autoSaveInterval = Duration(seconds: 3);
  final Duration fileCheckInterval = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _notesController = TextEditingController();
    _autoScrollController = AutoScrollController();
    _tocController = TocController();
    _noteFocusNode = FocusNode();
    _undoHistoryController = UndoHistoryController();
    _loadFileContent();
    _loadConfig();

    if (widget.newNote == true) {
      _isEditingFile = true;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) _noteFocusNode.requestFocus();
        });
      });
    }

    _fileCheckTimer = Timer.periodic(
        fileCheckInterval, (_) => _checkForExternalChanges(context));
  }

  Future<void> _loadConfig() async {
    bool defaultEditMode =
        context.read<EditorConfigProvider>().defaultEditorMode;
    if (defaultEditMode) setState(() => _isEditingFile = defaultEditMode);
  }

  /// Load the passed files contents and set the state
  Future<void> _loadFileContent() async {
    context.read<SettingsProvider>().addRecentFile(widget.fileUri.toFilePath());
    try {
      final file = File.fromUri(widget.fileUri);
      final content = await file.readAsString();
      final lastMod = await file.lastModified();

      setState(() {
        _notesController.text = content;
        _lastModifiedTime = lastMod;
        _isLoading = false;
        _hasUnsavedChanges = false;

        if (mounted &&
            !widget.fileUri
                .toFilePath()
                .contains(context.read<SettingsProvider>().mainDir)) {
          _readOnlyMode = true;
        }
      });
    } catch (e) {
      debugPrint('Error loading file content: $e');
      setState(() {
        _isError = true;
        _isLoading = false;
      });
    }
  }

  void _setUpAutoSave() {
    _autoSaveTimer?.cancel();
    _hasUnsavedChanges = true;

    _autoSaveTimer = Timer(autoSaveInterval, () {
      if (_hasUnsavedChanges && context.mounted) {
        _saveFileContent(context);
        _hasUnsavedChanges = false;
      }
    });
  }

  /// Check if file has been modified outside of app
  Future<void> _checkForExternalChanges(BuildContext context) async {
    if (_isError || _isLoading) return;

    try {
      final file = File.fromUri(widget.fileUri);
      final lastMod = await file.lastModified();

      if (_lastModifiedTime != null &&
          lastMod.isAfter(_lastModifiedTime!) &&
          mounted &&
          context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('文件已更改'),
            content: const Text(
                '此文件已在 App 外被修改。是否重新加载？'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _saveFileContent(context);
                },
                child: const Text('保留我的更改'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _loadFileContent();
                },
                child: const Text('重新加载文件'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      debugPrint('Error checking file modification: $e');
    }
  }

  Future<bool> _saveFileContent(BuildContext context) async {
    if (_isError) return true;
    try {
      final file = File.fromUri(widget.fileUri);
      await file.writeAsString(_notesController.text);

      _lastModifiedTime = DateTime.now();
      _hasUnsavedChanges = false;

      return true;
    } catch (e) {
      debugPrint('Error saving file content: $e');
      if (context.mounted) {
        customSnackBar('保存文件失败', type: 'error').show(context);
      }
      return false;
    }
  }

  void _toggleMode() {
    if (!_readOnlyMode) {
      setState(() => _isEditingFile = !_isEditingFile);
    }
  }

  @override
  Widget build(BuildContext context) {
    bool useFM = context.read<SettingsProvider>().useFrontmatter;
    String? fmBody;
    String? fmTitle;

    if (widget.jumpToHeader != null) {
      _scrollToHeader = Timer(Duration(microseconds: 800), () {
        _tocController.jumpToText(widget.jumpToHeader!);
        setState(() {});
      });
    }

    // frontmatter logic
    if (useFM) {
      final doc = FrontmatterHandleParsing.getParsedData(_notesController.text);
      fmTitle =
          FrontmatterHandleParsing.getTagString(_notesController.text, 'title');
      if (doc != null) fmBody = doc.body;
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;

        bool canPop =
            _hasUnsavedChanges ? await _saveFileContent(context) : true;
        if (canPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        appBar: AppBarDragWrapper(
          child: AppBar(
            centerTitle: false,
            title: Text(
              fmTitle ??
                  path.basenameWithoutExtension(widget.fileUri.toFilePath()),
              style: TextStyle(overflow: TextOverflow.ellipsis),
            ),
            actions: _isError
                ? null
                : [
                    if (!_readOnlyMode)
                      IconButton(
                          tooltip: '预览/编辑模式',
                          icon: Icon(_isEditingFile
                              ? Icons.visibility
                              : Icons.mode_edit),
                          onPressed: _toggleMode),
                    if (isScreenLarge(context) &&
                        _notesController.text.contains("# "))
                      IconButton(
                        tooltip: '目录',
                        onPressed: () =>
                            _scaffoldKey.currentState!.openEndDrawer(),
                        icon: const Icon(Icons.toc_rounded),
                      ),
                    PopupMenuButton(
                      itemBuilder: (context) => <PopupMenuEntry>[
                        PopupMenuItem(
                          child: const ListTile(
                            leading: Icon(Icons.info_outline),
                            title: Text('信息'),
                          ),
                          onTap: () =>
                              modalShowFileInfo(context, widget.fileUri),
                        ),
                        // PopupMenuItem(
                        //   child: ListTile(
                        //     leading: const Icon(Icons.find_in_page_outlined),
                        //     title: Text('Find in page...'),
                        //     onTap: () {},
                        //   ),
                        // ),
                        PopupMenuItem(
                          child: ListTile(
                            leading: const Icon(Icons.share),
                            title: Text('分享'),
                            onTap: () {
                              SharePlus.instance.share(
                                  ShareParams(text: _notesController.text));
                            },
                          ),
                        ),
                        PopupMenuItem(
                          child: const ListTile(
                            leading: Icon(Icons.tune),
                            title: Text('配置'),
                          ),
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (context) =>
                                      const EditorConfigPage())),
                        ),
                        PopupMenuItem(
                          child: ListTile(
                            leading: const Icon(Icons.folder_open),
                            title: const Text("Open Location"),
                            iconColor: mobileNullColor(context),
                            textColor: mobileNullColor(context),
                          ),
                          onTap: () async =>
                              await openExplorer(context, widget.fileUri),
                        ),
                      ],
                    ),
                  ],
          ),
        ),
        body: Column(
          children: [
            if (_readOnlyMode)
              Container(
                width: double.infinity,
                color: Colors.amber.shade700,
                padding: const EdgeInsets.all(8),
                child: const Text(
                  "Read-Only Mode",
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
            Expanded(child: buildMarkdownView(fmBody ?? _notesController.text)),
          ],
        ),
        endDrawerEnableOpenDragGesture: false,
        endDrawer: _isError
            ? null
            // Drawer for table of contents
            : Drawer(
                child: SafeArea(
                  child: Column(
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(10),
                        child: Text(
                          '目录',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 24),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const Divider(
                        thickness: 0.3,
                      ),
                      Expanded(
                        child: _notesController.text.contains("# ")
                            ? buildTocList()
                            : const Center(
                                child: Text(
                                  '使用 "#" 添加标题以生成目录',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
        floatingActionButton: !isScreenLarge(context) &&
                _notesController.text.contains("# ") &&
                !_isEditingFile
            ? FloatingActionButton(
                onPressed: _scaffoldKey.currentState!.openEndDrawer,
                heroTag: 'Table of Contents',
                child: const Icon(Icons.format_list_bulleted),
              )
            : null,
      ),
    );
  }

  /// Table of Contents
  Widget buildTocList() => Container(
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20)),
        child: TocWidget(controller: _tocController),
      );

  Widget buildMarkdownView(String previewBody) {
    if (widget.fileUri.toFilePath().endsWith('.csv')) {
      previewBody = csvToMarkdownTable(previewBody);
    }
    return SafeArea(
      child: CenteredPageWrapper(
        padding: EdgeInsets.all(
            context.watch<CustomizationProvider>().noteEditorPadding),
        width: 1000,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [
            BoxShadow(
                color: Colors.grey.withValues(alpha: 0.2),
                spreadRadius: 5,
                blurRadius: 7,
                offset: const Offset(0, 3)),
          ],
          borderRadius:
              isScreenLarge(context) ? BorderRadius.circular(10) : null,
        ),
        // Wrap child to add Toolbar at the bottom（原 FooterLayout 跟随键盘，
        // 依赖 keyboard_attachable/flutter_keyboard_visibility 与 AGP 9 不兼容，
        // 改为普通 Column，工具栏固定底部）。
        child: Column(
          children: [
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _isError
                      ? const Center(
                          child: Text(
                              '读取文件失败，请重新打开文件'))
                      // Catch if "ctrl+shift+v" was used to switch between
                      // edit and preview mode
                      : Shortcuts(
                          shortcuts: <ShortcutActivator, Intent>{
                            LogicalKeySet(
                                LogicalKeyboardKey.control,
                                LogicalKeyboardKey.shift,
                                LogicalKeyboardKey.keyV):
                                const SwitchModeIntent(),
                          },
                          child: Actions(
                            actions: <Type, Action<Intent>>{
                          SwitchModeIntent: CallbackAction<SwitchModeIntent>(
                              onInvoke: (SwitchModeIntent intent) =>
                                  _toggleMode()),
                        },
                        child: FocusableActionDetector(
                          autofocus: true,
                          child: SingleChildScrollView(
                            controller: _autoScrollController,
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 100),
                            child: _isEditingFile
                                ? EditorField(
                                    controller: _notesController,
                                    focusNode: _noteFocusNode,
                                    onChanged: (value) => _setUpAutoSave(),
                                    undoController: _undoHistoryController,
                                    fontSize: context
                                        .watch<EditorConfigProvider>()
                                        .fontSize,
                                  )
                                : GestureDetector(
                                    // Check if double tap to change to edit mode
                                    onDoubleTap: _toggleMode,
                                    child: _notesController.text.isEmpty
                                        // If note is empty so message
                                        ? SizedBox(
                                            height: MediaQuery.sizeOf(context)
                                                .height,
                                            child: Text(
                                              '双击屏幕或点击右上角铅笔图标开始编辑！',
                                              style: TextStyle(
                                                  color: Theme.of(context)
                                                      .hintColor),
                                            ),
                                          )
                                        // Parse and render the markdown text
                                        : buildMarkdownWidget(
                                            context,
                                            data: previewBody,
                                            fileUri: widget.fileUri,
                                            controller: _autoScrollController,
                                            tocController: _tocController,
                                            physics:
                                                NeverScrollableScrollPhysics(),
                                            shrinkWrap: true,
                                            editingController: _notesController,
                                            onCheckboxToggle: () =>
                                                _saveFileContent(context),
                                          ),
                                  ),
                          ),
                                  ),
                            ),
                          ),
            ),
            if (_isEditingFile)
              MarkdownToolbar(
                controller: _notesController,
                onValueChange: (value) => _setUpAutoSave(),
                onPreviewChanged: _toggleMode,
                undoController: _undoHistoryController,
                toolbarBackground:
                    Theme.of(context).colorScheme.surfaceContainer,
                expandableBackground: Theme.of(context).colorScheme.surface,
                userToolbarItemList:
                    context.watch<EditorConfigProvider>().toolbarItemList,
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (_hasUnsavedChanges && context.mounted) {
      _saveFileContent(context);
    }

    _notesController.dispose();
    _autoScrollController.dispose();
    _tocController.dispose();
    _noteFocusNode.dispose();
    _undoHistoryController.dispose();

    _fileCheckTimer?.cancel();
    _autoSaveTimer?.cancel();
    _scrollToHeader?.cancel();
    super.dispose();
  }
}
