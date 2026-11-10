import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'printnotes/app.dart';
import 'printnotes/providers/customization_provider.dart'
    as printnotes;
import 'printnotes/providers/editor_config_provider.dart'
    as printnotes;
import 'printnotes/providers/navigation_provider.dart' as printnotes;
import 'printnotes/providers/selecting_provider.dart' as printnotes;
import 'printnotes/providers/settings_provider.dart' as printnotes;
import 'printnotes/providers/theme_provider.dart' as printnotes;
import 'printnotes/ui/screens/home/main_screen.dart' as printnotes;
import 'printnotes/ui/screens/editors/notes/note_editor.dart' as printnotes;

import 'agent/agent.dart';
import 'agent/company.dart';
import 'agent/context_compressor.dart';
import 'agent/workflow.dart';
import 'config/mix_config.dart';
import 'db/session_db.dart';
import 'llm/openai_llm.dart';
import 'notes/notes_paths.dart';
import 'refine/edit_journal.dart';
import 'refine/prompt_notes_store.dart';
import 'refine/refine_pipeline.dart';
import 'refine/trajectory_store.dart';
import 'screens/settings_screen.dart';
import 'services/chinese_segmenter.dart';
import 'services/debug_server.dart';
import 'services/goal_store.dart';
import 'services/memory_db.dart';
import 'services/memory_indexer.dart';
import 'services/memory_learning.dart';
import 'services/memory_profile.dart';
import 'services/memory_summarizer.dart';
import 'services/memory_tagger.dart';
import 'services/multi_agent.dart';
import 'services/notes_sync.dart';
import 'services/services.dart';
import 'services/storage_permission.dart';
import 'services/study_engine.dart';
import 'services/study_question_service.dart';
import 'services/update_service.dart';
import 'theme/theme_ext.dart';
import 'theme/theme_provider.dart';
import 'tools/clarify_tool.dart';
import 'tools/company_tool.dart';
import 'tools/context_retriever.dart';
import 'tools/cron_tools.dart';
import 'tools/delegate_tool.dart';
import 'tools/file_tools.dart';
import 'tools/git_tools.dart';
import 'tools/goal_tool.dart';
import 'tools/memory_manager.dart';
import 'tools/memory_search_tool.dart';
import 'tools/memory_tool.dart';
import 'tools/memory_verify_tool.dart';
import 'tools/moa_tool.dart';
import 'tools/model_tools.dart';
import 'tools/notes_tools.dart';
import 'tools/convert_tools.dart';
import 'tools/read_doc_tool.dart';
import 'tools/session_search_tool.dart';
import 'tools/skills_tool.dart';
import 'tools/study_status_tool.dart';
import 'tools/study_tools.dart';
import 'tools/todo_tool.dart';
import 'tools/vision_tool.dart';
import 'tools/web_tools.dart';
import 'widgets/markdown_math.dart';

import 'screens/chat_screen.dart';
/// 全局主题控制器（设置页/切换入口共用）。
ThemeController themeController = ThemeController();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  themeController.load();
  // printnotes 子系统需要 SharedPreferences 全局（App.localStorage）。
  // 不静默吞异常：迁移/初始化失败要打日志，便于排查。
  try {
    await App.init();
  } catch (e, st) {
    debugPrint('App.init failed: $e\n$st');
  }
  runApp(const MIXApp());
}

class MIXApp extends StatelessWidget {
  const MIXApp({super.key});

  @override
  Widget build(BuildContext context) {
    // printnotes 子系统用 provider 管理状态（主题/设置/导航/编辑器配置等）。
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => printnotes.ThemeProvider()),
        ChangeNotifierProvider(create: (_) => printnotes.SettingsProvider()),
        ChangeNotifierProvider(
            create: (_) => printnotes.NavigationProvider()),
        ChangeNotifierProvider(
            create: (_) => printnotes.EditorConfigProvider()),
        ChangeNotifierProvider(
            create: (_) => printnotes.SelectingProvider()),
        ChangeNotifierProvider(
            create: (_) => printnotes.CustomizationProvider()),
      ],
      // 监听主题 + 明暗，任一变化 → 整树 rebuild（ThemeExtension 全量替换）。
      child: ValueListenableBuilder(
        valueListenable: themeController.themeNotifier,
        builder: (context, theme, child) {
          return ValueListenableBuilder(
            valueListenable: themeController.brightnessNotifier,
            builder: (context, brightness, child) {
              return MaterialApp(
                title: 'MIX',
                theme: themeController.themeData,
                home: const ChatScreen(),
              );
            },
          );
        },
      ),
    );
  }
}