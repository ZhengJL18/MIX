import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mix/theme/app_theme.dart';

void main() {
  test('Claude light card matches dsh-claude-style literals', () {
    final palette = buildClaudeTheme(isDark: false).extension<AppPalette>()!;
    expect(palette.primary, const Color(0xFFD97757));
    expect(palette.canvas, const Color(0xFFFFFFFF));
    expect(palette.sidebar, const Color(0xFFFAFAFA));
    expect(palette.bubble, const Color(0xFFF4F2F3));
    expect(palette.textPrimary, const Color(0xFF161616));
    expect(palette.border, const Color(0xFFE9E9E9));
    expect(palette.codeInk, const Color(0xFF943333));
    expect(palette.link, const Color(0xFF184F95));
  });

  test('Claude dark card avoids pure black', () {
    final palette = buildClaudeTheme(isDark: true).extension<AppPalette>()!;
    expect(palette.primary, const Color(0xFFD97757));
    expect(palette.canvas, const Color(0xFF191919));
    expect(palette.sidebar, const Color(0xFF1F1F1F));
    expect(palette.bubble, const Color(0x0FFFFFFF));
    expect(palette.textPrimary, const Color(0xFFFDFDFD));
    expect(palette.inset, const Color(0xFF141414));
    expect(palette.canvas, isNot(const Color(0xFF000000)));
    expect(palette.inset, isNot(const Color(0xFF000000)));
    expect(palette.sidebar, isNot(const Color(0xFF000000)));
  });

  test('retired theme ids fall back to the Claude card', () {
    expect(findTheme('teal').id, 'claude');
    expect(findTheme('claude').name, 'Claude');
    expect(builtinThemes, hasLength(1));
  });
}
