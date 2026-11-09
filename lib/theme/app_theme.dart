/// 主题系统：Claude 色卡（dsh-claude-style）+ 明暗。
///
/// 色值取自 dsh-claude-style 的 **claude** 卡（不是 deepseek 卡，也不是
/// Anthropic 官方客户端）。强调色只留给发送、选中和主按钮，画布保持暖中性，
/// 深色不用纯黑。
///
/// 用 ThemeExtension 让配色自动继承到所有 context（`context.appPalette`）。
library;

import 'package:flutter/material.dart';

/// dsh-claude-style Claude 卡的已解析色值。明暗各一套字面量，运行时不再推导。
@immutable
class ClaudeTokens {
  final Color accent;
  final Color accentHover;
  final Color accentTint;
  final Color onAccent;
  final Color canvas;
  final Color surface1;
  final Color surface2;
  final Color surface3;
  final Color overlay;
  final Color sidebar;
  final Color card;
  final Color bubble;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color ink4;
  final Color border1;
  final Color border2;
  final Color divider;
  final Color hoverPlate;
  final Color codeInk;
  final Color link;
  final Color inset;
  final Color inverseFill;
  final Color inverseInk;
  final Color success;
  final Color danger;
  final Color scrollbar;

  const ClaudeTokens({
    required this.accent,
    required this.accentHover,
    required this.accentTint,
    required this.onAccent,
    required this.canvas,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.overlay,
    required this.sidebar,
    required this.card,
    required this.bubble,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.ink4,
    required this.border1,
    required this.border2,
    required this.divider,
    required this.hoverPlate,
    required this.codeInk,
    required this.link,
    required this.inset,
    required this.inverseFill,
    required this.inverseInk,
    required this.success,
    required this.danger,
    required this.scrollbar,
  });

  /// Claude 浅色：白画布、`#fafafa` 侧栏、`#f4f2f3` 读者气泡。
  static const light = ClaudeTokens(
    accent: Color(0xFFD97757),
    accentHover: Color(0xFFC46343),
    accentTint: Color(0xFFF6DED7),
    onAccent: Color(0xFFFFFFFF),
    canvas: Color(0xFFFFFFFF),
    surface1: Color(0xFFFFFFFF),
    surface2: Color(0xFFFFFFFF),
    surface3: Color(0xFFFFFFFF),
    overlay: Color(0xFFFFFFFF),
    sidebar: Color(0xFFFAFAFA),
    card: Color(0xFFFFFFFF),
    bubble: Color(0xFFF4F2F3),
    ink: Color(0xFF161616),
    ink2: Color(0xFF70686A),
    ink3: Color(0xFF91888A),
    ink4: Color(0xFFB2ACAD),
    border1: Color(0xFFE9E9E9),
    border2: Color(0xFFDEDEDE),
    divider: Color(0x0D161616),
    hoverPlate: Color(0xFFF4F4F4),
    codeInk: Color(0xFF943333),
    link: Color(0xFF184F95),
    inset: Color(0xFFFFFFFF),
    inverseFill: Color(0xFF161616),
    inverseInk: Color(0xFFFFFFFF),
    success: Color(0xFF3D7550),
    danger: Color(0xFF9C3B32),
    scrollbar: Color(0xE6D5D5D5),
  );

  /// Claude 深色：`#191919` 画布、`#1f1f1f` 侧栏、6% 白气泡。描边是高光，不是纯黑轮廓。
  static const dark = ClaudeTokens(
    accent: Color(0xFFD97757),
    accentHover: Color(0xFFEB9170),
    accentTint: Color(0xFF48261B),
    onAccent: Color(0xFFFBFBFB),
    canvas: Color(0xFF191919),
    surface1: Color(0xFF212121),
    surface2: Color(0xFF282828),
    surface3: Color(0xFF323232),
    overlay: Color(0xFF282828),
    sidebar: Color(0xFF1F1F1F),
    card: Color(0xFF232323),
    bubble: Color(0x0FFFFFFF),
    ink: Color(0xFFFDFDFD),
    ink2: Color(0xFFBEB6B8),
    ink3: Color(0xFF9C9395),
    ink4: Color(0xFF776F71),
    border1: Color(0x17FFFFFF),
    border2: Color(0x2EFFFFFF),
    divider: Color(0x0FFFFFFF),
    hoverPlate: Color(0xFF323232),
    codeInk: Color(0xFFE8A08A),
    link: Color(0xFF8AB4F8),
    inset: Color(0xFF141414),
    inverseFill: Color(0xFFFDFDFD),
    inverseInk: Color(0xFF171717),
    success: Color(0xFF8CBF96),
    danger: Color(0xFFE7A198),
    scrollbar: Color(0xE63E3E3E),
  );
}

/// 应用调色板：一套完整配色（替代各处硬编码 Colors.x）。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  final Color primary; // 陶土强调色（发送 / 选中 / 主按钮）
  final Color onPrimary; // 强调色上的文字
  final Color primaryContainer; // 强调色浅底
  final Color onPrimaryContainer;
  final Color surface; // 画布
  final Color surfaceVariant; // 侧栏 / 次要表面
  final Color textPrimary; // 主要文本
  final Color textSecondary; // 次要文本
  final Color success; // 成功
  final Color danger; // 危险 / 删除
  final Color accent; // 链接蓝（非品牌强调，避免第二块橙色）
  final Color border; // 标准描边（border-1）
  final Color canvas;
  final Color sidebar;
  final Color bubble;
  final Color inkTertiary;
  final Color codeInk;
  final Color link;
  final Color hover;
  final Color inset;
  final Color accentHover;

  const AppPalette({
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.surface,
    required this.surfaceVariant,
    required this.textPrimary,
    required this.textSecondary,
    required this.success,
    required this.danger,
    required this.accent,
    required this.border,
    required this.canvas,
    required this.sidebar,
    required this.bubble,
    required this.inkTertiary,
    required this.codeInk,
    required this.link,
    required this.hover,
    required this.inset,
    required this.accentHover,
  });

  @override
  AppPalette copyWith({
    Color? primary,
    Color? onPrimary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? surface,
    Color? surfaceVariant,
    Color? textPrimary,
    Color? textSecondary,
    Color? success,
    Color? danger,
    Color? accent,
    Color? border,
    Color? canvas,
    Color? sidebar,
    Color? bubble,
    Color? inkTertiary,
    Color? codeInk,
    Color? link,
    Color? hover,
    Color? inset,
    Color? accentHover,
  }) {
    return AppPalette(
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      primaryContainer: primaryContainer ?? this.primaryContainer,
      onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
      surface: surface ?? this.surface,
      surfaceVariant: surfaceVariant ?? this.surfaceVariant,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      success: success ?? this.success,
      danger: danger ?? this.danger,
      accent: accent ?? this.accent,
      border: border ?? this.border,
      canvas: canvas ?? this.canvas,
      sidebar: sidebar ?? this.sidebar,
      bubble: bubble ?? this.bubble,
      inkTertiary: inkTertiary ?? this.inkTertiary,
      codeInk: codeInk ?? this.codeInk,
      link: link ?? this.link,
      hover: hover ?? this.hover,
      inset: inset ?? this.inset,
      accentHover: accentHover ?? this.accentHover,
    );
  }

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      primaryContainer:
          Color.lerp(primaryContainer, other.primaryContainer, t)!,
      onPrimaryContainer:
          Color.lerp(onPrimaryContainer, other.onPrimaryContainer, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceVariant: Color.lerp(surfaceVariant, other.surfaceVariant, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      success: Color.lerp(success, other.success, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      border: Color.lerp(border, other.border, t)!,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      bubble: Color.lerp(bubble, other.bubble, t)!,
      inkTertiary: Color.lerp(inkTertiary, other.inkTertiary, t)!,
      codeInk: Color.lerp(codeInk, other.codeInk, t)!,
      link: Color.lerp(link, other.link, t)!,
      hover: Color.lerp(hover, other.hover, t)!,
      inset: Color.lerp(inset, other.inset, t)!,
      accentHover: Color.lerp(accentHover, other.accentHover, t)!,
    );
  }
}

/// Claude 卡 → [AppPalette]。深色气泡保持半透明，叠在画布上才是 token 里的那一层。
AppPalette claudePalette(ClaudeTokens c) {
  return AppPalette(
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: c.accentTint,
    onPrimaryContainer: c.ink,
    surface: c.canvas,
    surfaceVariant: c.sidebar,
    textPrimary: c.ink,
    textSecondary: c.ink2,
    success: c.success,
    danger: c.danger,
    accent: c.link,
    border: c.border1,
    canvas: c.canvas,
    sidebar: c.sidebar,
    bubble: c.bubble,
    inkTertiary: c.ink3,
    codeInk: c.codeInk,
    link: c.link,
    hover: c.hoverPlate,
    inset: c.inset,
    accentHover: c.accentHover,
  );
}

/// 一套完整主题（亮 + 暗）。种子色只用于设置页色点，真正的 ThemeData 走 Claude 字面量。
class AppThemeSpec {
  final String id;
  final String name;
  final Color lightSeed;
  final Color darkSeed;

  const AppThemeSpec({
    required this.id,
    required this.name,
    required this.lightSeed,
    required this.darkSeed,
  });

  ThemeData lightTheme() => buildClaudeTheme(isDark: false);
  ThemeData darkTheme() => buildClaudeTheme(isDark: true);
}

/// 由 Claude 色卡构建 ThemeData。强调色是 primary；大面积表面保持中性。
ThemeData buildClaudeTheme({required bool isDark}) {
  final c = isDark ? ClaudeTokens.dark : ClaudeTokens.light;
  final palette = claudePalette(c);
  final scheme = ColorScheme(
    brightness: isDark ? Brightness.dark : Brightness.light,
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: c.accentTint,
    onPrimaryContainer: c.ink,
    secondary: c.ink2,
    onSecondary: c.canvas,
    secondaryContainer: c.hoverPlate,
    onSecondaryContainer: c.ink,
    tertiary: c.link,
    onTertiary: const Color(0xFFFFFFFF),
    tertiaryContainer: c.sidebar,
    onTertiaryContainer: c.ink,
    error: c.danger,
    onError: c.onAccent,
    errorContainer: c.danger.withValues(alpha: 0.14),
    onErrorContainer: c.ink,
    surface: c.canvas,
    onSurface: c.ink,
    onSurfaceVariant: c.ink2,
    outline: c.border2,
    outlineVariant: c.border1,
    shadow: const Color(0x1A141413),
    scrim: const Color(0x73141413),
    inverseSurface: c.inverseFill,
    onInverseSurface: c.inverseInk,
    inversePrimary: c.accentHover,
    surfaceTint: const Color(0x00000000),
    surfaceContainerLowest: c.inset,
    surfaceContainerLow: c.sidebar,
    surfaceContainer: c.surface1,
    surfaceContainerHigh: c.surface2,
    surfaceContainerHighest: c.hoverPlate,
  );

  final radius12 = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
    side: BorderSide(color: c.border1),
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: c.canvas,
    dividerColor: c.border1,
    splashColor: c.accent.withValues(alpha: 0.08),
    highlightColor: c.hoverPlate.withValues(alpha: isDark ? 0.4 : 0.8),
  );

  return base.copyWith(
    extensions: [palette],
    appBarTheme: AppBarTheme(
      backgroundColor: c.canvas,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: const Color(0x00000000),
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: c.ink,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      iconTheme: IconThemeData(color: c.ink2),
      actionsIconTheme: IconThemeData(color: c.ink2),
    ),
    cardTheme: CardThemeData(
      color: c.card,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: radius12,
      surfaceTintColor: const Color(0x00000000),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? c.card : c.canvas,
      surfaceTintColor: const Color(0x00000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.border1),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: isDark ? c.overlay : c.canvas,
      surfaceTintColor: const Color(0x00000000),
      shape: radius12,
      textStyle: TextStyle(color: c.ink, fontSize: 14),
    ),
    dividerTheme: DividerThemeData(
      color: c.divider,
      thickness: 0.5,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? c.inset : c.canvas,
      hintStyle: TextStyle(color: c.ink3),
      labelStyle: TextStyle(color: c.ink2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.border1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.border1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.danger),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        disabledBackgroundColor: c.hoverPlate,
        disabledForegroundColor: c.ink3,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        side: BorderSide(color: c.border2),
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.ink2),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.ink2),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return c.onAccent;
        return c.ink4;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return c.accent;
        return c.hoverPlate;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return c.accent;
        return c.border2;
      }),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.border1,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.accent,
      thumbColor: c.accent,
      inactiveTrackColor: c.border2,
      overlayColor: c.accent.withValues(alpha: 0.12),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return c.accent;
        return const Color(0x00000000);
      }),
      checkColor: WidgetStateProperty.all(c.onAccent),
      side: BorderSide(color: c.border2, width: 1.4),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return c.accent;
        return c.ink3;
      }),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.ink2,
      textColor: c.ink,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.inverseFill,
      contentTextStyle: TextStyle(color: c.inverseInk),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.inverseFill,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: c.inverseInk, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(c.scrollbar),
      radius: const Radius.circular(8),
      thickness: WidgetStateProperty.all(4),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isDark ? c.card : c.canvas,
      surfaceTintColor: const Color(0x00000000),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: c.ink,
      unselectedLabelColor: c.ink3,
      indicatorColor: c.accent,
      dividerColor: c.divider,
      indicatorSize: TabBarIndicatorSize.label,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: c.ink,
      displayColor: c.ink,
    ),
  );
}

/// 内置主题。只有 Claude 色卡：明暗由 [ThemeController] 切换，不再提供另一套品牌色。
const List<AppThemeSpec> builtinThemes = [
  AppThemeSpec(
    id: 'claude',
    name: 'Claude',
    lightSeed: Color(0xFFD97757),
    darkSeed: Color(0xFFD97757),
  ),
];

AppThemeSpec findTheme(String id) {
  for (final t in builtinThemes) {
    if (t.id == id) return t;
  }
  // 旧的青绿 / 靛蓝等 id 一律回到 Claude 色卡。
  return builtinThemes.first;
}
