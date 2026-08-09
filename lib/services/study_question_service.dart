/// 多阶段精炼出题管线（Phase 0-6）。
///
/// 模仿人类出题：选点取材(0) → 出雏形(1) → 加复杂度×1-4轮(2) → 独立批判(3)
/// → 回头(4) → 优化精炼(5) → 终审(6)。复杂度轮不维持答案一致。
///
/// 每阶段 LLM 调用 token 有界（只带当前题目状态 + 阶段指令，不重发全量历史），
/// 前置子查询全纯本地（SQLite + 文件读）。含 cancel 检查 + 总时长超时。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../llm/openai_llm.dart';
import 'study_engine.dart';

/// 出题阶段（供 UI 进度显示）。
enum StudyStage {
  loading, // 选点取材
  drafting, // 出雏形
  complexity, // 加复杂度
  critique, // 独立批判
  retrying, // 回头重炼
  refining, // 优化精炼
  finalCheck, // 终审
  done,
}

/// 出题进度回调（UI 显示"审题中→加复杂度 2/4→批判中→…"）。
typedef StudyProgress = void Function(StudyStage stage, String detail);

/// 出题管线返回：题目 JSON 或错误。
class QuestionResult {
  final String? json; // 成功：题目 JSON 字符串。
  final String? error;

  QuestionResult({this.json, this.error});
}

/// 多阶段出题管线服务。
class StudyQuestionService {
  final OpenAiLlmClient llm;
  final StudyEngine engine;
  final String subjectLibraryDir; // subject_library 根目录。
  final String profilePath; // 0_profile.md 路径。
  final String skillPath; // question-design/SKILL.md 路径。
  final bool Function()? isCancelled;

  /// 阶段进度回调。
  final StudyProgress? onProgress;

  StudyQuestionService({
    required this.llm,
    required this.engine,
    required this.subjectLibraryDir,
    required this.profilePath,
    required this.skillPath,
    this.isCancelled,
    this.onProgress,
  });

  bool get _cancelled => isCancelled?.call() ?? false;

  /// 每阶段调用 LLM（非流式，带 maxTokens + 总超时）。
  Future<String> _llmOnce(
    String system,
    String user, {
    int maxTokens = 1200,
  }) async {
    if (_cancelled) throw Exception('cancelled');
    final result = await llm
        .chat(
          messages: [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': user},
          ],
          maxTokens: maxTokens,
        )
        .timeout(const Duration(seconds: 60));
    if (_cancelled) throw Exception('cancelled');
    return result.content ?? '';
  }

  /// 更新学生画像（0_profile.md）：读旧画像 + LLM 合并本次观察 + 写回。
  ///
  /// [studentNote] 是 agent 观察到的本次作答表现（对/错/混淆点/进步等）。
  /// 不做"做错才重写"的精细触发——agent 觉得有新情况就调用。
  /// [reasoningEffort] 走设置里"画像更新"流程的思考强度档。
  Future<String> updateProfile(String studentNote,
      {String? reasoningEffort}) async {
    final existing = _readFileSafe(profilePath);
    final result = await llm.chat(
      messages: [
        {
          'role': 'system',
          'content': '你是学生画像管理员。你维护一份学生学科画像（Markdown），'
              '它会被出题老师读取来针对性地出题。画像要简洁、聚焦：'
              '记录学生的强项、弱项、常错概念、混淆点、学习风格。'
              '不要编造未观察到的内容，把新观察合并进旧画像，结构保持一致。',
        },
        {
          'role': 'user',
          'content': '现有画像：\n${existing.isEmpty ? '(无画像记录)' : existing}\n\n'
              '本次观察到的学生表现：\n$studentNote\n\n'
              '输出更新后的完整画像（纯 Markdown，不要用代码块包裹）：',
        },
      ],
      maxTokens: 1500,
      reasoningEffort: reasoningEffort,
    );
    final updated = result.content ?? '';
    final trimmed = updated.trim();
    if (trimmed.isEmpty) {
      return '画像更新失败：LLM 返回空内容';
    }
    try {
      final f = File(profilePath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(trimmed);
      return '画像已更新';
    } catch (e) {
      return '画像写入失败: $e';
    }
  }

  /// 从 LLM 输出提取 JSON（容忍被 markdown fence 包裹 / 前后杂文字）。
  Map<String, dynamic>? _extractJson(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 读文件（容错）。
  String _readFileSafe(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.readAsStringSync() : '';
    } catch (_) {
      return '';
    }
  }

  /// 找知识点讲义文件：subject_library/{subject}/{kp}.md（按文件名匹配）。
  String _findNoteForKp(KpInfo kp) {
    try {
      final root = Directory(subjectLibraryDir);
      if (!root.existsSync()) return '';
      // 遍历找名字含知识点名或目录名匹配的 .md。
      final walk = root.listSync(recursive: true, followLinks: false);
      final candidates = <File>[];
      for (final e in walk) {
        if (e is File && e.path.endsWith('.md')) {
          candidates.add(e);
        }
      }
      // 优先文件名/目录名精确含 kp.name 的。
      for (final f in candidates) {
        if (f.path.contains(kp.name)) return _readFileSafe(f.path);
      }
      // 兜底：任何包含该科目名的。
      for (final f in candidates) {
        if (f.path.contains(kp.subjectName)) return _readFileSafe(f.path);
      }
      // 最后：取同名目录下的 SKILL 或第一个。
      for (final f in candidates) {
        if (f.path.contains(kp.name) ||
            f.path.contains(_toFileName(kp.name))) {
          return _readFileSafe(f.path);
        }
      }
    } catch (_) {}
    return '';
  }

  String _toFileName(String s) => s.replaceAll(' ', '_');

  /// 主入口：为知识点 [kpId] 出一题。
  Future<QuestionResult> generate(int kpId, {String? targetDifficulty}) async {
    // ── Phase 0 选点取材（纯本地，零 LLM） ──
    onProgress?.call(StudyStage.loading, '选点取材');
    final kps = await engine.listKps();
    KpInfo? kp;
    for (final k in kps) {
      if (k.id == kpId) kp = k;
    }
    if (kp == null) return QuestionResult(error: '知识点不存在: $kpId');

    final recent = await engine.recentQuestions(kpId);
    final note = _findNoteForKp(kp);
    var profile = _readFileSafe(profilePath);
    final skill = _readFileSafe(skillPath);
    final mastery = kp.mastery;
    // 画像不做长度上限会击穿 taskCard 的 ≤1K token 预算，截断保护。
    if (profile.length > 2000) profile = profile.substring(0, 2000);

    // 难度档：优先入参，否则由掌握度推（低掌握→简单）。
    final difficulty = targetDifficulty ??
        (mastery < 0.4
            ? 'easy'
            : mastery < 0.7
                ? 'medium'
                : 'hard');

    // 出题任务卡（≤1K token）。
    final taskCard = '''
知识点: ${kp.subjectName} / ${kp.name}
目标难度: $difficulty
掌握度(近15题正确率): ${(mastery * 100).toStringAsFixed(0)}%
学生画像:
${profile.isEmpty ? '(无画像记录)' : profile}
讲义素材:
${note.isEmpty ? '(无讲义)' : note.substring(0, note.length > 3000 ? 3000 : note.length)}
最近出过的题(严禁雷同, 换数字也不算新题):
${recent.isEmpty ? '(无)' : recent.map((q) => '- ${q.content} [答案${q.answer}]').join('\n')}
''';

    // ── Phase 1 出雏形 ──
    onProgress?.call(StudyStage.drafting, '出雏形');
    final draftText = await _llmOnce(
      '你是出题老师。${skill.isNotEmpty ? '参考出题方法论：\n${skill.substring(0, skill.length > 2500 ? 2500 : skill.length)}' : ''}',
      '根据出题任务卡，先出这道题最朴素的雏形（允许粗糙、答案简单）。'
          '严格输出 JSON: {"question","options":[4个],"answer":"A","explanation"}。\n\n$taskCard',
    );
    var questionJson = _extractJson(draftText);
    if (questionJson == null) {
      return QuestionResult(error: '雏形生成失败：无法解析输出');
    }

    // ── Phase 2 加复杂度 × N 轮（N 由难度档定） ──
    final roundsByDifficulty = {'easy': 1, 'medium': 2, 'hard': 4};
    final rounds = roundsByDifficulty[difficulty] ?? 2;
    final usedDims = <String>{};
    const allDims = [
      '多步推理', '条件分支', '数据干扰', '概念陷阱', '情境综合', '反向设问',
    ];

    for (var r = 0; r < rounds; r++) {
      if (_cancelled) return QuestionResult(error: 'cancelled');
      onProgress?.call(StudyStage.complexity, '加复杂度 ${r + 1}/$rounds');
      // 挑一个未用过的维度。
      String? dim;
      for (final d in allDims) {
        if (!usedDims.contains(d)) {
          dim = d;
          usedDims.add(d);
          break;
        }
      }
      if (dim == null) dim = '多步推理';
      final curJson = jsonEncode(questionJson);
      final upText = await _llmOnce(
        '你是出题老师，正在用「$dim」这个维度给题目加复杂度。'
            '${skill.isNotEmpty ? '参考该维度定义与示例（见方法论）' : ''}'
            '注意：不维持答案一致，答案可随题演化，但要保证答案唯一、无歧义。',
        '当前题目 JSON:\n$curJson\n\n'
            '用「$dim」维度升级这道题（加一步推理/加条件/加陷阱/换情境/反向设问）。'
            '严格输出升级后的 JSON: {"question","options":[4],"answer","explanation"}。'
            '不要说明，直接输出 JSON。',
      );
      final upJson = _extractJson(upText);
      if (upJson == null) {
        return QuestionResult(error: '复杂度轮 $dim 失败：无法解析输出');
      }
      questionJson = upJson;
    }

    // ── Phase 3 独立批判 + Phase 4 回头 ──
    String? critiqueNote;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_cancelled) return QuestionResult(error: 'cancelled');
      onProgress?.call(
          attempt == 0 ? StudyStage.critique : StudyStage.retrying,
          attempt == 0 ? '独立批判' : '回头重炼 ${attempt + 1}');
      final curJson = jsonEncode(questionJson);
      final critText = await _llmOnce(
        '你是出题组长，以独立视角审这道题。${skill.isNotEmpty ? '按方法论批判清单逐项审（样板题/难度匹配/干扰项有效/歧义/撞题/画像针对性）' : ''}',
        '审这道题:\n$curJson\n\n'
            '返回 JSON: {"pass": true/false, "reasons": ["..."]}。'
            '不通过时必须给出 2-5 条具体原因（按方法论清单）。',
        maxTokens: 800,
      );
      final crit = _extractJson(critText);
      final pass = crit?['pass'] == true;
      if (pass) break;
      critiqueNote = (crit?['reasons'] as List?)?.join('; ') ?? '批判未通过';
      if (attempt == 2) break; // 循环封顶。

      // 回 Phase 2 补一轮复杂度（按批判原因）。
      onProgress?.call(StudyStage.complexity, '按批判补复杂度');
      final curJson2 = jsonEncode(questionJson);
      final fixText = await _llmOnce(
        '你是出题老师，你的题没通过组长批判。按批判意见修订题目。不维持答案一致。',
        '批判意见: $critiqueNote\n\n当前题:\n$curJson2\n\n'
            '修订后严格输出 JSON: {"question","options":[4],"answer","explanation"}。',
      );
      final fixJson = _extractJson(fixText);
      if (fixJson == null) return QuestionResult(error: '修订失败：无法解析输出');
      questionJson = fixJson;
    }

    // ── Phase 5 优化精炼 ──
    onProgress?.call(StudyStage.refining, '优化精炼');
    final refineText = await _llmOnce(
      '你是出题老师，做最后精炼：打磨题干措辞、让干扰项更自然更像真错、'
          '让解析讲清"为什么对、干扰项为什么错"。不改变答案语义。',
      '题目 JSON:\n${jsonEncode(questionJson)}\n\n'
          '精炼后严格输出 JSON: {"question","options":[4],"answer","explanation"}。',
    );
    final refineJson = _extractJson(refineText);
    if (refineJson != null) questionJson = refineJson;

    // ── Phase 6 终审（规则 + LLM） ──
    onProgress?.call(StudyStage.finalCheck, '终审');
    // 非空局部变量：questionJson 是 var 且反复赋值，Dart 流分析无法收窄。
    final current = questionJson ?? <String, dynamic>{};
    // 规则校验。
    final options = (current['options'] as List?)?.cast<String>() ?? [];
    final answer = (current['answer'] as String? ?? '').toUpperCase();
    final q = current['question'] as String? ?? '';
    if (options.length != 4 ||
        !'ABCD'.contains(answer) ||
        q.trim().isEmpty) {
      return QuestionResult(error: '终审规则失败：题目结构不合法');
    }
    final finalText = await _llmOnce(
      '你是最终审核员。确认题目解析完整、讲解清晰、答案与选项匹配、无歧义。'
          '若通过返回 JSON {"pass":true}；否则返回 {"pass":false,"reasons":[...]}。',
      '题目:\n${jsonEncode(current)}',
      maxTokens: 400,
    );
    final finalCheck = _extractJson(finalText);
    final finalPass = finalCheck?['pass'] == true;
    var finalCurrent = current;
    if (!finalPass) {
      // 终审不过 → 最后精炼一次。
      onProgress?.call(StudyStage.refining, '终审不过，再精炼');
      final lastText = await _llmOnce(
        '你是出题老师，终审没通过，按原因最后修订。',
        '原因: ${(finalCheck?['reasons'] as List?)?.join('; ')}\n\n题目:\n${jsonEncode(finalCurrent)}\n\n'
            '修订后严格输出 JSON。',
      );
      final lastJson = _extractJson(lastText);
      if (lastJson != null) finalCurrent = lastJson;
    }

    // 落库。
    final finalOptions =
        (finalCurrent['options'] as List?)?.cast<String>() ?? [];
    final finalAnswer = (finalCurrent['answer'] as String? ?? '').toUpperCase();
    if (finalOptions.length == 4 && 'ABCD'.contains(finalAnswer)) {
      final qid = await engine.insertQuestion(
        kpId: kpId,
        content: finalCurrent['question'] as String? ?? '',
        answer: finalAnswer,
        options: finalOptions,
        explanation: finalCurrent['explanation'] as String? ?? '',
      );
      onProgress?.call(StudyStage.done, '完成');
      return QuestionResult(
          json: jsonEncode({...finalCurrent, 'question_id': qid}));
    }
    return QuestionResult(error: '终审失败：题目结构不合法');
  }
}
