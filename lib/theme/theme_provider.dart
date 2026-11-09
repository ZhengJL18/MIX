/// 主题提供者：管理当前主题 + 明暗，持久化，驱动全局 rebuild。
///
/// 用 ValueNotifier，MaterialApp 外层包 ValueListenableBuilder——切换明暗时
/// 整棵 widget 树重建（ThemeExtension 全量替换），硬编码色不会停在旧方案上。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';

/// 明暗模式。
enum ThemeBrightness { light, dark }

class ThemeController {
  final ValueNotifier<AppThemeSpec> themeNotifier;
  final ValueNotifier<ThemeBrightness> brightnessNotifier;

  ThemeController({
    AppThemeSpec? initialTheme,
    ThemeBrightness initialBrightness = ThemeBrightness.light,
  })  : themeNotifier = ValueNotifier(initialTheme ?? builtinThemes.first),
        brightnessNotifier = ValueNotifier(initialBrightness);

  AppThemeSpec get theme => themeNotifier.value;
  ThemeBrightness get brightness => brightnessNotifier.value;

  /// 当前主题数据（按明暗）。
  ThemeData get themeData =>
      brightness == ThemeBrightness.dark ? theme.darkTheme() : theme.lightTheme();

  /// 从 SharedPreferences 加载。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final themeId = prefs.getString('theme_id') ?? 'claude';
    final dark = prefs.getBool('theme_dark') ?? false;
    themeNotifier.value = findTheme(themeId);
    brightnessNotifier.value =
        dark ? ThemeBrightness.dark : ThemeBrightness.light;
  }

  /// 切换主题。
  Future<void> setTheme(AppThemeSpec t) async {
    themeNotifier.value = t;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_id', t.id);
  }

  /// 切换明暗。
  Future<void> setBrightness(ThemeBrightness b) async {
    brightnessNotifier.value = b;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('theme_dark', b == ThemeBrightness.dark);
  }

  /// 切换明暗（快捷）。
  Future<void> toggleBrightness() async {
    await setBrightness(brightness == ThemeBrightness.light
        ? ThemeBrightness.dark
        : ThemeBrightness.light);
  }

  void dispose() {
    themeNotifier.dispose();
    brightnessNotifier.dispose();
  }
}
