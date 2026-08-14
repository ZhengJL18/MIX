/// 对应 `ref/hermes-agent/toolsets.py`（像素级复刻）。
///
/// 工具集定义与解析系统：把工具名分组为"工具集"，支持 includes 组合，
/// 供 model_tools.get_tool_definitions 做 toolset 过滤。
library;

import 'registry.dart';

/// Hermes 核心工具（所有平台共享的基线工具名）。
const List<String> hermesCoreTools = [
  // Web
  'web_search', 'web_extract',
  // Terminal + process management
  'terminal', 'process',
  // Desktop GUI affordances（经 check_fn 门控，GUI 外隐藏）
  'read_terminal', 'close_terminal', 'open_preview', 'focus_pane',
  'react_to_message',
  // File manipulation
  'read_file', 'write_file', 'patch', 'search_files',
  // Vision + image generation
  'vision_analyze', 'image_generate',
  // BFL FLUX 3 video generation
  'bfl_flux3_text_to_video', 'bfl_flux3_image_to_video',
  'bfl_flux3_keyframes_to_video', 'bfl_flux3_video_continuation',
  'bfl_flux3_get_result', 'bfl_flux3_prompting_guide',
  // Skills
  'skills_list', 'skill_view', 'skill_manage',
  // Browser automation
  'browser_navigate', 'browser_snapshot', 'browser_click',
  'browser_type', 'browser_scroll', 'browser_back',
  'browser_press', 'browser_get_images',
  'browser_vision', 'browser_console', 'browser_cdp', 'browser_dialog',
  // Text-to-speech
  'text_to_speech',
  // Planning & memory
  'todo', 'memory',
  // Session history search
  'session_search',
  // Clarifying questions
  'clarify',
  // Code execution + delegation
  'execute_code', 'delegate_task',
  // Cronjob management
  'cronjob',
  // Home Assistant（HASS_TOKEN check_fn 门控）
  'ha_list_entities', 'ha_get_state', 'ha_list_services', 'ha_call_service',
  // Kanban（HERMES_KANBAN_TASK env 或显式启用时）
  'kanban_show', 'kanban_list',
  'kanban_complete', 'kanban_block', 'kanban_heartbeat',
  'kanban_comment', 'kanban_create', 'kanban_link',
  'kanban_unblock',
  'kanban_attach', 'kanban_attach_url', 'kanban_attachments',
  // Computer use（macOS，cua-driver check_fn 门控）
  'computer_use',
];

/// Webhook 事件可能来自不受信任第三方内容。默认 webhook 工具集刻意受限，避免
/// prompt injection 造成本地文件/系统执行。
const List<String> hermesWebhookSafeTools = [
  'web_search',
  'web_extract',
  'vision_analyze',
  'clarify',
];

/// 单个工具集定义。
class ToolsetDef {
  final String description;
  final List<String> tools;
  final List<String> includes;
  final bool? posture;

  const ToolsetDef({
    required this.description,
    this.tools = const [],
    this.includes = const [],
    this.posture,
  });
}

/// 核心工具集定义（对应 Python TOOLSETS dict）。
Map<String, ToolsetDef> toolsetDefs = {
  'web': ToolsetDef(
    description: 'Web research, content extraction, and file download tools',
    tools: ['web_search', 'web_extract', 'web_download'],
  ),
  'search': ToolsetDef(
    description: 'Web search only (no content extraction/scraping)',
    tools: ['web_search'],
  ),
  'x_search': ToolsetDef(
    description:
        "Search X (Twitter) posts and threads via xAI's built-in x_search "
        'Responses tool. Read-only public X discovery; use the xurl skill for '
        'authenticated X API reads and account actions. Available when xAI '
        'credentials are configured (SuperGrok OAuth or XAI_API_KEY). Off by '
        'default; enable in `hermes tools` → X (Twitter) Search.',
    tools: ['x_search'],
  ),
  'vision': ToolsetDef(
    description: 'Image analysis and vision tools',
    tools: ['vision_analyze'],
  ),
  'video': ToolsetDef(
    description:
        'Video analysis and understanding tools (opt-in, not in default toolset)',
    tools: ['video_analyze'],
  ),
  'image_gen': ToolsetDef(
    description: 'Creative generation tools (images)',
    tools: ['image_generate'],
  ),
  'video_gen': ToolsetDef(
    description:
        'Video generation tools. Single ``video_generate`` tool covers '
        'text-to-video (prompt only) and image-to-video (prompt + image_url), '
        'plus reference-to-video. Provider-specific edit/extend workflows may '
        'appear as separate tools. Configure via ``hermes tools`` → Video '
        'Generation.',
    tools: ['video_generate', 'xai_video_edit', 'xai_video_extend'],
  ),
  'bfl': ToolsetDef(
    description:
        'Black Forest Labs FLUX 3 video generation through the Nous tool '
        'gateway: per-mode submit tools (text, image, keyframes, continuation), '
        'a poll tool, and a prompting guide. Generations take minutes, so submit '
        'returns a job id and the model polls for the result.',
    tools: [
      'bfl_flux3_text_to_video',
      'bfl_flux3_image_to_video',
      'bfl_flux3_keyframes_to_video',
      'bfl_flux3_video_continuation',
      'bfl_flux3_get_result',
      'bfl_flux3_prompting_guide',
    ],
  ),
  'computer_use': ToolsetDef(
    description:
        'Background desktop control via cua-driver (macOS/Windows/Linux) — '
        'screenshots, mouse, keyboard, scroll, drag. Does NOT steal the '
        "user's cursor or keyboard focus. Works with any tool-capable model.",
    tools: ['computer_use'],
  ),
  'terminal': ToolsetDef(
    description: 'Terminal/command execution and process management tools',
    tools: ['terminal', 'process'],
  ),
  'skills': ToolsetDef(
    description:
        'Access, create, edit, and manage skill documents with specialized '
        'instructions and knowledge',
    tools: ['skills_list', 'skill_view', 'skill_manage'],
  ),
  'browser': ToolsetDef(
    description:
        'Browser automation for web interaction (navigate, click, type, '
        'scroll, iframes, hold-click) with web search for finding URLs',
    tools: [
      'browser_navigate', 'browser_snapshot', 'browser_click',
      'browser_type', 'browser_scroll', 'browser_back',
      'browser_press', 'browser_get_images',
      'browser_vision', 'browser_console', 'browser_cdp',
      'browser_dialog', 'web_search',
    ],
  ),
  'cronjob': ToolsetDef(
    description:
        'Cronjob management tool - create, list, update, pause, resume, remove, '
        'and trigger scheduled tasks',
    tools: ['cronjob'],
  ),
  'file': ToolsetDef(
    description:
        'File manipulation tools: read, write, patch (with fuzzy matching), '
        'and search (content + files)',
    tools: ['read_file', 'write_file', 'patch', 'search_files'],
  ),
  'convert': ToolsetDef(
    description:
        'Format conversion tools: export Markdown as Word (.docx) or PDF, '
        'and cloud extract (large PDF / OCR / pandoc)',
    tools: ['md_to_docx', 'md_to_pdf', 'cloud_extract'],
  ),
  'git': ToolsetDef(
    description:
        'Git version control via embedded libgit2: init, status, add, '
        'commit, log, branch, clone, push, pull, diff',
    tools: [
      'git_version', 'git_init', 'git_status', 'git_add', 'git_commit',
      'git_log', 'git_branch', 'git_diff', 'git_clone', 'git_push', 'git_pull',
      'github_ci_logs',
    ],
  ),
  'tts': ToolsetDef(
    description:
        'Text-to-speech: convert text to audio with Edge TTS (free), '
        'ElevenLabs, OpenAI, or xAI',
    tools: ['text_to_speech'],
  ),
  'todo': ToolsetDef(
    description: 'Task planning and tracking for multi-step work',
    tools: ['todo'],
  ),
  'memory': ToolsetDef(
    description:
        'Persistent memory across sessions (personal notes + user profile)',
    tools: ['memory'],
  ),
  'context_engine': ToolsetDef(
    description: 'Runtime tools exposed by the active context engine',
    tools: [],
  ),
  'session_search': ToolsetDef(
    description: 'Search and recall past conversations with summarization',
    tools: ['session_search'],
  ),
  'clarify': ToolsetDef(
    description: 'Ask the user a clarifying question when a task is ambiguous',
    tools: ['clarify'],
  ),
  'delegate': ToolsetDef(
    description: 'Delegate a sub-task to an independent sub-agent',
    tools: ['delegate_task'],
  ),
  'moa': ToolsetDef(
    description:
        'Multi-agent discussion (Kimi-style): sub-agents with different '
        'perspectives debate over rounds, then synthesize a conclusion',
    tools: ['moa_discuss'],
  ),
  'company': ToolsetDef(
    description:
        'Company mode: delegate tasks to departments (code/research/office) '
        'with specialized roles working in parallel',
    tools: ['delegate_to_department'],
  ),
  'cron': ToolsetDef(
    description: 'Recurring scheduled tasks that run while the app is open',
    tools: ['cron_create', 'cron_list', 'cron_delete'],
  ),
  'study': ToolsetDef(
    description:
        'Learning mode tools: list knowledge points and generate questions '
        '(multi-stage refined pipeline)',
    tools: ['study_list', 'study_question'],
  ),
  'quiz': ToolsetDef(
    description:
        'Interactive batch quiz cards: present multiple questions at once '
        '(swipe cards), mechanically grade answers in UI, and optionally '
        'record results to the student profile',
    tools: ['study_quiz'],
  ),
  'notes': ToolsetDef(
    description:
        'Notes library tools: list/search/read/write the notes library '
        '(documents/notes, includes subject_library 讲义)',
    tools: ['notes_list', 'notes_search', 'notes_read', 'notes_write'],
  ),
  'project': ToolsetDef(
    description:
        'Desktop Projects — create/switch named workspaces (GUI sessions only)',
    tools: ['project_list', 'project_create', 'project_switch'],
  ),
  'code_execution': ToolsetDef(
    description:
        'Run Python scripts that call tools programmatically (reduces LLM '
        'round trips)',
    tools: ['execute_code'],
  ),
  'delegation': ToolsetDef(
    description:
        'Spawn subagents with isolated context for complex subtasks',
    tools: ['delegate_task'],
  ),
  'homeassistant': ToolsetDef(
    description: 'Home Assistant smart home control and monitoring',
    tools: [
      'ha_list_entities', 'ha_get_state', 'ha_list_services', 'ha_call_service',
    ],
  ),
  'kanban': ToolsetDef(
    description:
        'Kanban multi-agent coordination — only active when the agent is '
        'spawned by the kanban dispatcher (HERMES_KANBAN_TASK env set). Lets '
        'workers mark tasks done with structured handoffs, block for human '
        'input, heartbeat during long ops, comment on threads, attach files, '
        'and (for orchestrators) list, unblock, and fan out tasks.',
    tools: [
      'kanban_show', 'kanban_list', 'kanban_complete', 'kanban_block',
      'kanban_heartbeat', 'kanban_comment',
      'kanban_create', 'kanban_link',
      'kanban_unblock',
      'kanban_attach', 'kanban_attach_url', 'kanban_attachments',
    ],
  ),
  'discord': ToolsetDef(
    description:
        'Discord read and participate tools (fetch messages, search members, '
        'create threads)',
    tools: ['discord'],
  ),
  'discord_admin': ToolsetDef(
    description:
        'Discord server management (list channels/roles, pin messages, '
        'assign roles)',
    tools: ['discord_admin'],
  ),
  'yuanbao': ToolsetDef(
    description: 'Yuanbao platform tools - group info, member queries, DM, stickers',
    tools: [
      'yb_query_group_info',
      'yb_query_group_members',
      'yb_send_dm',
      'yb_search_sticker',
      'yb_send_sticker',
    ],
  ),
  'feishu_doc': ToolsetDef(
    description: 'Read Feishu/Lark document content',
    tools: ['feishu_doc_read'],
  ),
  'feishu_drive': ToolsetDef(
    description:
        'Feishu/Lark document comment operations (list, reply, add)',
    tools: [
      'feishu_drive_list_comments', 'feishu_drive_list_comment_replies',
      'feishu_drive_reply_comment', 'feishu_drive_add_comment',
    ],
  ),
  'spotify': ToolsetDef(
    description:
        'Native Spotify playback, search, playlist, album, and library tools',
    tools: [
      'spotify_playback', 'spotify_devices', 'spotify_queue', 'spotify_search',
      'spotify_playlists', 'spotify_albums', 'spotify_library',
    ],
  ),

  // Scenario-specific toolsets
  'debugging': ToolsetDef(
    description: 'Debugging and troubleshooting toolkit',
    tools: ['terminal', 'process'],
    includes: ['web', 'file'],
  ),
  'safe': ToolsetDef(
    description: 'Safe toolkit without terminal access',
    tools: [],
    includes: ['web', 'vision', 'image_gen'],
  ),
  'coding': ToolsetDef(
    description:
        'Coding-focused toolset: files, terminal, search, web docs, skills, '
        'todo, delegate, vision, browser',
    tools: [
      'web_search', 'web_extract',
      'terminal', 'process', 'read_terminal', 'close_terminal',
      'read_file', 'write_file', 'patch', 'search_files',
      'vision_analyze',
      'skills_list', 'skill_view', 'skill_manage',
      'browser_navigate', 'browser_snapshot', 'browser_click',
      'browser_type', 'browser_scroll', 'browser_back',
      'browser_press', 'browser_get_images',
      'browser_vision', 'browser_console', 'browser_cdp', 'browser_dialog',
      'todo', 'memory',
      'session_search', 'clarify',
      'execute_code', 'delegate_task',
    ],
    posture: true,
  ),

  // Full Hermes toolsets (CLI + messaging platforms)
  'hermes-acp': ToolsetDef(
    description:
        'Editor integration (VS Code, Zed, JetBrains) — coding-focused tools '
        'without messaging, audio, or clarify UI',
    tools: [
      'web_search', 'web_extract',
      'terminal', 'process',
      'read_file', 'write_file', 'patch', 'search_files',
      'vision_analyze',
      'skills_list', 'skill_view', 'skill_manage',
      'browser_navigate', 'browser_snapshot', 'browser_click',
      'browser_type', 'browser_scroll', 'browser_back',
      'browser_press', 'browser_get_images',
      'browser_vision', 'browser_console', 'browser_cdp', 'browser_dialog',
      'todo', 'memory',
      'session_search',
      'execute_code', 'delegate_task',
    ],
  ),
  'hermes-api-server': ToolsetDef(
    description:
        'OpenAI-compatible API server — full agent tools accessible via HTTP '
        '(no interactive UI tools like clarify or send_message)',
    tools: [
      'web_search', 'web_extract',
      'terminal', 'process',
      'read_file', 'write_file', 'patch', 'search_files',
      'vision_analyze', 'image_generate',
      'bfl_flux3_text_to_video', 'bfl_flux3_image_to_video',
      'bfl_flux3_keyframes_to_video', 'bfl_flux3_video_continuation',
      'bfl_flux3_get_result', 'bfl_flux3_prompting_guide',
      'skills_list', 'skill_view', 'skill_manage',
      'browser_navigate', 'browser_snapshot', 'browser_click',
      'browser_type', 'browser_scroll', 'browser_back',
      'browser_press', 'browser_get_images',
      'browser_vision', 'browser_console', 'browser_cdp', 'browser_dialog',
      'todo', 'memory',
      'session_search',
      'execute_code', 'delegate_task',
      'cronjob',
      'ha_list_entities', 'ha_get_state', 'ha_list_services', 'ha_call_service',
    ],
  ),
  'hermes-cli': ToolsetDef(
    description:
        'Full interactive CLI toolset - all default tools plus cronjob management',
    tools: hermesCoreTools,
  ),
  'hermes-cron': ToolsetDef(
    description:
        'Default cron toolset - same core tools as hermes-cli; gated by '
        '`hermes tools`',
    tools: hermesCoreTools,
  ),
  'hermes-telegram': ToolsetDef(
    description:
        'Telegram bot toolset - full access for personal use (terminal has '
        'safety checks)',
    tools: hermesCoreTools,
  ),
  'hermes-discord': ToolsetDef(
    description:
        'Discord bot toolset - full access (terminal has safety checks via '
        'dangerous command approval)',
    tools: [...hermesCoreTools, 'discord', 'discord_admin'],
  ),
  'hermes-whatsapp': ToolsetDef(
    description:
        'WhatsApp bot toolset - similar to Telegram (personal messaging, more trusted)',
    tools: hermesCoreTools,
  ),
  'hermes-slack': ToolsetDef(
    description:
        'Slack bot toolset - full access for workspace use (terminal has '
        'safety checks)',
    tools: hermesCoreTools,
  ),
  'hermes-signal': ToolsetDef(
    description:
        'Signal bot toolset - encrypted messaging platform (full access)',
    tools: hermesCoreTools,
  ),
  'hermes-bluebubbles': ToolsetDef(
    description:
        'BlueBubbles iMessage bot toolset - Apple iMessage via local '
        'BlueBubbles server',
    tools: hermesCoreTools,
  ),
  'hermes-homeassistant': ToolsetDef(
    description:
        'Home Assistant bot toolset - smart home event monitoring and control',
    tools: hermesCoreTools,
  ),
  'hermes-email': ToolsetDef(
    description: 'Email bot toolset - interact with Hermes via email (IMAP/SMTP)',
    tools: hermesCoreTools,
  ),
  'hermes-mattermost': ToolsetDef(
    description:
        'Mattermost bot toolset - self-hosted team messaging (full access)',
    tools: hermesCoreTools,
  ),
  'hermes-matrix': ToolsetDef(
    description:
        'Matrix bot toolset - decentralized encrypted messaging (full access)',
    tools: hermesCoreTools,
  ),
  'hermes-dingtalk': ToolsetDef(
    description:
        'DingTalk bot toolset - enterprise messaging platform (full access)',
    tools: hermesCoreTools,
  ),
  'hermes-feishu': ToolsetDef(
    description:
        'Feishu/Lark bot toolset - enterprise messaging via Feishu/Lark '
        '(full access)',
    tools: [
      ...hermesCoreTools,
      'feishu_doc_read',
      'feishu_drive_list_comments',
      'feishu_drive_list_comment_replies',
      'feishu_drive_reply_comment',
      'feishu_drive_add_comment',
    ],
  ),
  'hermes-weixin': ToolsetDef(
    description:
        'Weixin bot toolset - personal WeChat messaging via iLink (full access)',
    tools: hermesCoreTools,
  ),
  'hermes-qqbot': ToolsetDef(
    description: 'QQBot toolset - QQ messaging via Official Bot API v2 (full access)',
    tools: hermesCoreTools,
  ),
  'hermes-wecom': ToolsetDef(
    description:
        'WeCom bot toolset - enterprise WeChat messaging (full access)',
    tools: hermesCoreTools,
  ),
  'hermes-wecom-callback': ToolsetDef(
    description:
        'WeCom callback toolset - enterprise self-built app messaging '
        '(full access)',
    tools: hermesCoreTools,
  ),
  'hermes-yuanbao': ToolsetDef(
    description: 'Yuanbao Bot 元宝消息平台工具集 - 群信息、成员查询、私聊、贴纸表情',
    tools: [...hermesCoreTools, 'yb_query_group_info', 'yb_query_group_members', 'yb_send_dm', 'yb_search_sticker', 'yb_send_sticker'],
  ),
  'hermes-sms': ToolsetDef(
    description: 'SMS bot toolset - interact with Hermes via SMS (Twilio)',
    tools: hermesCoreTools,
  ),
  'hermes-webhook': ToolsetDef(
    description: 'Webhook toolset - receive and process external webhook events',
    tools: hermesWebhookSafeTools,
  ),
  'hermes-gateway': ToolsetDef(
    description: 'Gateway toolset - union of all messaging platform tools',
    tools: [],
    includes: [
      'hermes-telegram', 'hermes-discord', 'hermes-whatsapp', 'hermes-slack',
      'hermes-signal', 'hermes-bluebubbles', 'hermes-homeassistant',
      'hermes-email', 'hermes-sms', 'hermes-mattermost', 'hermes-matrix',
      'hermes-dingtalk', 'hermes-feishu', 'hermes-wecom',
      'hermes-wecom-callback', 'hermes-weixin', 'hermes-qqbot',
      'hermes-webhook', 'hermes-yuanbao',
    ],
  ),
};

/// 返回插件注册的工具集名（在 registry 中但不在静态 TOOLSETS 中）。
Set<String> _getPluginToolsetNames() {
  try {
    return registry
        .getRegisteredToolsetNames()
        .where((name) => !toolsetDefs.containsKey(name))
        .toSet();
  } catch (_) {
    return <String>{};
  }
}

/// 返回 registry 中注册的显式工具集别名。
Map<String, String> _getRegistryToolsetAliases() {
  try {
    return registry.getRegisteredToolsetAliases();
  } catch (_) {
    return <String, String>{};
  }
}

/// 获取工具集定义。
///
/// [includeRegistry] 为 True（默认）时合并 plugins/overlays 经 registry 注册进
/// 此工具集的工具。为 False 时只返回静态 ``TOOLSETS`` 定义。
ToolsetDef? getToolset(String name, {bool includeRegistry = true}) {
  final toolset = toolsetDefs[name];

  if (!includeRegistry) {
    if (toolset == null) {
      return null;
    }
    return ToolsetDef(
      description: toolset.description,
      tools: List.of(toolset.tools),
      includes: List.of(toolset.includes),
      posture: toolset.posture,
    );
  }

  if (toolset != null) {
    final mergedTools = toolset.tools
        .toSet()
        .union(registry.getToolNamesForToolset(name).toSet())
        .toList()
      ..sort();
    return ToolsetDef(
      description: toolset.description,
      tools: mergedTools,
      includes: toolset.includes,
      posture: toolset.posture,
    );
  }

  var registryToolset = name;
  var description = 'Plugin toolset: $name';
  final aliasTarget = registry.getToolsetAliasTarget(name);

  if (!_getPluginToolsetNames().contains(name)) {
    registryToolset = aliasTarget ?? '';
    if (registryToolset.isEmpty) {
      return null;
    }
    description = "MCP server '$name' tools";
  } else {
    final reverseAliases = <String, String>{};
    _getRegistryToolsetAliases().forEach((alias, canonical) {
      if (!toolsetDefs.containsKey(alias)) {
        reverseAliases[canonical] = alias;
      }
    });
    final alias = reverseAliases[name];
    if (alias != null) {
      description = "MCP server '$alias' tools";
    }
  }

  return ToolsetDef(
    description: description,
    tools: registry.getToolNamesForToolset(registryToolset),
    includes: const [],
  );
}

/// 返回 ``hermes-*`` bundle 的平台特定工具，排除 core。
///
/// Platform bundles 定义为 ``_HERMES_CORE_TOOLS + [platform extras]``。当 bundle
/// 名出现在 ``disabled_toolsets`` 时，减掉整个 bundle 会剥离每个启用工具集共享
/// 的 core 工具（terminal、read_file 等），清空模型工具列表。此函数只返回 bundle
/// 的非 core 差集。
Set<String> bundleNonCoreTools(String toolsetName) {
  final core = hermesCoreTools.toSet();
  final tsDef = getToolset(toolsetName);
  if (tsDef == null || tsDef.tools.isEmpty) {
    return resolveToolset(toolsetName).toSet().difference(core);
  }
  final toRemove = tsDef.tools.toSet().difference(core);
  for (final inc in tsDef.includes) {
    final incDef = getToolset(inc);
    if (incDef != null && incDef.tools.isNotEmpty) {
      toRemove.addAll(incDef.tools.toSet().difference(core));
    }
  }
  return toRemove;
}

/// 递归解析工具集到所有工具名。
///
/// 处理工具集组合（递归解析 includes），带循环检测。
List<String> resolveToolset(String name, {Set<String>? visited, bool includeRegistry = true}) {
  final visitedSet = visited ?? <String>{};

  // 特殊别名：代表每个工具集的所有工具。
  if (name == 'all' || name == '*') {
    final allTools = <String>{};
    for (final toolsetName in getToolsetNames()) {
      allTools.addAll(
        resolveToolset(toolsetName, visited: {...visitedSet}, includeRegistry: includeRegistry),
      );
    }
    return allTools.toList()..sort();
  }

  // 循环/已解析（菱形依赖）检测：静默返回 []。
  if (visitedSet.contains(name)) {
    return [];
  }
  visitedSet.add(name);

  // 获取工具集定义。
  final toolset = getToolset(name, includeRegistry: includeRegistry);
  if (toolset == null) {
    return [];
  }

  // 收集直接工具。
  final tools = toolset.tools.toSet();

  // 递归解析 includes，跨兄弟 include 共享 visited 集。
  for (final includedName in toolset.includes) {
    tools.addAll(
      resolveToolset(
        includedName,
        visited: visitedSet,
        includeRegistry: includeRegistry,
      ),
    );
  }

  return tools.toList()..sort();
}

/// 解析多个工具集并合并工具。
List<String> resolveMultipleToolsets(List<String> toolsetNames) {
  final allTools = <String>{};
  for (final name in toolsetNames) {
    allTools.addAll(resolveToolset(name));
  }
  return allTools.toList()..sort();
}

/// 获取所有可用工具集及其定义（静态 + 插件注册）。
Map<String, ToolsetDef> getAllToolsets() {
  final result = Map<String, ToolsetDef>.from(toolsetDefs);
  final aliases = _getRegistryToolsetAliases();
  for (final tsName in _getPluginToolsetNames()) {
    var displayName = tsName;
    aliases.forEach((alias, canonical) {
      if (canonical == tsName && !toolsetDefs.containsKey(alias)) {
        displayName = alias;
      }
    });
    if (result.containsKey(displayName)) {
      continue;
    }
    final toolset = getToolset(displayName);
    if (toolset != null) {
      result[displayName] = toolset;
    }
  }
  return result;
}

/// 获取所有可用工具集名（排除别名），含插件注册。
List<String> getToolsetNames() {
  final names = toolsetDefs.keys.toSet();
  final aliases = _getRegistryToolsetAliases();
  for (final tsName in _getPluginToolsetNames()) {
    var added = false;
    aliases.forEach((alias, canonical) {
      if (canonical == tsName && !toolsetDefs.containsKey(alias)) {
        names.add(alias);
        added = true;
      }
    });
    if (!added) {
      names.add(tsName);
    }
  }
  return names.toList()..sort();
}

/// 检查工具集名是否有效。
bool validateToolset(String name) {
  if (name == 'all' || name == '*') {
    return true;
  }
  if (toolsetDefs.containsKey(name)) {
    return true;
  }
  if (_getPluginToolsetNames().contains(name)) {
    return true;
  }
  return _getRegistryToolsetAliases().containsKey(name);
}

/// 运行时创建自定义工具集。
void createCustomToolset(
  String name,
  String description, {
  List<String>? tools,
  List<String>? includes,
}) {
  toolsetDefs[name] = ToolsetDef(
    description: description,
    tools: tools ?? const [],
    includes: includes ?? const [],
  );
}

/// 获取工具集详细信息（含解析后工具）。
Map<String, dynamic>? getToolsetInfo(String name) {
  final toolset = getToolset(name);
  if (toolset == null) {
    return null;
  }
  final resolvedTools = resolveToolset(name);
  return {
    'name': name,
    'description': toolset.description,
    'direct_tools': toolset.tools,
    'includes': toolset.includes,
    'resolved_tools': resolvedTools,
    'tool_count': resolvedTools.length,
    'is_composite': toolset.includes.isNotEmpty,
  };
}
