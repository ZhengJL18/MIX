/// 工作流定义：一套人设 + 工具 + 行为约束（Claude Code 式）。
///
/// 引擎（MIXAgent）是通用的，工作流是配置。换工作流 = 换配置对象。
library;

class AgentWorkflow {
  final String id;
  final String name;
  final String description; // 给用户看的简短说明。
  final String systemPrompt;
  final List<String> toolsets;
  final bool planGate; // 是否强制先计划（plan 模式）。
  final bool autoDelegate; // 是否鼓励委派子任务给快模型。
  final int maxSteps;

  const AgentWorkflow({
    required this.id,
    required this.name,
    required this.description,
    required this.systemPrompt,
    required this.toolsets,
    this.planGate = false,
    this.autoDelegate = false,
    this.maxSteps = 100,
  });

  /// 完整的系统提示（人设 + 委派策略）。
  String buildSystemPrompt({
    String contextBlock = '',
    String skillBlock = '',
  }) {
    var prompt = systemPrompt;
    if (autoDelegate) {
      prompt += '\n\n遇到机械性、可独立的小任务（改一行代码、简单文件操作、'
          '格式化、简单验证）时，用 delegate_task 委派给快速子代理处理，'
          '光速返回结果；复杂任务（架构设计、多文件重构、调试）自己处理。';
    }
    if (planGate) {
      prompt += '\n\n重要任务先规划再执行：用只读工具探索现状，'
          '输出清晰的执行计划。';
    }
    if (contextBlock.isNotEmpty) {
      prompt = '$prompt\n\n$contextBlock';
    }
    if (skillBlock.isNotEmpty) {
      prompt = '$prompt\n\n$skillBlock';
    }
    return prompt;
  }
}

/// 内置工作流。
const List<AgentWorkflow> builtinWorkflows = [
  AgentWorkflow(
    id: 'coding',
    name: '写代码',
    description: '编程 agent：先计划后执行，git 管理，可跑终端',
    systemPrompt: '你是 MIX 的编程助手，在 App 文档目录（工作目录）中工作。\n'
        '工作流：\n'
        '1) 动手前先探索：git_status/git_diff 看现状，read_file/search_files '
        '了解相关代码，必要时看目录结构。\n'
        '2) 优先用 patch 做小改动（比整体重写精准、省 token）；大改动先想清楚'
        '影响面再写。\n'
        '3) 改完用 git_diff 自查改动是否符合预期。\n'
        '4) 遵守项目现有风格与约定，不引入无关改动。\n'
        '5) 需要提交时用 git_add/git_commit，提交信息简洁说明"做了什么、为什么"。\n'
        '用中文回答。',
    toolsets: ['file', 'git', 'web', 'vision', 'delegate', 'moa', 'clarify', 'todo'],
    planGate: true,
    autoDelegate: true,
    maxSteps: 150,
  ),
  AgentWorkflow(
    id: 'research',
    name: '研究',
    description: '调研分析：搜索提取总结，不写代码',
    systemPrompt: '你是 MIX 的研究助手。搜索→提取→总结，用 web_search 找'
        '资料、web_extract 抓全文，关键信息存入 memory。不写代码。用中文。',
    toolsets: ['web', 'memory', 'todo', 'clarify', 'delegate', 'moa'],
    planGate: false,
    autoDelegate: false,
    maxSteps: 60,
  ),
  AgentWorkflow(
    id: 'daily',
    name: '通用助手',
    description: '全能 agent：文件/终端/git/上网/记忆/技能',
    systemPrompt: '你是 MIX，一个通用的 AI agent，具备文件读写、git、上网、'
        '记忆、技能等能力。可以操作 App 文档目录里的文件、改代码、查资料。'
        '对不确定的任务先探查再动手。用户要求出题/刷题/考考我时，用 '
        'study_quiz 工具呈现批量题卡（一次多题，可机械判分）。用中文回答。',
    toolsets: [
      'file', 'web', 'memory', 'todo', 'skills', 'session_search', 'git',
      'clarify', 'delegate', 'moa', 'cron', 'vision', 'notes', 'quiz',
    ],
    planGate: false,
    autoDelegate: true,
    maxSteps: 100,
  ),
  AgentWorkflow(
    id: 'company',
    name: '公司模式',
    description: 'CEO 调度部门：多角色分工讨论处理复杂任务',
    systemPrompt: '你是 MIX 公司的 CEO。你手下有多个部门，每个部门由'
        '专业角色组成。收到任务时：1) 判断任务性质，选择合适部门；'
        '2) 用 delegate_to_department 把任务派给部门；3) 汇总部门结果给用户。'
        '任务复杂时可拆分成多个子任务分派给不同部门，或让部门内的子代理'
        '继续下探。部门列表：\n',
    toolsets: [
      'file', 'web', 'memory', 'todo', 'skills', 'session_search', 'git',
      'company', 'moa', 'delegate', 'clarify', 'vision', 'cron',
    ],
    planGate: false,
    autoDelegate: true,
    maxSteps: 200,
  ),
  AgentWorkflow(
    id: 'study',
    name: '学习模式',
    description: '聊天即学习主场：出题、作答、判题、讲解',
    systemPrompt: '你是 MIX 的学习教练。这是学习模式，聊天就是学习主场。\n'
        '工作流：\n'
        '1) 学生说"出几道X的题"→ 先调 study_list 宣告回合（"这轮 N 题，'
        '主练 X，上次正确率 Y%"），再调 study_question 出题。\n'
        '2) 出题呈现用 study_quiz 工具（一次可传多题，UI 渲染成可滑动题卡，'
        '题目和选项在同一张卡上）。题目内容可以直接写，也可以用 study_question '
        '生成后传入。每题结构：question（题干）、options（2-4 个选项，不带'
        '字母前缀）、answer（正确选项，与选项文本一致）、explanation（简短解析）。'
        '选择题设 grade=true（UI 机械判分）；开放题（无选项）设 grade=false，'
        '由你讲解点评。update_profile 在本次作答值得记入画像时设 true。\n'
        '3) study_quiz 返回逐题作答结果（含「机械判定：回答正确 / 回答错误」'
        '标记——判题由界面机械完成，你直接读标记，绝不要自己比较字母）。'
        '然后流式讲解：答对一句带过（省 token），答错讲清错因、正确思路、'
        '干扰项为什么错，开放题点评思路与不足。题目来自 study_question（有'
        '真实 question_id）时调 study_record 落库；自己手写的题目没有 '
        'question_id，不落库，靠讲解和 study_profile_update 沉淀。\n'
        '4) 讲解完提议下一题，但保持题间零废话，练习密度优先。\n'
        '5) 连续几题后做回合小结："N 题对 M，弱项在…，建议…"。\n'
        '6) 学生追问概念、问"为什么选B"、要求举反例 → 展开讲（开放题天然支持）。\n'
        '7) 讲解过程中如果观察到学生的新情况（常错概念、混淆点、反复犯的'
        '错误、明显的进步），调用 study_profile_update 记进学生画像，'
        '画像会用于后续出题针对性。不需要"做错才记"，有值得记的就记。\n'
        '用中文。',
    toolsets: ['study', 'quiz', 'clarify', 'memory', 'file', 'session_search', 'notes'],
    planGate: false,
    autoDelegate: false,
    maxSteps: 120,
  ),
];

/// 按 id 查找工作流。
AgentWorkflow? findWorkflow(String id) {
  for (final w in builtinWorkflows) {
    if (w.id == id) {
      return w;
    }
  }
  return null;
}
