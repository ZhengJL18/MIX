/// 对应 `ref/hermes-agent/agent/conversation_loop.py` 的 run_conversation 核心
/// （像素级复刻，最小闭环子集）。
///
/// 完整 run_conversation 是 4500+ 行（压缩门控、截断重试、中断、记忆 review、
/// MoA、fallback 链等）。本文件复刻**主循环骨架**（这是最小闭环的核心数据流）：
///
/// 1. **Prologue**：组装 messages（system + conversation_history + user）
/// 2. **主循环**（while api_call_count < max_iterations 且 budget 有余量）：
///    - 组包：api_messages + getToolDefinitions()（OpenAI 格式工具 schema）
///    - LLM 调用：chatStream（含 tool_calls 聚合）
///    - 响应含 tool_calls → 逐工具经 model_tools.handleFunctionCall 执行，
///      结果回填为 role=tool 消息 → 继续循环
///    - 响应无 tool_calls → 确定 final_response → 结束
/// 3. **收尾**：返回 {final_response, messages, api_calls, completed}
///
/// 外围（压缩/截断重试/中断/持久化）留接口，App 首版不实现。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../db/session_db.dart';
import '../llm/openai_llm.dart';import '../tools/delegate_tool.dart' show currentAgentDepth;
import '../tools/memory_manager.dart';
import '../tools/model_tools.dart';
import 'context_compressor.dart';
import 'error_classifier.dart';
import 'iteration_budget.dart';
import 'retry_utils.dart';

/// P3 技能目录注入 provider（DSH 启示 4，v4 §7.4）：返回技能目录摘要块
/// （名 + 一句话描述），由 main.dart 注入（持有 SkillDiscovery）。
/// 可空——未注入时不注入技能目录，不影响主循环。
String Function()? skillCatalogProvider;

/// agent 主循环的结果。
class ConversationResult {
  final String? finalResponse;
  final List<Map<String, dynamic>> messages;
  final int apiCalls;
  final bool completed;
  final String? error;

  const ConversationResult({
    this.finalResponse,
    required this.messages,
    required this.apiCalls,
    required this.completed,
    this.error,
  });
}

/// Agent 主循环。
class MIXAgent {
  /// LLM 客户端。
  final OpenAiLlmClient llm;

  /// 系统提示词（三层 system_prompt 的简化：stable 身份提示）。
  final String systemPrompt;

  /// 工具 schema 提供者（默认取 Hermes getToolDefinitions）。
  final List<Map<String, dynamic>> Function()? toolDefinitionsProvider;

  /// 最大迭代次数（Hermes 默认 500）。
  final int maxIterations;

  /// 迭代预算。
  final IterationBudget iterationBudget;

  /// 取消标志：UI 调 [cancel] 后，循环在下一个检查点停止并返回已流式内容。
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// 防死循环：同一工具+同参数连续失败达到 [_loopFailThreshold] 次时注入
  /// 警告消息；注入 [_loopWarnLimit] 次后仍不收敛，直接中断本轮对话。
  String? _loopFailSignature; // 当前正在连续失败的签名（工具名|归一化参数）。
  int _loopFailCount = 0; // 同一签名连续失败次数。
  int _loopWarnCount = 0; // 当前循环已注入的警告轮数。
  static const int _loopFailThreshold = 3; // 同一签名连续失败 3 次 → 警告
  static const int _loopWarnLimit = 2; // 已警告 2 轮仍失败 → 中断

  /// 请求取消当前对话。
  void cancel() => _cancelled = true;

  /// 流式文本回调（UI 打字）。
  final void Function(String delta)? onDelta;

  /// reasoning_content 回调（DeepSeek 类先思考后输出，流式透传）。
  final void Function(String delta)? onReasoning;

  /// 工具调用事件回调（UI 显示工具执行）。
  final void Function(String name, String status)? onToolEvent;

  /// 记忆管理器（可选）。提供时，记忆块注入 system prompt。
  final MemoryManager? memoryManager;

  /// 上下文压缩器（可选）。提供时，超阈值自动压缩。
  final ContextCompressor? contextCompressor;

  /// 会话库（可选）。提供时，消息落库 + 跨重启恢复。
  final SessionDB? sessionDb;

  /// 会话 id（可选，落库时用）。
  final String? sessionId;

  /// 代理层数（0=主代理，N=第 N 层子代理）。工具执行段用它设置 delegate 工具
  /// 读取的深度，避免并行子代理共享全局 [currentAgentDepth] 时互相覆盖。
  final int agentDepth;

  MIXAgent({
    required this.llm,
    required this.systemPrompt,
    this.toolDefinitionsProvider,
    this.maxIterations = 500,
    this.onDelta,
    this.onReasoning,
    this.onToolEvent,
    this.memoryManager,
    this.contextCompressor,
    this.sessionDb,
    this.sessionId,
    this.agentDepth = 0,
  }) : iterationBudget = IterationBudget(maxIterations);

  /// 判断工具执行结果是否为错误（dispatch 失败约定：JSON 含非空 "error" 键，
  /// 部分 handler 也直接返回 {"error": ...}）。仅做字符串探测，不完整解析，
  /// 避免误判成功工具结果里的 "error" 字面量。
  bool _isToolErrorResult(String result) {
    if (result.startsWith('[TOOL_ERROR]')) {
      return true;
    }
    // 必须是 JSON 对象且顶层有 "error" 字段（值非 null/空）。
    if (!result.trimLeft().startsWith('{')) {
      return false;
    }
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'];
        return err is String && err.isNotEmpty;
      }
    } catch (_) {}
    return false;
  }

  /// 归一化失败签名：工具名 + 排序后的参数键值对。LLM 重试同一调用时可能
  /// 微调 JSON 的键顺序或空白，签名归一化后仍能命中循环检测。
  String _toolFailSignature(String name, String arguments) {
    final trimmed = arguments.trim();
    if (trimmed.isEmpty) return name;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        final keys = decoded.keys.toList()..sort();
        final buf = StringBuffer('$name|');
        for (final k in keys) {
          buf.write('$k=${jsonEncode(decoded[k])};');
        }
        return buf.toString();
      }
    } catch (_) {}
    return '$name|$trimmed';
  }

  /// 把分类后的 API 错误转成用户可读的中文提示。
  String _friendlyApiError(ClassifiedError classified, String raw) {
    switch (classified.reason) {
      case FailoverReason.auth:
        return '认证失败（API key 无效或过期），请检查设置里的 API key。';
      case FailoverReason.billing:
        return '额度不足或计费问题，请检查账户余额。';
      case FailoverReason.rateLimit:
        return '请求过于频繁被限流，已重试仍失败，请稍后再试。';
      case FailoverReason.overloaded:
        return '模型服务繁忙，请稍后再试。';
      case FailoverReason.payloadTooLarge:
        return '请求过大（上下文太长），请精简内容。';
      case FailoverReason.serverError:
        return '模型服务出错（5xx），已重试仍失败。';
      case FailoverReason.clientError:
        return '请求参数被拒绝（可能是消息格式问题）。';
      case FailoverReason.network:
        return '网络错误，请检查连接。';
      default:
        return raw;
    }
  }

  /// 发送前最终防线：清洗 messages 中残缺/错位的 assistant↔tool 消息对。
  ///
  /// OpenAI 兼容后端严格要求：assistant 消息声明 tool_calls 后，每个
  /// tool_call_id 必须紧跟对应的 tool 结果消息，且整批 tool 结果必须连续
  /// （中间不能插 user/system/其他 assistant），否则 400：
  /// - 孤儿 tool 消息（无前置 assistant 声明）→ "Messages with role 'tool'
  ///   must be a response to a preceding message with 'tool_calls'"
  /// - assistant 声明了 tool_calls 但无对应结果 → "insufficient tool
  ///   messages following tool_calls message"
  ///
  /// 残缺/错位可能来自历史遗留、上下文压缩修剪、并行工具结果间插入的 user
  /// 警告、中断/异常等任何路径。这里统一修复（**严格按顺序**清洗，不只看 id
  /// 是否存在——只查"存在"会让"声明在结果之后"或"结果被 user 消息打断"的
  /// 错位对漏网，同样被严格后端 400）：
  /// - tool 消息必须与其声明的 assistant 连续相邻且按声明顺序出现，否则丢弃
  /// - 非 tool 消息打断未消费完的批次 → 该批次剩余声明从 assistant 上剔除
  ///   （有文本则保留为纯文本 assistant；无文本整条丢弃）
  List<Map<String, dynamic>> sanitizeToolPairing(
    List<Map<String, dynamic>> messages,
  ) {
    if (messages.length < 2) return List.of(messages);
    final cleaned = <Map<String, dynamic>>[];
    var lastAssistantIdx = -1; // cleaned 中最近一个带未消费 tool_calls 的 assistant
    var openCalls = <String>[]; // 该批次尚未消费的 tool_call id（FIFO）

    // 批次被打断（非 tool 消息插入 / 列表结束）：未消费的声明从 assistant
    // 上剔除，避免留下"声明了却无结果"的残缺批次。
    void closeOpenBatch() {
      if (openCalls.isEmpty) return;
      if (lastAssistantIdx >= 0 && lastAssistantIdx < cleaned.length) {
        final m = cleaned[lastAssistantIdx];
        final rawCalls = m['tool_calls'] as List;
        final keep = <dynamic>[
          for (final c in rawCalls)
            if (c is Map<String, dynamic> &&
                !openCalls.contains(c['id'] as String? ?? ''))
              c,
        ];
        final content = m['content'] as String? ?? '';
        if (keep.isEmpty && content.trim().isEmpty) {
          cleaned.removeAt(lastAssistantIdx);
        } else if (keep.isEmpty) {
          cleaned[lastAssistantIdx] = {...m}..remove('tool_calls');
        } else {
          cleaned[lastAssistantIdx] = {...m, 'tool_calls': keep};
        }
      }
      openCalls = <String>[];
      lastAssistantIdx = -1;
    }

    for (final m in messages) {
      final role = m['role'];
      if (role == 'assistant' && m['tool_calls'] is List) {
        // 新批次开始：若上一批次未消费完，先清理（防声明交错）。
        closeOpenBatch();
        final rawCalls = m['tool_calls'] as List;
        final calls = <Map<String, dynamic>>[];
        final seen = <String>{};
        for (final c in rawCalls) {
          if (c is! Map<String, dynamic>) continue;
          final cid = c['id'] as String? ?? '';
          if (cid.isNotEmpty && seen.add(cid)) {
            calls.add(c);
          }
        }
        final content = m['content'] as String? ?? '';
        if (calls.isNotEmpty) {
          // 声明完整（id 齐全且不重复）或带文本 → 保留；否则整条丢弃。
          final declaredCount = rawCalls.whereType<Map<String, dynamic>>().length;
          if (calls.length == declaredCount || content.trim().isNotEmpty) {
            cleaned.add({...m, 'tool_calls': calls});
            lastAssistantIdx = cleaned.length - 1;
            openCalls = [for (final c in calls) c['id'] as String];
          }
          // else：声明残缺（空/重复 id）且无文本 → 整条丢弃。
        } else if (content.trim().isNotEmpty) {
          cleaned.add({...m}..remove('tool_calls'));
        }
        // else：无有效调用且无文本 → 整条丢弃。
        continue;
      }
      if (role == 'tool') {
        final tid = m['tool_call_id'];
        // 严格校验：id 非空、批次开放、且与批次头部 id 一致（按声明顺序，
        // 不得被其他消息打断）。孤儿/错位/重复的 tool 消息一律丢弃。
        if (tid is String &&
            tid.isNotEmpty &&
            openCalls.isNotEmpty &&
            openCalls.first == tid) {
          cleaned.add(m);
          openCalls.removeAt(0);
          if (openCalls.isEmpty) {
            lastAssistantIdx = -1;
          }
        }
        continue;
      }
      // 非 tool 消息：打断开放批次 → 清理该批次未消费的声明。
      closeOpenBatch();
      cleaned.add(m);
    }
    // 列表末尾仍有未消费完的批次 → 清理。
    closeOpenBatch();
    // 返回新 list：原 list 可能是测试/调用处推断的更窄类型（如
    // List<Map<String,String>>），原地 addAll(List<Map<String,dynamic>>)
    // 会触发运行时 "not a subtype" TypeError。
    return cleaned;
  }

  /// 把收集到的防死循环警告统一追加为 user 消息（内存 + 落库）。
  ///
  /// 只在**整批工具结果回填完毕之后**调用，避免 user 消息插进同一批
  /// assistant(tool_calls) 与其 tool 结果之间（严格后端会 400
  /// "Messages with role 'tool' must be a response..."）。
  Future<void> _flushUserWarns(
    List<Map<String, dynamic>> messages,
    List<String> warns,
    SessionDB? sdb,
    String? sid,
  ) async {
    if (warns.isEmpty) return;
    for (final w in warns) {
      messages.add({'role': 'user', 'content': w});
      if (sdb != null && sid != null) {
        await sdb.appendMessage(sid, role: 'user', content: w);
      }
    }
    warns.clear();
  }

  /// 运行一次完整对话（带工具调用直到完成）。
  ///
  /// [conversationHistory] 之前对话消息（可选）。
  Future<ConversationResult> runConversation(
    String userMessage, {
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    // ── Prologue：组装 messages ──
    // 有记忆管理器时，把冻结快照 + 记忆检索拼进 system prompt（Hermes 记忆注入
    // + v4 §5 prefetchRecall：热词检索记忆文档，<memory-context> 围栏注入）。
    // 有界等待 8s（Hermes prefetch_all 范式）：超时跳过本轮，不阻塞对话。
    memoryManager?.onTurnStart();
    var effectiveSystem = systemPrompt;
    // P3 技能目录注入（v4 §7.4）：技能名+一句话并入 volatile 层，
    // 避免 agent 想不起可用技能（渐进式披露的目录版）。
    try {
      final skillBlock = skillCatalogProvider?.call();
      if (skillBlock != null && skillBlock.isNotEmpty) {
        effectiveSystem = '$effectiveSystem\n\n$skillBlock';
      }
    } catch (_) {}
    String memoryBlock;
    try {
      memoryBlock = await (memoryManager?.prefetchRecall(userMessage) ??
              Future.value(''))
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      memoryBlock = ''; // 超时/异常 → 跳过记忆预取（宁可缺，不可杂）。
    }
    if (memoryBlock.isNotEmpty) {
      effectiveSystem = '$effectiveSystem\n\n$memoryBlock';
    }
    var messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': effectiveSystem},
      ...?conversationHistory,
      {'role': 'user', 'content': userMessage},
    ];

    debugPrint('[Agent] runConversation 开始');
    // ── 会话落库：恢复历史 + 追加当前 user 消息 ──
    final sdb = sessionDb;
    final sid = sessionId;
    if (sdb != null && sid != null) {
      // 从库恢复历史（若该 session 已有消息）。
      // DB 行含内部列（id/session_id/timestamp/active 等），必须转成
      // OpenAI 消息格式再发给 LLM，否则严格后端会 400。
      final stored = await sdb.getMessages(sid);
      if (stored.isNotEmpty) {
        // 第一遍：收集 DB 中所有 tool 结果消息的 tool_call_id，用于判断
        // assistant 声明的 tool_calls 是否有对应结果。残缺对（assistant 声明
        // 了 tool_calls 但无 tool 结果跟进）会导致 OpenAI 兼容后端 400
        // "insufficient tool messages following tool_calls"。
        final answeredIds = <String>{};
        for (final m in stored) {
          if (m['role'] == 'tool') {
            final tid = m['tool_call_id'];
            if (tid is String && tid.isNotEmpty) answeredIds.add(tid);
          }
        }
        final restored = <Map<String, dynamic>>[];
        // 前面 assistant 声明、等待 tool 结果消费的 tool_call id。
        final pendingIds = <String>{};
        for (final m in stored) {
          final role = m['role'] as String? ?? 'user';
          final rawContent = m['content'] as String? ?? '';
          if (role == 'tool') {
            final tid = m['tool_call_id'] as String? ?? '';
            // 孤儿 tool 消息（前面没有 assistant(tool_calls) 声明）直接丢弃，
            // 否则 OpenAI 兼容后端 400（tool 消息必须紧跟 assistant 声明）。
            if (tid.isEmpty || !pendingIds.remove(tid)) {
              continue;
            }
            restored.add({
              'role': 'tool',
              'tool_call_id': tid,
              'name': m['tool_name'] ?? '',
              'content': rawContent.isEmpty ? ' ' : rawContent,
            });
            continue;
          }
          final msg = <String, dynamic>{
            'role': role,
            // assistant 消息 content 兜底空串（防 "content or tool_calls must
            // be sent"；tool 消息需空 content 用于占位）。
            'content': role == 'tool' && rawContent.isEmpty
                ? ' '
                : rawContent,
          };
          if (role == 'assistant' && m['tool_calls'] is List) {
            final rawCalls = m['tool_calls'] as List;
            final validCalls = <Map<String, dynamic>>[];
            final missingIds = <String>[];
            for (final c in rawCalls) {
              if (c is! Map<String, dynamic>) continue;
              final cid = c['id'] as String? ?? '';
              // 空 id 无法与 tool 结果可靠配对 → 视为残缺；非空且存在对应
              // tool 结果 → 有效调用，登记进 pending 供后续 tool 消息消费。
              if (cid.isNotEmpty && answeredIds.contains(cid)) {
                validCalls.add(c);
                pendingIds.add(cid);
              } else {
                missingIds.add(cid);
              }
            }
            if (validCalls.isEmpty && rawContent.trim().isEmpty) {
              // 全部残缺且无文本 → 整条丢弃，避免空 assistant 消息 400。
              continue;
            }
            if (validCalls.isNotEmpty) {
              msg['tool_calls'] = validCalls;
            }
            // 全部残缺但有文本 → 保留为纯文本 assistant（不带 tool_calls）。
            restored.add(msg);
            // 残缺调用补占位 tool 消息，紧跟其 assistant 声明之后
            // （OpenAI 格式要求：assistant(tool_calls) 后必须紧跟 tool 结果）。
            for (final cid in missingIds) {
              restored.add({
                'role': 'tool',
                'tool_call_id': cid,
                'name': '',
                'content': '（工具调用中断，无结果）',
              });
            }
            continue;
          }
          restored.add(msg);
        }
        messages.insertAll(1, restored);
      }
      await sdb.appendMessage(sid, role: 'user', content: userMessage);
    }

    var apiCallCount = 0;
    String? finalResponse;
    var failed = false;

    while (apiCallCount < maxIterations &&
        iterationBudget.remaining > 0 &&
        !_cancelled) {
      apiCallCount++;

      // 消耗迭代预算。
      if (!iterationBudget.consume()) {
        break;
      }

      // ── 上下文压缩：超阈值时用 LLM 摘要中间段 ──
      final cc = contextCompressor;
      if (cc != null) {
        final currentTokens = estimateMessagesTokens(messages);
        if (cc.shouldCompress(currentTokens)) {
          final compressed = await cc.compress(messages);
          if (compressed.length != messages.length) {
            // 替换为压缩后消息（保留历史语义）。
            messages
              ..clear()
              ..addAll(compressed);
          }
        }
      }

      // ── 组包：api_messages + tools ──
      final tools = toolDefinitionsProvider != null
          ? toolDefinitionsProvider!()
          : getToolDefinitions(quietMode: true);

      // ── LLM 调用（带错误分类 + 重试） ──
      // 发送前清洗残缺消息对（覆盖历史恢复、压缩、中断等所有残留路径），
      // 防止严格后端 400 "insufficient tool messages following tool_calls"。
      messages = sanitizeToolPairing(messages);
      LlmTurnResult turn;
      const maxRetries = 3;
      var attempt = 0;
      var lastError = '';
      while (true) {
        try {
          final result = await llm.chatStream(
            messages: messages,
            tools: tools,
            onDelta: onDelta,
            onReasoning: onReasoning,
            isCancelled: () => _cancelled,
          );
          turn = result;
          break;
        } catch (e) {
          // 取消时不重试，直接返回已流式内容。
          if (_cancelled) {
            return ConversationResult(
              finalResponse: null,
              messages: messages,
              apiCalls: apiCallCount,
              completed: false,
              error: 'cancelled',
            );
          }
          // 分类错误，决定是否重试。
          final classified = classifyApiError(e);
          lastError = e.toString();
          debugPrint('[Agent] API 调用失败 (attempt $attempt): $lastError');
          if (!classified.retryable || attempt >= maxRetries) {
            failed = true;
            final friendly = _friendlyApiError(classified, lastError);
            return ConversationResult(
              finalResponse: 'API 调用失败：$friendly\n（原始错误：$lastError）',
              messages: messages,
              apiCalls: apiCallCount,
              completed: false,
              error: lastError,
            );
          }
          // 退避后重试。
          attempt++;
          final delay = jitteredBackoff(
            attempt,
            baseDelay: 2.0,
            maxDelay: 15.0,
          );
          await Future<void>.delayed(
            Duration(milliseconds: (delay * 1000).toInt()),
          );
        }
      }

      // 部分后端不返回 tool_call id —— 先合成稳定 id，保证 assistant 消息里
      // 的 tool_calls 与后续 tool 结果回填的 tool_call_id 一致（否则恢复历史
      // 时配对不上，OpenAI 兼容后端会 400）。
      for (var ti = 0; ti < turn.toolCalls.length; ti++) {
        final tc = turn.toolCalls[ti];
        if (tc.id.isEmpty) {
          tc.id = 'call_${apiCallCount}_$ti';
        }
      }
      // 把 assistant turn 追加进消息历史。
      messages.add(turn.toAssistantMessage());

      // 落库 assistant 消息。
      if (sdb != null && sid != null) {
        final toolCallsJson = turn.toolCalls.isNotEmpty
            ? jsonEncode([for (final tc in turn.toolCalls) tc.toJson()])
            : null;
        await sdb.appendMessage(
          sid,
          role: 'assistant',
          content: turn.content,
          toolCalls: toolCallsJson,
        );
      }

      // ── 有 tool_calls → 执行并回填 ──
      if (turn.hasToolCalls) {
        if (_cancelled) {
          // 用户中断：assistant(tool_calls) 已入列/落库，必须给每个 tool_call
          // 补占位 tool 结果，否则留下残缺对 → 后续请求 400。
          for (var ti = 0; ti < turn.toolCalls.length; ti++) {
            final pTc = turn.toolCalls[ti];
            final pId = pTc.id.isEmpty ? 'call_${apiCallCount}_$ti' : pTc.id;
            const placeholder = '（用户中断，工具未执行）';
            messages.add({
              'role': 'tool',
              'tool_call_id': pId,
              'name': pTc.name,
              'content': placeholder,
            });
            if (sdb != null && sid != null) {
              await sdb.appendMessage(
                sid,
                role: 'tool',
                content: placeholder,
                toolCallId: pId,
                toolName: pTc.name,
              );
            }
          }
          break;
        }
        // 防死循环警告先收集，等本批所有 tool 结果回填完毕再统一注入：
        // OpenAI 兼容后端要求 assistant(tool_calls) 的 tool 结果连续排列，
        // 中间插 user 警告会把后续 tool 结果变成孤儿 → 400 "Messages with
        // role 'tool' must be a response to a preceding message with
        // 'tool_calls'"。
        final pendingWarns = <String>[];
        for (var ti = 0; ti < turn.toolCalls.length; ti++) {
          final tc = turn.toolCalls[ti];
          Map<String, dynamic> args;
          try {
            final decoded = tc.arguments.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(tc.arguments);
            args = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
          } catch (_) {
            args = <String, dynamic>{};
          }

          onToolEvent?.call(tc.name, 'running');
          // 工具执行段：把当前 agent 的深度临时设给 delegate 工具读取
          // （_handleDelegate 在首个 await 前同步读 currentAgentDepth）。
          // 用 try/finally 恢复，并行子代理互不覆盖。
          final savedDepth = currentAgentDepth;
          currentAgentDepth = agentDepth;
          String result;
          try {
            result = await handleFunctionCall(tc.name, args);
          } catch (e, st) {
            // 工具执行异常也必须回填 tool 结果，否则 assistant(tool_calls)
            // 之后缺 tool 消息 → OpenAI 兼容后端 400。
            result = jsonEncode({'error': 'tool execution failed: $e'});
            debugPrint('[Agent] 工具 ${tc.name} 执行异常: $e\n$st');
          } finally {
            currentAgentDepth = savedDepth;
          }
          onToolEvent?.call(tc.name, 'done');

          // 工具 id 缺失时合成（部分后端不返回 id）。
          final effectiveId =
              tc.id.isEmpty ? 'call_${apiCallCount}_$ti' : tc.id;

          messages.add({
            'role': 'tool',
            'tool_call_id': effectiveId,
            'name': tc.name, // OpenAI 兼容端要求 tool 消息带 name。
            'content': result,
          });
          // 落库 tool 消息。
          if (sdb != null && sid != null) {
            await sdb.appendMessage(
              sid,
              role: 'tool',
              content: result,
              toolCallId: effectiveId,
              toolName: tc.name,
            );
          }

          // ── 防死循环：同一工具+同参数连续失败 → 警告，仍不收敛则中断 ──
          // 警告先收进 pendingWarns，等本批所有 tool 结果回填后再统一注入：
          // 保证消息流为 assistant(tool_calls) → tool(result)×N → user(warn)，
          // 符合 OpenAI 格式（user 消息不允许插在 assistant 的 tool_calls
          // 与其 tool 结果之间，并行调用时在循环内注入会把后续 tool 结果变孤儿）。
          final isToolError = _isToolErrorResult(result);
          if (isToolError) {
            final signature = _toolFailSignature(tc.name, tc.arguments);
            if (_loopFailSignature != signature) {
              // 换了失败点 → 重新计数（警告不跨失败模式累计）。
              _loopFailSignature = signature;
              _loopFailCount = 1;
              _loopWarnCount = 0;
            } else {
              _loopFailCount++;
            }
            if (_loopFailCount >= _loopFailThreshold) {
              _loopFailCount = 0; // 本轮已处理，重新计数（签名保持，继续追踪同循环）。
              if (_loopWarnCount >= _loopWarnLimit) {
                // 已警告过 _loopWarnLimit 轮仍失败 → 先落库待注入警告，再中断。
                await _flushUserWarns(messages, pendingWarns, sdb, sid);
                final loopMsg = '工具 ${tc.name} 反复调用失败，已自动中止以防死循环。'
                    '请检查参数或改用其他方式。';
                if (sdb != null && sid != null) {
                  await sdb.appendMessage(
                    sid,
                    role: 'assistant',
                    content: loopMsg,
                  );
                }
                return ConversationResult(
                  finalResponse: loopMsg,
                  messages: messages,
                  apiCalls: apiCallCount,
                  completed: false,
                  error: 'tool_loop_detected: ${tc.name}',
                );
              }
              _loopWarnCount++;
              pendingWarns.add('⚠️ 工具 ${tc.name} 已连续失败 $_loopFailThreshold 次'
                  '（参数相同）。请停止重试该调用，先检查参数/路径是否合理，'
                  '或改用其他工具/直接回答用户。');
            }
          } else {
            // 成功 → 清空失败签名与警告计数，避免历史失败影响后续。
            _loopFailSignature = null;
            _loopFailCount = 0;
            _loopWarnCount = 0;
          }
        }
        // 本批所有工具结果已连续回填，统一注入防死循环警告（内存 + 落库）。
        await _flushUserWarns(messages, pendingWarns, sdb, sid);
        continue; // 有工具调用 → 继续循环（模型看到工具结果再决定）
      }

      // ── 无 tool_calls → final_response ──
      finalResponse = turn.content ?? '';
      break;
    }

    // 预算耗尽但未完成。
    if (finalResponse == null && !failed) {
      if (_cancelled) {
        return ConversationResult(
          finalResponse: '（已停止生成）',
          messages: messages,
          apiCalls: apiCallCount,
          completed: false,
        );
      }
      return ConversationResult(
        finalResponse: 'Iteration budget exhausted (${iterationBudget.used}/'
            '${iterationBudget.maxTotal} iterations used)',
        messages: messages,
        apiCalls: apiCallCount,
        completed: false,
      );
    }

    return ConversationResult(
      finalResponse: finalResponse,
      messages: messages,
      apiCalls: apiCallCount,
      completed: finalResponse != null,
    );
  }
}
