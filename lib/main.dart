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
import 'screens/file_browser_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/theme_screen.dart';
import 'services/multi_agent.dart';
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
import 'tools/memory_manager.dart';
import 'tools/memory_tool.dart';
import 'tools/moa_tool.dart';
import 'tools/model_tools.dart';
import 'tools/notes_tools.dart';
import 'tools/pdf_extract_tool.dart';
import 'tools/session_search_tool.dart';
import 'tools/skills_tool.dart';
import 'tools/study_tools.dart';
import 'tools/todo_tool.dart';
import 'tools/vision_tool.dart';
import 'tools/web_tools.dart';
import 'widgets/markdown_math.dart';

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

/// 对话历史页「继续聊天」回调：切换 ChatScreen 到指定会话。
/// 由 ChatScreen 注册，HistoryScreen 调用。
Future<void> Function(String sessionId)? resumeSessionHandler;

/// 「检查更新」回调：由 ChatScreen 注册，设置页调用。
Future<void> Function()? checkUpdateHandler;

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

/// 单条对话消息。
class _ChatMessage {
  final String role; // user / assistant / tool / discussion / refine
  final String? text;
  final String? toolName;
  final String? toolStatus;
  // discussion 专用：进度/分工展示。
  final bool discussionRunning;
  final int? discussionRound;
  final int? discussionTotalRounds;
  final String? discussionPerspective;
  final List<(String, String)> discussionPerspectives; // 每视角最终发言。
  final String? discussionSummary;
  // refine 专用：自进化建议卡。
  final List<RefineProposal> refineProposals;
  final bool refineApplied;
  final bool refineIgnored;
  // study 专用：题目卡。
  final int? studyQuestionId;
  final String? studyQuestion;
  final List<String> studyOptions;
  final String? studyAnswer; // 正确答案（机械判用）。
  final String? studyExplanation;
  final bool? studyCorrect; // 机械判结果。

  _ChatMessage.user(this.text)
      : role = 'user',
        toolName = null,
        toolStatus = null,
        discussionRunning = false,
        discussionRound = null,
        discussionTotalRounds = null,
        discussionPerspective = null,
        discussionPerspectives = const [],
        discussionSummary = null,
        refineProposals = const [],
        refineApplied = false,
        refineIgnored = false,
        studyQuestionId = null,
        studyQuestion = null,
        studyOptions = const [],
        studyAnswer = null,
        studyExplanation = null,
        studyCorrect = null;
  _ChatMessage.assistant(this.text)
      : role = 'assistant',
        toolName = null,
        toolStatus = null,
        discussionRunning = false,
        discussionRound = null,
        discussionTotalRounds = null,
        discussionPerspective = null,
        discussionPerspectives = const [],
        discussionSummary = null,
        refineProposals = const [],
        refineApplied = false,
        refineIgnored = false,
        studyQuestionId = null,
        studyQuestion = null,
        studyOptions = const [],
        studyAnswer = null,
        studyExplanation = null,
        studyCorrect = null;
  _ChatMessage.tool(this.toolName, this.toolStatus)
      : role = 'tool',
        text = null,
        discussionRunning = false,
        discussionRound = null,
        discussionTotalRounds = null,
        discussionPerspective = null,
        discussionPerspectives = const [],
        discussionSummary = null,
        refineProposals = const [],
        refineApplied = false,
        refineIgnored = false,
        studyQuestionId = null,
        studyQuestion = null,
        studyOptions = const [],
        studyAnswer = null,
        studyExplanation = null,
        studyCorrect = null;
  _ChatMessage.discussion({
    required this.discussionRunning,
    this.discussionRound,
    this.discussionTotalRounds,
    this.discussionPerspective,
    this.discussionPerspectives = const [],
    this.discussionSummary,
  })  : role = 'discussion',
        text = null,
        toolName = null,
        toolStatus = null,
        refineProposals = const [],
        refineApplied = false,
        refineIgnored = false,
        studyQuestionId = null,
        studyQuestion = null,
        studyOptions = const [],
        studyAnswer = null,
        studyExplanation = null,
        studyCorrect = null;
  _ChatMessage.refine({
    required this.refineProposals,
    this.refineApplied = false,
    this.refineIgnored = false,
  })  : role = 'refine',
        text = null,
        toolName = null,
        toolStatus = null,
        discussionRunning = false,
        discussionRound = null,
        discussionTotalRounds = null,
        discussionPerspective = null,
        discussionPerspectives = const [],
        discussionSummary = null,
        studyQuestionId = null,
        studyQuestion = null,
        studyOptions = const [],
        studyAnswer = null,
        studyExplanation = null,
        studyCorrect = null;
  _ChatMessage.reasoning(this.text)
      : role = 'reasoning',
        toolName = null,
        toolStatus = null,
        discussionRunning = false,
        discussionRound = null,
        discussionTotalRounds = null,
        discussionPerspective = null,
        discussionPerspectives = const [],
        discussionSummary = null,
        refineProposals = const [],
        refineApplied = false,
        refineIgnored = false,
        studyQuestionId = null,
        studyQuestion = null,
        studyOptions = const [],
        studyAnswer = null,
        studyExplanation = null,
        studyCorrect = null;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  // 工具名 → 当前 running 卡片的消息索引（done 时更新而非新增）。
  final Map<String, int> _toolRunningIdx = {};
  bool _running = false;
  // 是否显示"回到底部"悬浮按钮（用户上滑离开底部时浮现）。
  bool _showScrollToBottom = false;
  /// 最后一条消息的 Key：可见性 = 视口底部是否已是最新消息。
  final GlobalKey _lastMessageKey = GlobalKey();
  bool _planMode = false; // Claude Code 式 plan 模式：先出计划，批准后执行。
  String? _pendingPlan; // 待批准的计划。
  String? _pendingTask; // 待执行的任务原文（批准计划后执行用）。
  String _workflowId = 'daily'; // 当前工作流（AgentWorkflow）。
  MIXAgent? _activeAgent;
  MultiAgentService? _multiAgent;
  int _discussionMsgIdx = -1; // 当前讨论消息索引（-1 表示无）。
  final Map<String, String> _lastPerspectiveOutputs = {}; // 视角 → 最终发言。
  int _reasoningMsgIdx = -1; // 当前"思考中"块索引（-1 表示无）。
  MemoryManager? _memory;
  SessionDB? _sessionDb;
  String? _currentSessionId;
  // 加载代际：每次加载递增，返回时若代际过期则丢弃结果（防并发加载串记录）。
  int _loadGen = 0;
  static const _lastSessionKey = 'last_session_id';

  /// 读取上次活动会话 id（无则 'main'），跨重启恢复到它而不是写死 'main'。
  Future<String> _loadLastSessionId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_lastSessionKey) ?? 'main';
    } catch (_) {
      return 'main';
    }
  }

  /// 记录当前活动会话（新建/切换/恢复时写，fire-and-forget 不阻塞 UI）。
  Future<void> _saveLastSessionId(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastSessionKey, id);
    } catch (_) {}
  }
  // 自进化（Continual Harness）存储。
  TrajectoryStore? _trajectory;
  PromptNotesStore? _promptNotes;
  EditJournal? _editJournal;
  RefinePipeline? _refine;
  bool _refineSuggesting = false;
  // 学习模式。
  StudyEngine? _studyEngine;
  StudyQuestionService? _studyQuestionService;
  final Map<String, String> _studyChoices = {}; // 题 key → 用户选项（key 兼容无 question_id 的题）。
  // 思考强度：聊天回答流程用滑块值(0-100)，各内部流程在设置里独立配置。
  int _chatEffort = 50;

  /// 聊天流程的 reasoning_effort 字符串（构造 LLM 时用）。
  String get _chatEffortKey => MIXConfig.effortValueToKey(_chatEffort);

  /// 停止当前生成（ESC / 停止按钮）。
  void _stop() {
    _activeAgent?.cancel();
    // 停在思考阶段（只流了 reasoning 无 content）时，移除残留的思考块，
    // 否则灰色"思考中…"永久卡在对话里。
    setState(() {
      if (_reasoningMsgIdx >= 0 && _reasoningMsgIdx < _messages.length) {
        _messages.removeAt(_reasoningMsgIdx);
        for (final k in _toolRunningIdx.keys.toList()) {
          final v = _toolRunningIdx[k];
          if (v != null && v > _reasoningMsgIdx) _toolRunningIdx[k] = v - 1;
        }
        _reasoningMsgIdx = -1;
      }
    });
  }

  /// 深链：打开 agent 刚写入的笔记（复用 printnotes 编辑器）。
  void _openNote(String? notePath) {
    if (notePath == null || notePath.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => printnotes.NoteEditorScreen(fileUri: File(notePath).uri),
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onChatScroll);
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    initConfig();
    _scrollController.addListener(_onChatScroll);
    registerFileTools();
    registerWebTools();
    registerTodoTool();
    registerSessionSearchTool();
    registerGitTools();
    registerClarifyTool();
    clarifyHandler = _showClarifyDialog;
    registerDelegateTool();
    delegateHandler = (task, toolsets, depth) async {
      final svc = await _ensureMultiAgent();
      if (svc == null) return '子任务未执行：AI 未配置';
      return svc.runSubAgent(
        task: task,
        toolsets: toolsets,
        depth: depth,
        onToolEvent: _onSubAgentToolEvent,
      );
    };
    registerMoaTool();
    moaHandler = (topic, rounds) async {
      final svc = await _ensureMultiAgent();
      if (svc == null) return '讨论未执行：AI 未配置';
      return svc.runDiscussion(
        topic: topic,
        rounds: rounds,
        onProgress: _onMoaProgress,
      );
    };
    registerCompanyTool();
    departmentHandler = (department, task, depth) async {
      final svc = await _ensureMultiAgent();
      if (svc == null) return '部门任务未执行：AI 未配置';
      return svc.runDepartment(
        department: department,
        task: task,
        depth: depth,
        onToolEvent: _onSubAgentToolEvent,
      );
    };
    registerCronTools();
    cronFireHandler = _fireCronJob;
    startCronScheduler();
    registerVisionTool();
    registerStudyTools();
    registerNotesTools();
    registerPdfExtractTool();
    studyListHandler = _studyList;
    studyQuestionHandler = _studyQuestion;
    studyProfileUpdateHandler = _studyProfileUpdate;
    // 对话历史页「继续聊天」→ 切换到指定会话并加载历史。
    resumeSessionHandler = _resumeSession;
    // 设置页「检查更新」→ 复用聊天页的检查逻辑。
    checkUpdateHandler = _checkForUpdateManually;
    // 加载持久化的聊天思考强度（默认中档）。
    MIXConfig.loadEffort('chat').then((effort) {
      if (mounted) setState(() => _chatEffort = effort);
    });
    final init = _initCwd();
    // 会话库就绪后，把当前会话历史恢复进 UI（重启 App 不再空白丢上下文）。
    init.then((_) {
      if (mounted && _currentSessionId != null) {
        _loadMessagesToUi(_currentSessionId!);
      }
    });
    // 自动更新检查（fire-and-forget，失败静默不打扰）。
    _checkUpdate();
  }

  /// 启动时静默检查更新，有新版 → 弹窗提示。
  Future<void> _checkUpdate() async {
    final info = await UpdateService.checkForUpdate();
    if (!mounted || info == null) return;
    _showUpdateDialog(info);
  }

  /// 手动检查更新（二级菜单入口）：有新版弹窗，无新版/失败给提示。
  Future<void> _checkForUpdateManually() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在检查更新…')),
    );
    UpdateInfo? info;
    var failed = false;
    try {
      info = await UpdateService.checkForUpdateDetailed();
    } catch (_) {
      failed = true; // 网络/解析失败。
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('检查更新失败，请检查网络')),
      );
    } else if (info != null) {
      _showUpdateDialog(info);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已是最新版本')),
      );
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v${info.version}'),
        content: SingleChildScrollView(
          child: Text(info.notes?.trim().isNotEmpty == true
              ? info.notes!
              : '有新版本可用，是否立即更新？'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _downloadAndInstall(info);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(UpdateInfo info) async {
    if (!mounted) return;
    // 下载提示可关闭（返回键/点击遮罩/「后台下载」都不打断下载，只收起弹窗）。
    // 之前 barrierDismissible: false 无取消按钮，国内慢网时 UI 永久阻塞。
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        content: const Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('正在下载更新…'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('后台下载'),
          ),
        ],
      ),
    ).then((_) => dialogOpen = false);
    final ok = await UpdateService.downloadAndInstall(info.downloadUrl);
    if (!mounted) return;
    // 弹窗还开着才关；用户已手动关闭则不再 pop（否则会误弹掉聊天页）。
    if (dialogOpen) Navigator.of(context).pop();
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载/安装失败，请稍后重试')),
      );
    }
  }

  /// 从对话历史切回某个会话继续聊：切换 sessionId + 加载历史到 UI。
  Future<void> _resumeSession(String sessionId) async {
    if (!mounted) return;
    // 生成中途切换会话：先停掉在跑的 agent，防止它往新会话流式写。
    if (_running) {
      _activeAgent?.cancel();
      _running = false;
    }
    unawaited(_saveLastSessionId(sessionId));
    setState(() {
      _messages.clear();
      _toolRunningIdx.clear();
      _reasoningMsgIdx = -1;
      _currentSessionId = sessionId;
      _pendingPlan = null;
      _pendingTask = null;
    });
    await _loadMessagesToUi(sessionId);
  }

  /// 从会话库把 [sessionId] 的历史加载进 UI（重启/切换会话复用）。
  ///
  /// 用代际令牌 [_loadGen] 丢弃过期加载结果：并发调用时（如启动加载与
  /// 「继续聊天」同时进行）只有最后一次加载生效，避免串到别的会话。
  Future<void> _loadMessagesToUi(String sessionId) async {
    final sdb = _sessionDb;
    if (sdb == null) return;
    if (!mounted) return;
    final gen = ++_loadGen;
    try {
      final stored = await sdb.getMessages(sessionId);
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _messages.clear();
        _toolRunningIdx.clear();
        _reasoningMsgIdx = -1;
        _showScrollToBottom = false; // 新会话从底部开始，恢复自动跟随。
        for (final m in stored) {
          final role = m['role'] as String? ?? 'user';
          final content = m['content'] as String?;
          if (role == 'user' && content != null) {
            _messages.add(_ChatMessage.user(content));
          } else if (role == 'assistant' && content != null) {
            _messages.add(_ChatMessage.assistant(content));
          } else if (role == 'tool') {
            _messages.add(_ChatMessage.tool(
              m['tool_name'] as String? ?? '',
              'done',
            ));
          }
        }
      });
      // 历史加载完直接看最新消息（会话开头先锚到底部）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      });
    } catch (_) {}
  }

  /// 新建会话：生成新 sessionId，清空当前对话。
  Future<void> _newSession() async {
    final sdb = _sessionDb;
    if (sdb == null) return;
    if (!mounted) return;
    // 生成中新建：先停掉在跑的 agent，防止它往新会话流式写。
    if (_running) {
      _activeAgent?.cancel();
      _running = false;
    }
    final newId = 's${DateTime.now().millisecondsSinceEpoch}';
    try {
      await sdb.createSession(newId, source: 'app');
      unawaited(_saveLastSessionId(newId));
    } catch (_) {}
    if (!mounted) return;
    // 作废任何在途的历史加载，防止旧会话内容写入新会话（防串号）。
    ++_loadGen;
    setState(() {
      _messages.clear();
      _toolRunningIdx.clear();
      _reasoningMsgIdx = -1;
      _currentSessionId = newId;
      _pendingPlan = null;
      _pendingTask = null;
      _studyChoices.clear(); // 题目作答状态不跨会话泄漏。
    });
  }

  /// Plan 模式：只读探索任务，生成计划并展示（不执行写操作）。
  Future<void> _generatePlan(String task) async {
    final config = await MIXConfig.load();
    if (config == null) {
      setState(() => _running = false);
      _addAssistant('请先配置 AI');
      return;
    }
    setState(() {
      _running = true;
      _pendingPlan = null;
    });
    final llm = OpenAiLlmClient(config: config.toLlmConfig(
        effort: MIXConfig.effortValueToKey(await MIXConfig.loadEffort('plan'))));
    final planAgent = MIXAgent(
      llm: llm,
      systemPrompt: '你是 MIX，处于计划模式。你现在只做探索和规划，'
          '绝对不要修改/创建/删除任何文件，不要 git add/commit/push。'
          '可以用 read_file / search_files / git_status / git_diff 探索当前状态，'
          '然后输出一个清晰的执行计划：列出要做的步骤、每步做什么、'
          '涉及什么文件/命令。计划要具体、可执行。用中文。',
      toolDefinitionsProvider: () => _readOnlyTools(),
      maxIterations: 15,
    );
    try {
      final result = await planAgent.runConversation(task);
      final plan = result.finalResponse ?? '(无计划输出)';
      if (!mounted) return;
      setState(() {
        _pendingPlan = plan;
        _running = false;
      });
      _addAssistant('📋 **执行计划**\n\n$plan');
      _addPlanApprovalBar();
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      _addAssistant('生成计划失败：$e');
    }
  }

  /// 计划批准/拒绝操作条。
  void _addPlanApprovalBar() {
    if (!mounted) return;
    _pendingPlan = _pendingPlan; // 保留计划。
    setState(() {
      _messages.add(_ChatMessage.tool('plan_approval', 'running'));
    });
  }

  /// 批准计划：用完整工具执行。
  Future<void> _executePlan(String task) async {
    final plan = _pendingPlan;
    setState(() {
      _pendingPlan = null;
      _running = true;
      _toolRunningIdx.clear();
    });
    if (plan != null) {
      // 把计划加进对话，agent 执行时参考（跳过重复检索，计划已是上下文）。
      await _runTaskWithFullTools(
        '$task\n\n按以下计划执行：\n$plan',
        skipRetrieval: true,
      );
      return;
    }
    await _runTaskWithFullTools(task);
  }

  /// 用完整工具集执行任务（现有 _send 主体逻辑抽取）。
  Future<void> _runTaskWithFullTools(String task, {bool skipRetrieval = false}) async {
    final config = await MIXConfig.load();
    if (config == null) {
      // 经 _executePlan 进入时 _running 已置 true，此处复位防 UI 永久锁死。
      setState(() => _running = false);
      _addAssistant('请先配置 AI');
      return;
    }
    final llm = OpenAiLlmClient(
        config: config.toLlmConfig(effort: _chatEffortKey));
    final compressor = ContextCompressor(
      contextLength: 100000,
      summarizer: (middle) async {
        final summaryTurn = await llm.chatStream(
          messages: [
            {
              'role': 'system',
              'content': 'Summarize the conversation below, preserving key '
                  'facts, decisions, and context. Be concise.',
            },
            {'role': 'user', 'content': jsonEncode(middle)},
          ],
        );
        return summaryTurn.content ?? '';
      },
    );
    // 工程检索：从历史消息召回与当前任务相关的片段，注入上下文（防污染）。
    // plan 执行时跳过（计划本身已是上下文，避免基于长拼接文本搜到无关内容）。
    final retrieved =
        skipRetrieval ? <ContextHit>[] : await _retrieveRelevantContext(task);
    _activeAgent = MIXAgent(
      llm: llm,
      memoryManager: _memory,
      sessionDb: _sessionDb,
      sessionId: _currentSessionId,
      contextCompressor: compressor,
      systemPrompt: _buildWorkflowPrompt(
        contextBlock: formatContextBlock(retrieved),
      ),
      toolDefinitionsProvider: () => getToolDefinitions(
        enabledToolsets: _currentWorkflow.toolsets,
        quietMode: true,
      ),
      onReasoning: (r) {
        // 思考阶段流式显示：DeepSeek 类模型先出 reasoning_content 再出 content。
        // 不显示会导致"沉默很久 → content 整句弹出"的假流式观感。
        setState(() {
          if (_reasoningMsgIdx >= 0 && _reasoningMsgIdx < _messages.length) {
            final prev = _messages[_reasoningMsgIdx].text ?? '';
            _messages[_reasoningMsgIdx] = _ChatMessage.reasoning(prev + r);
          } else {
            _reasoningMsgIdx = _messages.length;
            _messages.add(_ChatMessage.reasoning(r));
          }
        });
        _scrollToBottom();
      },
      onDelta: (delta) {
        setState(() {
          // content 开始：移除思考块，进入正常流式。
          if (_reasoningMsgIdx >= 0) {
            _messages.removeAt(_reasoningMsgIdx);
            // reasoning 块之后的工具卡索引整体前移 1，防 _toolRunningIdx 错位。
            for (final k in _toolRunningIdx.keys) {
              final v = _toolRunningIdx[k];
              if (v != null && v > _reasoningMsgIdx) {
                _toolRunningIdx[k] = v - 1;
              }
            }
            _reasoningMsgIdx = -1;
          }
          // 最后一条非 assistant（user/tool/refine/discussion/题卡…）→ 开新
          // assistant；否则拼接。修复 refine 卡在末尾时 delta 被静默丢弃。
          if (_messages.isEmpty || _messages.last.role != 'assistant') {
            _messages.add(_ChatMessage.assistant(delta));
          } else {
            final last = _messages.last;
            _messages[_messages.length - 1] = _ChatMessage.assistant(
                (last.text ?? '') + delta);
          }
        });
        _scrollToBottom();
      },
      onToolEvent: (name, status) {
        setState(() {
          if (status == 'running') {
            _toolRunningIdx[name] = _messages.length;
            _messages.add(_ChatMessage.tool(name, status));
          } else {
            final idx = _toolRunningIdx.remove(name);
            if (idx != null && idx < _messages.length) {
              _messages[idx] = _ChatMessage.tool(name, status);
            } else {
              _messages.add(_ChatMessage.tool(name, status));
            }
            // notes_write 完成后追加「打开笔记」卡片，深链到笔记编辑器。
            if (name == 'notes_write' && lastWrittenNotePath != null) {
              _messages.add(_ChatMessage.tool('notes_open', 'done'));
            }
          }
        });
      },
    );
    ConversationResult? lastResult;
    var ranError = false;
    try {
      final result = await _activeAgent!.runConversation(task);
      lastResult = result;
      if (result.completed &&
          result.finalResponse != null &&
          _messages.isNotEmpty &&
          _messages.last.role == 'assistant' &&
          _messages.last.text != result.finalResponse) {
        setState(() {
          _messages[_messages.length - 1] =
              _ChatMessage.assistant(result.finalResponse);
        });
      } else if (!result.completed && result.finalResponse != null) {
        _addAssistant(result.finalResponse!);
      }
    } catch (e) {
      ranError = true;
      _addAssistant('出错了：$e');
    } finally {
      _activeAgent = null;
      // 若仍残留思考块（停在纯 reasoning 阶段，onDelta 未触发过），一并清掉。
      setState(() {
        if (_reasoningMsgIdx >= 0 && _reasoningMsgIdx < _messages.length) {
          _messages.removeAt(_reasoningMsgIdx);
          for (final k in _toolRunningIdx.keys.toList()) {
            final v = _toolRunningIdx[k];
            if (v != null && v > _reasoningMsgIdx) _toolRunningIdx[k] = v - 1;
          }
        }
        _reasoningMsgIdx = -1;
        _running = false;
      });
    }
    _recordTrajectoryAndRefine(task, lastResult, ranError);
  }

  /// 任务完成后：写轨迹 + fire-and-forget 触发自进化建议。
  void _recordTrajectoryAndRefine(
    String task,
    ConversationResult? result,
    bool ranError,
  ) {
    final traj = _trajectory;
    if (traj == null) return;
    // 提取调用过的工具名（从 assistant 消息的 tool_calls）。
    final toolNames = <String>[];
    if (result != null) {
      for (final m in result.messages) {
        final calls = m['tool_calls'];
        if (calls is List) {
          for (final c in calls) {
            if (c is Map<String, dynamic>) {
              final fn = c['function'];
              if (fn is Map && fn['name'] is String) {
                toolNames.add(fn['name'] as String);
              }
            }
          }
        }
      }
    }
    final outcome = ranError
        ? 'error'
        : (result?.completed ?? false)
            ? 'success'
            : (result?.error == 'cancelled' ? 'cancelled' : 'budget');
    traj.append(TrajectoryRecord(
      ts: DateTime.now(),
      sessionId: _currentSessionId ?? 'main',
      userPrompt: task,
      toolNames: toolNames.toSet().toList(),
      completed: result?.completed ?? false,
      outcome: outcome,
      finalExcerpt: result?.finalResponse != null &&
              (result!.finalResponse!.length > 200)
          ? result.finalResponse!.substring(0, 200)
          : result?.finalResponse,
    ));
    // fire-and-forget：不阻塞主流程，建议卡追加到消息流。
    unawaited(_suggestRefine());
  }

  /// 异步跑 refine 提议，非空则追加建议卡。
  Future<void> _suggestRefine() async {
    if (_refineSuggesting) return;
    _refineSuggesting = true;
    try {
      await _suggestRefineInner();
    } finally {
      _refineSuggesting = false;
    }
  }

  /// study_list 执行器：返回科目/知识点（带掌握度）JSON。
  Future<String> _studyList() async {
    final engine = _studyEngine;
    if (engine == null) return '{"error":"学习引擎未初始化"}';
    try {
      final kps = await engine.listKps();
      final bySubject = <String, List<Map<String, dynamic>>>{};
      for (final k in kps) {
        bySubject.putIfAbsent(k.subjectName, () => []).add({
          'kp_id': k.id,
          'name': k.name,
          'mastery': k.mastery,
          'recent_count': k.recentCount,
        });
      }
      return jsonEncode({
        'subjects': [
          for (final e in bySubject.entries)
            {'subject': e.key, 'kps': e.value},
        ],
      });
    } catch (e) {
      // jsonEncode 而非字符串插值，防止异常消息含引号产出畸形 JSON。
      return jsonEncode({'error': e.toString()});
    }
  }

  /// study_question 执行器：多阶段精炼出题。
  /// 失败返回给 agent 的友好说明（不是 JSON），避免 agent 按学习工作流把
  /// 错误 JSON 原样包成 ```json 输出、界面把它当题目卡处理。
  Future<String> _studyQuestion(int kpId, {String? targetDifficulty}) async {
    final engine = _studyEngine;
    if (engine == null) return '出题失败：学习引擎未初始化';
    final svc = _studyQuestionService;
    if (svc == null) {
      final config = await MIXConfig.load();
      if (config == null) return '出题失败：AI 未配置';
      final dir = (await getApplicationDocumentsDirectory()).path;
      _studyQuestionService = StudyQuestionService(
        llm: OpenAiLlmClient(config: config.toLlmConfig(
            effort: MIXConfig.effortValueToKey(
                await MIXConfig.loadEffort('study_question')))),
        engine: engine,
        subjectLibraryDir: subjectLibraryPath(dir),
        profilePath: '${subjectLibraryPath(dir)}/0_profile.md',
        skillPath: '$dir/skills/question-design/SKILL.md',
        isCancelled: () => _activeAgent?.isCancelled ?? false,
      );
    }
    try {
      final result = await _studyQuestionService!.generate(
        kpId,
        targetDifficulty: targetDifficulty,
      );
      if (result.error != null) {
        return '出题失败：${result.error}（这不是题目，直接告诉用户出题失败'
            '并建议换一个知识点重试）';
      }
      return result.json ?? '出题失败：无输出';
    } catch (e) {
      return '出题失败：$e（这不是题目，直接告诉用户出题失败并建议重试）';
    }
  }

  /// study_profile_update 执行器：把 agent 观察到的学生表现写进画像。
  Future<String> _studyProfileUpdate(String note) async {
    final svc = _studyQuestionService;
    if (svc == null) return '画像更新失败：学习引擎未初始化';
    try {
      final effort = MIXConfig.effortValueToKey(
          await MIXConfig.loadEffort('study_profile'));
      return await svc.updateProfile(note, reasoningEffort: effort);
    } catch (e) {
      return '画像更新失败: $e';
    }
  }

  /// 点选题卡后触发 agent 讲解（合成 user turn，不在输入框显示）。
  /// [qid] 为 null 表示题目没带 question_id（LLM 复述丢失），仍触发讲解。
  void _onStudyAnswer(int? qid, String letter, String answer, bool correct) {
    if (_running) return;
    final label = qid != null ? '题目#$qid' : '刚答的那道题';
    final msg = '我刚答了$label，选了 $letter，'
        '${correct ? "对了" : "正确答案是 $answer，我答错了"}。'
        '请讲解这道题（为什么对、干扰项为什么错），然后提议下一题。';
    // 与 _send 一致：先把 user 消息加入 UI（讲解流式时 last 是 user → 开新
    // assistant），并置 _running 锁输入/显示进度。此前漏掉导致讲解被拼进
    // 题目卡、完成时题目卡被整条替换成裸文本。
    _addUser(msg);
    setState(() => _running = true);
    unawaited(_runTaskWithFullTools(msg));
  }

  Future<void> _suggestRefineInner() async {
    var refine = _refine;
    if (refine == null) {
      final config = await MIXConfig.load();
      final traj = _trajectory;
      final notes = _promptNotes;
      final journal = _editJournal;
      if (config == null || traj == null || notes == null || journal == null) {
        return;
      }
      refine = RefinePipeline(
        llm: OpenAiLlmClient(config: config.toLlmConfig(
            effort: MIXConfig.effortValueToKey(
                await MIXConfig.loadEffort('refine')))),
        trajectory: traj,
        journal: journal,
        memory: memoryStore,
        promptNotes: notes,
        skills: skillDiscovery,
      );
      _refine = refine;
    }
    if (!mounted) return;
    final proposals = await refine.suggest();
    if (proposals.isEmpty || !mounted) return;
    setState(() {
      _messages.add(_ChatMessage.refine(refineProposals: proposals));
    });
  }

  /// 接受全部自进化建议。
  void _applyRefineProposals(_ChatMessage msg) {
    final refine = _refine;
    if (refine == null) return;
    for (final p in msg.refineProposals) {
      refine.apply(p);
    }
    final idx = _messages.indexOf(msg);
    if (idx >= 0) {
      setState(() {
        _messages[idx] = _ChatMessage.refine(
          refineProposals: msg.refineProposals,
          refineApplied: true,
        );
      });
    }
  }

  /// 忽略建议卡。
  void _ignoreRefineProposals(_ChatMessage msg) {
    final idx = _messages.indexOf(msg);
    if (idx >= 0) {
      setState(() {
        _messages[idx] = _ChatMessage.refine(
          refineProposals: msg.refineProposals,
          refineIgnored: true,
        );
      });
    }
  }

  /// 惰性创建多代理执行器（子代理/部门/讨论共用，复用连接）。
  Future<MultiAgentService?> _ensureMultiAgent() async {
    if (_multiAgent != null) return _multiAgent;
    final config = await MIXConfig.load();
    if (config == null) return null;
    final fastEffort = MIXConfig.effortValueToKey(
        await MIXConfig.loadEffort('fast_agent'));
    final fast = await MIXConfig.loadFastConfig(effort: fastEffort);
    _multiAgent = MultiAgentService(
      llm: OpenAiLlmClient(config: config.toLlmConfig(
          effort: MIXConfig.effortValueToKey(
              await MIXConfig.loadEffort('agent')))),
      fastLlm: fast != null ? OpenAiLlmClient(config: fast) : null,
      isCancelled: () => _activeAgent?.isCancelled ?? false,
    );
    return _multiAgent;
  }

  /// 子代理/部门角色的工具事件 → UI 工具卡（带「子代理·」前缀，层级可辨）。
  void _onSubAgentToolEvent(String name, String status) {
    if (!mounted) return;
    final displayName = '子代理·$name';
    setState(() {
      if (status == 'running') {
        _toolRunningIdx[displayName] = _messages.length;
        _messages.add(_ChatMessage.tool(displayName, status));
      } else {
        final idx = _toolRunningIdx.remove(displayName);
        if (idx != null && idx < _messages.length) {
          _messages[idx] = _ChatMessage.tool(displayName, status);
        } else {
          _messages.add(_ChatMessage.tool(displayName, status));
        }
      }
    });
    _scrollToBottom();
  }

  /// MoA 讨论进度 → 更新讨论消息（对齐官方 moa-progress-event 语义）。
  void _onMoaProgress(MoaProgress p) {
    if (!mounted) return;
    setState(() {
      switch (p.stage) {
        case MoaStage.roundStart:
          _upsertDiscussion(_ChatMessage.discussion(
            discussionRunning: true,
            discussionRound: p.round,
            discussionTotalRounds: p.totalRounds,
          ));
        case MoaStage.perspectiveStart:
          _upsertDiscussion(_ChatMessage.discussion(
            discussionRunning: true,
            discussionRound: p.round,
            discussionTotalRounds: p.totalRounds,
            discussionPerspective: p.perspective,
          ));
        case MoaStage.perspectiveDone:
          if (p.perspective != null) {
            _lastPerspectiveOutputs[p.perspective!] = p.output ?? '';
          }
        case MoaStage.synthesizing:
          _upsertDiscussion(_ChatMessage.discussion(
            discussionRunning: true,
            discussionRound: p.round,
            discussionTotalRounds: p.totalRounds,
          ));
        case MoaStage.done:
          _upsertDiscussion(_ChatMessage.discussion(
            discussionRunning: false,
            discussionRound: p.round,
            discussionTotalRounds: p.totalRounds,
            discussionPerspectives: [
              for (final e in _lastPerspectiveOutputs.entries) (e.key, e.value),
            ],
            discussionSummary: p.output,
          ));
          _discussionMsgIdx = -1;
          _lastPerspectiveOutputs.clear();
      }
    });
    _scrollToBottom();
  }

  /// 插入或更新当前讨论消息（流式累积，同 _toolRunningIdx 模式）。
  void _upsertDiscussion(_ChatMessage msg) {
    if (_discussionMsgIdx >= 0 && _discussionMsgIdx < _messages.length) {
      _messages[_discussionMsgIdx] = msg;
    } else {
      _discussionMsgIdx = _messages.length;
      _messages.add(msg);
    }
  }

  /// 从历史消息检索与任务相关的上下文片段（FTS5 词法，工程检索一期）。
  Future<List<ContextHit>> _retrieveRelevantContext(String task) async {
    final sdb = _sessionDb;
    if (sdb == null) return [];
    try {
      return await retrieveRelevantContext(
        db: sdb,
        query: task,
        sessionId: _currentSessionId, // 限定当前会话，避免引用别的会话旧信息。
        limit: 5,
      );
    } catch (_) {
      return [];
    }
  }

  /// cron 触发回调：执行任务并把结果作为 assistant 消息加入对话。
  Future<void> _fireCronJob(CronJob job) async {
    if (!mounted) return;
    // 显示 cron 触发的提示。
    _addAssistant('⏰ [定时任务 ${job.id}] ${job.schedule}\n任务：${job.task}');
    // 附带 cron 工具集：任务文本里若写了「做完删除本任务」，子代理才真正有权删。
    final svc = await _ensureMultiAgent();
    final result = svc != null
        ? await svc.runSubAgent(
            task: job.task,
            toolsets: const ['file', 'web', 'git', 'cron'],
            depth: 0,
          )
        : '（AI 未配置）';
    if (!mounted) return;
    _addAssistant('[定时任务完成]\n$result');
  }

  /// clarify 回调：弹对话框收集用户答案。
  Future<String> _showClarifyDialog(
    String question,
    List<String> choices,
    bool multiSelect,
  ) async {
    final controller = TextEditingController();
    final selected = <String>{};
    final answer = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('MIX 想确认一下'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(question),
              ),
              if (choices.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final c in choices)
                  CheckboxListTile(
                    title: Text(c),
                    value: selected.contains(c),
                    dense: true,
                    onChanged: (v) => setDialogState(() {
                      if (multiSelect) {
                        if (v == true) {
                          selected.add(c);
                        } else {
                          selected.remove(c);
                        }
                      } else {
                        selected
                          ..clear()
                          ..add(c);
                      }
                    }),
                  ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: '或直接输入回答',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('跳过'),
            ),
            FilledButton(
              onPressed: () {
                final typed = controller.text.trim();
                if (typed.isNotEmpty) {
                  Navigator.pop(ctx, typed);
                } else if (selected.isNotEmpty) {
                  Navigator.pop(ctx, selected.join('、'));
                } else {
                  Navigator.pop(ctx, '');
                }
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    return answer ?? '';
  }

  /// 只读工具集（plan 模式用）：过滤掉写操作，防 plan 阶段误改文件。
  List<Map<String, dynamic>> _readOnlyTools() {
    const readOnly = {
      'read_file', 'search_files', 'git_status', 'git_diff', 'git_log',
      'git_branch', 'git_version',
    };
    final all = getToolDefinitions(
      enabledToolsets: const ['file', 'git'],
      quietMode: true,
    );
    return [
      for (final t in all)
        if (readOnly.contains((t['function'] as Map)['name'])) t,
    ];
  }

  /// 当前工作流（按 _workflowId，未知则回退通用）。
  AgentWorkflow get _currentWorkflow =>
      findWorkflow(_workflowId) ?? builtinWorkflows.last;

  /// 按工作流构建系统提示（人设 + 委派/计划策略 + 工程检索 + 技能 + 外部权限）。
  String _buildWorkflowPrompt({String contextBlock = ''}) {
    var prompt = _currentWorkflow.buildSystemPrompt(
      contextBlock: contextBlock,
      skillBlock: buildSkillsSystemPrompt(),
    );
    // 公司模式：追加部门列表，让 CEO 知道有哪些团队可用。
    if (_currentWorkflow.id == 'company') {
      prompt += '${departmentsSummary()}\n\n根据任务性质选择部门并分派。';
    }
    if (fileToolsAllowExternal) {
      prompt += '\n\n你已获准访问公共存储目录（/sdcard/Download、'
          '/sdcard/Documents 等）。用户可能请你读取、搜索或编辑这些目录里的'
          '文件（如课件、笔记、图片）。访问公共目录请用绝对路径，例如 '
          '`/sdcard/Download/文件名`。';
    }
    // 自进化 prompt notes：注入可自改的补充提示（基础 workflow 提示不可变）。
    final notesBlock = _promptNotes?.formatForSystemPrompt() ?? '';
    if (notesBlock.isNotEmpty) {
      prompt += notesBlock;
    }
    return prompt;
  }

  /// 把文件工具的 cwd 配置到 App documents 目录（隔离墙边界）。
  /// 不配置的话 Android 上 Directory.current 是 `/`，search_files 会递归
  /// 遍历整个文件系统导致卡死。
  /// 同时按「所有文件访问」权限决定是否允许访问公共目录。
  Future<void> _initCwd() async {
    // 各子系统独立初始化：任一失败不拖垮其他。
    final String dir;
    try {
      dir = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      configureFileTools(cwd: null);
      return;
    }
    rememberFileToolsCwd(dir);
    try {
      // 按「所有文件访问」权限设置 file_tools：cwd = documents + 外部访问开关。
      await syncExternalAccessPermission(fallbackCwd: dir);
    } catch (_) {}
    // 记忆存储。
    try {
      registerMemoryTool(baseDir: dir);
      _memory = MemoryManager(store: memoryStore!);
    } catch (_) {}
    // 自定义部门（公司模式）。
    try {
      await loadCustomDepartments();
    } catch (_) {}
    // 会话库。
    try {
      _sessionDb = SessionDB(dbPath: '$dir/state.db');
      await _sessionDb!.init();
      sessionDb = _sessionDb;
      // 恢复到上次活动的会话（无则 'main'）。createSession 对已存在会话
      // 保留原 started_at，不会把旧会话刷新成"刚刚"顶置历史页。
      _currentSessionId = await _loadLastSessionId();
      await _sessionDb!.createSession(_currentSessionId!, source: 'app');
    } catch (_) {}
    // skill 系统。
    try {
      final skillsRoot = '$dir/skills';
      Directory(skillsRoot).createSync(recursive: true);
      registerSkillTools(skillsRoot: skillsRoot);
    } catch (_) {}
    // 学习模式：study.db（事实层）+ 画像/讲义目录。
    try {
      final engine = StudyEngine(dbPath: '$dir/study.db');
      await engine.init();
      _studyEngine = engine;
    } catch (_) {}
    try {
      Directory(notesRootPath(dir)).createSync(recursive: true);
      Directory(subjectLibraryPath(dir)).createSync(recursive: true);
      // 旧路径迁移：之前版本 subject_library 在 documents/subject_library，
      // 现在移入 documents/notes/subject_library（笔记库可见）。检测旧目录
      // 存在且非空时迁移过去，避免学习数据丢失。
      final legacyLib = Directory('$dir/subject_library');
      final newLib = Directory(subjectLibraryPath(dir));
      if (await legacyLib.exists() && newLib.listSync().isEmpty) {
        await for (final e in legacyLib.list()) {
          await e.rename(p.join(newLib.path, p.basename(e.path)));
        }
      }
    } catch (_) {}
    // 自进化（Continual Harness）：轨迹 / prompt notes / 编辑台账。
    try {
      _trajectory = TrajectoryStore(filePath: '$dir/refine/trajectory.jsonl');
      _promptNotes = PromptNotesStore(filePath: '$dir/refine/prompt_notes.json');
      _editJournal = EditJournal(filePath: '$dir/refine/edit_journal.json');
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _running) return;
    // 一提交立即锁定发送状态（在 await config 之前），否则模型回答期间
    // 用户可重复回车穿透，并发执行多个任务。
    setState(() => _running = true);
    _controller.clear();

    final config = await MIXConfig.load();
    if (config == null) {
      setState(() => _running = false);
      _addUser(text);
      _addAssistant('请先在设置中配置 AI（厂商 + 模型 + API Key）。');
      return;
    }

    _addUser(text);

    // Plan 模式：UI 开关开启，或当前工作流要求先计划（planGate）。
    final needPlan = _planMode || _currentWorkflow.planGate;
    if (needPlan) {
      _pendingTask = text;
      await _generatePlan(text);
      return;
    }

    // 非 plan 模式：直接执行（完整工具集）。
    await _runTaskWithFullTools(text);
  }

  void _addUser(String text) {
    setState(() {
      _messages.add(_ChatMessage.user(text));
      _showScrollToBottom = false; // 发消息 = 主动回底，恢复自动跟随。
    });
    // 发送的消息必须立即可见：无条件跳到底部。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _addAssistant(String text) {
    setState(() => _messages.add(_ChatMessage.assistant(text)));
    _scrollToBottom();
  }

  /// 屏幕最底部是否已是最新消息：最后一条消息在视口内即视为可见。
  /// ListView.builder 只构建可见项，lastMessageKey 有 context = 最后一条在视口内。
  bool get _isAtLatestMessage => _lastMessageKey.currentContext != null;

  /// 消息列表滚动到底（流式输出时跟随最新文字）。
  /// 仅当屏幕底部已是最新消息才跟随；一旦用户上滑（最新消息不可见）
  /// 就完全停止打扰（直到他回底/发消息），避免"疯狂划回底部"。
  void _scrollToBottom() {
    if (!_isAtLatestMessage) return; // 用户在上方读历史，不打扰。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (pos.maxScrollExtent - pos.pixels < 120) {
        _scrollController.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  /// 滚动监听：屏幕底部不再是最后一条消息时浮现"回到底部"按钮。
  void _onChatScroll() {
    if (!_scrollController.hasClients) return;
    final shouldShow = !_isAtLatestMessage;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
  }

  /// 强制回到最新消息（点悬浮按钮）。
  void _forceScrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    if (_showScrollToBottom) {
      setState(() => _showScrollToBottom = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // ESC = 停止当前生成。
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _stop,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      appBar: AppBar(
        title: const Text('MIX'),
        actions: [
          // 思考强度选择器：回答问题时可选极低~极高（各内部流程在设置里独立调）。
          PopupMenuButton<int>(
            tooltip: '思考强度：${MIXConfig.effortValueLabel(_chatEffort)}',
            onSelected: (v) {
              setState(() => _chatEffort = v);
              MIXConfig.saveEffort('chat', v);
            },
            itemBuilder: (_) => [
              for (final v in const [0, 25, 50, 75, 100])
                PopupMenuItem(
                  value: v,
                  child: Row(
                    children: [
                      Icon(
                        v < 40
                            ? Icons.bolt
                            : v >= 80
                                ? Icons.auto_awesome
                                : Icons.tune,
                        size: 18,
                        color: _chatEffort == v
                            ? context.appPalette.primary
                            : context.appPalette.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Text(MIXConfig.effortValueLabel(v)),
                      if (_chatEffort == v) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.check,
                            size: 14, color: context.appPalette.primary),
                      ],
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(
                _chatEffort < 40
                    ? Icons.bolt
                    : _chatEffort >= 80
                        ? Icons.auto_awesome
                        : Icons.tune,
                size: 20,
                color: context.appPalette.textSecondary,
              ),
            ),
          ),
          // 工作流选择器。
          PopupMenuButton<String>(
            tooltip: '工作流：${_currentWorkflow.name}',
            onSelected: (id) => setState(() => _workflowId = id),
            itemBuilder: (_) => [
              for (final w in builtinWorkflows)
                PopupMenuItem(
                  value: w.id,
                  child: Row(
                    children: [
                      Icon(
                        w.id == 'coding'
                            ? Icons.code
                            : w.id == 'research'
                                ? Icons.search
                                : w.id == 'company'
                                    ? Icons.apartment
                                    : Icons.home,
                        size: 18,
                        color: _workflowId == w.id
                            ? context.appPalette.primary
                            : context.appPalette.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(w.name),
                                if (_workflowId == w.id) ...[
                                  SizedBox(width: 6),
                                  Icon(Icons.check,
                                      size: 14, color: context.appPalette.primary),
                                ],
                              ],
                            ),
                            Text(
                              w.description,
                              style: TextStyle(
                                  fontSize: 11, color: context.appPalette.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.tune, size: 20,
                  color: _currentWorkflow.id == 'coding'
                      ? context.appPalette.primary
                      : context.appPalette.textSecondary),
            ),
          ),
          // 更多菜单：计划/GitHub/设置（收纳二级入口）。
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) {
              switch (v) {
                case 'new_session':
                  _newSession();
                case 'plan':
                  setState(() => _planMode = !_planMode);
                case 'theme':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ThemeScreen()),
                  );
                case 'notes':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const printnotes.MainPage()),
                  );
                case 'files':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FileBrowserScreen()),
                  );
                case 'settings':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => SettingsScreen()),
                  );
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'new_session',
                child: Row(
                  children: [
                    Icon(Icons.add_comment, size: 18, color: context.appPalette.textSecondary),
                    SizedBox(width: 8),
                    Text('新建会话'),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'plan',
                child: Row(
                  children: [
                    Icon(_planMode ? Icons.check_circle : Icons.rule,
                        size: 18,
                        color: _planMode ? context.appPalette.primary : context.appPalette.textSecondary),
                    const SizedBox(width: 8),
                    Text(_planMode ? '计划模式（开）' : '计划模式（关）'),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'notes',
                child: Row(
                  children: [
                    Icon(Icons.menu_book_outlined, size: 18, color: context.appPalette.textSecondary),
                    SizedBox(width: 8),
                    Text('笔记库'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'theme',
                child: Row(
                  children: [
                    Icon(Icons.palette_outlined, size: 18, color: context.appPalette.textSecondary),
                    SizedBox(width: 8),
                    Text('主题'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'files',
                child: Row(
                  children: [
                    Icon(Icons.code, size: 18, color: context.appPalette.textSecondary),
                    SizedBox(width: 8),
                    Text('代码'),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings, size: 18, color: context.appPalette.textSecondary),
                    SizedBox(width: 8),
                    Text('设置'),
                  ],
                ),
              ),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.more_vert),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                if (_messages.isEmpty)
                  Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        'MIX —— 沙盒内的 agent。\n输入任务试试，'
                        '比如：在 notes 目录写一首关于安卓的俳句并读给我看',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.appPalette.textSecondary),
                      ),
                    ),
                  )
                else
                  ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final m = _messages[i];
                      final child = _buildMessage(m);
                      // 最后一条消息挂 key：可见性 = 视口底部是否已是最新消息。
                      return i == _messages.length - 1
                          ? KeyedSubtree(key: _lastMessageKey, child: child)
                          : child;
                    },
                  ),
                // 上滑离开底部时浮现"回到底部"小按钮。
                if (_showScrollToBottom)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: _ScrollToBottomButton(
                      onTap: _forceScrollToBottom,
                    ),
                  ),
              ],
            ),
          ),
          if (_running)
            const LinearProgressIndicator(minHeight: 2),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_running,
                      decoration: const InputDecoration(
                        hintText: '输入任务…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: _running
                        ? const Icon(Icons.stop)
                        : const Icon(Icons.send),
                    onPressed: _running ? _stop : _send,
                    tooltip: _running ? '停止生成' : '发送',
                  ),
                ],
              ),
            ),
          ),
        ],
        ),
        ),
      ),
    );
  }

  /// 自进化建议卡（Continual Harness /refine 的 UI）。
  /// 从 assistant 文本中提取题卡 JSON（agent 以 ```json 输出题目）。
  /// 返回 null 表示非题目。
  ///
  /// 按 ```json 围栏逐块解析：块内取第一 { 到最后一个 }（explanation 里
  /// 可能含 }），第一条消息有多个围栏时逐块尝试，返回首个有效题目。
  Map<String, dynamic>? _extractQuestionJson(String text) {
    final re = RegExp(r'```json(.*?)```', dotAll: true);
    for (final m in re.allMatches(text)) {
      final block = m.group(1) ?? '';
      final start = block.indexOf('{');
      final end = block.lastIndexOf('}');
      if (start < 0 || end <= start) continue;
      try {
        final decoded = jsonDecode(block.substring(start, end + 1));
        if (decoded is! Map<String, dynamic>) continue;
        // 必须是题目结构（有 question + 4 个 options）。
        if (decoded['question'] is String &&
            decoded['options'] is List &&
            (decoded['options'] as List).length == 4) {
          return decoded;
        }
      } catch (_) {}
    }
    return null;
  }

  /// 去掉文本里所有 ```json … ``` 题目块，保留其余文字。
  String _stripQuestionBlocks(String text) {
    return text.replaceAll(RegExp(r'```json.*?```', dotAll: true), '');
  }

  /// 归一化答案字母：容忍 'a' / 'A.' / 'A)' / 'A、' 等，取 A-D 首字母。
  String _normalizeAnswer(dynamic a) {
    if (a is! String) return '';
    final s = a.trim().toUpperCase();
    final m = RegExp(r'^[A-D]').firstMatch(s);
    return m?.group(0) ?? s;
  }

  /// 渲染题目卡（选项按钮 + 机械判）。
  Widget _buildStudyCard(Map<String, dynamic> q) {
    final options = (q['options'] as List).cast<String>();
    final answer = _normalizeAnswer(q['answer']);
    final qid = q['question_id'];
    // 题 key：有 question_id 用它，否则用题干哈希（LLM 复述可能丢 id）。
    final qkey = qid != null
        ? qid.toString()
        : 'q_${(q['question'] as String? ?? '').hashCode}';
    final realQid = qid is int ? qid as int : null;
    // 检查是否已作答。
    final answeredChoice = _studyChoices[qkey];
    final answered = answeredChoice != null;
    final isCorrect = answered && answeredChoice == answer;
    final optLetters = ['A', 'B', 'C', 'D'];

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(q['question'] as String? ?? '',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          for (var i = 0; i < options.length; i++) ...[
            _buildOptionButton(
                optLetters[i], options[i], answer, answered, answeredChoice,
                qkey, realQid),
            const SizedBox(height: 6),
          ],
          if (answered) ...[
            const Divider(height: 12),
            Text(
              isCorrect ? '✅ 正确！' : '❌ 答错了，正确答案是 $answer',
              style: TextStyle(
                color: isCorrect
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(q['explanation'] as String? ?? '',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionButton(
      String letter, String option, String answer,
      bool answered, String? userChoice, String qkey, int? realQid) {
    final isAnswer = letter == answer;
    final isChosen = letter == userChoice;
    final Color bg;
    if (!answered) {
      bg = Theme.of(context).colorScheme.surfaceContainerHighest;
    } else if (isAnswer) {
      bg = Theme.of(context).colorScheme.primary.withValues(alpha: 0.15);
    } else if (isChosen) {
      bg = Theme.of(context).colorScheme.error.withValues(alpha: 0.15);
    } else {
      bg = Theme.of(context).colorScheme.surfaceContainerHighest;
    }
    return InkWell(
      onTap: answered
          ? null
          : () {
              // 无论是否有 question_id 都记录 UI 选择（修复"按了选不了"）。
              setState(() => _studyChoices[qkey] = letter);
              final correct = letter == answer;
              if (realQid != null) {
                // 机械判 + 落库练习记录（零 LLM）。
                final engine = _studyEngine;
                if (engine != null) {
                  unawaited(engine.recordAnswer(
                    questionId: realQid,
                    correct: correct,
                  ));
                }
              }
              // 点选后触发 agent 讲解这题（合成 user turn，agent 在 study
              // workflow 下流式讲解 + 提议下一题）。
              _onStudyAnswer(realQid, letter, answer, correct);
            },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isChosen || (isAnswer && answered)
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(letter,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: isChosen || (isAnswer && answered)
                          ? Theme.of(context).colorScheme.onPrimary
                          : Theme.of(context).colorScheme.onSurface)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(option)),
          ],
        ),
      ),
    );
  }

  Widget _buildRefineCard(_ChatMessage m) {
    if (m.refineIgnored) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('已忽略自进化建议',
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    if (m.refineApplied) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: context.appPalette.primary, width: 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('✅ 已应用 ${m.refineProposals.length} 条自进化建议',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.appPalette.primary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final p in m.refineProposals)
              Text('• ${p.displayLabel}: ${p.content}',
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
          ],
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: context.appPalette.primary, width: 1.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, color: context.appPalette.primary, size: 16),
              const SizedBox(width: 6),
              Text('自进化建议（${m.refineProposals.length} 条）',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          for (final p in m.refineProposals) ...[
            Text('• [${p.displayLabel}] ${p.content}',
                style: Theme.of(context).textTheme.bodySmall),
            if ((p.trigger ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 1),
                child: Text('适用：${p.trigger}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline)),
              ),
            const SizedBox(height: 4),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => _applyRefineProposals(m),
                  style: FilledButton.styleFrom(
                      backgroundColor: context.appPalette.primary),
                  child: const Text('全部接受'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _ignoreRefineProposals(m),
                  child: const Text('忽略'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(_ChatMessage m) {
    switch (m.role) {
      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(m.text ?? ''),
          ),
        );
      case 'reasoning':
        // 思考中块（灰色斜体，reasoner 模型推理过程实时显示）。
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(10),
            ),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.9,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.psychology_outlined,
                    size: 14, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    (m.text ?? '').isEmpty ? '思考中…' : m.text!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: Theme.of(context).colorScheme.outline),
                  ),
                ),
              ],
            ),
          ),
        );
      case 'assistant':
        // 题目卡检测：agent 以 ```json 输出题目 → 渲染可点题卡。
        // 消息里若同时有普通文字和题目块，分别渲染，不吞掉文字。
        final qJson = _extractQuestionJson(m.text ?? '');
        if (qJson != null) {
          final prose = _stripQuestionBlocks(m.text ?? '').trim();
          if (prose.isEmpty) {
            return _buildStudyCard(qJson);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.85,
                  ),
                  child: MIXMarkdown(
                    data: prose,
                    selectable: true,
                  ),
                ),
              ),
              _buildStudyCard(qJson),
            ],
          );
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            child: MIXMarkdown(
              data: m.text ?? '',
              selectable: true,
            ),
          ),
        );
      case 'study':
        return _buildStudyCard({
          'question': m.studyQuestion,
          'options': m.studyOptions,
          'answer': m.studyAnswer,
          'explanation': m.studyExplanation,
          'question_id': m.studyQuestionId,
        });
      case 'refine':
        return _buildRefineCard(m);
      case 'discussion':
        if (m.discussionRunning) {
          final status = m.discussionPerspective != null
              ? '第 ${m.discussionRound}/${m.discussionTotalRounds} 轮 · '
                  '「${m.discussionPerspective}」思考中…'
              : '第 ${m.discussionRound}/${m.discussionTotalRounds} 轮进行中…';
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('🗣️ MoA 讨论 $status',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          );
        }
        // 完成：结构化分工块（Reference N — 视角 + 观点 + 综合结论）。
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.record_voice_over,
                      size: 16, color: context.appPalette.primary),
                  const SizedBox(width: 6),
                  Text('🗣️ MoA 讨论完成（${m.discussionTotalRounds} 轮）',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < m.discussionPerspectives.length; i++) ...[
                Text('Reference ${i + 1} — ${m.discussionPerspectives[i].$1}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.appPalette.primary,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(m.discussionPerspectives[i].$2,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
              ],
              const Divider(height: 12),
              Text('📌 综合结论',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(m.discussionSummary ?? '',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        );
      case 'tool':
        // 计划审批卡：批准/拒绝按钮。
        if (m.toolName == 'plan_approval') {
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(color: context.appPalette.primary, width: 1.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.rule, color: context.appPalette.primary, size: 16),
                    SizedBox(width: 6),
                    Text('计划已生成，是否执行？',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          _executePlan(_pendingTask ?? '继续');
                        },
                        style: FilledButton.styleFrom(backgroundColor: context.appPalette.primary),
                        child: const Text('批准并执行'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _pendingPlan = null;
                            // 精确删除审批卡，而非 removeLast（用户可能已发新消息）。
                            final idx = _messages.indexWhere((e) =>
                                e.role == 'tool' &&
                                e.toolName == 'plan_approval');
                            if (idx >= 0) _messages.removeAt(idx);
                          });
                        },
                        child: const Text('拒绝'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }
        // agent 写入笔记后的「打开笔记」深链卡。
        if (m.toolName == 'notes_open') {
          final notePath = lastWrittenNotePath;
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(color: context.appPalette.primary, width: 1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListTile(
              dense: true,
              leading: Icon(Icons.open_in_new,
                  size: 18, color: context.appPalette.primary),
              title: const Text('已写入笔记库'),
              subtitle: Text(
                notePath == null
                    ? '打开笔记库'
                    : p.basename(notePath),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => _openNote(notePath),
            ),
          );
        }
        // 普通工具调用卡片。
        final running = m.toolStatus == 'running';
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (running)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.check_circle,
                    size: 14, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                '🔧 ${m.toolName} ${running ? '运行中…' : '完成'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

/// "回到底部"小悬浮按钮：半透明圆形，上滑离开底部时浮现。
class _ScrollToBottomButton extends StatelessWidget {
  const _ScrollToBottomButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.keyboard_arrow_down,
            color: Theme.of(context).colorScheme.onSurface,
            size: 24,
          ),
        ),
      ),
    );
  }
}
