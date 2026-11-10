import 'package:flutter/material.dart';

import 'package:mix/printnotes/ui/components/app_bar_drag_wrapper.dart';
import 'package:mix/printnotes/ui/components/centered_page_wrapper.dart';
import 'package:mix/printnotes/ui/components/dialogs/libraries_dialog.dart';

import 'package:mix/printnotes/ui/widgets/menu_tile.dart';

import 'package:mix/printnotes/utils/handlers/open_url_link.dart';

import 'package:mix/printnotes/constants/constants.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBarDragWrapper(
        child: AppBar(
          backgroundColor: Theme.of(context).colorScheme.surface,
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: const Text('关于'),
        ),
      ),
      body: SingleChildScrollView(
        child: CenteredPageWrapper(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            children: [
              const SizedBox(height: 8),
              Image.asset('assets/brand/mix_mark.png',
                  width: 56, height: 56),
              const SizedBox(height: 8),
              Text('MIX',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold)),
              Text('v$appVersion',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text('在 Android 沙盒内运行 agent 级能力的笔记 + 学习 App',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(
                  '界面跟随 dsh-claude-style，不是 Anthropic 官方客户端',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              MenuTile(
                iconColor: Theme.of(context).colorScheme.secondary,
                leading: const Icon(Icons.code),
                title: '项目仓库',
                subtitle: MenuTile.subtitleText(context,
                    text: 'https://github.com/ZhengJL18/MIX'),
                onTap: () => urlHandler(
                    context, 'https://github.com/ZhengJL18/MIX'),
                onLongPress: () => urlHandler(
                    context, 'https://github.com/ZhengJL18/MIX',
                    copyToClipboard: true),
                trailing: const Icon(Icons.launch_rounded),
                isFirst: true,
              ),
              const SizedBox(height: 12),
              MenuTile(
                iconColor: Theme.of(context).colorScheme.secondary,
                leading: const Icon(Icons.menu_book),
                title: '第三方库',
                subtitle: MenuTile.subtitleText(context,
                    text: '点击查看使用的第三方库及许可'),
                onTap: () => showLibrariesDialog(context),
                trailing: const Icon(Icons.arrow_back_ios_new_rounded),
              ),
              const SizedBox(height: 12),
              MenuTile(
                iconColor: Theme.of(context).colorScheme.secondary,
                leading: const Icon(Icons.article),
                title: '笔记引擎',
                subtitle: MenuTile.subtitleText(context,
                    text: '内置笔记界面基于开源 printnotes（GPL-3.0）集成'),
                onTap: () => urlHandler(
                    context, 'https://github.com/RoBoT095/printnotes'),
                onLongPress: () => urlHandler(
                    context, 'https://github.com/RoBoT095/printnotes',
                    copyToClipboard: true),
                trailing: const Icon(Icons.launch_rounded),
                isLast: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
