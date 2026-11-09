/// 主题扩展：`context.appPalette` 访问当前调色板。
library;

import 'package:flutter/material.dart';

import 'app_theme.dart';

extension AppThemeContext on BuildContext {
  /// 当前主题调色板（替代硬编码 Colors.x）。
  AppPalette get appPalette =>
      Theme.of(this).extension<AppPalette>() ?? _fallbackPalette;
}

/// 兜底调色板（理论上不会用到，extension 缺失时保底为 Claude 浅色）。
final AppPalette _fallbackPalette = claudePalette(ClaudeTokens.light);
