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
}
