/// Central service container — replaces scattered global nullable singletons.
///
/// All services are registered here during `_ChatScreenState._initCwd`.
/// After [ready] is true, all services that successfully initialized are
/// available via [Services.instance]. This is the single source of truth —
/// no more bare `Foo? globalFoo` variables scattered across tool files.
///
/// Pure Dart, no external DI framework (GetIt etc.) per project convention.
library;

import '../db/session_db.dart';
import '../tools/cron_tools.dart' show CronJob;
import '../refine/edit_journal.dart';
import '../refine/prompt_notes_store.dart';
import '../refine/refine_pipeline.dart';
import '../refine/trajectory_store.dart';
import '../skills/skill_discovery.dart';
import '../tools/memory_manager.dart';
import '../tools/memory_tool.dart';
import 'debug_server.dart';
import 'goal_store.dart';
import 'memory_db.dart';
import 'memory_indexer.dart';
import 'memory_learning.dart';
import 'memory_profile.dart';
import 'memory_summarizer.dart';
import 'memory_tagger.dart';
import 'notes_sync.dart';
import 'study_engine.dart';
import 'study_question_service.dart';

// ------------------------------------------------------------------
// Handler / provider / hook typedefs
// ------------------------------------------------------------------

/// P1 记忆索引钩子：memory 工具写入成功后异步触发自动标签/知识点边索引。
typedef MemoryIndexHook = Future<void> Function(
    Map<String, dynamic> args, String result);

/// UI 注册的澄清回调：给定问题、选项与可选正确答案，返回用户答案。
typedef ClarifyHandler = Future<String> Function(
    String question, List<String> choices, bool multiSelect, String? answer);

/// 多代理讨论执行器。
typedef MoaHandler = Future<String> Function(String topic, int rounds);

/// 部门执行器：给定部门+任务，部门内角色分工执行。
typedef DepartmentHandler = Future<String> Function(
    String department, String task, int depth);

/// 子 agent 执行回调：给定任务，返回子 agent 的结果。
typedef DelegateHandler = Future<String> Function(
    String task, List<String>? toolsets, int depth);

/// 出题执行器（多阶段管线）：给定科目/知识点，返回题目 JSON。
typedef StudyQuestionHandler = Future<String> Function(
  int kpId, {
  String? targetDifficulty,
});

/// 知识点列表执行器：返回可用科目/知识点（带掌握度）。
typedef StudyListHandler = Future<String> Function();

/// 画像更新执行器：把本次作答观察写进学生画像。
typedef StudyProfileUpdateHandler = Future<String> Function(String note);

/// 作答记录执行器：把判题结果写入 practice_records。
typedef StudyRecordHandler = Future<String> Function({
  required int questionId,
  required bool correct,
  String? mainCause,
  String? minorCause,
});

/// 批量题卡执行器：把题目 JSON 交给 UI 渲染成可滑动题卡。
typedef StudyQuizHandler = Future<String> Function(
  List<Map<String, dynamic>> questions, {
  required bool grade,
  bool updateProfile,
  String? topic,
});

/// 全局服务容器（单例）。
///
/// 使用方式：
/// - 初始化阶段：`Services.instance.memoryDb = md;`
/// - 读取阶段：`final md = Services.instance.memoryDb;`（可能为 null，
///   和旧全局变量语义一致；Step 2 迁移完成后改为非空 getter + fooOrNull）。
class Services {
  Services._();
  static final Services instance = Services._();

  // ------------------------------------------------------------------
  // 就绪标志：_initCwd 完成后置 true。cron 调度器必须在 ready 之后启动，
  // 否则定时任务触发时服务可能未初始化（启动竞态根因）。
  // ------------------------------------------------------------------
  bool _ready = false;
  bool get ready => _ready;
  void markReady() => _ready = true;

  // === 核心服务 ===

  MemoryDB? _memoryDb;
  MemoryDB? get memoryDb => _memoryDb;
  set memoryDb(MemoryDB? v) => _memoryDb = v;

  MemoryStore? _memoryStore;
  MemoryStore? get memoryStore => _memoryStore;
  set memoryStore(MemoryStore? v) => _memoryStore = v;

  SessionDB? _sessionDb;
  SessionDB? get sessionDb => _sessionDb;
  set sessionDb(SessionDB? v) => _sessionDb = v;

  SkillDiscovery? _skillDiscovery;
  SkillDiscovery? get skillDiscovery => _skillDiscovery;
  set skillDiscovery(SkillDiscovery? v) => _skillDiscovery = v;

  GoalStore? _goalStore;
  GoalStore? get goalStore => _goalStore;
  set goalStore(GoalStore? v) => _goalStore = v;

  // === 记忆子系统 ===

  MemoryManager? _memoryManager;
  MemoryManager? get memoryManager => _memoryManager;
  set memoryManager(MemoryManager? v) => _memoryManager = v;

  MemoryTagger? _memoryTagger;
  MemoryTagger? get memoryTagger => _memoryTagger;
  set memoryTagger(MemoryTagger? v) => _memoryTagger = v;

  MemoryIndexer? _memoryIndexer;
  MemoryIndexer? get memoryIndexer => _memoryIndexer;
  set memoryIndexer(MemoryIndexer? v) => _memoryIndexer = v;

  MemorySummarizer? _memorySummarizer;
  MemorySummarizer? get memorySummarizer => _memorySummarizer;
  set memorySummarizer(MemorySummarizer? v) => _memorySummarizer = v;

  MemoryLearning? _memoryLearning;
  MemoryLearning? get memoryLearning => _memoryLearning;
  set memoryLearning(MemoryLearning? v) => _memoryLearning = v;

  MemoryProfileProjector? _memoryProfile;
  MemoryProfileProjector? get memoryProfile => _memoryProfile;
  set memoryProfile(MemoryProfileProjector? v) => _memoryProfile = v;

  // === 笔记 ===

  NotesSyncService? _notesSync;
  NotesSyncService? get notesSync => _notesSync;
  set notesSync(NotesSyncService? v) => _notesSync = v;

  // === 学习 ===

  StudyEngine? _studyEngine;
  StudyEngine? get studyEngine => _studyEngine;
  set studyEngine(StudyEngine? v) => _studyEngine = v;

  StudyQuestionService? _studyQuestionService;
  StudyQuestionService? get studyQuestionService => _studyQuestionService;
  set studyQuestionService(StudyQuestionService? v) => _studyQuestionService = v;

  // === 调试 ===

  DebugServer? _debugServer;
  DebugServer? get debugServer => _debugServer;
  set debugServer(DebugServer? v) => _debugServer = v;

  // === 自进化（Continual Harness）===

  TrajectoryStore? _trajectory;
  TrajectoryStore? get trajectory => _trajectory;
  set trajectory(TrajectoryStore? v) => _trajectory = v;

  PromptNotesStore? _promptNotes;
  PromptNotesStore? get promptNotes => _promptNotes;
  set promptNotes(PromptNotesStore? v) => _promptNotes = v;

  EditJournal? _editJournal;
  EditJournal? get editJournal => _editJournal;
  set editJournal(EditJournal? v) => _editJournal = v;

  RefinePipeline? _refine;
  RefinePipeline? get refine => _refine;
  set refine(RefinePipeline? v) => _refine = v;

  // === 跨文件全局可空单例（Step 2 迁移）===

  /// 异步委派用的记忆库（async_delegations 表）。
  MemoryDB? _delegateDb;
  MemoryDB? get delegateDb => _delegateDb;
  set delegateDb(MemoryDB? v) => _delegateDb = v;

  /// P1 记忆索引钩子（memory 工具写入后异步触发）。
  MemoryIndexHook? _memoryIndexHook;
  MemoryIndexHook? get memoryIndexHook => _memoryIndexHook;
  set memoryIndexHook(MemoryIndexHook? v) => _memoryIndexHook = v;

  /// 最近一次 notes_write 成功写入的笔记绝对路径。
  String? _lastWrittenNotePath;
  String? get lastWrittenNotePath => _lastWrittenNotePath;
  set lastWrittenNotePath(String? v) => _lastWrittenNotePath = v;

  // === UI 注册的 handler / provider ===

  ClarifyHandler? _clarifyHandler;
  ClarifyHandler? get clarifyHandler => _clarifyHandler;
  set clarifyHandler(ClarifyHandler? v) => _clarifyHandler = v;

  MoaHandler? _moaHandler;
  MoaHandler? get moaHandler => _moaHandler;
  set moaHandler(MoaHandler? v) => _moaHandler = v;

  DepartmentHandler? _departmentHandler;
  DepartmentHandler? get departmentHandler => _departmentHandler;
  set departmentHandler(DepartmentHandler? v) => _departmentHandler = v;

  DelegateHandler? _delegateHandler;
  DelegateHandler? get delegateHandler => _delegateHandler;
  set delegateHandler(DelegateHandler? v) => _delegateHandler = v;

  StudyQuestionHandler? _studyQuestionHandler;
  StudyQuestionHandler? get studyQuestionHandler => _studyQuestionHandler;
  set studyQuestionHandler(StudyQuestionHandler? v) => _studyQuestionHandler = v;

  StudyListHandler? _studyListHandler;
  StudyListHandler? get studyListHandler => _studyListHandler;
  set studyListHandler(StudyListHandler? v) => _studyListHandler = v;

  StudyProfileUpdateHandler? _studyProfileUpdateHandler;
  StudyProfileUpdateHandler? get studyProfileUpdateHandler =>
      _studyProfileUpdateHandler;
  set studyProfileUpdateHandler(StudyProfileUpdateHandler? v) =>
      _studyProfileUpdateHandler = v;

  StudyRecordHandler? _studyRecordHandler;
  StudyRecordHandler? get studyRecordHandler => _studyRecordHandler;
  set studyRecordHandler(StudyRecordHandler? v) => _studyRecordHandler = v;

  StudyQuizHandler? _studyQuizHandler;
  StudyQuizHandler? get studyQuizHandler => _studyQuizHandler;
  set studyQuizHandler(StudyQuizHandler? v) => _studyQuizHandler = v;

  /// P3 技能目录注入 provider。
  String Function()? _skillCatalogProvider;
  String Function()? get skillCatalogProvider => _skillCatalogProvider;
  set skillCatalogProvider(String Function()? v) => _skillCatalogProvider = v;

  /// P3 Goal 自动续跑 provider。
  String Function()? _goalCatalogProvider;
  String Function()? get goalCatalogProvider => _goalCatalogProvider;
  set goalCatalogProvider(String Function()? v) => _goalCatalogProvider = v;

  /// cron 定时任务触发回调：UI 注册，把 cron 任务交给 agent 执行。
  Future<void> Function(CronJob job)? _cronFireHandler;
  Future<void> Function(CronJob job)? get cronFireHandler => _cronFireHandler;
  set cronFireHandler(Future<void> Function(CronJob job)? v) => _cronFireHandler = v;

  /// 对话历史页「继续聊天」回调：切换 ChatScreen 到指定会话。
  /// 由 ChatScreen 注册，HistoryScreen 调用。
  Future<void> Function(String sessionId)? _resumeSessionHandler;
  Future<void> Function(String sessionId)? get resumeSessionHandler =>
      _resumeSessionHandler;
  set resumeSessionHandler(Future<void> Function(String sessionId)? v) =>
      _resumeSessionHandler = v;

  /// 「检查更新」回调：由 ChatScreen 注册，设置页调用。
  Future<void> Function()? _checkUpdateHandler;
  Future<void> Function()? get checkUpdateHandler => _checkUpdateHandler;
  set checkUpdateHandler(Future<void> Function()? v) => _checkUpdateHandler = v;
}
