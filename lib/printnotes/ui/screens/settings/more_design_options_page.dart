import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart';
import 'package:provider/provider.dart';

import 'package:mix/printnotes/providers/customization_provider.dart';

import 'package:mix/printnotes/utils/handlers/style_handler.dart';

import 'package:mix/printnotes/ui/components/app_bar_drag_wrapper.dart';
import 'package:mix/printnotes/ui/components/centered_page_wrapper.dart';

import 'package:mix/printnotes/ui/widgets/list_section_title.dart';
import 'package:mix/printnotes/ui/widgets/menu_tile.dart';

class MoreDesignOptionsPage extends StatefulWidget {
  const MoreDesignOptionsPage({super.key});

  @override
  State<MoreDesignOptionsPage> createState() => _MoreDesignOptionsPageState();
}

class _MoreDesignOptionsPageState extends State<MoreDesignOptionsPage> {
  bool _isLoading = false;
  List<DropdownMenuItem> _bgImgDropItemList = [];
  List<String> _bgImgPathList = [];

  @override
  void initState() {
    _loadImages();
    super.initState();
  }

  void _loadImages() async {
    setState(() => _isLoading = true);
    final List<DropdownMenuItem> saveStateList = [];
    final list = await StyleHandler.getBgImageList();
    if (list.isNotEmpty) {
      for (String imgPath in list) {
        saveStateList.add(
            DropdownMenuItem(value: imgPath, child: Text(basename(imgPath))));
      }
      saveStateList.add(DropdownMenuItem(value: null, child: Text('无图片')));
      saveStateList.add(
          DropdownMenuItem(value: 'add new image', child: Text('+ 添加图片')));
    }
    setState(() {
      _bgImgDropItemList = saveStateList;
      _bgImgPathList = list;
      _isLoading = false;
    });
  }

  void delImgDialog(BuildContext context) async {
    return await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除图片'),
        content: StatefulBuilder(
          builder: (context, setState) => SizedBox(
            height: double.maxFinite,
            width: 500,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _bgImgPathList.length,
              itemBuilder: (context, index) => Container(
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: FileImage(File(_bgImgPathList[index])),
                    fit: BoxFit.cover,
                  ),
                ),
                child: ListTile(
                  title:
                      Text('${index + 1}. ${basename(_bgImgPathList[index])}'),
                  trailing: IconButton(
                      onPressed: () {
                        _deleteImage(context, _bgImgPathList[index]);
                        setState(() {
                          _bgImgDropItemList.removeWhere(
                              (e) => e.value == _bgImgPathList[index]);
                          _bgImgPathList
                              .removeWhere((e) => e == _bgImgPathList[index]);
                        });
                      },
                      icon: Icon(
                        Icons.delete,
                        color: Colors.red,
                      )),
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondary,
              foregroundColor: Theme.of(context).colorScheme.onSecondary,
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _uploadImage(BuildContext context) async {
    final value = await StyleHandler.uploadBgImage();
    if (context.mounted) {
      if (value != null) {
        context.read<CustomizationProvider>().setBgImagePath(value);
        _loadImages();
      }
    }
  }

  void _deleteImage(BuildContext context, String imgPath) async {
    await StyleHandler.deleteBgImage(imgPath);
    _bgImgDropItemList.removeWhere((e) => e.value == imgPath);
    _bgImgPathList.removeWhere((e) => e == imgPath);
    if (context.mounted) {
      if (context.read<CustomizationProvider>().bgImagePath == imgPath) {
        context.read<CustomizationProvider>().setBgImagePath(null);
      }
    }
    _loadImages();
  }

  @override
  Widget build(BuildContext context) {
    final watchCustomizations = context.watch<CustomizationProvider>();
    final readCustomizations = context.read<CustomizationProvider>();
    bool isScreenLarge = MediaQuery.sizeOf(context).width >= 600;

    return Scaffold(
      appBar: AppBarDragWrapper(
        child: AppBar(
          centerTitle: true,
          title: const Text('更多设计选项'),
        ),
      ),
      body: CenteredPageWrapper(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: ListTileTheme(
            iconColor: Theme.of(context).colorScheme.secondary,
            child: _isLoading
                ? Center(child: CircularProgressIndicator())
                : ListView(
                    children: [
                      sectionTitle(
                        '主屏幕',
                        Theme.of(context).colorScheme.secondary,
                        padding: 10,
                      ),
                      MenuTile(
                        decoration: watchCustomizations.bgImagePath != null
                            ? BoxDecoration(
                                image: DecorationImage(
                                  repeat: StyleHandler.getBgImageRepeat(
                                      watchCustomizations.bgImageRepeat),
                                  fit: StyleHandler.getBgImageFit(
                                      watchCustomizations.bgImageFit),
                                  opacity: watchCustomizations.bgImageOpacity,
                                  image: FileImage(
                                      File(watchCustomizations.bgImagePath!)),
                                ),
                              )
                            : null,
                        leading: Icon(Icons.image),
                        title: '背景图片',
                        subtitle: isScreenLarge || _bgImgDropItemList.isEmpty
                            ? Text('用图片替换背景颜色')
                            : DropdownButton(
                                items: _bgImgDropItemList,
                                value: watchCustomizations.bgImagePath,
                                isExpanded: true,
                                hint: Text('选择图片'),
                                onChanged: (value) {
                                  if (value is String?) {
                                    if (value == 'add new image') {
                                      _uploadImage(context);
                                    } else {
                                      readCustomizations.setBgImagePath(value);
                                    }
                                  }
                                },
                              ),
                        trailing:
                            // If empty, show icon, otherwise dropdown of images
                            _bgImgDropItemList.isEmpty
                                ? IconButton(
                                    onPressed: () => _uploadImage(context),
                                    icon: Icon(Icons.add))
                                : isScreenLarge
                                    ? DropdownButton(
                                        items: _bgImgDropItemList,
                                        value: watchCustomizations.bgImagePath,
                                        hint: Text('选择图片'),
                                        onChanged: (value) {
                                          if (value is String?) {
                                            if (value == 'add new image') {
                                              _uploadImage(context);
                                            } else {
                                              readCustomizations
                                                  .setBgImagePath(value);
                                            }
                                          }
                                        },
                                      )
                                    : null,
                        isFirst: true,
                      ),
                      if (_bgImgDropItemList.isNotEmpty)
                        MenuTile(
                          leading: Icon(Icons.delete),
                          title: '删除图片',
                          trailing: Icon(Icons.chevron_right),
                          onTap: () => delImgDialog(context),
                        ),
                      if (watchCustomizations.bgImagePath != null)
                        MenuTile(
                          leading: Icon(Icons.opacity),
                          title: '背景图片透明度',
                          trailing: Text(
                              '${watchCustomizations.bgImageOpacity * 100}%'),
                          subtitle: Slider(
                            value: watchCustomizations.bgImageOpacity,
                            divisions: 10,
                            min: 0,
                            max: 1,
                            onChanged: (opacity) =>
                                readCustomizations.setBgImageOpacity(opacity),
                          ),
                        ),
                      if (watchCustomizations.bgImagePath != null)
                        MenuTile(
                          leading: Icon(Icons.format_shapes),
                          title: '背景图片适应方式',
                          trailing: DropdownButton(
                            value: watchCustomizations.bgImageFit,
                            items: [
                              DropdownMenuItem(
                                value: 'cover',
                                child: Text('覆盖'),
                              ),
                              DropdownMenuItem(
                                value: 'contain',
                                child: Text('包含'),
                              ),
                              DropdownMenuItem(
                                value: 'fill',
                                child: Text('填充'),
                              ),
                              DropdownMenuItem(
                                value: 'scaleDown',
                                child: Text('缩小'),
                              ),
                              DropdownMenuItem(
                                value: 'fitHeight',
                                child: Text('适应高度'),
                              ),
                              DropdownMenuItem(
                                value: 'fitWidth',
                                child: Text('适应宽度'),
                              ),
                              DropdownMenuItem(
                                value: 'none',
                                child: Text('无'),
                              ),
                            ],
                            onChanged: (fit) {
                              if (fit != null) {
                                readCustomizations.setBgImageFit(fit);
                              }
                            },
                          ),
                        ),
                      if (watchCustomizations.bgImagePath != null)
                        MenuTile(
                          leading: Icon(Icons.loop),
                          title: '背景图片重复',
                          trailing: DropdownButton(
                            value: watchCustomizations.bgImageRepeat,
                            items: [
                              DropdownMenuItem(
                                value: 'noRepeat',
                                child: Text('不重复'),
                              ),
                              DropdownMenuItem(
                                value: 'repeat',
                                child: Text('重复'),
                              ),
                              DropdownMenuItem(
                                value: 'repeatX',
                                child: Text('水平重复'),
                              ),
                              DropdownMenuItem(
                                value: 'repeatY',
                                child: Text('垂直重复'),
                              ),
                            ],
                            onChanged: (repeat) {
                              if (repeat != null) {
                                readCustomizations.setBgImageRepeat(repeat);
                              }
                            },
                          ),
                        ),
                      MenuTile(
                        leading: Icon(Icons.opacity),
                        title: '笔记卡片透明度',
                        trailing: Text(
                            '${watchCustomizations.noteTileOpacity * 100}%'),
                        subtitle: Slider(
                          value: watchCustomizations.noteTileOpacity,
                          divisions: 10,
                          min: 0.0,
                          max: 1,
                          onChanged: (opacity) =>
                              readCustomizations.setNoteTileOpacity(opacity),
                        ),
                      ),
                      MenuTile(
                        leading: const Icon(Icons.list_alt_rounded),
                        title: '笔记文字预览长度',
                        subtitle: Slider(
                          value: watchCustomizations.previewLength.toDouble(),
                          min: 0,
                          max: 200,
                          divisions: 10,
                          label:
                              sliderLabels(watchCustomizations.previewLength),
                          onChanged: (value) {
                            readCustomizations.setPreviewLength(value.toInt());
                          },
                        ),
                        isLast: true,
                      ),
                      sectionTitle(
                        '网格/列表视图',
                        Theme.of(context).colorScheme.secondary,
                        padding: 10,
                      ),
                      MenuTile(
                        leading: Icon(Icons.interests),
                        title: '笔记卡片形状',
                        trailing: DropdownButton(
                          value: watchCustomizations.noteTileShape,
                          items: [
                            DropdownMenuItem(
                              value: 'round',
                              child: Text('圆角'),
                            ),
                            DropdownMenuItem(
                              value: 'square',
                              child: Text('方形'),
                            ),
                          ],
                          onChanged: (shape) {
                            if (shape != null) {
                              readCustomizations.setNoteTileShape(shape);
                            }
                          },
                        ),
                        isFirst: true,
                      ),
                      MenuTile(
                        leading: Icon(Icons.padding),
                        title: '笔记卡片内边距',
                        trailing:
                            Text('${watchCustomizations.noteTilePadding} px'),
                        subtitle: Slider(
                          value: watchCustomizations.noteTilePadding,
                          divisions: 20,
                          min: 5,
                          max: 25,
                          onChanged: (padding) =>
                              readCustomizations.setNoteTilePadding(padding),
                        ),
                      ),
                      MenuTile(
                        leading: Icon(Icons.straighten),
                        title: '笔记卡片间距',
                        trailing:
                            Text('${watchCustomizations.noteTileSpacing} px'),
                        subtitle: Slider(
                          value: watchCustomizations.noteTileSpacing,
                          divisions: 20,
                          min: 0,
                          max: 20,
                          onChanged: (spacing) =>
                              readCustomizations.setNoteTileSpacing(spacing),
                        ),
                        isLast: true,
                      ),
                      sectionTitle(
                        '笔记编辑器',
                        Theme.of(context).colorScheme.secondary,
                        padding: 10,
                      ),
                      MenuTile(
                        leading: Icon(Icons.padding_outlined),
                        title: '笔记编辑器内边距',
                        trailing:
                            Text('${watchCustomizations.noteEditorPadding} px'),
                        subtitle: Slider(
                          value: watchCustomizations.noteEditorPadding,
                          divisions: 20,
                          min: 0,
                          max: 20,
                          onChanged: (padding) =>
                              readCustomizations.setNoteEditorPadding(padding),
                        ),
                        isFirst: true,
                        isLast: true,
                      ),
                      // const Divider(),
                      // ListTile(
                      //   title: Text(''),
                      // ),
                    ],
                  ),
          )),
    );
  }

  String sliderLabels(int value) {
    String valString = value.toString();
    if (value == 0) {
      return '仅标题: $valString';
    }
    if (value == 100) {
      return '默认: $valString';
    }
    return valString;
  }
}
