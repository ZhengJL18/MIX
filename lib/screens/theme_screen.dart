/// 主题设置页：选配色方案 + 明暗模式。
library;

import 'package:flutter/material.dart';

import '../main.dart' show themeController;
import '../theme/app_theme.dart';
import '../theme/theme_ext.dart';
import '../theme/theme_provider.dart';

class ThemeScreen extends StatefulWidget {
  const ThemeScreen({super.key});

  @override
  State<ThemeScreen> createState() => _ThemeScreenState();
}

class _ThemeScreenState extends State<ThemeScreen> {
  @override
  Widget build(BuildContext context) {
    final current = themeController.theme;
    final brightness = themeController.brightness;
    return Scaffold(
      appBar: AppBar(title: const Text('主题')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('配色',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '跟随 dsh-claude-style 的 Claude 色卡。这不是 Anthropic 官方主题。',
              style: TextStyle(
                color: context.appPalette.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final t in builtinThemes)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: t.lightSeed,
                  child: const Icon(Icons.palette, size: 18, color: Colors.white),
                ),
                title: Text(t.name),
                trailing: current.id == t.id
                    ? Icon(Icons.check, color: context.appPalette.primary)
                    : null,
                onTap: () {
                  themeController.setTheme(t);
                  setState(() {});
                },
              ),
            ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('明暗模式',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
          Card(
            child: SwitchListTile(
              title: const Text('深色模式'),
              subtitle: Text(brightness == ThemeBrightness.dark
                  ? '已开启深色'
                  : '已开启浅色'),
              value: brightness == ThemeBrightness.dark,
              onChanged: (_) async {
                await themeController.toggleBrightness();
                if (mounted) setState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }
}
