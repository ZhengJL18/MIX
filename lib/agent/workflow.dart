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
  String buildSystemPrompt({String contextBlock = '', String skillBlock = ''}) {
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
    description: '代码开发：先计划后执行，git 管理，可委派快模型',
    systemPrompt: '你是 MIX 的编程助手。用 git 管理代码：先看 status/diff '
        '了解现状，patch 优先于整体重写，改完用 git_status/git_diff 自查。'
        '需要时下载依赖、跑测试。用中文回答。',
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
    description: '全能助手：文件/上网/git/记忆/技能都用',
    systemPrompt: '你是 MIX，一个运行在 Android 上的全能 agent。'
        '文件、上网、git、记忆、技能都用得上。用中文回答。',
    toolsets: [
      'file', 'web', 'memory', 'todo', 'skills', 'session_search', 'git',
      'clarify', 'delegate', 'moa', 'cron', 'vision', 'notes',
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
        '2) study_question 会返回题目 JSON（含 question/options/answer/'
        'explanation/question_id）。你必须把这份 JSON **原样一字不改**用 '
        '```json 代码块包在回复里输出，这样界面才能渲染成可点的选择题卡片。'
        '绝对不要重排字段、不要丢 question_id（丢了它选项就点不了）。'
        '包题目时不要额外转述题干（界面会显示卡片），只简短引导如"来做这题"，'
        '然后输出 ```json 块。\n'
        '3) 学生作答后（机械判结果会记录）→ 用流式讲解：答对一句带过'
        '（省 token），答错讲清错因与正确思路。\n'
        '4) 讲解完提议下一题，但保持题间零废话，练习密度优先。\n'
        '5) 连续几题后做回合小结："N 题对 M，弱项在…，建议…"。\n'
        '6) 学生追问概念、问"为什么选B"、要求举反例 → 展开讲（开放题天然支持）。\n'
        '7) 讲解过程中如果观察到学生的新情况（常错概念、混淆点、反复犯的'
        '错误、明显的进步），调用 study_profile_update 记进学生画像，'
        '画像会用于后续出题针对性。不需要"做错才记"，有值得记的就记。\n'
        '用中文。判题是机械的，你只负责讲解，不要质疑机械判题结果。',
    toolsets: ['study', 'memory', 'file', 'session_search', 'notes'],
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
