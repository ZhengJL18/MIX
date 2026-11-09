/// 子代理 / 部门 / MoA 讨论执行器（从 ChatScreen 抽离，吸收官方健壮性机制）。
///
/// 对照 `NousResearch/hermes-agent/agent/moa_loop.py` 审核后重构：
/// - **进度事件**：讨论每轮/每视角实时回调 [onProgress]（对齐官方
///   `moa-progress-event` / `moa-reference-event` 驱动 UI）
/// - **失败隔离**：每视角 / 每角色 try/except → 注记，永不中断整体（对齐官方
///   `_run_reference` 的 `[failed]` 语义）
/// - **maxTokens**：讨论发言 / 子代理输出上限（对齐官方 `reference_max_tokens`
///   默认 600）
/// - **工具事件转发**：子代理 / 部门角色的 `onToolEvent` 透传 UI（对齐官方
///   delegate_task 的 live child status）
/// - **取消传播**：[isCancelled] 检查点，讨论轮间 / 子代理执行前早停（对齐官方
///   user interrupt 早停 reference fan-out）
library;

import '../agent/agent.dart';
import '../agent/company.dart';
import '../llm/llm_client.dart';
import '../llm/openai_llm.dart';
import '../tools/model_tools.dart';

/// MoA 讨论阶段。
enum MoaStage { roundStart, perspectiveStart, perspectiveDone, synthesizing, done }

/// 一条 MoA 讨论进度事件。
class MoaProgress {
  final MoaStage stage;
  final int round;
  final int totalRounds;
  final String? perspective; // 视角名（架构/性能/严谨）
  final String? output; // perspectiveDone 时该视角的发言 / done 时综合结果

  MoaProgress({
    required this.stage,
    required this.round,
    required this.totalRounds,
    this.perspective,
    this.output,
  });
}

/// 讨论视角人设（架构/性能/严谨）。
const List<(String, String)> discussionPerspectives = [
  ('架构', '你是一位资深架构师，关注系统结构、模块划分、可扩展性和维护性。'),
  ('性能', '你是一位性能优化专家，关注效率、资源占用、瓶颈和权衡。'),
  ('严谨', '你是一位批判性审查者，关注边界情况、错误处理、风险和遗漏。'),
];

/// 子代理工具事件回调（UI 显示工具卡）。
typedef SubAgentToolEvent = void Function(String name, String status);

/// 多代理执行器：runSubAgent / runDepartment / runDiscussion。
class MultiAgentService {
  /// 主模型客户端（主 agent 同款）。
  final LlmClient llm;

  /// 快模型客户端（分级委派：子任务优先用快/便宜模型）。null 则 fallback [llm]。
  final LlmClient? fastLlm;

  /// 取消检查点（主 agent cancel 时返回 true → 讨论/子代理早停）。
  final bool Function()? isCancelled;

  /// 讨论发言输出上限（对齐官方 reference_max_tokens=600）。
  final int discussionMaxTokens;

  /// 子代理 / 综合输出上限。
  final int subAgentMaxTokens;

  MultiAgentService({
    required this.llm,
    this.fastLlm,
    this.isCancelled,
    this.discussionMaxTokens = 600,
    this.subAgentMaxTokens = 2000,
  });

  bool get _cancelled => isCancelled?.call() ?? false;

  /// 子代理：独立 MIXAgent 执行任务，工具事件转发 UI。
  ///
  /// [depth] 当前层数（0=主代理，1=一级子代理…）；子代理可继续 delegate
  /// 下探（MIXAgent.agentDepth 传递，深度判断不再依赖并行共享全局）。
  Future<String> runSubAgent({
    required String task,
    List<String>? toolsets,
    required int depth,
    SubAgentToolEvent? onToolEvent,
    void Function(String delta)? onDelta,
  }) async {
    if (_cancelled) return '（已取消）';
    // 分级委派：快模型优先；未配置则 fallback 主模型。
    final effectiveLlm = fastLlm ?? llm;
    // 过滤 company（子代理不派部门，防部门递归）。
    final effectiveToolsets = (toolsets ?? const ['file', 'web', 'git'])
        .where((t) => t != 'company')
        .toList();
    final subAgent = MIXAgent(
      llm: effectiveLlm,
      systemPrompt: '你是 MIX 的第 $depth 层子代理。独立完成给定任务并'
          '简洁汇报结果。任务太复杂时，可继续 delegate_task 派给更下层的'
          '子代理。用中文。',
      toolDefinitionsProvider: () => getToolDefinitions(
        enabledToolsets: effectiveToolsets,
        quietMode: true,
      ),
      maxIterations: 20,
      agentDepth: depth + 1,
      onDelta: onDelta,
      onToolEvent: onToolEvent,
    );
    try {
      final result = await subAgent.runConversation(task);
      return result.finalResponse ?? '（子代理无输出）';
    } catch (e) {
      return '子任务失败：$e';
    }
  }

  /// 部门执行器（公司模式）：角色讨论 → 角色分工执行 → 经理汇总。
  ///
  /// 每角色执行独立 try/except（官方 `_run_reference` 失败隔离：一个角色
  /// 失败不拖垮整部门）；角色 MIXAgent 带 [agentDepth] 且工具事件转发。
  Future<String> runDepartment({
    required String department,
    required String task,
    required int depth,
    SubAgentToolEvent? onToolEvent,
    void Function(String delta)? onDelta,
  }) async {
    final dep = findActiveDepartment(department);
    if (dep == null) {
      return '未知部门：$department';
    }

    // 第 1 步：角色间讨论一轮（各自给专业意见，互看后补充/反驳）。
    String discussionBlock = '';
    if (dep.roles.length > 1) {
      final opinions = await Future.wait(
        dep.roles.map((role) async {
          if (_cancelled) return '「$role」：（已取消）';
          try {
            final turn = await llm.chatStream(
              messages: [
                {
                  'role': 'system',
                  'content': '你是「${dep.name}」的$role。围绕部门任务给出你的'
                      '专业意见，重点是你视角下的关键点。用中文。',
                },
                {'role': 'user', 'content': '部门任务：$task'},
              ],
              maxTokens: discussionMaxTokens,
            );
            return '「$role」：${turn.content ?? '(无意见)'}';
          } catch (e) {
            return '「$role」：（讨论失败 $e）';
          }
        }),
      );
      discussionBlock = opinions.join('\n');
    }

    // 第 2 步：各角色带讨论结果分工执行（并行，每角色隔离 + 工具事件转发）。
    final roleOutputs = await Future.wait(
      dep.roles.map((role) async {
        if (_cancelled) return '「$role」：（已取消）';
        try {
          final roleAgent = MIXAgent(
            llm: llm,
            systemPrompt: '你是「${dep.name}」的$role。参考团队讨论，完成你的'
                '分工工作。可调用工具。用中文。',
            toolDefinitionsProvider: () => getToolDefinitions(
              // 角色不再派部门（防部门递归），但可 delegate 子任务/讨论。
              enabledToolsets: dep.toolsets
                  .where((t) => t != 'company')
                  .toList(),
              quietMode: true,
            ),
            maxIterations: 20,
            agentDepth: depth + 1,
            onDelta: onDelta,
            onToolEvent: onToolEvent,
          );
          final result = await roleAgent.runConversation(
            '$task\n\n团队讨论：\n$discussionBlock',
          );
          return '「$role」：${result.finalResponse ?? '(无输出)'}';
        } catch (e) {
          return '「$role」：执行失败 $e';
        }
      }),
    );

    // 第 3 步：经理汇总各角色输出给 CEO。
    try {
      final summaryTurn = await llm.chatStream(
        messages: [
          {
            'role': 'system',
            'content': '你是「${dep.name}」的经理。综合下面部门成员的输出，'
                '给 CEO 一个简洁的最终结果：提炼关键结论，合并重复，标出分歧。'
                '用中文。',
          },
          {
            'role': 'user',
            'content': '部门任务：$task\n\n成员输出：\n${roleOutputs.join('\n')}',
          },
        ],
        maxTokens: subAgentMaxTokens,
      );
      final summary = summaryTurn.content ?? '';
      return summary.isNotEmpty ? summary : roleOutputs.join('\n');
    } catch (e) {
      return roleOutputs.join('\n');
    }
  }

  /// 多视角多轮讨论（Kimi 式，保留辩论形态）：每轮所有视角并行发言
  /// （看到上轮彼此内容），N 轮后主持人综合。
  ///
  /// 每视角经 [onProgress] 推 [MoaProgress] 进度（官方 progress-event 语义），
  /// 失败降级为 `(发言失败…)` 不中断；[rounds] 钳制到 [1, 4]。
  Future<String> runDiscussion({
    required String topic,
    required int rounds,
    void Function(MoaProgress progress)? onProgress,
  }) async {
    final transcript = <String>[];
    final totalRounds = rounds.clamp(1, 4);

    for (var r = 1; r <= totalRounds; r++) {
      if (_cancelled) break;
      onProgress?.call(MoaProgress(
        stage: MoaStage.roundStart,
        round: r,
        totalRounds: totalRounds,
      ));

      // 每轮并行：所有视角看到上轮记录，各自回应。
      final roundOutputs = await Future.wait(
        discussionPerspectives.map((p) async {
          if (_cancelled) return (p.$1, '（已取消）');
          onProgress?.call(MoaProgress(
            stage: MoaStage.perspectiveStart,
            round: r,
            totalRounds: totalRounds,
            perspective: p.$1,
          ));
          try {
            final system = '你是讨论参与者「${p.$1}」。${p.$2}\n'
                '围绕主题给出你的专业见解。讨论规则：观点要具体、可反驳、'
                '能补充或修正他人的意见。用中文。';
            final messages = <Map<String, dynamic>>[
              {'role': 'system', 'content': system},
              {
                'role': 'user',
                'content': '主题：$topic\n\n讨论记录：\n'
                    '${transcript.isEmpty ? '(这是第一轮，请给出你的初始见解)' : transcript.join('\n')}',
              },
            ];
            final turn = await llm.chatStream(
              messages: messages,
              maxTokens: discussionMaxTokens,
            );
            final text = turn.content ?? '（无发言）';
            onProgress?.call(MoaProgress(
              stage: MoaStage.perspectiveDone,
              round: r,
              totalRounds: totalRounds,
              perspective: p.$1,
              output: text,
            ));
            return (p.$1, text);
          } catch (e) {
            return (p.$1, '（发言失败：$e）');
          }
        }),
      );

      // 把本轮发言追加到共享记录。
      for (final (name, text) in roundOutputs) {
        transcript.add('「$name」：$text');
      }
    }

    if (_cancelled) {
      final cancelled = '讨论已取消。\n\n${transcript.join('\n')}';
      onProgress?.call(MoaProgress(
        stage: MoaStage.done,
        round: totalRounds,
        totalRounds: totalRounds,
        output: cancelled,
      ));
      return cancelled;
    }

    // 主持人综合所有讨论给最终结论。
    onProgress?.call(MoaProgress(
      stage: MoaStage.synthesizing,
      round: totalRounds,
      totalRounds: totalRounds,
    ));
    try {
      final finalTurn = await llm.chatStream(
        messages: [
          {
            'role': 'system',
            'content': '你是一位讨论主持人。综合下面所有专家的讨论，给出一个'
                '清晰的最终结论：总结共识、点明分歧、给出你的判断。用中文。',
          },
          {
            'role': 'user',
            'content': '主题：$topic\n\n完整讨论记录：\n${transcript.join('\n')}',
          },
        ],
        maxTokens: subAgentMaxTokens,
      );
      final summary = finalTurn.content ?? '';
      final result = summary.isNotEmpty
          ? summary
          : '讨论完成，但综合失败。\n\n${transcript.join('\n')}';
      onProgress?.call(MoaProgress(
        stage: MoaStage.done,
        round: totalRounds,
        totalRounds: totalRounds,
        output: result,
      ));
      return result;
    } catch (e) {
      final result = '讨论完成，但综合失败：$e\n\n${transcript.join('\n')}';
      onProgress?.call(MoaProgress(
        stage: MoaStage.done,
        round: totalRounds,
        totalRounds: totalRounds,
        output: result,
      ));
      return result;
    }
  }
}
