import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';
import 'package:mix/printnotes/providers/selecting_provider.dart';
import 'package:mix/printnotes/providers/navigation_provider.dart';
import 'package:mix/printnotes/providers/customization_provider.dart';
import 'package:mix/printnotes/utils/configs/data_path.dart';

import 'package:mix/printnotes/utils/handlers/style_handler.dart';
import 'package:mix/printnotes/utils/handlers/item_move.dart';
import 'package:mix/printnotes/utils/handlers/item_delete.dart';

import 'package:mix/printnotes/ui/screens/layout/grid_list_view.dart';
import 'package:mix/printnotes/ui/screens/layout/tree_view.dart';

import 'package:mix/printnotes/ui/components/app_bar_drag_wrapper.dart';
import 'package:mix/printnotes/ui/components/drawer_rail.dart';
import 'package:mix/printnotes/ui/components/search_view.dart';
import 'package:mix/printnotes/ui/widgets/speed_dial_fab.dart';

class NotesDisplay extends StatefulWidget {
  const NotesDisplay({
    super.key,
    required this.onReload,
    this.drawer,
  });

  final Function(VoidCallback) onReload;
  final Widget? drawer;

  @override
  State<NotesDisplay> createState() => _NotesDisplayState();
}

class _NotesDisplayState extends State<NotesDisplay> {
  String? _sharedFilePath;

  bool _isLoading = false;
  // 搜索态：顶栏唯一（MIX 集成后 MainScaffold 移除，搜索并入本页）。
  bool _isSearching = false;
  TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce; // 输入防抖，避免每键全库重扫。

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) _checkMediaIntent();
    _loadItems();
    // 注册刷新回调给抽屉（全部笔记/最近打开/标签切换时触发 _loadItems）。
    widget.onReload(_loadItems);
  }

  Future<void> _loadItems() async {
    setState(() => _isLoading = true);
    final readSettings = context.read<SettingsProvider>();
    final readNavProv = context.read<NavigationProvider>();

    // mainDir 兜底：loadSettings 异步，首帧可能未完成 → mainDir 空字符串会
    // 让 loadItems('') 走错分支。用 DataPath.selectedDirectory 取默认目录。
    if (readSettings.mainDir.isEmpty) {
      final dir = await DataPath.selectedDirectory;
      if (dir != null && dir.isNotEmpty) readSettings.setMainDir(dir);
    }

    // 确保 routeHistory 有初始条目（原 printnotes 在 App.loadApp 里做，
    // 本集成用 App.init 替代，这里补上）。否则 routeHistory.last 空列表抛异常，
    // _isLoading 卡 true 导致无限刷新。
    readNavProv.initRouteHistory(readSettings.mainDir);

    await readSettings.loadItems(context, readNavProv.routeHistory.last);

    if (mounted) setState(() => _isLoading = false);
  }

  void _navBack() async {
    context.read<NavigationProvider>().navigateBack();
    await _loadItems();
  }

  Future<void> _refreshPage() async {
    setState(() => _isLoading = true);

    Future.delayed(
        const Duration(milliseconds: 300), () async => await _loadItems());
  }

  /// FAB 新建的安全路径：最近打开/标签是伪视图（currentPath 为 'Recently
  /// Opened' 或裸标签名，非真实目录），新建会落到进程 cwd 而笔记库看不到。
  /// 用「是否真实目录」判断，非目录一律退回笔记根 mainDir。
  String _safeCreatePath(String currentPath) {
    if (currentPath.isEmpty || !Directory(currentPath).existsSync()) {
      return context.read<SettingsProvider>().mainDir;
    }
    return currentPath;
  }

  /// 更多菜单：布局 / 排序 / 文件夹置顶（原 MainScaffold 顶部菜单，合并后归属本页）。
  Widget _buildMoreMenu(BuildContext context) {
    final curLayout = context.watch<SettingsProvider>().layout;
    final curSort = context.watch<SettingsProvider>().sortOrder;
    final curFolderPriority = context.watch<SettingsProvider>().folderPriority;
    return PopupMenuButton(
      tooltip: '更多',
      icon: const Icon(Icons.more_vert),
      enabled: !_isSearching,
      itemBuilder: (context) => <PopupMenuEntry>[
        PopupMenuItem(
          child: PopupMenuButton(
            onSelected: (value) {
              context.read<SettingsProvider>().setLayout(value);
              context.read<SelectingProvider>().setSelectingMode(mode: false);
              Navigator.pop(context);
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                  value: 'grid', checked: curLayout == 'grid',
                  child: const Text('网格视图')),
              CheckedPopupMenuItem(
                  value: 'list', checked: curLayout == 'list',
                  child: const Text('列表视图')),
              CheckedPopupMenuItem(
                  value: 'tree', checked: curLayout == 'tree',
                  child: const Text('树状视图')),
            ],
            child: const ListTile(
                leading: Icon(Icons.grid_view), title: Text('布局')),
          ),
        ),
        PopupMenuItem(
          enabled: !context.read<SelectingProvider>().selectingMode,
          child: PopupMenuButton(
            onSelected: (value) {
              context.read<SettingsProvider>().setSortOrder(value);
              Navigator.pop(context);
            },
            enabled: !context.read<SelectingProvider>().selectingMode,
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                  value: 'default', checked: curSort == 'default',
                  child: const Text('默认排序')),
              CheckedPopupMenuItem(
                  value: 'titleAsc', checked: curSort == 'titleAsc',
                  child: const Text('标题 (升序)')),
              CheckedPopupMenuItem(
                  value: 'titleDsc', checked: curSort == 'titleDsc',
                  child: const Text('标题 (降序)')),
              CheckedPopupMenuItem(
                  value: 'lastModAsc', checked: curSort == 'lastModAsc',
                  child: const Text('修改 (升序)')),
              CheckedPopupMenuItem(
                  value: 'lastModDsc', checked: curSort == 'lastModDsc',
                  child: const Text('修改 (降序)')),
            ],
            child: const ListTile(
                leading: Icon(Icons.sort), title: Text('排序')),
          ),
        ),
        PopupMenuItem(
          enabled: !context.read<SelectingProvider>().selectingMode,
          child: PopupMenuButton(
            onSelected: (value) {
              context.read<SettingsProvider>().setFolderPriority(value);
              Navigator.pop(context);
            },
            enabled: !context.read<SelectingProvider>().selectingMode,
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                  value: 'above', checked: curFolderPriority == 'above',
                  child: const Text('文件夹在上')),
              CheckedPopupMenuItem(
                  value: 'none', checked: curFolderPriority == 'none',
                  child: const Text('不置顶')),
              CheckedPopupMenuItem(
                  value: 'below', checked: curFolderPriority == 'below',
                  child: const Text('文件夹在下')),
            ],
            child: const ListTile(
                leading: Icon(Icons.folder_copy_outlined),
                title: Text('文件夹置顶')),
          ),
        ),
      ],
    );
  }

  List<Uri> selectedItemsToFileEntity() {
    return context
        .read<SelectingProvider>()
        .selectedItems
        .map((item) => Uri.parse(item))
        .toList();
  }

  // 分享接收（listen_sharing_intent）首版禁用：不引重型依赖，保留结构。
  void _checkMediaIntent() {
    setState(() => _isLoading = true);
    setState(() => _isLoading = false);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isScreenLarge = MediaQuery.sizeOf(context).width >= 1000.0;

    final watchSettings = context.watch<SettingsProvider>();
    final items = watchSettings.items;
    final currentPath = watchSettings.currentPath;
    final currentFolderName = watchSettings.currentFolderName;
    final List<String> routeHistory =
        context.watch<NavigationProvider>().routeHistory;

    if (_sharedFilePath != null) {
      File file = File(_sharedFilePath!);
      if (file.existsSync()) {
        _sharedFilePath = null;

        if (context.mounted) {
          context.read<NavigationProvider>().routeItemToPage(context, file.uri);
        }
      }
    }

    Widget layoutView = watchSettings.layout == 'tree'
        ? TreeLayoutView(onChange: _loadItems)
        : GridListView(items: items, onChange: _loadItems);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        // 搜索态：系统返回 = 退出搜索，而不是导航/退出笔记页。
        if (_isSearching) {
          setState(() {
            _isSearching = false;
            _searchController.clear();
          });
          return;
        }
        // 嵌入 MIX：根目录返回 = 回到聊天页，而不是弹退出框杀整个 App。
        if (routeHistory.length > 1) {
          _navBack();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        drawer: widget.drawer,
        appBar: AppBarDragWrapper(
          child: AppBar(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            centerTitle: true,
            title: _isSearching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary),
                    decoration: InputDecoration(
                      hintText: '搜索笔记…',
                      hintStyle: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimary
                              .withValues(alpha: 0.7)),
                      border: InputBorder.none,
                    ),
                    onChanged: (_) {
                      _searchDebounce?.cancel();
                      _searchDebounce = Timer(
                          const Duration(milliseconds: 250),
                          () => setState(() {}));
                    },
                  )
                : Text(currentFolderName),
            leading: _isSearching
                ? IconButton(
                    tooltip: '关闭搜索',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() {
                        _isSearching = false;
                        _searchController.clear();
                      });
                    },
                  )
                : context.watch<SelectingProvider>().selectingMode
                    ? IconButton(
                        onPressed: () =>
                            context.read<SelectingProvider>().setSelectingMode(),
                        icon: const Icon(Icons.close))
                    : routeHistory.length > 1
                        ? IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: _navBack,
                          )
                        : IconButton(
                            icon: const Icon(Icons.arrow_back),
                            tooltip: '返回聊天',
                            onPressed: () => Navigator.of(context).pop(),
                          ),
            actions: context.watch<SelectingProvider>().selectingMode
                ? [
                    IconButton(
                      tooltip: '全选',
                      onPressed: () {
                        context
                            .read<SelectingProvider>()
                            .selectAll(currentPath);
                      },
                      icon: const Icon(Icons.select_all),
                    ),
                    IconButton(
                      tooltip: '移动选中',
                      onPressed: () {
                        ItemMoveHandler.showMoveDialog(
                            context, selectedItemsToFileEntity());
                        context
                            .read<SelectingProvider>()
                            .setSelectingMode(mode: false);
                      },
                      icon: const Icon(Icons.drive_file_move),
                    ),
                    IconButton(
                      tooltip: '删除选中',
                      onPressed: () {
                        ItemDeletionHandler(context).showTrashManyConfirmation(
                          selectedItemsToFileEntity()
                              .map((e) =>
                                  FileSystemEntity.isFileSync(e.toFilePath())
                                      ? File.fromUri(e)
                                      : Directory.fromUri(e))
                              .toList(),
                        );
                        context
                            .read<SelectingProvider>()
                            .setSelectingMode(mode: false);
                      },
                      icon: const Icon(Icons.delete),
                    ),
                  ]
                : [
                    IconButton(
                      tooltip: '刷新列表',
                      icon: const Icon(Icons.refresh),
                      onPressed: _refreshPage,
                    ),
                    IconButton(
                      tooltip: _isSearching ? '关闭搜索' : '搜索笔记',
                      icon: Icon(_isSearching ? Icons.close : Icons.search),
                      onPressed: () {
                        context
                            .read<SelectingProvider>()
                            .setSelectingMode(mode: false);
                        setState(() {
                          _isSearching = !_isSearching;
                          if (!_isSearching) _searchController.clear();
                        });
                      },
                    ),
                    _buildMoreMenu(context),
                  ],
          ),
        ),
        body: _isSearching
            ? SearchView(searchQuery: _searchController.text)
            : _isLoading
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? const Center(
                        child: Text('这里什么都没有！'),
                      )
                    : RefreshIndicator(
                    onRefresh: _refreshPage,
                    child: isScreenLarge
                        ? Row(
                            children: [
                              SizedBox(
                                  width: 50,
                                  child: DrawerRailView(reload: _refreshPage)),
                              Expanded(child: layoutView),
                            ],
                          )
                        : Container(
                            decoration: context
                                        .watch<CustomizationProvider>()
                                        .bgImagePath !=
                                    null
                                ? BoxDecoration(
                                    image: DecorationImage(
                                        opacity: context
                                            .watch<CustomizationProvider>()
                                            .bgImageOpacity,
                                        repeat: StyleHandler.getBgImageRepeat(
                                            context
                                                .watch<CustomizationProvider>()
                                                .bgImageRepeat),
                                        fit: StyleHandler.getBgImageFit(context
                                            .watch<CustomizationProvider>()
                                            .bgImageFit),
                                        image: FileImage(File(context
                                            .watch<CustomizationProvider>()
                                            .bgImagePath!))),
                                  )
                                : null,
                            child: layoutView),
                  ),
        floatingActionButton: _isSearching
            ? null
            : speedDialFAB(context, _safeCreatePath(currentPath)),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      ),
    );
  }
}
