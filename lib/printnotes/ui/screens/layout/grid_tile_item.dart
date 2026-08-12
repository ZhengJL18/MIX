import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import 'package:mix/printnotes/markdown/markdown_widget/markdown_widget.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';
import 'package:mix/printnotes/providers/navigation_provider.dart';
import 'package:mix/printnotes/providers/selecting_provider.dart';
import 'package:mix/printnotes/providers/customization_provider.dart';

import 'package:mix/printnotes/utils/storage_system.dart';
import 'package:mix/printnotes/utils/handlers/style_handler.dart';
import 'package:mix/printnotes/utils/handlers/file_extensions.dart';
import 'package:mix/printnotes/utils/parsers/frontmatter_parser.dart';
import 'package:mix/printnotes/utils/parsers/hex_color_extension.dart';

import 'package:mix/printnotes/markdown/build_markdown.dart';
import 'package:mix/printnotes/ui/components/dialogs/bottom_menu_popup.dart';

class GridTileItem extends StatelessWidget {
  const GridTileItem({super.key, required this.item, required this.onChange});

  final FileSystemEntity item;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final Map<String, Future<Widget>> previewCache = {};

    final isDirectory = item is Directory;
    final isSelected =
        context.read<SelectingProvider>().selectedItems.contains(item.path);
    final useFM = context.read<SettingsProvider>().useFrontmatter;
    String? fmColor;
    String? fmBgColor;

    if (useFM && item.path.endsWith('.md')) {
      fmColor = FrontmatterHandleParsing.getTagString(
          File(item.path).readAsStringSync(), 'color');
      fmBgColor = FrontmatterHandleParsing.getTagString(
          File(item.path).readAsStringSync(), 'background');
    }

    return GestureDetector(
      onTap: () {
        if (context.read<SelectingProvider>().selectingMode) {
          if (!isDirectory) {
            context.read<SelectingProvider>().updateSelectedList(item);
          }
        } else {
          if (isDirectory) {
            context.read<NavigationProvider>().addToRouteHistory(item.path);
            onChange();
          } else if (item is File) {
            context
                .read<NavigationProvider>()
                .routeItemToPage(context, item.uri);
          }
        }
      },
      onLongPress: () => showBottomMenu(context, item, onChange),
      child: AbsorbPointer(
        child: Card(
          color:
              (isDirectory && context.watch<SelectingProvider>().selectingMode)
                  ? Theme.of(context).disabledColor.withValues(alpha: 0.1)
                  : (fmBgColor != null
                          ? HexColor.fromHex(fmBgColor)
                          : Theme.of(context).colorScheme.surfaceContainer)
                      ?.withValues(
                          alpha: context
                              .watch<CustomizationProvider>()
                              .noteTileOpacity),
          shape: isSelected
              ? StyleHandler.getNoteTileShape(
                  context.watch<CustomizationProvider>().noteTileShape,
                  side: BorderSide(
                      color: Theme.of(context).colorScheme.primary, width: 5),
                  borderRadius: BorderRadius.circular(12))
              : StyleHandler.getNoteTileShape(
                  context.watch<CustomizationProvider>().noteTileShape),
          child: isDirectory
              ? ListTile(
                  leading: Icon(
                    Icons.folder,
                    size: 34,
                    color: context.watch<SelectingProvider>().selectingMode
                        ? Theme.of(context).disabledColor
                        : Theme.of(context).colorScheme.secondary,
                  ),
                  title: Text(
                    path.basename(item.path),
                    textAlign: TextAlign.start,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              : Padding(
                  padding: EdgeInsets.all(
                      context.watch<CustomizationProvider>().noteTilePadding),
                  child: FutureBuilder(
                      future: previewCache[item.path] ??= fileItem(
                          context,
                          item,
                          fmColor != null ? HexColor.fromHex(fmColor) : null),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.done) {
                          return snapshot.data ?? const SizedBox();
                        } else {
                          return Center(child: CircularProgressIndicator());
                        }
                      }),
                ),
        ),
      ),
    );
  }

  Future<Widget> fileItem(
      BuildContext context, FileSystemEntity item, Color? color) async {
    final itemName = path.basename(item.path);
    final useFM = context.read<SettingsProvider>().useFrontmatter;
    final markdownConfigs = theMarkdownConfigs(context,
        fileUri: item.uri, hideCodeButtons: true, textColor: color);
    final markdownGenerators = theMarkdownGenerators(context, textScale: 0.95);

    String? fmTitle;
    String? fmDescription;

    if (item is File) {
      if (fileTypeChecker(item.path) == CFileType.image) {
        return Image.file(item);
      } else if (fileTypeChecker(item.path) == CFileType.sketch) {
        return ListTile(
          leading: Icon(
            Icons.draw,
            size: 34,
          ),
          title: Text(
            itemName.replaceAll('.bson', ''),
            textAlign: TextAlign.start,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        );
      }
    }
    if (useFM) {
      // I am beginning to hate this function, but why create new one when
      // we can add more functionality to it
      String fileText = await StorageSystem(context)
          .getFilePreview(item.uri, isTrimmed: false);
      if (fileText != 'No preview available') {
        fmTitle = FrontmatterHandleParsing.getTagString(fileText, 'title');
        fmDescription =
            FrontmatterHandleParsing.getTagString(fileText, 'description');
      }
    }
    final String previewText = await StorageSystem(context)
        .getFilePreview(item.uri, parseFrontmatter: useFM);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          fmTitle ?? itemName.replaceAll(".md", ''),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: color,
            fontSize: 16,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 4),
        fmDescription != null
            ? Text(
                fmDescription,
                style: TextStyle(color: color),
              )
            : MarkdownBlock(
                selectable: false,
                data: previewText,
                config: markdownConfigs,
                generator: markdownGenerators,
              ),
      ],
    );
  }
}
