// printnotes 的 App 类适配：原 printnotes main.dart 里的 `App.localStorage`
// （SharedPreferences 全局静态）。printnotes 的 utils/configs/*.dart 依赖它，
// 这里提供等价物，避免引入 printnotes 完整 main.dart。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'utils/configs/data_path.dart';

class App {
  App._();

  static late SharedPreferences localStorage;

  /// 初始化 localStorage + 确保笔记库根目录存在（documents/notes）。
  /// 笔记根固定由 DataPath 提供，与 agent 的 notes_* 工具共用。
  static Future<void> init() async {
    localStorage = await SharedPreferences.getInstance();
    await _migrateLegacyPrefs();
    await DataPath.selectedDirectory;
  }

  /// 一次性迁移 printnotes 旧版默认值。
  ///
  /// 背景：printnotes 原版默认 useLatex=false（公式原样显示为 $...$）、
  /// layoutView=grid（手机双列网格，用户明确嫌"渗人"）。之前只改了
  /// SettingsProvider 的代码默认值（true / 'list'），但 loadSettings()
  /// 启动时会用 SharedPreferences 里已持久化的旧值覆盖代码默认值，
  /// 导致怎么改默认值都不生效。这里在 App 启动最早阶段直接纠正存储，
  /// 用版本标记保证只迁移一次，不干扰用户之后的手动设置。
  static const _legacyMigratedKey = 'mix_settings_migrated_v1';

  static Future<void> _migrateLegacyPrefs() async {
    final prefs = localStorage;
    if (prefs.getBool(_legacyMigratedKey) ?? false) return;
    // LaTeX 公式渲染：旧版默认关闭 → 打开。
    if (prefs.getBool('useLatex') == false) {
      await prefs.setBool('useLatex', true);
    }
    // 布局：旧版默认双列网格 → 单列列表。
    if (prefs.getString('layoutView') == 'grid') {
      await prefs.setString('layoutView', 'list');
    }
    await prefs.setBool(_legacyMigratedKey, true);
  }
}
